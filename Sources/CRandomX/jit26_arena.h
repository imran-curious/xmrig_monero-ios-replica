// iOS 26 TXM/SPTM JIT arena.
//
// On A15+/M2+ hardware running iOS 26, CS_DEBUGGED alone no longer produces
// executable memory: the only thing that marks a page executable is an
// out-of-process write performed by an attached debugger. StikDebug/StikJIT
// implement the debugger half and wait for the traced process to ask for a
// region via a breakpoint protocol:
//
//     mov x16, #1      // request code = "prepare region"
//     brk #0xf00d
//
// with x0 = NULL (the debugger allocates fresh; passing an address the process
// already mapped returns that same pointer and silently grants nothing) and
// x1 = length. The region that comes back is execute-only, so a writable alias
// is built with vm_remap().
//
// The brk traps to SIGTRAP and kills the process when no debugger is attached,
// so every entry point here checks CS_DEBUGGED first. The arena is never
// unmapped: a released region cannot be re-blessed.

#ifndef RX_JIT26_ARENA_H
#define RX_JIT26_ARENA_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Why the arena is or is not available.
#define RX_JIT26_UNTRIED       0
#define RX_JIT26_READY         1
#define RX_JIT26_NO_DEBUGGER   2  // CS_DEBUGGED clear: nothing attached yet
#define RX_JIT26_NO_SCRIPT     3  // attached, but the brk went unanswered
#define RX_JIT26_REFUSED       4  // answered, but handed back no region
#define RX_JIT26_REMAP_FAILED  5  // granted, but the RW alias could not be built

// 1 once the arena has been granted. Unlike rx_jit26_available() this never
// issues a request, so it stays true even if the debugger later detaches: the
// pages keep their execute permission.
int rx_jit26_is_ready(void);

// One of the RX_JIT26_* codes above.
int rx_jit26_status(void);

// 1 when the debugger granted an executable arena. Safe to call repeatedly;
// the request is attempted once and the result cached.
int rx_jit26_available(void);

// Carve `size` bytes out of the arena. Returns the executable address, and
// stores the writable alias of the same bytes in *rw_out. NULL when the arena
// is unavailable or exhausted, in which case *rw_out is untouched.
void* rx_jit26_alloc(size_t size, void** rw_out);

// Return a block to the arena's free list. Does not unmap anything.
void rx_jit26_free(void* rx_ptr, size_t size);

// Publish writes made through the RW alias so they are visible to instruction
// fetch at the RX address.
void rx_jit26_sync(void* rw_ptr, void* rx_ptr, size_t size);

#ifdef __cplusplus
}
#endif

#endif // RX_JIT26_ARENA_H
