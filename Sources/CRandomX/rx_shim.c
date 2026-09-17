#include "include/rx_shim.h"
#include "jit26_arena.h"
#include "randomx.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__)
#include <libkern/OSCacheControl.h>
void __clear_cache(void* start, void* end) {
    if (end > start) {
        sys_icache_invalidate(start, (size_t)((char*)end - (char*)start));
    }
}
#endif

#if !defined(__x86_64__) && !defined(_M_X64)
void* randomx_argon2_impl_avx2(void) {
    return NULL;
}
void* randomx_argon2_impl_ssse3(void) {
    return NULL;
}
#endif

uint32_t rx_get_flags(void) {
    return (uint32_t)randomx_get_flags();
}

void* rx_alloc_cache(uint32_t flags) {
    return (void*)randomx_alloc_cache((randomx_flags)flags);
}

void rx_init_cache(void* cache, const void* key, size_t keySize) {
    if (cache && key && keySize > 0) {
        randomx_init_cache((randomx_cache*)cache, key, keySize);
    }
}

void rx_release_cache(void* cache) {
    if (cache) {
        randomx_release_cache((randomx_cache*)cache);
    }
}

void* rx_alloc_dataset(uint32_t flags) {
    return (void*)randomx_alloc_dataset((randomx_flags)flags);
}

uint32_t rx_dataset_item_count(void) {
    return (uint32_t)randomx_dataset_item_count();
}

void rx_init_dataset_item(void* dataset, void* cache, uint32_t startItem, uint32_t itemCount) {
    if (dataset && cache) {
        randomx_init_dataset((randomx_dataset*)dataset, (randomx_cache*)cache, (unsigned long)startItem, (unsigned long)itemCount);
    }
}

struct DatasetWorkerArgs {
    randomx_dataset* dataset;
    randomx_cache*   cache;
    unsigned long    start_item;
    unsigned long    item_count;
};

static void* dataset_worker(void* arg) {
#if defined(__APPLE__)
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#endif
    struct DatasetWorkerArgs* a = (struct DatasetWorkerArgs*)arg;
    randomx_init_dataset(a->dataset, a->cache, a->start_item, a->item_count);
    return NULL;
}

void rx_init_dataset_multithreaded(void* dataset, void* cache, uint32_t threadCount) {
    if (!dataset || !cache) return;
    unsigned long total = (unsigned long)randomx_dataset_item_count();
    if (threadCount <= 1) {
        randomx_init_dataset((randomx_dataset*)dataset, (randomx_cache*)cache, 0, total);
        return;
    }

    pthread_t* threads = (pthread_t*)malloc(sizeof(pthread_t) * threadCount);
    struct DatasetWorkerArgs* args = (struct DatasetWorkerArgs*)malloc(sizeof(struct DatasetWorkerArgs) * threadCount);
    if (!threads || !args) {
        free(threads);
        free(args);
        randomx_init_dataset((randomx_dataset*)dataset, (randomx_cache*)cache, 0, total);
        return;
    }

    unsigned long per_thread = (total / threadCount) & ~3UL;
    for (uint32_t i = 0; i < threadCount; i++) {
        args[i].dataset = (randomx_dataset*)dataset;
        args[i].cache = (randomx_cache*)cache;
        args[i].start_item = i * per_thread;
        args[i].item_count = (i == threadCount - 1) ? (total - args[i].start_item) : per_thread;
        pthread_create(&threads[i], NULL, dataset_worker, &args[i]);
    }

    for (uint32_t i = 0; i < threadCount; i++) {
        pthread_join(threads[i], NULL);
    }

    free(threads);
    free(args);
}

void rx_release_dataset(void* dataset) {
    if (dataset) {
        randomx_release_dataset((randomx_dataset*)dataset);
    }
}

void* rx_create_vm(uint32_t flags, void* cache, void* dataset) {
    return (void*)randomx_create_vm((randomx_flags)flags, (randomx_cache*)cache, (randomx_dataset*)dataset);
}

void rx_vm_set_cache(void* vm, void* cache) {
    if (vm && cache) {
        randomx_vm_set_cache((randomx_vm*)vm, (randomx_cache*)cache);
    }
}

void rx_vm_set_dataset(void* vm, void* dataset) {
    if (vm && dataset) {
        randomx_vm_set_dataset((randomx_vm*)vm, (randomx_dataset*)dataset);
    }
}

void rx_destroy_vm(void* vm) {
    if (vm) {
        randomx_destroy_vm((randomx_vm*)vm);
    }
}

void rx_hash(void* vm, const void* input, size_t inputSize, void* output) {
    if (vm && input && output) {
        randomx_calculate_hash((randomx_vm*)vm, input, inputSize, output);
    }
}

int rx_self_test(uint32_t use_jit) {
    const char myKey[] = "test key 000";
    const char myInput[] = "This is a test";
    const uint8_t expected[32] = {
        0x63, 0x91, 0x83, 0xaa, 0xe1, 0xbf, 0x4c, 0x9a,
        0x35, 0x88, 0x4c, 0xb4, 0x6b, 0x09, 0xca, 0xd9,
        0x17, 0x5f, 0x04, 0xef, 0xd7, 0x68, 0x4e, 0x72,
        0x62, 0xa0, 0xac, 0x1c, 0x2f, 0x0b, 0x4e, 0x3f
    };
    randomx_flags flags = randomx_get_flags();
    if (use_jit) {
        flags |= RANDOMX_FLAG_JIT;
    } else {
        flags &= ~RANDOMX_FLAG_JIT;
    }
    flags &= ~RANDOMX_FLAG_FULL_MEM;
    flags &= ~RANDOMX_FLAG_SECURE;

    randomx_cache* cache = randomx_alloc_cache(flags);
    if (!cache) return 0;
    randomx_init_cache(cache, myKey, sizeof(myKey) - 1);

    randomx_vm* vm = randomx_create_vm(flags, cache, NULL);
    if (!vm) {
        randomx_release_cache(cache);
        return 0;
    }

    uint8_t hash[32];
    randomx_calculate_hash(vm, myInput, sizeof(myInput) - 1, hash);

    randomx_destroy_vm(vm);
    randomx_release_cache(cache);

    return (memcmp(hash, expected, 32) == 0) ? 1 : 0;
}

// ---------------------------------------------------------------------------
// JIT capability probe.
//
// mprotect(PROT_READ | PROT_WRITE | PROT_EXEC) is not a valid test on iOS: for a
// writable mapping the kernel strips VM_PROT_EXECUTE and still returns 0, so the
// call reports success while the pages stay non-executable. RandomX then enables
// its code buffer with setPagesRWX (which ignores the mprotect result), jumps
// into the generated program and the process is killed with EXC_BAD_ACCESS /
// KERN_PROTECTION_FAILURE, termination namespace CODESIGNING, Invalid Page.
//
// The real gate is CS_DEBUGGED, which the kernel sets once a debugger has
// attached (StikDebug, or LiveContainer with Launch with JIT enabled). Read it
// with csops, then confirm that an RWX mapping really keeps its execute bit.
// ---------------------------------------------------------------------------
#if defined(__APPLE__)

#include <unistd.h>
#include <sys/syscall.h>
#include <sys/mman.h>
#include <mach/mach.h>

#ifndef SYS_csops
#define SYS_csops 169
#endif

#define RX_CS_OPS_STATUS 0
#define RX_CS_DEBUGGED   0x10000000

int rx_process_is_debugged(void) {
    uint32_t csflags = 0;
    if (syscall(SYS_csops, getpid(), RX_CS_OPS_STATUS, &csflags, sizeof(csflags)) != 0) {
        return 0;
    }
    return (csflags & RX_CS_DEBUGGED) ? 1 : 0;
}

int rx_jit_allowed(void) {
    // Already granted: the pages keep execute permission even if the debugger
    // later drops, so do not re-gate on CS_DEBUGGED.
    if (rx_jit26_is_ready()) {
        return 1;
    }

    if (!rx_process_is_debugged()) {
        return 0;
    }

    // iOS 26 on A15+/M2+ (TXM/SPTM): CS_DEBUGGED no longer implies executable
    // memory. The only mechanism that marks a page executable is an
    // out-of-process write by the attached debugger, requested with
    // brk #0xf00d. If that succeeds, JIT is genuinely available and RandomX
    // will compile into the arena.
    if (rx_jit26_available()) {
        return 1;
    }

    // Pre-TXM devices: CS_DEBUGGED alone is enough and an RWX mapping really
    // does keep its execute bit.

    size_t page = (size_t)getpagesize();
    void* p = mmap(NULL, page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) {
        return 0;
    }

    int allowed = 0;
    if (mprotect(p, page, PROT_READ | PROT_WRITE | PROT_EXEC) == 0) {
        vm_address_t addr = (vm_address_t)p;
        vm_size_t region_size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        if (vm_region_64(mach_task_self(), &addr, &region_size, VM_REGION_BASIC_INFO_64,
                         (vm_region_info_t)&info, &count, &object) == KERN_SUCCESS) {
            allowed = (info.protection & VM_PROT_EXECUTE) ? 1 : 0;
        }
    }

    munmap(p, page);
    return allowed;
}

#else

int rx_process_is_debugged(void) { return 0; }
int rx_jit_allowed(void) { return 0; }

#endif

int rx_jit_arena_active(void) {
    return rx_jit26_available();
}

int rx_jit_arena_status(void) {
    return rx_jit26_status();
}
