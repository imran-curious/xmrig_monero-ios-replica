import Foundation
import Network
import Darwin
import CRandomX

final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func add(_ delta: UInt64) { lock.lock(); value &+= delta; lock.unlock() }
    func getAndReset() -> UInt64 { lock.lock(); let v = value; value = 0; lock.unlock(); return v }
}

final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set(_ v: Bool) { lock.lock(); flag = v; lock.unlock() }
    func get() -> Bool { lock.lock(); let v = flag; lock.unlock(); return v }
}

/// The core bare-metal mining engine.
/// Handles Stratum TCP JSON-RPC, thread QoS scheduling, thermal governing,
/// RandomX proof-of-work computation, and share verification/submission.
final class MinerCore: @unchecked Sendable {
    var onLog: (@Sendable (String) -> Void)?
    var onStats: (@Sendable (LocalMiningStats) -> Void)?

    private var randomx: RandomXController?
    private let activeFlag = AtomicBool()
    private let isEpochUpdating = AtomicBool()
    private let hashCounter = AtomicCounter()

    private let stateLock = NSLock()
    // Guarded by stateLock
    private var connection: NWConnection?
    private var sessionId = ""
    private var jobId = ""
    private var blob: [UInt8] = []
    private var seed = Data()
    private var target: UInt64 = 0
    private var accepted = 0
    private var rejected = 0
    private var difficulty: Int64 = 0
    private var uptimeSeconds = 0
    private var statusText = "READY"
    private var submitId = 100
    private var hashrateWindow: [Double] = []
    private var userConfiguredThreads = 2
    private var activeWorkerCount = 0
    private var workerGeneration = 0
    private var workerGenerations: [Int] = Array(repeating: 0, count: 8)
    private var isThermalPaused = false
    private var currentConfig: MiningConfig?
    private var reconnectAttempts = 0
    private var connectGeneration = 0
    private var pendingSubmits = Set<Int>()
    // ----------------------

    private static func stringValue(_ val: Any?) -> String? {
        if let s = val as? String { return s }
        if let n = val as? NSNumber { return n.stringValue }
        return nil
    }

    private static func errorMessage(from errorObj: Any?) -> String? {
        guard let errorObj, !(errorObj is NSNull) else { return nil }
        if let errStr = errorObj as? String { return errStr }
        if let errDict = errorObj as? [String: Any] {
            return errDict["message"] as? String ?? "\(errDict)"
        }
        if let errArr = errorObj as? [Any] {
            return errArr.map { String(describing: $0) }.joined(separator: ": ")
        }
        return String(describing: errorObj)
    }

    private let networkQueue = DispatchQueue(label: "com.monero.miner.network")
    private let epochQueue = DispatchQueue(label: "com.monero.miner.epoch", qos: .userInitiated)
    private var statsTimer: DispatchSourceTimer?
    private var keepaliveTimer: DispatchSourceTimer?
    private var watchdog: DispatchSourceTimer?
    private var recvBuffer = Data()
    private var thermalObserver: NSObjectProtocol?

    init() {
        setupThermalObserver()
    }

    deinit {
        if let observer = thermalObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Lifecycle

    func start(config: MiningConfig) {
        guard !activeFlag.get() else { return }

        // Self-test runs BEFORE the controller is allocated: rx_self_test builds its own
        // 256 MB cache internally, which must not overlap the controller cache/dataset
        // (2080 MB in fast mode) or the process gets jetsam-killed on the way in.
        let willUseJit = config.useJitIfAvailable && isJitAvailable()
        let probeModeStr = willUseJit ? "Active JIT (ARM64)" : "Interpreter Mode"
        log("[miner] Verifying RandomX self-test (\(probeModeStr))...")
        guard rx_self_test(willUseJit ? 1 : 0) == 1 else {
            log("[fatal] RandomX self-test FAILED for \(probeModeStr)! Halting to prevent submitting invalid shares.")
            setStatus("SELF-TEST FAILED")
            return
        }
        log("[miner] RandomX self-test PASSED")

        log("[miner] Initializing RandomX controller...")
        let rx = RandomXController(preferJit: config.useJitIfAvailable, allowFastMode: config.allowFastMode)
        guard let rx else {
            log("[fatal] Could not allocate RandomX memory. Check free RAM.")
            setStatus("NO MEMORY")
            return
        }
        let jitModeStr = rx.useJit ? "Active JIT (ARM64)" : "Interpreter Mode"

        self.randomx = rx
        self.activeFlag.set(true)
        self.isEpochUpdating.set(false)

        stateLock.lock()
        currentConfig = config
        userConfiguredThreads = max(1, min(8, config.threads))
        accepted = 0; rejected = 0; difficulty = 0; uptimeSeconds = 0
        sessionId = ""; jobId = ""; blob = []; seed = Data(); target = 0
        hashrateWindow.removeAll()
        pendingSubmits.removeAll()
        statusText = "CONNECTING"
        reconnectAttempts = 0
        isThermalPaused = false
        workerGeneration += 1
        for i in 0..<workerGenerations.count {
            workerGenerations[i] &+= 1
        }
        stateLock.unlock()

        log("[miner] RandomX initialized: \(jitModeStr), \(rx.memoryMode.rawValue)")
        log("[miner] Connecting to pool: \(config.poolUrl) as worker: \(config.workerName)")

        if config.backgroundAudio {
            AudioKeeper.shared.start()
            log("[miner] Background audio keepalive enabled")
        }

        startStatsTimer()
        startKeepaliveTimer()
        connect(config: config)
        reconcileWorkers()
    }

    func stop() {
        guard activeFlag.get() else { return }
        activeFlag.set(false)
        isEpochUpdating.set(false)

        statsTimer?.cancel(); statsTimer = nil
        keepaliveTimer?.cancel(); keepaliveTimer = nil
        watchdog?.cancel(); watchdog = nil

        stateLock.lock()
        connection?.cancel(); connection = nil
        currentConfig = nil
        activeWorkerCount = 0
        workerGeneration += 1
        for i in 0..<workerGenerations.count {
            workerGenerations[i] &+= 1
        }
        connectGeneration += 1
        hashrateWindow.removeAll()
        statusText = "STOPPED"
        pendingSubmits.removeAll()
        stateLock.unlock()

        AudioKeeper.shared.stop()
        _ = hashCounter.getAndReset()
        randomx = nil

        log("[miner] Mining stopped")
        emitStats(hashrateNow: 0)
    }

    func updateThreads(_ count: Int) {
        let clamped = max(1, min(8, count))
        stateLock.lock()
        userConfiguredThreads = clamped
        stateLock.unlock()
        log("[miner] Target threads set to \(clamped)")
        reconcileWorkers()
    }

    // MARK: - Thermal Governor (Part 7.3)

    private func setupThermalObserver() {
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleThermalStateChange()
        }
    }

    private func handleThermalStateChange() {
        let state = ProcessInfo.processInfo.thermalState
        stateLock.lock()
        let isMining = activeFlag.get()
        stateLock.unlock()
        guard isMining else { return }

        switch state {
        case .nominal, .fair:
            log("[thermal] Normal operating conditions (\(state == .nominal ? "nominal" : "fair")). Restoring threads.")
            stateLock.lock(); isThermalPaused = false; stateLock.unlock()
            reconcileWorkers()
        case .serious:
            log("[thermal] WARNING: Thermal state is SERIOUS. Throttling to 1 thread to avoid shutdown.")
            stateLock.lock(); isThermalPaused = false; stateLock.unlock()
            reconcileWorkers()
        case .critical:
            log("[thermal] CRITICAL THERMAL STATE. Pausing mining threads to allow cooldown.")
            stateLock.lock(); isThermalPaused = true; stateLock.unlock()
            reconcileWorkers()
        @unknown default:
            break
        }
    }

    private func reconcileWorkers() {
        stateLock.lock()
        guard activeFlag.get() else {
            activeWorkerCount = 0
            stateLock.unlock()
            return
        }

        let state = ProcessInfo.processInfo.thermalState
        let desired: Int
        if isThermalPaused || state == .critical {
            desired = 0
        } else if state == .serious {
            desired = 1
        } else {
            desired = userConfiguredThreads
        }

        let current = activeWorkerCount
        if desired < current {
            // Fence off retiring workers by bumping generation for every index being dropped.
            // When a retiring worker finishes its current hash, generation != workerGenerations[index]
            // will cause it to break and terminate, even if a thermal bounce restores desired count.
            for i in desired..<current {
                if i < workerGenerations.count {
                    workerGenerations[i] &+= 1
                }
            }
        }
        activeWorkerCount = desired

        var toStart: [(index: Int, gen: Int)] = []
        if desired > current {
            for i in current..<desired {
                let gen = (i < workerGenerations.count) ? workerGenerations[i] : workerGeneration
                toStart.append((index: i, gen: gen))
            }
        }
        stateLock.unlock()

        for w in toStart {
            startWorker(index: w.index, generation: w.gen)
        }
    }

    // MARK: - Stratum Networking (Part 8)

    /// NWError.localizedDescription collapses every case into "Network.NWError error N",
    /// which does not say whether the failure was DNS, POSIX or TLS. Unwrap it.
    private static func describe(_ err: NWError) -> String {
        switch err {
        case .posix(let code):
            return "posix \(code.rawValue) (\(String(cString: strerror(code.rawValue))))"
        case .dns(let code):
            return "dns \(code)"
        case .tls(let code):
            return "tls \(code)"
        case .wifiAware(let code):
            return "wifiAware \(code)"
        @unknown default:
            return String(describing: err)
        }
    }

    /// Reports what the system thinks the network path looks like for this process.
    /// A stratum connect that sits in .waiting is almost always a path problem, not a
    /// problem with the endpoint, so log the path once per connect attempt.
    private func logNetworkPath() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            var ifaces: [String] = []
            if path.usesInterfaceType(.wifi) { ifaces.append("wifi") }
            if path.usesInterfaceType(.cellular) { ifaces.append("cellular") }
            if path.usesInterfaceType(.wiredEthernet) { ifaces.append("ethernet") }
            if path.usesInterfaceType(.other) { ifaces.append("other") }
            if path.usesInterfaceType(.loopback) { ifaces.append("loopback") }
            let names = ifaces.isEmpty ? "none" : ifaces.joined(separator: "+")
            self.log("[net] Path \(path.status), via \(names), v4=\(path.supportsIPv4) v6=\(path.supportsIPv6) dns=\(path.supportsDNS)")
            monitor.cancel()
        }
        monitor.start(queue: networkQueue)
    }

    /// Independent, low-level reachability probe.
    ///
    /// NWConnection reports this pool as POSIX EINVAL without saying which step failed.
    /// Resolve and connect by hand with BSD sockets instead and report the exact errno
    /// the kernel gives us, which separates a DNS problem from a routing problem from a
    /// Network.framework problem.
    private func probeEndpoint(host: String, port: UInt16) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            hints.ai_protocol = IPPROTO_TCP

            var res: UnsafeMutablePointer<addrinfo>?
            let rc = getaddrinfo(host, String(port), &hints, &res)
            guard rc == 0, let head = res else {
                self.log("[probe] getaddrinfo failed: \(rc) (\(String(cString: gai_strerror(rc))))")
                return
            }
            defer { freeaddrinfo(head) }

            var target: (addr: UnsafeMutablePointer<sockaddr>, len: socklen_t, family: Int32)?
            var listed: [String] = []
            var node: UnsafeMutablePointer<addrinfo>? = head
            while let ai = node {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen,
                               &buf, socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST) == 0 {
                    let fam = ai.pointee.ai_family == AF_INET ? "v4" : "v6"
                    listed.append("\(fam) \(String(cString: buf))")
                }
                if target == nil, ai.pointee.ai_family == AF_INET {
                    target = (ai.pointee.ai_addr, ai.pointee.ai_addrlen, ai.pointee.ai_family)
                }
                node = ai.pointee.ai_next
            }
            self.log("[probe] DNS -> \(listed.isEmpty ? "nothing" : listed.joined(separator: ", "))")

            guard let t = target else {
                self.log("[probe] no IPv4 address returned")
                return
            }

            let fd = Darwin.socket(t.family, SOCK_STREAM, IPPROTO_TCP)
            guard fd >= 0 else {
                self.log("[probe] socket() failed: errno \(errno) (\(String(cString: strerror(errno))))")
                return
            }
            defer { Darwin.close(fd) }

            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

            if Darwin.connect(fd, t.addr, t.len) == 0 {
                self.log("[probe] TCP connect OK (immediate) -- raw sockets reach the pool")
                return
            }
            let ce = errno
            if ce != EINPROGRESS {
                self.log("[probe] connect() failed: errno \(ce) (\(String(cString: strerror(ce))))")
                return
            }

            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let pr = Darwin.poll(&pfd, 1, 10_000)
            if pr == 0 {
                self.log("[probe] TCP connect timed out after 10s (no SYN-ACK)")
                return
            }
            if pr < 0 {
                self.log("[probe] poll() failed: errno \(errno) (\(String(cString: strerror(errno))))")
                return
            }

            var soErr: Int32 = 0
            var soLen = socklen_t(MemoryLayout<Int32>.size)
            _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &soLen)
            if soErr == 0 {
                self.log("[probe] TCP connect OK -- raw sockets reach the pool")
            } else {
                self.log("[probe] TCP connect failed: errno \(soErr) (\(String(cString: strerror(soErr))))")
            }
        }
    }

    private func connect(config: MiningConfig) {
        var trimmedUrl = config.poolUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["stratum+tcp://", "stratum+ssl://", "stratum+tls://", "stratum://", "tcp://", "ssl://", "tls://", "http://", "https://"] {
            if trimmedUrl.lowercased().hasPrefix(scheme) {
                trimmedUrl = String(trimmedUrl.dropFirst(scheme.count))
            }
        }
        trimmedUrl = trimmedUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let parts = trimmedUrl.split(separator: ":")
        let host = parts.first.map(String.init) ?? "pool.supportxmr.com"
        let portNum = parts.count > 1 ? (UInt16(parts[1]) ?? 3333) : 3333

        guard let port = NWEndpoint.Port(rawValue: portNum) else {
            log("[net] Invalid port \(portNum)"); setStatus("BAD PORT"); return
        }

        let isTls = (portNum == 443 || portNum == 9000 || portNum == 20128)
        let tcpOpts = NWProtocolTCP.Options()
        tcpOpts.connectionTimeout = 12
        tcpOpts.noDelay = true

        let params = isTls ? NWParameters(tls: NWProtocolTLS.Options(), tcp: tcpOpts) : NWParameters(tls: nil, tcp: tcpOpts)
        // A stratum socket is never proxied. Evaluating the system proxy configuration is
        // a known source of POSIX EINVAL when a VPN or a configuration profile has left a
        // proxy entry behind, which a sideloader such as SideStore commonly does.
        params.preferNoProxies = true
        // The path monitor reports v4=true v6=false on this device. Letting Network.framework
        // consider AAAA records it can never route to is a known source of POSIX EINVAL, so
        // pin the stratum socket to IPv4.
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: params)

        stateLock.lock()
        connection = conn
        connectGeneration += 1
        let gen = connectGeneration
        stateLock.unlock()
        recvBuffer.removeAll(keepingCapacity: true)

        log("[net] Connecting to \(host):\(portNum)\(isTls ? " (TLS)" : "")...")
        logNetworkPath()
        probeEndpoint(host: host, port: portNum)
        startWatchdog(generation: gen, config: config)

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.stateLock.lock()
            let live = (gen == self.connectGeneration)
            self.stateLock.unlock()
            guard live else { return }

            switch state {
            case .ready:
                self.watchdog?.cancel(); self.watchdog = nil
                self.stateLock.lock(); self.reconnectAttempts = 0; self.stateLock.unlock()
                self.log("[net] Connected to \(host):\(portNum)")
                self.sendLogin(config: config)
                self.receiveLoop(conn)
            case .waiting(let err):
                self.log("[net] Waiting: \(MinerCore.describe(err))")
                self.setStatus("RETRYING")
            case .preparing:
                self.log("[net] Resolving \(host)...")
            case .failed(let err):
                self.log("[net] Connection failed: \(MinerCore.describe(err))")
                self.handleDisconnect()
            case .cancelled:
                self.log("[net] Connection closed")
            default:
                break
            }
        }
        conn.start(queue: networkQueue)
    }

    private func startWatchdog(generation: Int, config: MiningConfig) {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: networkQueue)
        timer.schedule(deadline: .now() + 14)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let live = (generation == self.connectGeneration) && self.activeFlag.get()
            self.stateLock.unlock()
            guard live else { return }

            self.log("[net] Connection timed out, retrying...")
            self.connection?.cancel()
            self.handleDisconnect()
        }
        timer.resume()
        watchdog = timer
    }

    private func scheduleReconnect(generation: Int, config: MiningConfig) {
        stateLock.lock()
        guard activeFlag.get(), generation == connectGeneration else { stateLock.unlock(); return }
        reconnectAttempts += 1
        let delay = min(30, 2 * reconnectAttempts)
        stateLock.unlock()

        log("[net] Reconnecting in \(delay)s (attempt \(reconnectAttempts))...")
        networkQueue.asyncAfter(deadline: .now() + .seconds(delay)) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let live = self.activeFlag.get() && (generation == self.connectGeneration)
            self.stateLock.unlock()
            guard live else { return }
            self.connect(config: config)
        }
    }

    private func sendLogin(config: MiningConfig) {
        var wallet = config.walletAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let worker = config.workerName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Ask for a fixed low difficulty. Without this the pool starts a new miner at
        // 52k-100k, which a phone doing tens of hashes a second would take hours to hit.
        // xmrig-compatible pools read the suffix off the login field. C3Pool floors it
        // at 15000, so the exact number below only has to be under that.
        if !wallet.contains("+") { wallet += "+1000" }
        let msg: [String: Any] = [
            "id": 1,
            "jsonrpc": "2.0",
            "method": "login",
            "params": [
                "login": wallet,
                "pass": worker.isEmpty ? "x" : worker,
                "agent": "ios-bare/0.1",
                "algo": ["rx/0"]
            ]
        ]
        sendJSON(msg)
        log("[net] Login sent (algo=rx/0, agent=ios-bare/0.1)")
        setStatus("LOGGING IN")
    }

    private func sendJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        guard let payload = line.data(using: .utf8) else { return }

        stateLock.lock()
        let conn = connection
        stateLock.unlock()

        conn?.send(content: payload, completion: .contentProcessed { [weak self] err in
            if let err { self?.log("[net] Send error: \(err.localizedDescription)") }
        })
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, err in
            guard let self else { return }
            if let content, !content.isEmpty {
                self.recvBuffer.append(content)
                if self.recvBuffer.count > 1_000_000 {
                    self.recvBuffer.removeAll(keepingCapacity: false)
                }
                self.processRecvBuffer()
            }
            if isComplete {
                self.log("[net] Remote host closed connection")
                self.handleDisconnect()
                return
            }
            if let err {
                self.log("[net] Recv error: \(err.localizedDescription)")
                self.handleDisconnect()
                return
            }
            self.receiveLoop(conn)
        }
    }

    private func handleDisconnect() {
        stateLock.lock()
        watchdog?.cancel()
        watchdog = nil
        connection?.cancel()
        connection = nil
        sessionId = ""
        jobId = ""
        target = 0
        statusText = "DISCONNECTED"
        pendingSubmits.removeAll()
        connectGeneration += 1
        let gen = connectGeneration
        let cfg = currentConfig
        stateLock.unlock()
        if let cfg {
            scheduleReconnect(generation: gen, config: cfg)
        }
    }

    private func processRecvBuffer() {
        let newline = UInt8(ascii: "\n")
        let cr = UInt8(ascii: "\r")
        while let idx = recvBuffer.firstIndex(of: newline) {
            var lineData = recvBuffer.subdata(in: 0..<idx)
            recvBuffer.removeSubrange(0...idx)
            if let last = lineData.last, last == cr {
                lineData.removeLast()
            }
            if lineData.isEmpty { continue }
            handleJSONLine(lineData)
        }
    }

    private func handleJSONLine(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let json = obj as? [String: Any] else { return }

        let respId = json["id"] as? Int

        // 1. Check if this response was for login (id == 1)
        if respId == 1 {
            if let errStr = Self.errorMessage(from: json["error"]) {
                log("[net] Login failed: \(errStr)")
                setStatus("LOGIN FAILED")
                handleDisconnect()
                return
            }
            if let result = json["result"] as? [String: Any] {
                if let sid = Self.stringValue(result["id"]) {
                    stateLock.lock()
                    sessionId = sid
                    stateLock.unlock()
                    log("[net] Login successful (session \(sid.prefix(8)))")
                }
                if let algoStr = result["algo"] as? String {
                    randomx?.setAlgo(algoStr)
                    log("[net] Pool algo: \(algoStr)")
                } else if let algos = result["algo"] as? [String], let first = algos.first {
                    randomx?.setAlgo(first)
                    log("[net] Pool algo: \(first)")
                }
                if let job = result["job"] as? [String: Any] {
                    parseJob(job)
                }
            }
            return
        }

        // 2. Check if this response was for a share submission
        var isShareSubmit = false
        if let respId {
            stateLock.lock()
            isShareSubmit = pendingSubmits.remove(respId) != nil
            stateLock.unlock()
        }

        if isShareSubmit {
            var isOk = false
            if let resBool = json["result"] as? Bool, resBool {
                isOk = true
            } else if let result = json["result"] as? [String: Any],
                      let status = result["status"] as? String, status.lowercased() == "ok" {
                isOk = true
            }

            if isOk {
                stateLock.lock()
                accepted += 1
                let a = accepted, r = rejected, d = difficulty
                stateLock.unlock()
                log("[cpu] Share accepted (\(a)/\(r)) diff \(d)")
            } else {
                let m = Self.errorMessage(from: json["error"]) ?? "rejected"
                stateLock.lock()
                rejected += 1
                let a = accepted, r = rejected
                stateLock.unlock()
                log("[cpu] Share rejected (\(a)/\(r)): \(m)")
            }
            return
        }

        // 3. Unsolicited job notification: {"method":"job","params":{...}}
        if let method = json["method"] as? String, method == "job",
           let params = json["params"] as? [String: Any] {
            parseJob(params)
            return
        }

        // 4. General pool error not matching submit/login
        if let errStr = Self.errorMessage(from: json["error"]) {
            log("[net] Pool error: \(errStr)")
        }
    }

    private func parseJob(_ job: [String: Any]) {
        guard let blobHex = job["blob"] as? String,
              let jid = Self.stringValue(job["job_id"]), !jid.isEmpty else { return }

        let newBlob = Self.hexToBytes(blobHex)
        let seedHex = job["seed_hash"] as? String ?? ""
        let newSeed = Data(Self.hexToBytes(seedHex))
        let tgt = Self.parseTarget(job["target"] as? String ?? "")
        let diff: Int64 = tgt == 0 ? 0 : Int64(clamping: UInt64.max / tgt)

        stateLock.lock()
        let isNewSeed = !newSeed.isEmpty && (seed != newSeed)
        blob = newBlob; jobId = jid; seed = newSeed; target = tgt; difficulty = diff
        statusText = "MINING"
        let threads = userConfiguredThreads
        let rx = self.randomx
        stateLock.unlock()

        if isNewSeed, let rx {
            isEpochUpdating.set(true)
            epochQueue.async { [weak self] in
                rx.ensureCache(seed: newSeed, threadCount: threads)
                self?.isEpochUpdating.set(false)
            }
        }
        log("[miner] New job \(jid.prefix(8)) diff \(diff) seed \(seedHex.prefix(8))")
    }

    private func submitShare(jobId: String, nonceLE: [UInt8], result: [UInt8]) {
        stateLock.lock()
        let sid = sessionId
        submitId += 1
        let id = submitId
        pendingSubmits.insert(id)
        stateLock.unlock()
        guard !sid.isEmpty else { return }

        let msg: [String: Any] = [
            "id": id,
            "jsonrpc": "2.0",
            "method": "submit",
            "params": [
                "id": sid,
                "job_id": jobId,
                "nonce": Self.bytesToHex(nonceLE),
                "result": Self.bytesToHex(result)
            ]
        ]
        sendJSON(msg)
        log("[cpu] Submitting share nonce \(Self.bytesToHex(nonceLE)) job \(jobId.prefix(8))")
    }

    // MARK: - Keepalive

    private func startKeepaliveTimer() {
        keepaliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: networkQueue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self, self.activeFlag.get() else { return }
            self.stateLock.lock()
            let sid = self.sessionId
            self.submitId += 1
            let id = self.submitId
            self.stateLock.unlock()
            guard !sid.isEmpty else { return }

            let msg: [String: Any] = [
                "id": id,
                "jsonrpc": "2.0",
                "method": "keepalived",
                "params": ["id": sid]
            ]
            self.sendJSON(msg)
        }
        timer.resume()
        keepaliveTimer = timer
    }

    // MARK: - Hashing Workers (Part 7.2 & 8)

    private func startWorker(index: Int, generation: Int) {
        let rx = randomx
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self, let rx else { return }

            // Set thread QoS to User Interactive for P-core scheduling
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)

            var vm: UnsafeMutableRawPointer?
            var boundSeed = Data()
            // Nonce space partitioning: disjoint nonce slice per thread
            let baseNonce = UInt32(index) &* 0x20000000
            var nonce = baseNonce &+ UInt32.random(in: 0...0x000fffff)
            var output = [UInt8](repeating: 0, count: 32)
            var localBatch: UInt64 = 0

            while self.activeFlag.get() {
                self.stateLock.lock()
                let currentGen = (index < self.workerGenerations.count) ? self.workerGenerations[index] : self.workerGeneration
                let targetCount = self.activeWorkerCount
                let isPaused = self.isThermalPaused
                let jBlob = self.blob, jSeed = self.seed, jTarget = self.target, jId = self.jobId
                self.stateLock.unlock()

                // Check if this worker should retire
                if generation != currentGen || index >= targetCount || isPaused {
                    break
                }

                guard jBlob.count >= 43, !jSeed.isEmpty, jTarget != 0 else {
                    Thread.sleep(forTimeInterval: 0.1)
                    continue
                }

                if self.isEpochUpdating.get() || !rx.isReady {
                    Thread.sleep(forTimeInterval: 0.05)
                    continue
                }

                if vm == nil {
                    vm = rx.makeVM()
                    boundSeed = Data()
                    if vm == nil {
                        Thread.sleep(forTimeInterval: 0.1)
                        continue
                    }
                }

                // Insert 4-byte nonce at byte offset 39 (little-endian)
                var input = jBlob
                let n0 = UInt8(nonce & 0xff)
                let n1 = UInt8((nonce >> 8) & 0xff)
                let n2 = UInt8((nonce >> 16) & 0xff)
                let n3 = UInt8((nonce >> 24) & 0xff)
                input[39] = n0
                input[40] = n1
                input[41] = n2
                input[42] = n3

                rx.hash(vm: vm!, boundSeed: &boundSeed, input: input, output: &output)

                // Share test: last 8 bytes of hash as LE UInt64 < target (matches xmrig)
                var tail: UInt64 = 0
                for i in 0..<8 {
                    tail |= UInt64(output[24 + i]) << (8 * i)
                }

                if tail < jTarget {
                    self.submitShare(jobId: jId, nonceLE: [n0, n1, n2, n3], result: output)
                }

                nonce = nonce &+ 1
                localBatch += 1
                if localBatch >= 8 {
                    self.hashCounter.add(localBatch)
                    localBatch = 0
                }
            }

            self.hashCounter.add(localBatch)
            rx.destroyVM(vm)
        }
    }

    // MARK: - Stats

    private func startStatsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: networkQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.activeFlag.get() else { return }
            let hashes = self.hashCounter.getAndReset()
            let now = Double(hashes)
            self.stateLock.lock()
            self.uptimeSeconds += 1
            self.hashrateWindow.append(now)
            if self.hashrateWindow.count > 900 { self.hashrateWindow.removeFirst() }
            self.stateLock.unlock()
            self.emitStats(hashrateNow: now)
        }
        timer.resume()
        statsTimer = timer
    }

    private func emitStats(hashrateNow: Double) {
        stateLock.lock()
        let win = hashrateWindow
        let r60 = win.suffix(60), r900 = win.suffix(900)
        let avg60 = r60.isEmpty ? 0 : r60.reduce(0, +) / Double(r60.count)
        let avg900 = r900.isEmpty ? 0 : r900.reduce(0, +) / Double(r900.count)

        var snap = LocalMiningStats()
        snap.isMining = activeFlag.get()
        snap.statusText = statusText
        snap.currentHashrate = hashrateNow
        snap.hashrate60s = avg60
        snap.hashrate15m = avg900
        snap.acceptedShares = accepted
        snap.rejectedShares = rejected
        snap.difficulty = difficulty
        snap.activeThreads = activeWorkerCount
        snap.uptimeSeconds = uptimeSeconds
        snap.thermalState = ProcessInfo.processInfo.thermalState
        snap.availableMemoryMB = Int(os_proc_available_memory() / (1024 * 1024))

        if let rx = randomx {
            snap.jitMode = rx.useJit ? .activeJit : .interpreterOnly
            snap.memoryMode = rx.memoryMode
        } else {
            snap.jitMode = isJitAvailable() ? .activeJit : .waitingForJit
        }
        stateLock.unlock()

        let cb = onStats
        DispatchQueue.main.async { cb?(snap) }
    }

    private func setStatus(_ s: String) {
        stateLock.lock(); statusText = s; stateLock.unlock()
        emitStats(hashrateNow: 0)
    }

    private func log(_ message: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(ts)] \(message)"
        let cb = onLog
        DispatchQueue.main.async { cb?(line) }
    }

    // MARK: - Helpers

    static func hexToBytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var it = s.unicodeScalars.makeIterator()
        func nib(_ c: Unicode.Scalar) -> UInt8? {
            switch c {
            case "0"..."9": return UInt8(c.value - 48)
            case "a"..."f": return UInt8(c.value - 87)
            case "A"..."F": return UInt8(c.value - 55)
            default: return nil
            }
        }
        while let hi = it.next(), let lo = it.next() {
            guard let h = nib(hi), let l = nib(lo) else { break }
            out.append((h << 4) | l)
        }
        return out
    }

    static func bytesToHex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let table = Array("0123456789abcdef".unicodeScalars)
        var s = ""
        for b in bytes {
            s.unicodeScalars.append(table[Int(b >> 4)])
            s.unicodeScalars.append(table[Int(b & 0x0f)])
        }
        return s
    }

    static func parseTarget(_ hex: String) -> UInt64 {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 8 || trimmed.count == 16 else { return 0 }
        let bytes = hexToBytes(trimmed)
        if bytes.count == 4 {
            var t: UInt32 = 0
            for i in 0..<4 { t |= UInt32(bytes[i]) << (8 * i) }
            if t == 0 { return 0 }
            let diff32 = UInt64(0xFFFFFFFF) / UInt64(t)
            if diff32 == 0 { return 0 }
            return UInt64(0xFFFFFFFFFFFFFFFF) / diff32
        } else if bytes.count == 8 {
            var t: UInt64 = 0
            for i in 0..<8 { t |= UInt64(bytes[i]) << (8 * i) }
            return t
        }
        return 0
    }
}
