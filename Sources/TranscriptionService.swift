import AVFAudio
import Foundation
import Speech

/// On-device, long-form speech-to-text.
///
/// Primary path (iOS 26+): SpeechAnalyzer + SpeechTranscriber. Runs entirely on device; the language
/// model asset is downloaded once by the OS (AssetInventory) and then works in airplane mode.
/// Emits volatile (live, may change) and final (committed) results with audio time ranges.
actor TranscriptionService {
    struct Result: Sendable {
        let text: String
        let start: Date          // wall clock
        let end: Date
        let isFinal: Bool
    }

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var sessionStart = Date()

    /// The audio format the analyzer wants; give this to AudioCaptureEngine.
    private(set) var analyzerFormat: AVAudioFormat?

    // MARK: - Setup

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    /// Prepares the transcriber for `locale` and makes sure the on-device model is installed.
    func prepare(locale: Locale) async throws -> AVAudioFormat {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.localeNotSupported(locale)
        }
        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        self.transcriber = transcriber

        // One-time download of the on-device model. After this, fully offline.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.noAudioFormat
        }
        analyzerFormat = format
        return format
    }

    // MARK: - Run

    /// Starts analysis. `onResult` is called for every volatile and final result.
    func start(sessionStart: Date, onResult: @escaping @Sendable (Result) async -> Void) async throws {
        guard let transcriber else { throw TranscriptionError.notPrepared }
        self.sessionStart = sessionStart

        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        let start = sessionStart
        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let range = result.range
                    let begin = start.addingTimeInterval(range.start.seconds)
                    let end = start.addingTimeInterval((range.start + range.duration).seconds)
                    await onResult(Result(text: text, start: begin, end: end, isFinal: result.isFinal))
                }
            } catch {
                // Surface in UI via the store's error state if needed.
            }
        }
        try await analyzer.start(inputSequence: inputSequence)
    }

    /// Feed buffers from AudioCaptureEngine (already in `analyzerFormat`).
    func append(_ buffer: AVAudioPCMBuffer) {
        inputContinuation?.yield(AnalyzerInput(buffer: buffer))
    }

    /// Flushes and finalizes everything spoken so far.
    func finish() async {
        inputContinuation?.finish()
        inputContinuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        resultsTask = nil
        analyzer = nil
    }
}

enum TranscriptionError: LocalizedError {
    case localeNotSupported(Locale)
    case noAudioFormat
    case notPrepared

    var errorDescription: String? {
        switch self {
        case .localeNotSupported(let l): "On-device transcription is not available for \(l.identifier)."
        case .noAudioFormat: "No compatible audio format for on-device transcription."
        case .notPrepared: "Transcriber not prepared."
        }
    }
}
