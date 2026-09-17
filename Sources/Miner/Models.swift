import Foundation

public enum JitMode: String, Codable, Sendable {
    case unprobed = "Probing..."
    case activeJit = "Active JIT (ARM64)"
    case waitingForJit = "Waiting for JIT"
    case interpreterOnly = "Interpreter Mode"
}

public enum MemoryMode: String, Codable, Sendable {
    case lightMode256MB = "Light Mode (256 MB)"
    case fastMode2GB = "Fast Mode (2080 MB)"
}

public struct MiningConfig: Codable, Sendable {
    public var walletAddress: String = "47fdNY4jLJ7816dKoTRrvvfwMYq7fAZNWfYNrPs12ejZgs4XkmScH2w65v8btcHPEn9epxZiK8Hh8RbehFxnHnMV3nLbLZu"
    public var poolUrl: String = "auto.c3pool.org:80"
    public var workerName: String = "ios-miner"
    public var password: String = "x"
    public var threads: Int = 2
    public var useJitIfAvailable: Bool = true
    public var allowFastMode: Bool = false
    public var backgroundAudio: Bool = true

    public init() {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        // A-series chips typically have 2 performance cores
        self.threads = min(2, max(1, cores))
    }
}

public struct LocalMiningStats: Sendable {
    public var isMining: Bool = false
    public var currentHashrate: Double = 0.0
    public var hashrate60s: Double = 0.0
    public var hashrate15m: Double = 0.0
    public var acceptedShares: Int = 0
    public var rejectedShares: Int = 0
    public var difficulty: Int64 = 0
    public var activeThreads: Int = 2
    public var uptimeSeconds: Int = 0
    public var statusText: String = "READY"
    public var jitMode: JitMode = .unprobed
    public var memoryMode: MemoryMode = .lightMode256MB
    public var thermalState: ProcessInfo.ThermalState = .nominal
    public var availableMemoryMB: Int = 0

    public init() {}

    public var formattedUptime: String {
        let hours = uptimeSeconds / 3600
        let minutes = (uptimeSeconds % 3600) / 60
        let seconds = uptimeSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    public var formattedThermalState: String {
        switch thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious (Throttled)"
        case .critical: return "Critical (Paused)"
        @unknown default: return "Unknown"
        }
    }
}
