import Foundation
import AVFoundation

/// Background audio session manager.
/// When enabled, plays an imperceptible silent loop with AVAudioSessionCategoryPlayback
/// to prevent iOS from suspending the process when the screen is locked or blanked.
final class AudioKeeper: @unchecked Sendable {
    static let shared = AudioKeeper()

    private var audioPlayer: AVAudioPlayer?
    private var isPlaying = false
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private let lock = NSLock()

    private init() {}

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isPlaying else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            // Generate a 1-second silent WAV in memory
            let sampleRate: Double = 8000.0
            let numSamples = Int(sampleRate)
            var wavData = Data()

            // RIFF header
            wavData.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
            let fileSize = UInt32(36 + numSamples)
            withUnsafeBytes(of: fileSize.littleEndian) { wavData.append(contentsOf: $0) }
            wavData.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
            // fmt chunk
            wavData.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
            let chunkSize = UInt32(16)
            withUnsafeBytes(of: chunkSize.littleEndian) { wavData.append(contentsOf: $0) }
            let audioFormat = UInt16(1) // PCM
            withUnsafeBytes(of: audioFormat.littleEndian) { wavData.append(contentsOf: $0) }
            let numChannels = UInt16(1) // Mono
            withUnsafeBytes(of: numChannels.littleEndian) { wavData.append(contentsOf: $0) }
            let sRate = UInt32(sampleRate)
            withUnsafeBytes(of: sRate.littleEndian) { wavData.append(contentsOf: $0) }
            let byteRate = UInt32(sampleRate)
            withUnsafeBytes(of: byteRate.littleEndian) { wavData.append(contentsOf: $0) }
            let blockAlign = UInt16(1)
            withUnsafeBytes(of: blockAlign.littleEndian) { wavData.append(contentsOf: $0) }
            let bitsPerSample = UInt16(8)
            withUnsafeBytes(of: bitsPerSample.littleEndian) { wavData.append(contentsOf: $0) }
            // data chunk
            wavData.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
            let dataSize = UInt32(numSamples)
            withUnsafeBytes(of: dataSize.littleEndian) { wavData.append(contentsOf: $0) }
            // 8-bit PCM silence is 128 (0x80)
            wavData.append(Data(repeating: 0x80, count: numSamples))

            let player = try AVAudioPlayer(data: wavData)
            player.numberOfLoops = -1 // Infinite loop
            player.volume = 0.01 // Near silence
            player.prepareToPlay()
            player.play()
            self.audioPlayer = player
            self.isPlaying = true

            // Observe audio interruptions (phone calls, FaceTime, alarms)
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notif in
                guard let self, let info = notif.userInfo,
                      let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
                if type == .ended {
                    let optionsVal = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsVal)
                    if options.contains(.shouldResume) {
                        self.resumePlayback()
                    }
                }
            }

            // Observe route changes (e.g. unplugging headphones)
            routeObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.resumePlayback()
            }
        } catch {
            print("[AudioKeeper] Could not start background audio: \(error)")
        }
    }

    private func resumePlayback() {
        lock.lock()
        defer { lock.unlock() }
        guard isPlaying, let player = audioPlayer, !player.isPlaying else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isPlaying else { return }
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
            interruptionObserver = nil
        }
        if let obs = routeObserver {
            NotificationCenter.default.removeObserver(obs)
            routeObserver = nil
        }
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
