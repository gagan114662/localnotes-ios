import Foundation

/// Shared between the app and the Broadcast Upload Extension.
enum AppGroup {
    /// Must match the App Group capability on BOTH targets.
    static let id = "group.com.yourcompany.localnotes"

    static var container: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) { return url }
        // Unsigned builds (simulator, CI) have no App Group: fall back to the app's own Application Support.
        let url = URL.applicationSupportDirectory.appending(path: "LocalNotes", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Frames saved by the broadcast extension: <container>/Frames/<epochMillis>.jpg
    static var framesDirectory: URL {
        let dir = container.appending(path: "Frames", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return dir
    }

    /// File name encodes the capture time so the app can align it with the transcript.
    static func frameURL(capturedAt date: Date) -> URL {
        framesDirectory.appending(path: "\(Int64(date.timeIntervalSince1970 * 1000)).jpg")
    }

    static func captureDate(fromFrameURL url: URL) -> Date? {
        guard let ms = Int64(url.deletingPathExtension().lastPathComponent) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }
}
