# LocalNotes: on-device lecture/meeting notes for iPhone and iPad

Records continuously, transcribes on the device, keeps the raw transcript untouched, captures slides
(Google Slides, screenshots, PDFs, photos), and writes structured notes that tie each slide to what was said.
No audio, transcript, image or note ever leaves the device. No cloud APIs, no API keys, no usage bills.

Status: source written for iOS/iPadOS 26 (Xcode 26). NOT yet compiled: no Mac with Xcode 26 is available
(the Mac has Command Line Tools only, macOS 15.7). First step on a Mac with Xcode 26: create the project as
described in "Project setup" and build; expect small API-signature fixes.

---

## 1. Architecture

```
            ┌──────────────── Main app (SwiftUI) ────────────────┐
 Mic ──► AudioCaptureEngine ──buffers──► TranscriptionService ──► TranscriptStore (append-only)
             │ (AVAudioEngine, bg audio)     (SpeechAnalyzer +        │  SwiftData + JSONL per session
             └─► raw .caf chunks (optional)   SpeechTranscriber)      │
                                                                      ▼
 Photos / Files / PDF ──► VisualIngest ──► VisionOCR ──► VisualStore ──► Contextualizer ──► NoteGenerator
                                ▲          (Vision)      (SwiftData)     (time + text        (Foundation
 Broadcast Upload Extension ────┘                                          alignment,         Models, map-
 (ReplayKit: whole screen, incl.                                           NLEmbedding)       reduce) ──► Note
  Google Slides; dedupes frames,                                                                         (Markdown)
  writes JPEGs to App Group)
```

Modules (one file each in `Sources/`):

| Module | Job | Apple framework |
|---|---|---|
| `AudioCaptureEngine` | Mic capture that survives screen lock, interruptions, route changes; feeds buffers in the analyzer's format | AVFAudio |
| `TranscriptionService` | Live, long-form, on-device speech-to-text with timestamps; volatile (live) and final results | Speech (`SpeechAnalyzer`, `SpeechTranscriber`); fallback `SFSpeechRecognizer` with `requiresOnDeviceRecognition` |
| `TranscriptStore` | Append-only raw transcript. Final segments are never edited. Mirrored to a JSONL file per session for crash safety and export | SwiftData, FileManager (`.complete` file protection) |
| `VisualIngest` + `VisionOCR` | Imports photos, screenshots, PDFs (one image per page), and broadcast frames; extracts text with positions | PhotosUI, PDFKit, Vision (`RecognizeTextRequest`) |
| `BroadcastExtension` | Captures the whole screen while Google Slides (or anything) is open; keeps only frames that changed (slide changes) | ReplayKit |
| `Contextualizer` | Links each slide to the transcript: by time for live captures, by meaning for imported files | NaturalLanguage (`NLEmbedding`) |
| `NoteGenerator` | Turns slide + transcript chunks into structured notes, then merges them | FoundationModels (`@Generable`) |

### Key design decisions

1. **Raw is sacred.** Transcript segments are append-only. Notes are a derived artifact with a `sourceSegmentIDs`
   trail, so every bullet can be traced back to the raw words, and notes can be regenerated any time.
2. **Wall-clock timeline.** Every segment and every visual capture is stamped with absolute `Date`. The
   transcriber's `audioTimeRange` is converted with `sessionStart + offset`. This is what lets a slide captured at
   10:42:13 attach to the words spoken while it was on screen.
3. **Map-reduce notes.** The on-device model has a small context window (about 4K tokens). Notes are generated per
   "chapter" (one slide plus its speech, or about 1,200 words of speech when there are no slides), then merged.
4. **Extensions stay tiny.** Broadcast extensions have a memory limit of about 50 MB, so the extension only
   downsamples, dedupes and saves JPEGs. OCR and notes run in the main app.
5. **Graceful device tiers.**
   - Transcription: `SpeechTranscriber` (iOS 26, all supported devices) → `SFSpeechRecognizer` on-device.
   - Notes: Apple Foundation Models (Apple Intelligence devices: iPhone 15 Pro and later, M1 iPads and later)
     → optional MLX Swift with a small open model (e.g. a 1.5–3B instruct model, 4-bit) → rule-based outline
     (headings from slides, sentences with "need to / will / by Friday" as action items).

### iOS limits you must design around (no workaround exists)

- Recording must **start in the foreground**. It then continues in the background with the orange mic dot.
- A phone call or Siri **interrupts** recording. The engine restarts automatically when the interruption ends
  (`.shouldResume`), and the gap is recorded as a marker in the transcript.
- iOS can still end a background app under memory pressure. The JSONL mirror means nothing already
  transcribed is lost.
- Screen capture of other apps is only possible through a **user-started broadcast** (Control Center or the
  in-app picker). There is no silent screen capture.
- Recording other people may require their consent depending on where you are. Show a clear recording banner.

---

## 2. Tech stack

- Swift 6, SwiftUI, SwiftData, iOS/iPadOS 26 minimum (for `SpeechAnalyzer` and Foundation Models).
- Speech-to-text: `SpeechAnalyzer` + `SpeechTranscriber` (on-device, long-form, fast). Language assets are downloaded
  once by the OS through `AssetInventory` and then work offline.
  - Alternative: WhisperKit (open source, Core ML Whisper), if you need a language Apple doesn't cover.
- OCR: Vision `RecognizeTextRequest` (accurate mode, language correction on).
- Semantic matching: `NLEmbedding.sentenceEmbedding(for:)`, on-device.
- Notes: `FoundationModels` (`LanguageModelSession`, guided generation with `@Generable`).
- Screen capture: ReplayKit Broadcast Upload Extension + App Group shared container.
- Storage: SwiftData in the App Group container; files with `FileProtectionType.complete`.

---

## 3. Project setup (Xcode 26)

1. New project → iOS App "LocalNotes", SwiftUI, SwiftData. Deployment target iOS 26.0, iPhone + iPad.
2. Add target → **Broadcast Upload Extension** "LocalNotesBroadcast" (no UI extension needed).
3. Signing & Capabilities on both targets → **App Groups** → `group.com.yourcompany.localnotes`
   (set the same value in `AppGroup.id` in `Shared/AppGroup.swift`).
4. App target → **Background Modes** → check *Audio, AirPlay, and Picture in Picture*.
5. App target Info.plist:
   - `NSMicrophoneUsageDescription`: "LocalNotes records audio to transcribe it on this device. Audio never leaves your device."
   - `NSSpeechRecognitionUsageDescription`: "Speech is transcribed on this device only."
   - `NSPhotoLibraryUsageDescription`: "Import slide photos and screenshots."
6. Copy `Sources/*` into the app target, `Shared/*` into both targets, `BroadcastExtension/SampleHandler.swift`
   into the extension target (replace the template).
7. Run on a real device (the simulator has no on-device speech assets or Apple Intelligence).

---

## 4. Step-by-step build order

1. `AudioCaptureEngine` + a record button. Verify: record with the screen locked for 10 minutes; take a call in the middle.
2. `TranscriptionService` + `TranscriptStore`. Verify: live text appears within about 1 s; final segments survive force-quit (JSONL).
3. `VisualIngest` + `VisionOCR`: import a Google Slides PDF export and a screenshot. Verify: OCR text per page.
4. `BroadcastExtension`: start a broadcast, flip through 5 slides in Google Slides. Verify: exactly 5 frames saved.
5. `Contextualizer`: verify each slide gets the speech spoken while it was visible (live) or the best-matching window (import).
6. `NoteGenerator`: verify every action item quotes a real segment; regenerate gives the same structure.

### Tests that matter (black-box, through public interfaces)

- 60-minute recording → transcript duration within 1% of audio duration, no gap longer than 2 s except interruptions.
- Airplane mode on for the whole session → everything still works (proves no cloud dependency).
- Slide change detector: 20 distinct slides + 100 near-duplicate frames (cursor moves, video in slide) → 20 kept.
- Alignment: scripted session with known slide times → at least 95% of words attached to the right slide.
- Notes: action-item recall on a scripted meeting with 8 known action items → at least 7 found, 0 invented
  (each must cite a segment that contains it).
- Privacy: run with a network proxy logging all traffic → zero requests carrying audio/text.
