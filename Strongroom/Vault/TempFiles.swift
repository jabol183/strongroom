import Foundation

/// Decrypted copies (for video playback, previews, exports) and import staging files.
/// Everything lives under one folder that is wiped on lock and on launch.
enum TempFiles {
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Open", isDirectory: true)
    }

    /// A fresh URL with the given file name, in its own subfolder so names never collide.
    static func newURL(name: String) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let safe = name.isEmpty ? "file" : name.replacingOccurrences(of: "/", with: "-")
        return folder.appendingPathComponent(safe, isDirectory: false)
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    static func wipe() {
        try? FileManager.default.removeItem(at: directory)
    }
}
