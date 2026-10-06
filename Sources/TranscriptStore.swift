import Foundation
import SwiftData

/// Append-only raw transcript.
/// - Final results are inserted once and never modified.
/// - Volatile (live) text is held in memory only, for display.
/// - Every final segment is also appended to <AppGroup>/Transcripts/<session-id>.jsonl so nothing is lost
///   if iOS kills the app in the background.
@MainActor
@Observable
final class TranscriptStore {
    private(set) var liveText: String = ""
    private(set) var finalSegments: [TranscriptSegment] = []

    private let context: ModelContext
    private let session: Session
    private let journal: FileHandle?

    init(context: ModelContext, session: Session) {
        self.context = context
        self.session = session

        let dir = AppGroup.container.appending(path: "Transcripts", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "\(session.id.uuidString).jsonl")
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil,
                                           attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        journal = try? FileHandle(forWritingTo: file)
        _ = try? journal?.seekToEnd()
        finalSegments = session.segments.sorted { $0.startedAt < $1.startedAt }
    }

    func handle(_ result: TranscriptionService.Result) {
        if result.isFinal {
            appendFinal(text: result.text, start: result.start, end: result.end)
            liveText = ""
        } else {
            liveText = result.text
        }
    }

    func markInterruption(from start: Date, to end: Date) {
        appendFinal(text: "[recording interrupted]", start: start, end: end, marker: true)
    }

    func close() {
        try? context.save()
        try? journal?.close()
    }

    /// Plain text export of the raw transcript, with timestamps.
    func exportRaw() -> String {
        let f = Date.FormatStyle(date: .omitted, time: .standard)
        return finalSegments.map { "[\($0.startedAt.formatted(f))] \($0.text)" }.joined(separator: "\n")
    }

    // MARK: - Private

    private func appendFinal(text: String, start: Date, end: Date, marker: Bool = false) {
        let segment = TranscriptSegment(text: text, startedAt: start, endedAt: end, isInterruptionMarker: marker)
        segment.session = session
        context.insert(segment)
        finalSegments.append(segment)

        struct Line: Encodable { let id: UUID; let start: Date; let end: Date; let text: String; let marker: Bool }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Line(id: segment.id, start: start, end: end, text: text, marker: marker)) {
            journal?.write(data + Data("\n".utf8))
        }
        // Save often; cheap, and protects against background termination.
        if finalSegments.count % 5 == 0 { try? context.save() }
    }
}
