#ifndef RX_SHIM_H
#define RX_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Mirror RandomX flags as uint32_t constants for Swift ease of use
#define RX_FLAG_DEFAULT       ((uint32_t)0)
#define RX_FLAG_LARGE_PAGES   ((uint32_t)1)
#define RX_FLAG_HARD_AES      ((uint32_t)2)
#define RX_FLAG_FULL_MEM      ((uint32_t)4)
#define RX_FLAG_JIT           ((uint32_t)8)
#define RX_FLAG_SECURE        ((uint32_t)16)
#define RX_FLAG_ARGON2_SSSE3  ((uint32_t)32)
#define RX_FLAG_ARGON2_AVX2   ((uint32_t)64)
#define RX_FLAG_ARGON2        ((uint32_t)96)
#define RX_FLAG_V2            ((uint32_t)128)

#define RX_HASH_SIZE          32
#define RX_DATASET_ITEM_SIZE  64

// Hardware & flag detection
uint32_t rx_get_flags(void);

// Cache operations (for Light Mode and dataset initialization)
void* rx_alloc_cache(uint32_t flags);
void  rx_init_cache(void* cache, const void* key, size_t keySize);
void  rx_release_cache(void* cache);

// Dataset operations (for Fast Mode)
void*    rx_alloc_dataset(uint32_t flags);
uint32_t rx_dataset_item_count(void);
void     rx_init_dataset_item(void* dataset, void* cache, uint32_t startItem, uint32_t itemCount);
void     rx_init_dataset_multithreaded(void* dataset, void* cache, uint32_t threadCount);
void     rx_release_dataset(void* dataset);

// VM operations
void* rx_create_vm(uint32_t flags, void* cache, void* dataset);
void  rx_vm_set_cache(void* vm, void* cache);
void  rx_vm_set_dataset(void* vm, void* dataset);
void  rx_destroy_vm(void* vm);

// Hashing
void rx_hash(void* vm, const void* input, size_t inputSize, void* output);

// JIT capability. rx_jit_allowed() is true only when the process is CS_DEBUGGED
// and an RWX mapping actually keeps its execute bit (see rx_shim.c).
int rx_process_is_debugged(void);
int rx_jit_allowed(void);

// 1 when the iOS 26 debugger arena (brk #0xf00d) granted executable memory, as
// opposed to JIT being available through the pre-TXM RWX path.
int rx_jit_arena_active(void);

// Why the arena is or is not available; see RX_JIT26_* in jit26_arena.h.
// 0 untried, 1 ready, 2 no debugger, 3 no JIT script loaded, 4 refused,
// 5 writable alias could not be built.
int rx_jit_arena_status(void);

// Official RandomX test vector check: returns 1 if valid, 0 if failure
int rx_self_test(uint32_t use_jit);

#ifdef __cplusplus
}
#endif

#endif // RX_SHIM_H
