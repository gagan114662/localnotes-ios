import AVFAudio
import Foundation
import PhotosUI
import SwiftData
import SwiftUI
import ReplayKit

/// Wires the modules together for one session.
@MainActor
@Observable
final class RecordingController {
    enum State: Equatable { case idle, preparing, recording, finishing, error(String) }

    private(set) var state: State = .idle
    private(set) var store: TranscriptStore?
    private(set) var session: Session?

    private let context: ModelContext
    private let transcriber = TranscriptionService()
    private var capture: AudioCaptureEngine?
    private var pumpTask: Task<Void, Never>?
    private var interruptedAt: Date?

    init(context: ModelContext) { self.context = context }

    func start(title: String) async {
        state = .preparing
        guard await AudioCaptureEngine.requestPermission(),
              await TranscriptionService.requestAuthorization() else {
            state = .error("Microphone and speech permissions are needed."); return
        }
        do {
            let format = try await transcriber.prepare(locale: .current)
            let session = Session(title: title)
            context.insert(session)
            let store = TranscriptStore(context: context, session: session)
            self.session = session
            self.store = store

            try await transcriber.start(sessionStart: session.startedAt) { result in
                await MainActor.run { store.handle(result) }
            }
            let capture = AudioCaptureEngine(targetFormat: format)
            self.capture = capture
            let events = try capture.start()
            let transcriber = self.transcriber
            pumpTask = Task { [weak self] in
                for await event in events {
                    switch event {
                    case .buffer(let buffer, _):
                        await transcriber.append(buffer)
                    case .interrupted(let at):
                        await MainActor.run { self?.interruptedAt = at }
                    case .resumed(let at):
                        await MainActor.run {
                            if let from = self?.interruptedAt { store.markInterruption(from: from, to: at) }
                            self?.interruptedAt = nil
                        }
                    }
                }
            }
            state = .recording
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func stop() async {
        state = .finishing
        capture?.stop()
        await pumpTask?.value
        await transcriber.finish()
        session?.endedAt = .now
        await importBroadcastFrames()
        store?.close()
        state = .idle
    }

    /// Pulls frames saved by the broadcast extension during this session, OCRs them, and attaches them.
    func importBroadcastFrames() async {
        guard let session else { return }
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: AppGroup.framesDirectory, includingPropertiesForKeys: nil)) ?? []
        let end = session.endedAt ?? .now
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let at = AppGroup.captureDate(fromFrameURL: url), at >= session.startedAt, at <= end,
                  let item = try? await VisualIngest.broadcastFrame(at: url) else { continue }
            add(item, to: session)
            try? fm.removeItem(at: url)
        }
        try? context.save()
    }

    func importPhoto(_ data: Data) async {
        guard let session, let item = try? await VisualIngest.image(data: data, fallbackDate: .now) else { return }
        add(item, to: session); try? context.save()
    }

    func importPDF(_ url: URL) async {
        guard let session else { return }
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        for item in (try? await VisualIngest.pdf(at: url)) ?? [] { add(item, to: session) }
        try? context.save()
    }

    func generateNotes() async {
        guard let session else { return }
        let segs = session.segments.filter { !$0.isInterruptionMarker }
            .map { Contextualizer.Seg(id: $0.id, text: $0.text, start: $0.startedAt, end: $0.endedAt) }
        let vis = session.visuals.map {
            Contextualizer.Vis(id: $0.id, text: $0.ocrText, capturedAt: $0.capturedAt, pageIndex: $0.pageIndex)
        }
        let chapters = Contextualizer().chapters(segments: segs, visuals: vis)
        do {
            let (md, engine) = try await NoteGenerator().generate(chapters: chapters)
            let note = Note(markdown: md, generator: engine.rawValue,
                            sourceSegmentIDs: chapters.flatMap(\.segmentIDs),
                            sourceVisualIDs: chapters.compactMap(\.visualID))
            note.session = session
            context.insert(note)
            try context.save()
        } catch {
            state = .error("Could not generate notes: \(error.localizedDescription)")
        }
    }

    private func add(_ item: VisualIngest.Item, to session: Session) {
        let v = VisualCapture(source: item.source, capturedAt: item.capturedAt, pageIndex: item.pageIndex,
                              imageData: item.jpeg, ocrText: item.ocrText)
        v.session = session
        context.insert(v)
    }
}

// MARK: - UI

@main
struct LocalNotesApp: App {
    let container: ModelContainer = {
        do { return try .localNotes() } catch { fatalError("Store failed: \(error)") }
    }()

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("-demo") {
                DemoView(runner: DemoRunner(context: container.mainContext))
            } else {
                RecordView(context: container.mainContext)
            }
        }
            .modelContainer(container)
    }
}

struct RecordView: View {
    @State private var controller: RecordingController
    @State private var photo: PhotosPickerItem?
    @State private var showPDF = false

    init(context: ModelContext) { _controller = State(initialValue: RecordingController(context: context)) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if controller.state == .recording {
                    Label("Recording — stays on this device", systemImage: "record.circle")
                        .foregroundStyle(.red).font(.headline)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(controller.store?.finalSegments ?? []) { seg in
                            Text(seg.text).foregroundStyle(seg.isInterruptionMarker ? .secondary : .primary)
                        }
                        if let live = controller.store?.liveText, !live.isEmpty {
                            Text(live).foregroundStyle(.secondary).italic()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button(controller.state == .recording ? "Stop" : "Record") {
                        Task {
                            if controller.state == .recording { await controller.stop() }
                            else { await controller.start(title: Date.now.formatted(date: .abbreviated, time: .shortened)) }
                        }
                    }.buttonStyle(.borderedProminent)

                    // Starts a whole-screen broadcast (pick "LocalNotesBroadcast"), e.g. for Google Slides.
                    BroadcastPickerButton().frame(width: 44, height: 44)

                    PhotosPicker("Slide photo", selection: $photo, matching: .images)
                    Button("PDF") { showPDF = true }
                    Button("Notes") { Task { await controller.generateNotes() } }
                        .disabled(controller.session == nil)
                }
                if case .error(let msg) = controller.state { Text(msg).foregroundStyle(.red) }
                if let md = controller.session?.notes.sorted(by: { $0.createdAt < $1.createdAt }).last?.markdown,
                   let attributed = try? AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                    ScrollView { Text(attributed).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
            .padding()
            .navigationTitle("LocalNotes")
            .onChange(of: photo) { _, item in
                Task { if let data = try? await item?.loadTransferable(type: Data.self) { await controller.importPhoto(data) } }
            }
            .fileImporter(isPresented: $showPDF, allowedContentTypes: [.pdf]) { result in
                if case .success(let url) = result { Task { await controller.importPDF(url) } }
            }
        }
    }
}

struct BroadcastPickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: .init(x: 0, y: 0, width: 44, height: 44))
        v.preferredExtension = Bundle.main.bundleIdentifier.map { $0 + ".LocalNotesBroadcast" }
        v.showsMicrophoneButton = false   // the app already records the mic
        return v
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
