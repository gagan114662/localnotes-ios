import AVFAudio
import Foundation

/// Continuous microphone capture that keeps running with the screen locked
/// (requires Background Modes → Audio, and must be STARTED while the app is in the foreground).
///
/// Delivers buffers already converted to `targetFormat` (the speech analyzer's preferred format).
/// Handles phone-call/Siri interruptions and route changes (AirPods in/out) by restarting itself.
final class AudioCaptureEngine: @unchecked Sendable {
    enum Event: @unchecked Sendable {
        case buffer(AVAudioPCMBuffer, hostTime: Date)
        case interrupted(at: Date)
        case resumed(at: Date)
    }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var continuation: AsyncStream<Event>.Continuation?
    private let targetFormat: AVAudioFormat
    private var observers: [NSObjectProtocol] = []
    private(set) var isRunning = false

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    /// Ask once, up front.
    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() throws -> AsyncStream<Event> {
        let session = AVAudioSession.sharedInstance()
        // .record keeps capturing in the background; .measurement disables AGC/voice processing for cleaner STT.
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.allowBluetoothHFP, .defaultToSpeaker, .mixWithOthers])
        try session.setActive(true, options: [])

        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.continuation = continuation
        observeSession()
        try startEngine()
        continuation.onTermination = { [weak self] _ in self?.stop() }
        return stream
    }

    func stop() {
        guard isRunning || continuation != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        continuation?.finish()
        continuation = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Engine

    private func startEngine() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converted = self.convert(buffer) else { return }
            self.continuation?.yield(.buffer(converted, hostTime: .now))
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return nil }
        if buffer.format == targetFormat { return buffer }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed { inputStatus.pointee = .noDataNow; return nil }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return (status == .error || out.frameLength == 0) ? nil : out
    }

    // MARK: - Interruptions & route changes

    private func observeSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: nil) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: nil, queue: nil) { [weak self] _ in
            // Input format can change (e.g. AirPods). Rebuild the tap with the new format.
            guard let self, self.isRunning else { return }
            self.engine.stop()
            try? self.startEngine()
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            try? self.startEngine()
        })
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            isRunning = false
            continuation?.yield(.interrupted(at: .now))
        case .ended:
            // Resume even without .shouldResume: this is a recorder, the user expects it to keep going.
            try? AVAudioSession.sharedInstance().setActive(true)
            if (try? startEngine()) != nil {
                continuation?.yield(.resumed(at: .now))
            }
        @unknown default:
            break
        }
    }
}
