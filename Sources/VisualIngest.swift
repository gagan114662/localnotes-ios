import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UIKit
import Vision

/// On-device text recognition for slides, screenshots, photos and PDF pages.
enum VisionOCR {
    struct Line: Sendable {
        let text: String
        let box: CGRect       // normalized, origin bottom-left
        let height: CGFloat   // used to spot titles (largest text near the top)
    }

    /// Returns recognized lines in reading order (top to bottom, left to right).
    static func recognize(_ image: CGImage) async throws -> [Line] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let observations = try await request.perform(on: image)
        return observations
            .compactMap { obs -> Line? in
                guard let candidate = obs.topCandidates(1).first else { return nil }
                let r = obs.boundingBox.cgRect
                return Line(text: candidate.string, box: r, height: r.height)
            }
            .sorted { a, b in
                abs(a.box.midY - b.box.midY) > 0.01 ? a.box.midY > b.box.midY : a.box.minX < b.box.minX
            }
    }

    /// Slide-friendly text: first line = probable title (largest text in the top third).
    static func slideText(from lines: [Line]) -> String {
        guard !lines.isEmpty else { return "" }
        let top = lines.filter { $0.box.midY > 0.66 }
        let title = top.max(by: { $0.height < $1.height })
        var body = lines.map(\.text)
        if let title, let i = body.firstIndex(of: title.text) {
            body.remove(at: i)
            return "# \(title.text)\n" + body.joined(separator: "\n")
        }
        return body.joined(separator: "\n")
    }
}

/// Turns imports into VisualCapture records (with OCR).
enum VisualIngest {
    struct Item: Sendable {
        let source: VisualSource
        let capturedAt: Date?
        let pageIndex: Int?
        let jpeg: Data
        let ocrText: String
    }

    /// Photo or screenshot. Uses the EXIF/creation date when present so it can be time-aligned.
    static func image(data: Data, fallbackDate: Date? = nil) async throws -> Item {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw IngestError.unreadable }
        let date = exifDate(src) ?? fallbackDate
        let lines = try await VisionOCR.recognize(cg)
        return Item(source: .photo, capturedAt: date, pageIndex: nil,
                    jpeg: jpeg(cg), ocrText: VisionOCR.slideText(from: lines))
    }

    /// Broadcast frame saved by the extension (time from the file name).
    static func broadcastFrame(at url: URL) async throws -> Item {
        let data = try Data(contentsOf: url)
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw IngestError.unreadable }
        let lines = try await VisionOCR.recognize(cg)
        return Item(source: .broadcast, capturedAt: AppGroup.captureDate(fromFrameURL: url), pageIndex: nil,
                    jpeg: data, ocrText: VisionOCR.slideText(from: lines))
    }

    /// PDF (e.g. Google Slides → File → Download → PDF). Uses the embedded text when present, OCR otherwise.
    static func pdf(at url: URL, maxPages: Int = 200) async throws -> [Item] {
        guard let doc = PDFDocument(url: url) else { throw IngestError.unreadable }
        var items: [Item] = []
        for i in 0..<min(doc.pageCount, maxPages) {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale = 1600 / max(bounds.width, 1)
            let thumb = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
            guard let cg = thumb.cgImage else { continue }
            let embedded = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let text = embedded.count > 20 ? embedded : VisionOCR.slideText(from: try await VisionOCR.recognize(cg))
            items.append(Item(source: .document, capturedAt: nil, pageIndex: i, jpeg: jpeg(cg), ocrText: text))
        }
        return items
    }

    // MARK: - Helpers

    private static func jpeg(_ cg: CGImage) -> Data {
        UIImage(cgImage: cg).jpegData(compressionQuality: 0.7) ?? Data()
    }

    private static func exifDate(_ src: CGImageSource) -> Date? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.timeZone = .current
        return f.date(from: s)
    }
}

enum IngestError: LocalizedError {
    case unreadable
    var errorDescription: String? { "This file could not be read." }
}
