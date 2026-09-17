#include "jit26_arena.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

#if defined(__APPLE__) && defined(__aarch64__)

#include <unistd.h>
#include <sys/syscall.h>
#include <mach/mach.h>
#include <libkern/OSCacheControl.h>
#include <signal.h>
#include <setjmp.h>

#ifndef SYS_csops
#define SYS_csops 169
#endif

#define CS_OPS_STATUS_OP 0
#define CS_DEBUGGED_FLAG 0x10000000u

// Play--CodeGen uses 64 MB for its arena. A RandomX JitCompilerA64 needs
// CodeSize + CalcDatasetItemSize (~64 KB), so this holds every VM we can
// realistically run plus the dataset-init compiler.
#define ARENA_SIZE  (64u * 1024u * 1024u)

// iOS 26 grants execute permission one 16K page at a time.
#define ARENA_ALIGN (16u * 1024u)

typedef struct FreeBlock {
	size_t offset;
	size_t size;
	struct FreeBlock* next;
} FreeBlock;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static uint8_t*  g_rx    = NULL;   // execute-only, from the debugger
static uint8_t*  g_rw    = NULL;   // writable alias of the same pages
static size_t    g_bump  = 0;
static FreeBlock* g_free = NULL;
static int       g_state = 0;      // 0 untried, 1 ready, -1 failed
static int       g_reason = RX_JIT26_UNTRIED;
static int       g_attempts = 0;

// The script attaches with vAttach after the app has already started, so an
// early request can arrive before anything is listening. Retry a bounded
// number of times (the caller polls every 2s) before giving up for good.
#define MAX_TRAP_RETRIES 20

static size_t align_up(size_t n)
{
	return (n + (ARENA_ALIGN - 1)) & ~(size_t)(ARENA_ALIGN - 1);
}

static int debugger_attached(void)
{
	uint32_t csflags = 0;
	if (syscall(SYS_csops, getpid(), CS_OPS_STATUS_OP, &csflags, sizeof(csflags)) != 0)
		return 0;
	return (csflags & CS_DEBUGGED_FLAG) ? 1 : 0;
}

static sigjmp_buf g_trap_jmp;
static volatile sig_atomic_t g_trap_armed = 0;

static void trap_handler(int sig)
{
	(void)sig;
	if (g_trap_armed) {
		g_trap_armed = 0;
		siglongjmp(g_trap_jmp, 1);
	}
	_exit(1);
}

// x0 = requested address (must be NULL to get a fresh grant), x1 = length.
// x16 = 1 selects the debugger's "prepare region" command.
__attribute__((naked, noinline))
static void* jit26_request_region(void* addr, size_t len)
{
	__asm__ volatile(
		"mov x16, #1\n"
		"brk #0xf00d\n"
		"ret\n"
	);
}

// Caller must hold g_lock.
static int arena_init_locked(void)
{
	if (g_state != 0)
		return g_state == 1;

	// Not a failure, just not yet: StikDebug attaches after launch, so leave
	// the state untried so a later probe retries.
	if (!debugger_attached()) {
		g_reason = RX_JIT26_NO_DEBUGGER;
		return 0;
	}

	// From here on a failure is permanent - each retry costs another brk.
	g_state = -1;

	// A debugger that does not speak this protocol leaves the brk unhandled
	// and it arrives as SIGTRAP. Catch it so an unsupported debugger degrades
	// to the interpreter instead of killing the process.
	struct sigaction trap_action;
	struct sigaction saved_action;
	memset(&trap_action, 0, sizeof(trap_action));
	trap_action.sa_handler = trap_handler;
	sigemptyset(&trap_action.sa_mask);
	trap_action.sa_flags = 0;
	if (sigaction(SIGTRAP, &trap_action, &saved_action) != 0) {
		g_reason = RX_JIT26_REFUSED;
		return 0;
	}

	void* rx = NULL;
	int trapped = 0;
	if (sigsetjmp(g_trap_jmp, 1) == 0) {
		g_trap_armed = 1;
		rx = jit26_request_region(NULL, ARENA_SIZE);
	}
	else {
		trapped = 1;
	}
	g_trap_armed = 0;
	sigaction(SIGTRAP, &saved_action, NULL);

	if (rx == NULL || rx == (void*)-1) {
		// Trapped means nothing answered the breakpoint: the debugger is
		// attached but no JIT script is loaded on its side.
		if (trapped) {
			g_reason = RX_JIT26_NO_SCRIPT;
			if (++g_attempts < MAX_TRAP_RETRIES)
				g_state = 0;  // unresolved, not failed: let a later poll retry
		}
		else {
			g_reason = RX_JIT26_REFUSED;
		}
		return 0;
	}

	vm_address_t rw = 0;
	vm_prot_t cur = 0;
	vm_prot_t max = 0;
	kern_return_t kr = vm_remap(mach_task_self(), &rw, ARENA_SIZE, 0,
	                            VM_FLAGS_ANYWHERE, mach_task_self(),
	                            (vm_address_t)rx, FALSE, &cur, &max,
	                            VM_INHERIT_NONE);
	if (kr != KERN_SUCCESS) {
		g_reason = RX_JIT26_REMAP_FAILED;
		return 0;
	}

	if (vm_protect(mach_task_self(), rw, ARENA_SIZE, FALSE,
	               VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS) {
		vm_deallocate(mach_task_self(), rw, ARENA_SIZE);
		g_reason = RX_JIT26_REMAP_FAILED;
		return 0;
	}

	g_rx = (uint8_t*)rx;
	g_rw = (uint8_t*)rw;
	g_bump = 0;
	g_state = 1;
	g_reason = RX_JIT26_READY;
	return 1;
}

int rx_jit26_is_ready(void)
{
	pthread_mutex_lock(&g_lock);
	int ready = (g_state == 1);
	pthread_mutex_unlock(&g_lock);
	return ready;
}

int rx_jit26_status(void)
{
	pthread_mutex_lock(&g_lock);
	arena_init_locked();
	int reason = g_reason;
	pthread_mutex_unlock(&g_lock);
	return reason;
}

int rx_jit26_available(void)
{
	pthread_mutex_lock(&g_lock);
	int ok = arena_init_locked();
	pthread_mutex_unlock(&g_lock);
	return ok;
}

void* rx_jit26_alloc(size_t size, void** rw_out)
{
	if (size == 0)
		return NULL;

	size = align_up(size);

	pthread_mutex_lock(&g_lock);

	if (!arena_init_locked()) {
		pthread_mutex_unlock(&g_lock);
		return NULL;
	}

	size_t offset;
	FreeBlock** link = &g_free;
	while (*link != NULL) {
		FreeBlock* block = *link;
		if (block->size >= size) {
			offset = block->offset;
			if (block->size == size) {
				*link = block->next;
				free(block);
			} else {
				block->offset += size;
				block->size   -= size;
			}
			goto found;
		}
		link = &block->next;
	}

	if (g_bump + size > ARENA_SIZE) {
		pthread_mutex_unlock(&g_lock);
		return NULL;
	}
	offset = g_bump;
	g_bump += size;

found:
	pthread_mutex_unlock(&g_lock);
	if (rw_out != NULL)
		*rw_out = g_rw + offset;
	return g_rx + offset;
}

void rx_jit26_free(void* rx_ptr, size_t size)
{
	if (rx_ptr == NULL || size == 0)
		return;

	size = align_up(size);

	pthread_mutex_lock(&g_lock);
	if (g_state == 1 &&
	    (uint8_t*)rx_ptr >= g_rx &&
	    (uint8_t*)rx_ptr + size <= g_rx + ARENA_SIZE) {
		FreeBlock* block = (FreeBlock*)malloc(sizeof(FreeBlock));
		if (block != NULL) {
			block->offset = (size_t)((uint8_t*)rx_ptr - g_rx);
			block->size   = size;
			block->next   = g_free;
			g_free = block;
		}
	}
	pthread_mutex_unlock(&g_lock);
}

void rx_jit26_sync(void* rw_ptr, void* rx_ptr, size_t size)
{
	if (size == 0)
		return;
	// Writes landed in the RW alias, instruction fetch happens at RX. Both
	// map the same physical pages, so clean the data side then invalidate
	// the instruction side.
	sys_dcache_flush(rw_ptr, size);
	sys_icache_invalidate(rx_ptr, size);
}

#else // !(__APPLE__ && __aarch64__)

int   rx_jit26_available(void) { return 0; }
int   rx_jit26_status(void) { return RX_JIT26_NO_DEBUGGER; }
int   rx_jit26_is_ready(void) { return 0; }
void* rx_jit26_alloc(size_t size, void** rw_out) { (void)size; (void)rw_out; return NULL; }
void  rx_jit26_free(void* rx_ptr, size_t size) { (void)rx_ptr; (void)size; }
void  rx_jit26_sync(void* rw_ptr, void* rx_ptr, size_t size) { (void)rw_ptr; (void)rx_ptr; (void)size; }

#endif
