import SwiftUI

let MoneroOrange = Color(red: 1.0, green: 0.4, blue: 0.0)
let DarkBackground = Color(red: 0.08, green: 0.08, blue: 0.09)
let DarkSurface = Color(red: 0.14, green: 0.14, blue: 0.16)
let DarkCard = Color(red: 0.18, green: 0.18, blue: 0.20)
let MiningGreen = Color(red: 0.0, green: 0.9, blue: 0.46)
let MiningRed = Color(red: 1.0, green: 0.32, blue: 0.32)
let WarningYellow = Color(red: 1.0, green: 0.8, blue: 0.2)

struct ContentView: View {
    @StateObject private var engine = MiningEngine()
    @State private var config = MiningConfig()
    @State private var showSettings = false

    var body: some View {
        ZStack {
            DarkBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top Header
                headerView
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                ScrollView {
                    VStack(spacing: 14) {
                        // JIT Status Gate
                        jitStatusBanner

                        // Main Action Button
                        miningActionButton

                        // Key Metrics Card
                        metricsCard

                        // System & Governor Status Card
                        systemStatusCard

                        // Live Event Logs
                        logConsoleCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            settingsSheet
        }
    }

    // MARK: - Header
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("MONERO")
                        .font(.system(size: 22, weight: .black))
                        .foregroundColor(MoneroOrange)
                        .tracking(1.5)
                    Text("BARE-METAL")
                        .font(.system(size: 22, weight: .light))
                        .foregroundColor(.white)
                }
                Text("iOS 26.5.1 ARM64 Native Engine")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.gray)
            }
            Spacer()
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18))
                    .foregroundColor(MoneroOrange)
                    .padding(10)
                    .background(DarkSurface)
                    .clipShape(Circle())
            }
        }
    }

    // MARK: - JIT Gate Banner (Part 3.1)
    private var jitStatusBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: engine.isJitAttached ? "bolt.fill" : "hourglass.badge.plus")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(engine.isJitAttached ? MiningGreen : WarningYellow)

            VStack(alignment: .leading, spacing: 2) {
                Text(engine.isJitAttached ? "JIT Enabled (ARM64 Native)" : "Waiting for JIT (StikDebug)")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Text(engine.isJitAttached ? "Full RandomX JIT compiler active (~200+ H/s)" : "Attach StikDebug via StosVPN, or run in Interpreter mode (~3-8 H/s)")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }
            Spacer()
        }
        .padding(12)
        .background(DarkSurface)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(engine.isJitAttached ? MiningGreen.opacity(0.4) : WarningYellow.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Action Button
    private var miningActionButton: some View {
        Button(action: {
            if engine.stats.isMining {
                engine.stopMining()
            } else {
                engine.startMining(config: config)
            }
        }) {
            HStack(spacing: 10) {
                Image(systemName: engine.stats.isMining ? "stop.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold))
                Text(engine.stats.isMining ? "STOP MINING" : "START MINING")
                    .font(.system(size: 17, weight: .heavy))
                    .tracking(1.2)
            }
            .foregroundColor(DarkBackground)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(engine.stats.isMining ? MiningRed : MiningGreen)
            .cornerRadius(14)
            .shadow(color: (engine.stats.isMining ? MiningRed : MiningGreen).opacity(0.3), radius: 8, y: 3)
        }
    }

    // MARK: - Metrics Card
    private var metricsCard: some View {
        VStack(spacing: 14) {
            HStack {
                Text("MINING PERFORMANCE")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.gray)
                    .tracking(1)
                Spacer()
                Text(engine.stats.statusText)
                    .font(.system(size: 11, weight: .black))
                    .foregroundColor(engine.stats.isMining ? MiningGreen : .gray)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(DarkCard)
                    .cornerRadius(6)
            }

            // Primary Hashrate
            VStack(spacing: 4) {
                Text(String(format: "%.1f", engine.stats.currentHashrate))
                    .font(.system(size: 44, weight: .black, design: .monospaced))
                    .foregroundColor(.white)
                Text("HASHES / SECOND")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(MoneroOrange)
                    .tracking(1.5)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)

            Divider().background(Color.white.opacity(0.1))

            // Sub stats grid
            HStack(spacing: 12) {
                statColumn(title: "60s AVG", value: String(format: "%.1f H/s", engine.stats.hashrate60s))
                statColumn(title: "15m AVG", value: String(format: "%.1f H/s", engine.stats.hashrate15m))
                statColumn(title: "SHARES", value: "\(engine.stats.acceptedShares) / \(engine.stats.rejectedShares)", valueColor: engine.stats.acceptedShares > 0 ? MiningGreen : .white)
                statColumn(title: "UPTIME", value: engine.stats.formattedUptime)
            }
        }
        .padding(16)
        .background(DarkSurface)
        .cornerRadius(16)
    }

    private func statColumn(title: String, value: String, valueColor: Color = .white) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.gray)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - System Status Card
    private var systemStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RUNTIME GOVERNOR")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.gray)
                .tracking(1)

            HStack {
                Label("Thermal State", systemImage: "thermometer.medium")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                Spacer()
                Text(engine.stats.formattedThermalState)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(thermalColor(engine.stats.thermalState))
            }

            HStack {
                Label("Active Threads", systemImage: "cpu")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                Spacer()
                Text("\(engine.stats.activeThreads) cores (QoS Interactive)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
            }

            HStack {
                Label("Memory Mode", systemImage: "memorychip")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                Spacer()
                Text("\(engine.stats.memoryMode.rawValue) [\(engine.stats.availableMemoryMB)MB Free]")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .padding(16)
        .background(DarkSurface)
        .cornerRadius(16)
    }

    private func thermalColor(_ state: ProcessInfo.ThermalState) -> Color {
        switch state {
        case .nominal: return MiningGreen
        case .fair: return MiningGreen
        case .serious: return WarningYellow
        case .critical: return MiningRed
        @unknown default: return .gray
        }
    }

    // MARK: - Live Logs Console
    private var logConsoleCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("EVENT LOG")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.gray)
                    .tracking(1)
                Spacer()
                Text("\(engine.logs.count) lines")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(engine.logs.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(lineColor(line))
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 140)
                .background(Color.black.opacity(0.4))
                .cornerRadius(8)
                .onChange(of: engine.logs.count) { _, _ in
                    if let lastIndex = engine.logs.indices.last {
                        proxy.scrollTo(lastIndex, anchor: .bottom)
                    }
                }
            }
        }
        .padding(16)
        .background(DarkSurface)
        .cornerRadius(16)
    }

    private func lineColor(_ line: String) -> Color {
        if line.contains("[fatal]") || line.contains("[cpu] Share rejected") { return MiningRed }
        if line.contains("[cpu] Share accepted") || line.contains("[selftest] RandomX self-test PASSED") { return MiningGreen }
        if line.contains("[thermal]") || line.contains("[jit]") { return WarningYellow }
        return Color(white: 0.78)
    }

    // MARK: - Settings Sheet
    private var settingsSheet: some View {
        NavigationView {
            Form {
                Section(header: Text("Stratum Pool Configuration")) {
                    TextField("Pool URL (e.g. pool.supportxmr.com:3333)", text: $config.poolUrl)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("Wallet Address (XMR)", text: $config.walletAddress)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("Worker Name", text: $config.workerName)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }

                Section(header: Text("Execution & Hardware Tuning")) {
                    Stepper(value: $config.threads, in: 1...8) {
                        HStack {
                            Text("Hashing Threads")
                            Spacer()
                            Text("\(config.threads)")
                                .fontWeight(.bold)
                        }
                    }
                    .onChange(of: config.threads) { _, val in
                        engine.updateThreads(val)
                    }

                    Toggle("Enable JIT if Available", isOn: $config.useJitIfAvailable)
                    Toggle("Fast Mode (2080 MB Dataset)", isOn: $config.allowFastMode)
                    Toggle("Background Audio Keepalive", isOn: $config.backgroundAudio)
                }

                Section(footer: Text("Monero bare-metal miner compiled for iOS 26.5.1 arm64 with xtool. JIT capability requires StikDebug debugger attachment.")) {
                    EmptyView()
                }
            }
            .navigationTitle("Configuration")
            .navigationBarItems(trailing: Button("Done") { showSettings = false })
        }
    }
}
