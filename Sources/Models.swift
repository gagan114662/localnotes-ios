import Foundation
import SwiftData

/// One recording session (a lecture, a meeting).
@Model
final class Session {
    @Attribute(.unique) var id: UUID
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var localeIdentifier: String

    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.session)
    var segments: [TranscriptSegment] = []

    @Relationship(deleteRule: .cascade, inverse: \VisualCapture.session)
    var visuals: [VisualCapture] = []

    @Relationship(deleteRule: .cascade, inverse: \Note.session)
    var notes: [Note] = []

    init(title: String, startedAt: Date = .now, locale: Locale = .current) {
        self.id = UUID()
        self.title = title
        self.startedAt = startedAt
        self.localeIdentifier = locale.identifier
    }
}

/// A FINAL, raw transcript segment. Append-only: never edited after insert.
@Model
final class TranscriptSegment {
    @Attribute(.unique) var id: UUID
    var text: String
    var startedAt: Date        // wall clock
    var endedAt: Date
    var isInterruptionMarker: Bool
    var session: Session?

    init(text: String, startedAt: Date, endedAt: Date, isInterruptionMarker: Bool = false) {
        self.id = UUID()
        self.text = text
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.isInterruptionMarker = isInterruptionMarker
    }
}

enum VisualSource: String, Codable {
    case broadcast   // live screen capture (time-aligned)
    case photo       // photo/screenshot import (time from EXIF/creation date if any)
    case document    // PDF page / slide deck export (no time; aligned by meaning)
}

/// A slide, screenshot, photo or document page, plus its OCR text.
@Model
final class VisualCapture {
    @Attribute(.unique) var id: UUID
    var sourceRaw: String
    var capturedAt: Date?          // nil for document pages
    var pageIndex: Int?            // for documents
    @Attribute(.externalStorage) var imageData: Data
    var ocrText: String
    var session: Session?

    var source: VisualSource { VisualSource(rawValue: sourceRaw) ?? .photo }

    init(source: VisualSource, capturedAt: Date?, pageIndex: Int? = nil, imageData: Data, ocrText: String) {
        self.id = UUID()
        self.sourceRaw = source.rawValue
        self.capturedAt = capturedAt
        self.pageIndex = pageIndex
        self.imageData = imageData
        self.ocrText = ocrText
    }
}

/// Derived, regenerable. Stored as Markdown plus provenance.
@Model
final class Note {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var markdown: String
    var generator: String            // "foundation-models" | "rule-based"
    var sourceSegmentIDs: [UUID]
    var sourceVisualIDs: [UUID]
    var session: Session?

    init(markdown: String, generator: String, sourceSegmentIDs: [UUID], sourceVisualIDs: [UUID]) {
        self.id = UUID()
        self.createdAt = .now
        self.markdown = markdown
        self.generator = generator
        self.sourceSegmentIDs = sourceSegmentIDs
        self.sourceVisualIDs = sourceVisualIDs
    }
}

extension ModelContainer {
    /// Store lives in the App Group so it is shared and file-protected.
    static func localNotes() throws -> ModelContainer {
        let url = AppGroup.container.appending(path: "LocalNotes.store")
        let config = ModelConfiguration(url: url, allowsSave: true)
        return try ModelContainer(for: Session.self, TranscriptSegment.self, VisualCapture.self, Note.self,
                                  configurations: config)
    }
}
