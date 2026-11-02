import Foundation

/// Everything a vault knows about its contents. Stored as one encrypted, padded blob.
/// Each item has its own random key, which makes per-item sharing and re-keying
/// possible later without touching other items.
struct VaultIndex: Codable, Sendable {
    var version = 1
    var items: [Item] = []
    /// Reserved for nested folders (step 2).
    var folders: [Folder] = []

    struct Item: Codable, Identifiable, Hashable, Sendable {
        enum Kind: String, Codable, Sendable { case photo, video, file }

        var id = UUID()
        var kind: Kind
        var name: String
        var takenAt: Date?
        var addedAt: Date
        var byteCount: Int
        var blobName: String
        var thumbnailName: String?
        var fileKey: Data
        var pixelWidth: Int?
        var pixelHeight: Int?
        var duration: Double?
        var folderID: UUID?

        var sortDate: Date { takenAt ?? addedAt }
    }

    struct Folder: Codable, Identifiable, Hashable, Sendable {
        var id = UUID()
        var name: String
        var parentID: UUID?
        var sortOrder: Int
    }
}

/// Decrypted contents of a vault header blob. The header's file name is derived
/// from the pattern; its contents are sealed with the pattern's wrap key.
struct VaultHeader: Codable {
    var version = 1
    var masterKey: Data
    var indexName: String
    var createdAt: Date
}
