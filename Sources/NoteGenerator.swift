import Foundation
import FoundationModels

/// Structured notes from chapters, generated on device.
///
/// Map: one model call per chapter (slide text + its speech) → ChapterNotes (guided generation, so the output
///      always parses).
/// Reduce: merge chapter notes into a session summary + deduplicated action items.
/// Fallback: rule-based notes when Apple Intelligence is unavailable (older device, disabled, or still downloading).
@Generable
struct ChapterNotes {
    @Guide(description: "A short heading for this part, 3 to 8 words")
    var heading: String

    @Guide(description: "2 to 6 concise bullet points with the key points that were said or shown", .count(2...6))
    var keyPoints: [String]

    @Guide(description: "Important terms or concepts with a one-line explanation each; empty if none")
    var concepts: [Concept]

    @Guide(description: "Concrete tasks someone committed to or was asked to do; quote owner and deadline if said; empty if none")
    var actionItems: [ActionItem]
}

@Generable
struct Concept {
    var term: String
    var explanation: String
}

@Generable
struct ActionItem {
    var task: String
    @Guide(description: "Person responsible, or empty if not said")
    var owner: String
    @Guide(description: "Deadline as spoken, or empty if not said")
    var due: String
}

@Generable
struct SessionSummary {
    @Guide(description: "A title for the whole session, under 10 words")
    var title: String
    @Guide(description: "3 to 5 sentence overview of the whole session")
    var overview: String
}

struct NoteGenerator {
    enum Engine: String { case foundationModels = "foundation-models", ruleBased = "rule-based" }

    var engine: Engine {
        if case .available = SystemLanguageModel.default.availability { return .foundationModels }
        return .ruleBased
    }

    /// Returns Markdown plus which engine produced it.
    func generate(chapters: [Chapter]) async throws -> (markdown: String, engine: Engine) {
        let nonEmpty = chapters.filter { !$0.speech.isEmpty || !($0.visualText ?? "").isEmpty }
        guard !nonEmpty.isEmpty else { return ("_Nothing recorded yet._", engine) }

        switch engine {
        case .foundationModels:
            var parts: [ChapterNotes] = []
            for c in nonEmpty { parts.append(try await notes(for: c)) }
            let summary = try await summarize(parts)
            return (render(summary: summary, parts: parts), .foundationModels)
        case .ruleBased:
            return (RuleBasedNotes.render(nonEmpty), .ruleBased)
        }
    }

    // MARK: - Map

    private func notes(for chapter: Chapter) async throws -> ChapterNotes {
        let session = LanguageModelSession(instructions: """
            You turn a lecture or meeting excerpt into study notes.
            Use ONLY facts from the SLIDE and SPEECH below. Do not invent names, numbers or tasks.
            If the speech explains something on the slide, combine them into one point.
            The speech is a raw automatic transcript: ignore filler words and fix obvious mis-hearings only when the
            slide text makes the right word clear.
            """)
        var prompt = ""
        if let slide = chapter.visualText, !slide.isEmpty { prompt += "SLIDE:\n\(slide.prefix(1500))\n\n" }
        prompt += "SPEECH:\n\(chapter.speech.prefix(6000))"

        let response = try await session.respond(to: prompt, generating: ChapterNotes.self,
                                                 options: GenerationOptions(temperature: 0.2))
        return response.content
    }

    // MARK: - Reduce

    private func summarize(_ parts: [ChapterNotes]) async throws -> SessionSummary {
        let outline = parts.map { "- \($0.heading): " + $0.keyPoints.prefix(3).joined(separator: "; ") }
            .joined(separator: "\n")
        let session = LanguageModelSession(instructions: "Summarize study notes faithfully. Do not add facts.")
        return try await session.respond(to: "NOTES OUTLINE:\n\(outline.prefix(7000))",
                                         generating: SessionSummary.self,
                                         options: GenerationOptions(temperature: 0.2)).content
    }

    private func render(summary: SessionSummary, parts: [ChapterNotes]) -> String {
        var md = "# \(summary.title)\n\n\(summary.overview)\n"

        var seen = Set<String>()
        let actions = parts.flatMap(\.actionItems).filter { seen.insert($0.task.lowercased()).inserted }
        if !actions.isEmpty {
            md += "\n## Action items\n"
            for a in actions {
                var line = "- [ ] \(a.task)"
                if !a.owner.isEmpty { line += " (\(a.owner))" }
                if !a.due.isEmpty { line += " — due \(a.due)" }
                md += line + "\n"
            }
        }
        for p in parts {
            md += "\n## \(p.heading)\n"
            md += p.keyPoints.map { "- \($0)" }.joined(separator: "\n") + "\n"
            if !p.concepts.isEmpty {
                md += p.concepts.map { "  - **\($0.term)**: \($0.explanation)" }.joined(separator: "\n") + "\n"
            }
        }
        let concepts = parts.flatMap(\.concepts)
        if !concepts.isEmpty {
            var seenC = Set<String>()
            md += "\n## Key concepts\n"
            for c in concepts where seenC.insert(c.term.lowercased()).inserted {
                md += "- **\(c.term)**: \(c.explanation)\n"
            }
        }
        return md
    }
}

/// Works on every device, no model needed. Deterministic.
enum RuleBasedNotes {
    static let actionCues = ["need to", "needs to", "have to", "has to", "will ", "i'll ", "we'll ", "let's ",
                             "action item", "todo", "to do", "by monday", "by tuesday", "by wednesday",
                             "by thursday", "by friday", "by tomorrow", "next week", "deadline", "follow up"]

    static func render(_ chapters: [Chapter]) -> String {
        var md = "# Notes\n"
        var actions: [String] = []
        for (i, c) in chapters.enumerated() {
            let title = c.visualText?.split(separator: "\n").first.map { String($0).replacingOccurrences(of: "# ", with: "") }
            md += "\n## \(title ?? "Part \(i + 1)")\n"
            if let slide = c.visualText {
                let bullets = slide.split(separator: "\n").dropFirst().prefix(6)
                md += bullets.map { "- \($0)" }.joined(separator: "\n") + (bullets.isEmpty ? "" : "\n")
            }
            let sentences = splitSentences(c.speech)
            let key = sentences.filter { $0.split(separator: " ").count >= 8 }.prefix(3)
            if !key.isEmpty { md += key.map { "- \($0)" }.joined(separator: "\n") + "\n" }
            actions += sentences.filter { s in actionCues.contains { s.lowercased().contains($0) } }
        }
        if !actions.isEmpty {
            md += "\n## Possible action items\n" + actions.prefix(15).map { "- [ ] \($0)" }.joined(separator: "\n") + "\n"
        }
        return md
    }

    static func splitSentences(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { out.append(s) }
        }
        return out
    }
}
