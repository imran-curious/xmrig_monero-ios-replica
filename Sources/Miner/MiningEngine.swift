import Foundation
import Combine
import UIKit
import CRandomX

/// MainActor UI bridge connecting the SwiftUI views to MinerCore and RandomXController.
@MainActor
final class MiningEngine: ObservableObject {
    @Published var stats = LocalMiningStats()
    @Published var logs: [String] = []
    @Published var isJitAttached: Bool = false
    @Published var selfTestPassed: Bool? = nil

    private let core = MinerCore()
    private var jitPollTask: Task<Void, Never>?
    private var lastJitStatus: Int32 = -1

    init() {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let ramMB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024)
        let availMB = Int(os_proc_available_memory() / (1024 * 1024))

        appendLog("[init] Bare-metal Monero Miner initialized (arm64, SwiftPM)")
        appendLog("[init] Hardware: \(cores) cores, \(ramMB) MB physical RAM (\(availMB) MB available)")

        // Probe JIT on startup
        let jitInitial = isJitAvailable()
        self.isJitAttached = jitInitial
        self.stats.jitMode = jitInitial ? .activeJit : .waitingForJit
        self.stats.availableMemoryMB = availMB

        lastJitStatus = rx_jit_arena_status()
        appendLog(jitStatusLine())

        // No self-test at launch: rx_self_test allocates its own 256 MB cache and runs a
        // full Argon2 fill. MinerCore.start() enforces the same test before it allocates
        // anything, so doing it here only adds a large allocation to app startup.

        core.onLog = { [weak self] line in
            MainActor.assumeIsolated { self?.appendLog(line) }
        }

        core.onStats = { [weak self] newStats in
            MainActor.assumeIsolated { self?.apply(newStats) }
        }

        startJitPolling()
    }

    func startMining(config: MiningConfig) {
        if selfTestPassed == false {
            appendLog("[miner] ERROR: Cannot start mining - RandomX self-test failed. Halting to prevent rejected shares.")
            stats.statusText = "SELF-TEST FAILED"
            return
        }

        // Prevent screen sleep while mining
        UIApplication.shared.isIdleTimerDisabled = true

        stats.isMining = true
        stats.statusText = "STARTING"
        stats.activeThreads = config.threads
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.core.start(config: config)
        }
    }

    func stopMining() {
        UIApplication.shared.isIdleTimerDisabled = false
        stats.isMining = false
        stats.statusText = "STOPPED"
        stats.currentHashrate = 0
        core.stop()
    }

    func updateThreads(_ count: Int) {
        stats.activeThreads = count
        core.updateThreads(count)
    }

    private func apply(_ s: LocalMiningStats) {
        stats = s
        isJitAttached = (s.jitMode == .activeJit)
    }

    /// Reports which stage of the iOS 26 handshake we reached, so the event log
    /// says why JIT is or is not active rather than just "waiting".
    private func jitStatusLine() -> String {
        switch rx_jit_arena_status() {
        case 1:
            return "[jit] JIT ACTIVE via iOS 26 debugger arena (brk #0xf00d granted RX pages)"
        case 2:
            return "[jit] No debugger attached (CS_DEBUGGED clear) - launch this app from StikDebug."
        case 3:
            return "[jit] Debugger attached but brk #0xf00d went unanswered. In StikDebug: Settings > enable \"Always Run Scripts\", then pick universal.js as this app\u{27}s JIT script and relaunch."
        case 4:
            return "[jit] Debugger answered but granted no region - staying on interpreter."
        case 5:
            return "[jit] Region granted but the writable alias failed - staying on interpreter."
        default:
            return isJitAvailable()
                ? "[jit] JIT active via RWX mapping (CS_DEBUGGED, pre-TXM path)"
                : "[jit] Interpreter mode."
        }
    }

    private func appendLog(_ message: String) {
        logs.append(message)
        if logs.count > 300 {
            logs.removeFirst(50)
        }
    }

    private func startJitPolling() {
        jitPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { break }
                let avail = isJitAvailable()

                let status = rx_jit_arena_status()
                if status != self.lastJitStatus {
                    self.lastJitStatus = status
                    self.appendLog(self.jitStatusLine())
                }

                if avail != self.isJitAttached {
                    self.isJitAttached = avail
                    if !self.stats.isMining {
                        self.stats.jitMode = avail ? .activeJit : .waitingForJit
                    }
                    self.appendLog(avail ? "[jit] JIT became available!" : "[jit] JIT detached")

                    // Re-test vector for the updated JIT mode, but never while mining:
                    // rx_self_test allocates its own 256 MB cache and would sit on top of
                    // the live cache/dataset. MinerCore re-tests on the next start anyway.
                    guard !self.stats.isMining else { continue }
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        let testPassed = rx_self_test(avail ? 1 : 0) == 1
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.selfTestPassed = testPassed
                            if testPassed {
                                self.appendLog("[selftest] RandomX self-test PASSED for \(avail ? "JIT" : "Interpreter") mode")
                            } else {
                                self.stats.statusText = "SELF-TEST FAILED"
                                self.appendLog("[selftest] ERROR: RandomX self-test failed for \(avail ? "JIT" : "Interpreter") mode! Mining disabled.")
                            }
                        }
                    }
                }
            }
        }
    }
}
