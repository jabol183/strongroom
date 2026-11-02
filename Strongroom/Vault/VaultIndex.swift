import Foundation

/// Everything a vault knows about its contents. Stored as one encrypted, padded blob.
/// Each item has its own random key, which makes per-item sharing and re-keying
/// possible without touching other items.
///
/// Decoding is tolerant (missing keys fall back to defaults) so the format can grow.
struct VaultIndex: Codable, Sendable {
    var version = 2
    var items: [Item] = []
    var folders: [Folder] = []
    /// Deleted item and folder IDs with deletion time, so sync can propagate deletes.
    var tombstones: [UUID: Date] = [:]
    var settings = Settings()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
        folders = try c.decodeIfPresent([Folder].self, forKey: .folders) ?? []
        tombstones = try c.decodeIfPresent([UUID: Date].self, forKey: .tombstones) ?? [:]
        settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
    }

    struct Item: Codable, Identifiable, Hashable, Sendable {
        enum Kind: String, Codable, Sendable { case photo, video, file, note }

        var id = UUID()
        var kind: Kind
        var name: String
        var takenAt: Date?
        var addedAt: Date
        var modifiedAt: Date?
        var byteCount: Int
        var blobName: String
        var thumbnailName: String?
        var fileKey: Data
        var pixelWidth: Int?
        var pixelHeight: Int?
        var duration: Double?
        var folderID: UUID?
        /// File name extension used when the item is opened or exported ("heic", "mov", "pdf").
        var fileExtension: String?

        var sortDate: Date { takenAt ?? addedAt }
        var changedAt: Date { modifiedAt ?? addedAt }
        var isVisualMedia: Bool { kind == .photo || kind == .video }
    }

    struct Folder: Codable, Identifiable, Hashable, Sendable {
        var id = UUID()
        var name: String
        var parentID: UUID?
        var sortOrder: Int
        var modifiedAt: Date?

        var changedAt: Date { modifiedAt ?? .distantPast }
    }

    struct Settings: Codable, Hashable, Sendable {
        /// The vault's recovery phrase, kept so it can be shown again while unlocked.
        var recoveryPhrase: String?
        /// File name of the header that the recovery phrase opens (phrase-derived, same on every device).
        var recoveryHeaderName: String?
        /// Opening this vault wipes every other vault on the device.
        var isDuress = false
        var backupEnabled = true
        var shares: [ShareRecord] = []
        /// When any setting last changed; the newer settings win when devices merge.
        var modifiedAt: Date?
        /// Highest backup revision this vault has written or read. Non-zero means a cloud copy exists.
        var lastBackupRevision = 0

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            recoveryPhrase = try c.decodeIfPresent(String.self, forKey: .recoveryPhrase)
            recoveryHeaderName = try c.decodeIfPresent(String.self, forKey: .recoveryHeaderName)
            isDuress = try c.decodeIfPresent(Bool.self, forKey: .isDuress) ?? false
            backupEnabled = try c.decodeIfPresent(Bool.self, forKey: .backupEnabled) ?? true
            shares = try c.decodeIfPresent([ShareRecord].self, forKey: .shares) ?? []
            modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt)
            lastBackupRevision = try c.decodeIfPresent(Int.self, forKey: .lastBackupRevision) ?? 0
        }
    }

    /// A share this vault created, so it can be listed and revoked.
    struct ShareRecord: Codable, Hashable, Identifiable, Sendable {
        var id: String            // public-database record name of the share manifest
        var createdAt: Date
        var expiresAt: Date?
        var maxOpens: Int?
        var allowExport: Bool
        var itemCount: Int
        var recordNames: [String] // every public record belonging to the share
    }
}

/// Decrypted contents of a vault header blob. The header's file name is derived
/// from the pattern (or recovery phrase); its contents are sealed with that secret's wrap key.
struct VaultHeader: Codable {
    var version = 1
    var masterKey: Data
    var indexName: String
    var createdAt: Date
}

extension Array where Element == VaultIndex.Folder {
    /// The folder and all folders nested inside it.
    func descendants(of id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var frontier = [id]
        while let next = frontier.popLast() {
            for child in self where child.parentID == next && !result.contains(child.id) {
                result.insert(child.id)
                frontier.append(child.id)
            }
        }
        return result
    }

    /// "Parent / Child" path for display.
    func path(of id: UUID?) -> String {
        var names: [String] = []
        var current = id
        var guardCount = 0
        while let cid = current, let folder = first(where: { $0.id == cid }), guardCount < 64 {
            names.insert(folder.name, at: 0)
            current = folder.parentID
            guardCount += 1
        }
        return names.isEmpty ? "Vault" : names.joined(separator: " / ")
    }
}
