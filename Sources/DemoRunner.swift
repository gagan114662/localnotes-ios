import AVFAudio
import Foundation
import Speech
import SwiftData
import SwiftUI

/// End-to-end demo with no human input, used for the CI video and as an integration test.
/// Launch with argument `-demo`. Uses bundled `demo.aiff` (a spoken meeting) and `slides.pdf` (3 slides).
///
/// Pipeline (same modules as a live session, only the audio source differs):
///   demo.aiff → on-device STT → raw transcript → PDF import + OCR → Contextualizer → NoteGenerator → notes
@MainActor
@Observable
final class DemoRunner {
    struct Step: Identifiable { let id = UUID(); let text: String; let ok: Bool }
    private(set) var steps: [Step] = []
    private(set) var transcript: [String] = []
    private(set) var slideTexts: [String] = []
    private(set) var notes: String = ""
    private(set) var done = false

    private let context: ModelContext
    init(context: ModelContext) { self.context = context }

    func run() async {
        log("Airplane-mode safe: everything below runs on this device", true)
        guard let audioURL = Bundle.main.url(forResource: "demo", withExtension: "aiff"),
              let pdfURL = Bundle.main.url(forResource: "slides", withExtension: "pdf") else {
            log("Demo files missing from bundle", false); done = true; return
        }
        let session = Session(title: "Q4 launch meeting (demo)")
        context.insert(session)
        let store = TranscriptStore(context: context, session: session)

        // 1. Speech to text, on device.
        log("Transcribing meeting audio on device…", true)
        let engineUsed = await transcribe(audioURL, start: session.startedAt, store: store)
        transcript = store.finalSegments.map(\.text)
        log("Raw transcript: \(store.finalSegments.count) segments (\(engineUsed))", !store.finalSegments.isEmpty)

        // 2. Slides: PDF import + on-device OCR.
        log("Reading slides with on-device OCR…", true)
        let items = (try? await VisualIngest.pdf(at: pdfURL)) ?? []
        for item in items {
            let v = VisualCapture(source: item.source, capturedAt: nil, pageIndex: item.pageIndex,
                                  imageData: item.jpeg, ocrText: item.ocrText)
            v.session = session
            context.insert(v)
        }
        slideTexts = items.map { $0.ocrText.split(separator: "\n").first.map(String.init) ?? "" }
        log("Slides read: \(items.count)", items.count == 3)

        // 3. Link speech to slides and write notes.
        let segs = store.finalSegments.map { Contextualizer.Seg(id: $0.id, text: $0.text, start: $0.startedAt, end: $0.endedAt) }
        let vis = session.visuals.map { Contextualizer.Vis(id: $0.id, text: $0.ocrText, capturedAt: nil, pageIndex: $0.pageIndex) }
        let chapters = Contextualizer().chapters(segments: segs, visuals: vis)
        log("Linked speech to \(chapters.filter { !$0.speech.isEmpty }.count) of \(chapters.count) slides", true)

        do {
            let (md, engine) = try await NoteGenerator().generate(chapters: chapters)
            notes = md
            log("Notes written (\(engine.rawValue == "foundation-models" ? "Apple on-device AI" : "rule-based fallback"))", !md.isEmpty)
        } catch {
            log("Notes failed: \(error.localizedDescription)", false)
        }
        store.close()
        try? context.save()
        done = true
        print("DEMO_RESULT steps=\(steps.map { $0.ok ? "ok" : "FAIL" }.joined(separator: ",")) segments=\(transcript.count) slides=\(slideTexts.count)")
        print("DEMO_TRANSCRIPT \(transcript.joined(separator: " | "))")
        print("DEMO_NOTES_BEGIN\n\(notes)\nDEMO_NOTES_END")
    }

    /// SpeechAnalyzer from file; falls back to SFSpeechRecognizer on-device when the new transcriber is unavailable.
    private func transcribe(_ url: URL, start: Date, store: TranscriptStore) async -> String {
        _ = await TranscriptionService.requestAuthorization()
        do {
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
                throw TranscriptionError.localeNotSupported(.current)
            }
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                                attributeOptions: [.audioTimeRange])
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await req.downloadAndInstall()
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let collect = Task { @MainActor in
                for try await r in transcriber.results where r.isFinal {
                    let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    store.handle(.init(text: text, start: start.addingTimeInterval(r.range.start.seconds),
                                       end: start.addingTimeInterval((r.range.start + r.range.duration).seconds), isFinal: true))
                }
            }
            let file = try AVAudioFile(forReading: url)
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            try await collect.value
            if !store.finalSegments.isEmpty { return "SpeechAnalyzer" }
        } catch {
            log("SpeechAnalyzer unavailable here (\(error.localizedDescription)); using on-device SFSpeechRecognizer", true)
        }
        return await legacyTranscribe(url, start: start, store: store)
    }

    private func legacyTranscribe(_ url: URL, start: Date, store: TranscriptStore) async -> String {
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), rec.isAvailable else { return "no recognizer" }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.requiresOnDeviceRecognition = rec.supportsOnDeviceRecognition
        req.addsPunctuation = true
        let onDevice = req.requiresOnDeviceRecognition
        let result: SFSpeechRecognitionResult? = await withCheckedContinuation { cont in
            var resumed = false
            rec.recognitionTask(with: req) { r, err in
                if resumed { return }
                if let r, r.isFinal { resumed = true; cont.resume(returning: r) }
                else if err != nil { resumed = true; cont.resume(returning: nil) }
            }
        }
        guard let result else { return "SFSpeechRecognizer failed" }
        // Split into sentences, keep timings from word segments.
        let segs = result.bestTranscription.segments
        var sentence = "", sStart: TimeInterval? = nil
        for (i, s) in segs.enumerated() {
            if sStart == nil { sStart = s.timestamp }
            sentence += (sentence.isEmpty ? "" : " ") + s.substring
            let last = i == segs.count - 1
            if last || s.substring.hasSuffix(".") || s.substring.hasSuffix("?") || sentence.split(separator: " ").count > 30 {
                store.handle(.init(text: sentence, start: start.addingTimeInterval(sStart ?? 0),
                                   end: start.addingTimeInterval(s.timestamp + s.duration), isFinal: true))
                sentence = ""; sStart = nil
            }
        }
        return onDevice ? "SFSpeechRecognizer, on-device" : "SFSpeechRecognizer"
    }

    private func log(_ text: String, _ ok: Bool) {
        steps.append(Step(text: text, ok: ok))
        print("DEMO_STEP \(ok ? "OK" : "FAIL") \(text)")
    }
}

struct DemoView: View {
    @State var runner: DemoRunner

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(runner.steps) { s in
                        Label(s.text, systemImage: s.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(s.ok ? .green : .red).font(.subheadline)
                    }
                    if !runner.transcript.isEmpty {
                        Text("Raw transcript").font(.headline)
                        Text(runner.transcript.joined(separator: " ")).font(.footnote).foregroundStyle(.secondary)
                    }
                    if !runner.slideTexts.isEmpty {
                        Text("Slides").font(.headline)
                        ForEach(runner.slideTexts, id: \.self) { Text("▸ " + $0.replacingOccurrences(of: "# ", with: "")).font(.footnote) }
                    }
                    if !runner.notes.isEmpty {
                        Text("Notes").font(.headline)
                        Text(runner.notes).font(.footnote.monospaced())
                    }
                    if !runner.done { ProgressView() }
                }
                .padding()
                .accessibilityIdentifier(runner.done ? "demo-done" : "demo-running")
            }
            .navigationTitle("LocalNotes demo")
        }
        .task { await runner.run() }
    }
}
