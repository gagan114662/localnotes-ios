import Foundation
import NaturalLanguage

/// Splits a session into "chapters": one visual plus the speech that belongs to it.
///
/// - Time-stamped visuals (broadcast frames, photos with EXIF): a slide owns everything said from the moment it
///   appeared until the next slide appeared (with a small lead-in, because people often start talking about a
///   slide just before switching to it).
/// - Undated visuals (PDF pages): matched by meaning. The transcript is cut into windows of about 150 words; each
///   window goes to the page whose OCR text is most similar (on-device sentence embeddings), with a preference
///   for keeping page order monotonic (lectures move forward through a deck).
/// - Speech with no visual becomes text-only chapters of about 1,200 words (fits the on-device model's context).
struct Chapter: Sendable {
    let visualID: UUID?
    let visualText: String?
    let segmentIDs: [UUID]
    let speech: String
    let start: Date?
    let end: Date?
}

struct Contextualizer {
    var leadIn: TimeInterval = 3
    var windowWords = 150
    var textOnlyChapterWords = 1200

    struct Seg: Sendable { let id: UUID; let text: String; let start: Date; let end: Date }
    struct Vis: Sendable { let id: UUID; let text: String; let capturedAt: Date?; let pageIndex: Int? }

    func chapters(segments: [Seg], visuals: [Vis]) -> [Chapter] {
        let segs = segments.sorted { $0.start < $1.start }
        let timed = visuals.filter { $0.capturedAt != nil }.sorted { $0.capturedAt! < $1.capturedAt! }
        let pages = visuals.filter { $0.capturedAt == nil }.sorted { ($0.pageIndex ?? 0) < ($1.pageIndex ?? 0) }

        if !timed.isEmpty { return byTime(segs, timed) }
        if !pages.isEmpty { return byMeaning(segs, pages) }
        return textOnly(segs)
    }

    // MARK: - Time alignment

    func byTime(_ segs: [Seg], _ visuals: [Vis]) -> [Chapter] {
        var chapters: [Chapter] = []
        // Speech before the first slide.
        let firstAt = visuals[0].capturedAt!.addingTimeInterval(-leadIn)
        let before = segs.filter { $0.end <= firstAt }
        if !before.isEmpty { chapters += textOnly(before) }

        for (i, v) in visuals.enumerated() {
            let from = v.capturedAt!.addingTimeInterval(-leadIn)
            let to = i + 1 < visuals.count ? visuals[i + 1].capturedAt!.addingTimeInterval(-leadIn) : .distantFuture
            // A segment belongs to the slide that was showing at its midpoint.
            let owned = segs.filter {
                let mid = $0.start.addingTimeInterval($0.end.timeIntervalSince($0.start) / 2)
                return mid >= from && mid < to
            }
            chapters.append(Chapter(visualID: v.id, visualText: v.text,
                                    segmentIDs: owned.map(\.id),
                                    speech: owned.map(\.text).joined(separator: " "),
                                    start: owned.first?.start ?? v.capturedAt, end: owned.last?.end))
        }
        return chapters
    }

    // MARK: - Meaning alignment

    func byMeaning(_ segs: [Seg], _ pages: [Vis]) -> [Chapter] {
        let windows = makeWindows(segs, words: windowWords)
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            // No embedding model: spread speech evenly across pages in order.
            return evenSplit(windows, pages)
        }
        let pageVectors = pages.map { embedding.vector(for: String($0.text.prefix(2000))) ?? [] }

        var assignment: [Int] = []
        var current = 0
        for w in windows {
            let v = embedding.vector(for: w.text) ?? []
            var best = current, bestScore = -Double.infinity
            for (p, pv) in pageVectors.enumerated() {
                var score = cosine(v, pv)
                if p < current { score -= 0.15 }               // discourage going backwards
                if p > current + 2 { score -= 0.05 * Double(p - current - 2) } // discourage big jumps
                if score > bestScore { bestScore = score; best = p }
            }
            current = max(current, best)
            assignment.append(best)
        }

        return pages.enumerated().map { (p, page) in
            let ws = windows.enumerated().filter { assignment[$0.offset] == p }.map(\.element)
            return Chapter(visualID: page.id, visualText: page.text,
                           segmentIDs: ws.flatMap(\.ids),
                           speech: ws.map(\.text).joined(separator: " "),
                           start: ws.first?.start, end: ws.last?.end)
        }
    }

    // MARK: - Text only

    func textOnly(_ segs: [Seg]) -> [Chapter] {
        makeWindows(segs, words: textOnlyChapterWords).map {
            Chapter(visualID: nil, visualText: nil, segmentIDs: $0.ids, speech: $0.text, start: $0.start, end: $0.end)
        }
    }

    // MARK: - Helpers

    struct Window { var ids: [UUID] = []; var text = ""; var start: Date?; var end: Date?; var words = 0 }

    func makeWindows(_ segs: [Seg], words limit: Int) -> [Window] {
        var out: [Window] = [], w = Window()
        for s in segs {
            if w.start == nil { w.start = s.start }
            w.ids.append(s.id)
            w.text += (w.text.isEmpty ? "" : " ") + s.text
            w.end = s.end
            w.words += s.text.split(separator: " ").count
            if w.words >= limit { out.append(w); w = Window() }
        }
        if !w.ids.isEmpty { out.append(w) }
        return out
    }

    private func evenSplit(_ windows: [Window], _ pages: [Vis]) -> [Chapter] {
        let per = max(1, Int((Double(windows.count) / Double(max(pages.count, 1))).rounded(.up)))
        return pages.enumerated().map { (p, page) in
            let ws = Array(windows.dropFirst(p * per).prefix(per))
            return Chapter(visualID: page.id, visualText: page.text, segmentIDs: ws.flatMap(\.ids),
                           speech: ws.map(\.text).joined(separator: " "), start: ws.first?.start, end: ws.last?.end)
        }
    }

    private func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return dot / ((na.squareRoot() * nb.squareRoot()) + 1e-9)
    }
}
