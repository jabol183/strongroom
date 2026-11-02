import Foundation

/// One flat directory of opaque, encrypted blobs. Every name is 32 random-looking
/// hex characters, whether it's a vault header, an index, a thumbnail or a photo,
/// so the directory doesn't reveal which blob belongs to which vault.
struct BlobStorage: Sendable {
    let root: URL

    static func appDefault() throws -> BlobStorage {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return try BlobStorage(root: support.appendingPathComponent("Store", isDirectory: true))
    }

    init(root: URL) throws {
        self.root = root
        var dir = root
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        // Device backups are useless here: the device salt never leaves this phone.
        // Encrypted backup of our own arrives with CloudKit in a later step.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try dir.setResourceValues(values)
    }

    static func randomName() throws -> String {
        try KDF.randomBytes(16).hexString
    }

    func url(for name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: false)
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: name).path)
    }

    func read(_ name: String) throws -> Data {
        try Data(contentsOf: url(for: name))
    }

    func write(_ data: Data, to name: String) throws {
        try data.write(to: url(for: name), options: [.atomic, .completeFileProtection])
    }

    func delete(_ name: String) {
        try? FileManager.default.removeItem(at: url(for: name))
    }

    func allNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
    }
}
