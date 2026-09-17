import Foundation
import Darwin
import CRandomX

/// Controller for RandomX proof-of-work computation.
/// Manages shared cache (256 MB in light mode) or dataset (2080 MB in fast mode),
/// allocates per-thread VMs, and synchronizes epoch re-keying under a read-write lock.
final class RandomXController: @unchecked Sendable {
    let useJit: Bool
    var memoryMode: MemoryMode
    private var flags: UInt32

    private var cache: UnsafeMutableRawPointer?
    private var dataset: UnsafeMutableRawPointer?
    private var cacheSeed = Data()
    private let rwlock = UnsafeMutablePointer<pthread_rwlock_t>.allocate(capacity: 1)

    var isReady: Bool {
        pthread_rwlock_rdlock(rwlock)
        defer { pthread_rwlock_unlock(rwlock) }
        return !cacheSeed.isEmpty
    }

    init?(preferJit: Bool, allowFastMode: Bool) {
        pthread_rwlock_init(rwlock, nil)

        // 1. Probe JIT capability
        let jitAvailable = isJitAvailable()
        self.useJit = preferJit && jitAvailable

        // 2. Query available memory budget via Darwin
        let availBytes = os_proc_available_memory()
        // Fast mode requires ~2080 MB dataset + VM scratchpads + system headroom
        let canUseFast = allowFastMode && (availBytes >= 2_700_000_000)

        var f = rx_get_flags()
        // Never set large pages on iOS (VM_FLAGS_SUPERPAGE_SIZE_2MB unavailable)
        // Never set SECURE flag (avoids W^X flipping per hash; maps RWX once at VM creation)
        f &= ~(RX_FLAG_LARGE_PAGES | RX_FLAG_SECURE)

        if self.useJit {
            f |= RX_FLAG_JIT
        } else {
            f &= ~RX_FLAG_JIT
        }

        if canUseFast {
            f |= RX_FLAG_FULL_MEM
            self.memoryMode = .fastMode2GB
        } else {
            f &= ~RX_FLAG_FULL_MEM
            self.memoryMode = .lightMode256MB
        }
        self.flags = f

        // 3. Allocate cache
        guard let c = rx_alloc_cache(f) else {
            pthread_rwlock_destroy(rwlock)
            rwlock.deallocate()
            return nil
        }
        self.cache = c

        // 4. Allocate dataset if Fast Mode
        if canUseFast {
            if let ds = rx_alloc_dataset(f) {
                self.dataset = ds
            } else {
                // Fallback to Light Mode if dataset alloc failed
                f &= ~RX_FLAG_FULL_MEM
                self.flags = f
                self.memoryMode = .lightMode256MB
            }
        }
    }

    deinit {
        pthread_rwlock_wrlock(rwlock)
        if let dataset { rx_release_dataset(dataset) }
        if let cache { rx_release_cache(cache) }
        pthread_rwlock_unlock(rwlock)
        pthread_rwlock_destroy(rwlock)
        rwlock.deallocate()
    }

    /// Re-key the cache (and rebuild dataset if fast mode) for the new epoch.
    func ensureCache(seed: Data, threadCount: Int) {
        guard !seed.isEmpty else { return }
        pthread_rwlock_rdlock(rwlock)
        let isAlreadyCurrent = (cacheSeed == seed)
        pthread_rwlock_unlock(rwlock)
        if isAlreadyCurrent { return }

        pthread_rwlock_wrlock(rwlock)
        defer { pthread_rwlock_unlock(rwlock) }
        guard let cache, cacheSeed != seed else { return }

        seed.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            rx_init_cache(cache, base, raw.count)
        }

        if let dataset {
            rx_init_dataset_multithreaded(dataset, cache, UInt32(max(1, threadCount)))
        }

        cacheSeed = seed
    }

    /// Update algorithm flags from stratum pool negotiation (e.g. rx/0 vs rx/v2)
    func setAlgo(_ algo: String) {
        pthread_rwlock_wrlock(rwlock)
        defer { pthread_rwlock_unlock(rwlock) }
        let lower = algo.lowercased()
        if lower.contains("v2") {
            flags |= RX_FLAG_V2
        } else {
            flags &= ~RX_FLAG_V2
        }
    }


    /// Creates a VM bound to the shared cache and dataset.
    func makeVM() -> UnsafeMutableRawPointer? {
        pthread_rwlock_rdlock(rwlock)
        defer { pthread_rwlock_unlock(rwlock) }
        guard let cache, !cacheSeed.isEmpty else { return nil }
        return rx_create_vm(flags, cache, dataset)
    }

    func destroyVM(_ vm: UnsafeMutableRawPointer?) {
        if let vm { rx_destroy_vm(vm) }
    }

    /// Compute one RandomX hash. If the epoch changed, rebound the VM cache/dataset.
    func hash(vm: UnsafeMutableRawPointer, boundSeed: inout Data, input: [UInt8], output: inout [UInt8]) {
        pthread_rwlock_rdlock(rwlock)
        defer { pthread_rwlock_unlock(rwlock) }

        if boundSeed != cacheSeed {
            if let cache { rx_vm_set_cache(vm, cache) }
            if let dataset { rx_vm_set_dataset(vm, dataset) }
            boundSeed = cacheSeed
        }

        input.withUnsafeBytes { inRaw in
            output.withUnsafeMutableBytes { outRaw in
                rx_hash(vm, inRaw.baseAddress, inRaw.count, outRaw.baseAddress)
            }
        }
    }
}
