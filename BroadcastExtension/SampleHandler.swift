import Accelerate
import CoreImage
import CoreMedia
import ReplayKit

/// Broadcast Upload Extension: captures the whole screen while the user flips through Google Slides
/// (or anything else) and saves a JPEG ONLY when the screen content really changed (a new slide).
///
/// Memory limit for this extension is about 50 MB, so: downsample hard, keep one previous fingerprint,
/// no OCR here (the main app does OCR when it imports the frames from the App Group folder).
final class SampleHandler: RPBroadcastSampleHandler {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var lastFingerprint: [Float]?
    private var lastSavedAt = Date.distantPast
    private var pendingFingerprint: [Float]?
    private var pendingSince = Date.distantPast
    private var lastSampleAt = Date.distantPast

    // Tunables
    private let sampleInterval: TimeInterval = 0.5   // look at 2 frames/second at most
    private let changeThreshold: Float = 0.08         // mean abs diff (0...1) that counts as "new content"
    private let settleTime: TimeInterval = 1.0        // new content must stay stable this long (skip animations)
    private let fingerprintSide = 32                  // 32x32 grayscale fingerprint

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        _ = AppGroup.framesDirectory
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSampleAt) >= sampleInterval else { return }
        lastSampleAt = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        autoreleasepool {
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            guard let fp = fingerprint(image) else { return }

            // First frame: save it.
            guard let last = lastFingerprint else {
                save(image, at: now); lastFingerprint = fp; return
            }
            if distance(fp, last) < changeThreshold {
                pendingFingerprint = nil          // back to the saved slide; nothing to do
                return
            }
            // Content changed: wait until it settles (slide transitions, scrolling).
            if let pending = pendingFingerprint, distance(fp, pending) < changeThreshold / 2 {
                if now.timeIntervalSince(pendingSince) >= settleTime {
                    save(image, at: now)
                    lastFingerprint = fp
                    pendingFingerprint = nil
                }
            } else {
                pendingFingerprint = fp
                pendingSince = now
            }
        }
    }

    // MARK: - Helpers

    private func fingerprint(_ image: CIImage) -> [Float]? {
        let side = CGFloat(fingerprintSide)
        let scaled = image
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .transformed(by: CGAffineTransform(scaleX: side / image.extent.width, y: side / image.extent.height))
        var bytes = [UInt8](repeating: 0, count: fingerprintSide * fingerprintSide * 4)
        ciContext.render(scaled, toBitmap: &bytes, rowBytes: fingerprintSide * 4,
                         bounds: CGRect(x: 0, y: 0, width: side, height: side),
                         format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return stride(from: 0, to: bytes.count, by: 4).map { Float(bytes[$0]) / 255 }
    }

    private func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var diff = [Float](repeating: 0, count: a.count)
        vDSP_vsub(b, 1, a, 1, &diff, 1, vDSP_Length(a.count))
        var mean: Float = 0
        vDSP_meamgv(diff, 1, &mean, vDSP_Length(diff.count))
        return mean
    }

    private func save(_ image: CIImage, at date: Date) {
        // Downsample to max 1600 px on the long side to keep memory and disk low.
        let longSide = max(image.extent.width, image.extent.height)
        let scale = min(1, 1600 / longSide)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let data = ciContext.jpegRepresentation(of: scaled, colorSpace: CGColorSpaceCreateDeviceRGB(),
                                                      options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7])
        else { return }
        try? data.write(to: AppGroup.frameURL(capturedAt: date), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        lastSavedAt = date
    }
}
