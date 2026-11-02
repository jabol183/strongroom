import Foundation

/// Merges two copies of the same vault's index (this device and the cloud).
/// Commutative and idempotent, so devices converge whatever order they sync in.
///
/// - Items and folders: union by ID; the newer `modifiedAt` wins.
/// - Deletes: tombstones are unioned. A tombstone removes the item or folder unless it
///   was changed after the deletion.
/// - Items or folders whose folder no longer exists move to the top level.
/// - Settings: the newer set wins wholesale (including the share list); the backup revision is the max.
enum VaultMerge {
    static func merge(_ a: VaultIndex, _ b: VaultIndex) -> VaultIndex {
        var result = VaultIndex()
        result.version = max(a.version, b.version)
        result.tombstones = a.tombstones.merging(b.tombstones, uniquingKeysWith: max)

        var items: [UUID: VaultIndex.Item] = [:]
        for item in a.items + b.items {
            guard let existing = items[item.id] else {
                items[item.id] = item
                continue
            }
            // Newer wins; ties break on blob name so both devices pick the same copy.
            if item.changedAt > existing.changedAt
                || (item.changedAt == existing.changedAt && item.blobName > existing.blobName) {
                items[item.id] = item
            }
        }
        var folders: [UUID: VaultIndex.Folder] = [:]
        for folder in a.folders + b.folders {
            guard let existing = folders[folder.id] else {
                folders[folder.id] = folder
                continue
            }
            if folder.changedAt > existing.changedAt
                || (folder.changedAt == existing.changedAt && folder.name > existing.name) {
                folders[folder.id] = folder
            }
        }

        func alive(_ id: UUID, changedAt: Date) -> Bool {
            guard let deletedAt = result.tombstones[id] else { return true }
            return changedAt > deletedAt
        }
        var liveFolders = folders.values.filter { alive($0.id, changedAt: $0.changedAt) }
        let folderIDs = Set(liveFolders.map(\.id))
        for i in liveFolders.indices {
            if let parent = liveFolders[i].parentID, !folderIDs.contains(parent) { liveFolders[i].parentID = nil }
        }
        // Concurrent moves on two devices can create a cycle (A in B, B in A); lift such folders to the top.
        let parentOf = Dictionary(uniqueKeysWithValues: liveFolders.map { ($0.id, $0.parentID) })
        for i in liveFolders.indices {
            var seen: Set<UUID> = [liveFolders[i].id]
            var cursor = liveFolders[i].parentID
            while let current = cursor {
                if !seen.insert(current).inserted {
                    liveFolders[i].parentID = nil
                    break
                }
                cursor = parentOf[current] ?? nil
            }
        }
        var liveItems = items.values.filter { alive($0.id, changedAt: $0.changedAt) }
        for i in liveItems.indices {
            if let folder = liveItems[i].folderID, !folderIDs.contains(folder) { liveItems[i].folderID = nil }
        }
        result.folders = liveFolders.sorted { ($0.sortOrder, $0.id.uuidString) < ($1.sortOrder, $1.id.uuidString) }
        result.items = liveItems.sorted { ($0.addedAt, $0.id.uuidString) < ($1.addedAt, $1.id.uuidString) }

        let aTime = a.settings.modifiedAt ?? .distantPast
        let bTime = b.settings.modifiedAt ?? .distantPast
        var settings = aTime >= bTime ? a.settings : b.settings
        settings.lastBackupRevision = max(a.settings.lastBackupRevision, b.settings.lastBackupRevision)
        result.settings = settings
        return result
    }
}
