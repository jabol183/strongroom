import CryptoKit
import Foundation

enum VaultError: LocalizedError {
    case corruptHeader
    case itemNotFound
    case folderNotFound
    case invalidMove
    case patternInUse
    case phraseInUse
    case noRecoveryPhrase

    var errorDescription: String? {
        switch self {
        case .corruptHeader: "The vault header couldn't be read."
        case .itemNotFound: "That item no longer exists."
        case .folderNotFound: "That folder no longer exists."
        case .invalidMove: "A folder can't be moved inside itself."
        case .patternInUse: "That pattern already opens a vault. Choose a different one."
        case .phraseInUse: "That phrase already opens another vault. Choose a different one."
        case .noRecoveryPhrase: "This vault has no recovery phrase yet."
        }
    }
}

/// What the UI needs to draw a vault.
struct VaultSnapshot: Sendable {
    var items: [VaultIndex.Item] = []
    var folders: [VaultIndex.Folder] = []
    var settings = VaultIndex.Settings()

    func items(in folderID: UUID?) -> [VaultIndex.Item] {
        items.filter { $0.folderID == folderID }
    }

    func folders(in parentID: UUID?) -> [VaultIndex.Folder] {
        folders.filter { $0.parentID == parentID }.sorted { $0.sortOrder < $1.sortOrder }
    }
}

/// Everything needed to add one item. Prepared (optimized, thumbnailed) by `ImportPipeline`.
struct ImportSource: Sendable {
    enum Payload: Sendable {
        case data(Data)
        case file(URL)
    }

    var payload: Payload
    var kind: VaultIndex.Item.Kind
    var name: String
    var fileExtension: String?
    var takenAt: Date?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var duration: Double?
    var thumbnailJPEG: Data?
    var folderID: UUID?
}

/// An unlocked vault. Holds the master key in memory until the actor is released.
actor Vault {
    static let headerPadding = 1024
    static let indexPadding = 4096
    static let headerAAD = Data("strongroom.header.v1".utf8)
    static let indexAAD = Data("strongroom.index.v1".utf8)
    static let thumbAAD = Data("strongroom.thumb.v1".utf8)

    let storage: BlobStorage
    let masterKey: SymmetricKey
    let indexName: String
    private let indexKey: SymmetricKey
    private(set) var index: VaultIndex
    /// The pattern header this vault was opened with on this device (nil if opened by recovery phrase).
    private(set) var openedHeaderName: String?

    init(storage: BlobStorage, masterKey: SymmetricKey, indexName: String, index: VaultIndex, openedHeaderName: String? = nil) {
        self.storage = storage
        self.masterKey = masterKey
        self.indexKey = KDF.subkey(masterKey, info: "strongroom.index.v1")
        self.indexName = indexName
        self.index = index
        self.openedHeaderName = openedHeaderName
    }

    // MARK: Opening

    enum LocateResult: Sendable {
        case found(Vault)
        case notFound(PendingVault)
    }

    /// Stretches the pattern (slow: ~0.5 s at 600k iterations) and looks for its header.
    static func locate(
        pattern: Pattern,
        deviceSalt: Data,
        storage: BlobStorage,
        iterations: UInt32 = KDF.productionIterations
    ) throws -> LocateResult {
        let keys = try PatternKeys.derive(patternEncoding: pattern.encoded, deviceSalt: deviceSalt, iterations: iterations)
        if let vault = try open(headerName: keys.headerName, wrapKey: keys.wrapKey, storage: storage) {
            return .found(vault)
        }
        return .notFound(PendingVault(keys: keys, storage: storage))
    }

    /// Opens the vault whose header lives at `headerName`, or returns nil if there's no such header.
    /// `isPatternHeader` is false when opening with the recovery phrase.
    static func open(headerName: String, wrapKey: SymmetricKey, storage: BlobStorage, isPatternHeader: Bool = true) throws -> Vault? {
        guard storage.exists(headerName) else { return nil }
        let header: VaultHeader
        do {
            let padded = try Box.open(storage.read(headerName), key: wrapKey, aad: headerAAD)
            header = try JSONDecoder().decode(VaultHeader.self, from: Padding.unpad(padded))
        } catch {
            throw VaultError.corruptHeader
        }
        let masterKey = SymmetricKey(data: header.masterKey)
        let index = try readIndex(name: header.indexName, masterKey: masterKey, storage: storage)
        return Vault(storage: storage, masterKey: masterKey, indexName: header.indexName, index: index, openedHeaderName: isPatternHeader ? headerName : nil)
    }

    static func readIndex(name: String, masterKey: SymmetricKey, storage: BlobStorage) throws -> VaultIndex {
        let key = KDF.subkey(masterKey, info: "strongroom.index.v1")
        let padded = try Box.open(storage.read(name), key: key, aad: indexAAD)
        return try JSONDecoder().decode(VaultIndex.self, from: Padding.unpad(padded))
    }

    /// Writes a header that opens this vault, sealed with `wrapKey`, at `name`.
    static func writeHeader(masterKey: SymmetricKey, indexName: String, wrapKey: SymmetricKey, name: String, storage: BlobStorage) throws {
        let header = VaultHeader(masterKey: masterKey.rawData, indexName: indexName, createdAt: Date())
        let padded = Padding.pad(try JSONEncoder().encode(header), toMultipleOf: headerPadding)
        try storage.write(try Box.seal(padded, key: wrapKey, aad: headerAAD), to: name)
    }

    /// A pattern with no vault yet. Creating it writes an empty index and a header.
    struct PendingVault: @unchecked Sendable {
        let keys: PatternKeys
        let storage: BlobStorage

        func create(settings: VaultIndex.Settings = VaultIndex.Settings()) throws -> Vault {
            let masterKey = SymmetricKey(size: .bits256)
            let indexName = try BlobStorage.randomName()
            var index = VaultIndex()
            index.settings = settings
            try Vault.writeIndex(index, name: indexName, masterKey: masterKey, storage: storage)
            try Vault.writeHeader(masterKey: masterKey, indexName: indexName, wrapKey: keys.wrapKey, name: keys.headerName, storage: storage)
            return Vault(storage: storage, masterKey: masterKey, indexName: indexName, index: index, openedHeaderName: keys.headerName)
        }
    }

    // MARK: Reading

    func snapshot() -> VaultSnapshot {
        VaultSnapshot(
            items: index.items.sorted { $0.sortDate > $1.sortDate },
            folders: index.folders,
            settings: index.settings
        )
    }

    var items: [VaultIndex.Item] { snapshot().items }

    func thumbnail(for item: VaultIndex.Item) throws -> Data? {
        guard let name = item.thumbnailName else { return nil }
        return try Box.open(storage.read(name), key: SymmetricKey(data: item.fileKey), aad: Self.thumbAAD)
    }

    func contents(of item: VaultIndex.Item) throws -> Data {
        try ChunkedCipher.decrypt(storage.read(item.blobName), key: SymmetricKey(data: item.fileKey))
    }

    /// Decrypts into the app's temporary folder for players and previews. Wiped on lock.
    func decryptToTemporaryFile(_ item: VaultIndex.Item) throws -> URL {
        let url = try TempFiles.newURL(name: item.exportFileName)
        try ChunkedCipher.decryptFile(at: storage.url(for: item.blobName), to: url, key: SymmetricKey(data: item.fileKey))
        return url
    }

    /// Every blob this vault owns, including its index (headers are added by the caller).
    func ownedBlobNames() -> Set<String> {
        var names: Set<String> = [indexName]
        for item in index.items {
            names.insert(item.blobName)
            if let thumb = item.thumbnailName { names.insert(thumb) }
        }
        return names
    }

    // MARK: Adding

    @discardableResult
    func add(_ source: ImportSource) throws -> VaultIndex.Item {
        let fileKey = SymmetricKey(size: .bits256)
        let blobName = try BlobStorage.randomName()
        let byteCount: Int
        switch source.payload {
        case .data(let data):
            try storage.write(try ChunkedCipher.encrypt(data, key: fileKey), to: blobName)
            byteCount = data.count
        case .file(let url):
            try ChunkedCipher.encryptFile(at: url, to: storage.url(for: blobName), key: fileKey)
            byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }

        var thumbnailName: String?
        if let thumb = source.thumbnailJPEG {
            let thumbBlob = try BlobStorage.randomName()
            try storage.write(try Box.seal(thumb, key: fileKey, aad: Self.thumbAAD), to: thumbBlob)
            thumbnailName = thumbBlob
        }

        let now = Date()
        let item = VaultIndex.Item(
            kind: source.kind,
            name: source.name,
            takenAt: source.takenAt,
            addedAt: now,
            modifiedAt: now,
            byteCount: byteCount,
            blobName: blobName,
            thumbnailName: thumbnailName,
            fileKey: fileKey.rawData,
            pixelWidth: source.pixelWidth,
            pixelHeight: source.pixelHeight,
            duration: source.duration,
            folderID: source.folderID,
            fileExtension: source.fileExtension
        )
        do {
            try mutate { $0.items.append(item) }
        } catch {
            storage.delete(blobName)
            if let thumbnailName { storage.delete(thumbnailName) }
            throw error
        }
        return item
    }

    /// Convenience used by tests and simple callers.
    @discardableResult
    func importPhoto(_ data: Data, name: String? = nil) throws -> VaultIndex.Item {
        let info = ImageInfo.read(from: data)
        return try add(ImportSource(
            payload: .data(data), kind: .photo, name: name ?? "Photo",
            fileExtension: ImageInfo.fileExtension(of: data) ?? "jpg",
            takenAt: info?.takenAt, pixelWidth: info?.width, pixelHeight: info?.height,
            thumbnailJPEG: ImageInfo.jpegThumbnail(from: data)
        ))
    }

    /// Creates or replaces a text note. Returns the saved item.
    @discardableResult
    func saveNote(id: UUID?, title: String, text: String, folderID: UUID?) throws -> VaultIndex.Item {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled note" : title
        if let id, let existing = index.items.first(where: { $0.id == id }) {
            let fileKey = SymmetricKey(data: existing.fileKey)
            let blobName = try BlobStorage.randomName()
            let data = Data(text.utf8)
            try storage.write(try ChunkedCipher.encrypt(data, key: fileKey), to: blobName)
            var updated = existing
            updated.name = name
            updated.blobName = blobName
            updated.byteCount = data.count
            updated.modifiedAt = Date()
            do {
                try mutate { index in
                    if let i = index.items.firstIndex(where: { $0.id == id }) { index.items[i] = updated }
                }
            } catch {
                storage.delete(blobName)
                throw error
            }
            storage.delete(existing.blobName)
            return updated
        }
        return try add(ImportSource(payload: .data(Data(text.utf8)), kind: .note, name: name, fileExtension: "txt", folderID: folderID))
    }

    // MARK: Editing

    func rename(_ itemID: UUID, to name: String) throws {
        try mutate { index in
            guard let i = index.items.firstIndex(where: { $0.id == itemID }) else { throw VaultError.itemNotFound }
            index.items[i].name = name
            index.items[i].modifiedAt = Date()
        }
    }

    func move(_ itemIDs: Set<UUID>, to folderID: UUID?) throws {
        try mutate { index in
            if let folderID, !index.folders.contains(where: { $0.id == folderID }) { throw VaultError.folderNotFound }
            let now = Date()
            for i in index.items.indices where itemIDs.contains(index.items[i].id) {
                index.items[i].folderID = folderID
                index.items[i].modifiedAt = now
            }
        }
    }

    func delete(_ itemIDs: Set<UUID>) throws {
        let removed = index.items.filter { itemIDs.contains($0.id) }
        try mutate { index in
            index.items.removeAll { itemIDs.contains($0.id) }
            let now = Date()
            for id in itemIDs { index.tombstones[id] = now }
        }
        deleteBlobs(of: removed)
    }

    func delete(_ item: VaultIndex.Item) throws {
        guard index.items.contains(where: { $0.id == item.id }) else { throw VaultError.itemNotFound }
        try delete([item.id])
    }

    // MARK: Folders

    @discardableResult
    func createFolder(named name: String, in parentID: UUID?) throws -> VaultIndex.Folder {
        let siblings = index.folders.filter { $0.parentID == parentID }
        let folder = VaultIndex.Folder(
            name: name, parentID: parentID,
            sortOrder: (siblings.map(\.sortOrder).max() ?? -1) + 1,
            modifiedAt: Date()
        )
        try mutate { $0.folders.append(folder) }
        return folder
    }

    func renameFolder(_ id: UUID, to name: String) throws {
        try mutate { index in
            guard let i = index.folders.firstIndex(where: { $0.id == id }) else { throw VaultError.folderNotFound }
            index.folders[i].name = name
            index.folders[i].modifiedAt = Date()
        }
    }

    func moveFolder(_ id: UUID, to parentID: UUID?) throws {
        try mutate { index in
            guard let i = index.folders.firstIndex(where: { $0.id == id }) else { throw VaultError.folderNotFound }
            if let parentID, index.folders.descendants(of: id).contains(parentID) { throw VaultError.invalidMove }
            let siblings = index.folders.filter { $0.parentID == parentID }
            index.folders[i].parentID = parentID
            index.folders[i].sortOrder = (siblings.map(\.sortOrder).max() ?? -1) + 1
            index.folders[i].modifiedAt = Date()
        }
    }

    /// Deletes the folder, its subfolders and every item inside them.
    func deleteFolder(_ id: UUID) throws {
        let doomed = index.folders.descendants(of: id)
        let removedItems = index.items.filter { $0.folderID.map(doomed.contains) ?? false }
        try mutate { index in
            index.folders.removeAll { doomed.contains($0.id) }
            index.items.removeAll { $0.folderID.map(doomed.contains) ?? false }
            let now = Date()
            for fid in doomed { index.tombstones[fid] = now }
            for item in removedItems { index.tombstones[item.id] = now }
        }
        deleteBlobs(of: removedItems)
    }

    func reorderFolders(in parentID: UUID?, orderedIDs: [UUID]) throws {
        try mutate { index in
            let now = Date()
            for (order, id) in orderedIDs.enumerated() {
                if let i = index.folders.firstIndex(where: { $0.id == id && $0.parentID == parentID }) {
                    index.folders[i].sortOrder = order
                    index.folders[i].modifiedAt = now
                }
            }
        }
    }

    func updateSettings(_ change: (inout VaultIndex.Settings) -> Void) throws {
        try mutate { change(&$0.settings) }
    }

    // MARK: Security

    /// Opens a vault on this device with its recovery phrase, or returns nil if none matches here.
    static func recover(phrase: String, storage: BlobStorage, iterations: UInt32 = KDF.productionIterations) throws -> Vault? {
        let keys = try RecoveryKeys.derive(phrase: phrase, iterations: iterations)
        return try open(headerName: keys.headerName, wrapKey: keys.wrapKey, storage: storage, isPatternHeader: false)
    }

    /// Sets (or replaces) the recovery phrase: writes a header the phrase opens and removes the old one.
    func setRecoveryPhrase(_ phrase: String, iterations: UInt32 = KDF.productionIterations) throws {
        let normalized = RecoveryPhrase.normalize(phrase)
        let keys = try RecoveryKeys.derive(phrase: normalized, iterations: iterations)
        let newName = keys.headerName
        if newName != index.settings.recoveryHeaderName, storage.exists(newName) {
            throw VaultError.phraseInUse
        }
        try Self.writeHeader(masterKey: masterKey, indexName: indexName, wrapKey: keys.wrapKey, name: newName, storage: storage)
        let oldName = index.settings.recoveryHeaderName
        try mutate {
            $0.settings.recoveryPhrase = normalized
            $0.settings.recoveryHeaderName = newName
        }
        if let oldName, oldName != newName { storage.delete(oldName) }
    }

    /// Makes `pattern` open this vault on this device and retires the pattern it was opened with.
    func changePattern(to pattern: Pattern, deviceSalt: Data, iterations: UInt32 = KDF.productionIterations) throws {
        let keys = try PatternKeys.derive(patternEncoding: pattern.encoded, deviceSalt: deviceSalt, iterations: iterations)
        let newName = keys.headerName
        if newName == openedHeaderName { return }
        if storage.exists(newName) { throw VaultError.patternInUse }
        try Self.writeHeader(masterKey: masterKey, indexName: indexName, wrapKey: keys.wrapKey, name: newName, storage: storage)
        if let old = openedHeaderName { storage.delete(old) }
        openedHeaderName = newName
    }

    /// Duress: deletes every blob on this device that doesn't belong to this vault, including
    /// other vaults' headers, indexes, files and recovery headers. Returns how many were removed.
    @discardableResult
    func wipeOtherVaults() throws -> Int {
        var keep = ownedBlobNames()
        if let opened = openedHeaderName { keep.insert(opened) }
        if let recovery = index.settings.recoveryHeaderName { keep.insert(recovery) }
        var removed = 0
        for name in try storage.allNames() where !keep.contains(name) {
            storage.delete(name)
            removed += 1
        }
        return removed
    }

    /// Deletes this vault from the device: items, index and every header that opens it.
    func destroy() {
        for name in ownedBlobNames() { storage.delete(name) }
        if let opened = openedHeaderName { storage.delete(opened) }
        if let recovery = index.settings.recoveryHeaderName { storage.delete(recovery) }
        index = VaultIndex()
    }

    // MARK: Persistence

    /// Applies a change to a copy, writes it, then swaps it in, so a failed write leaves memory and disk consistent.
    func mutate(_ change: (inout VaultIndex) throws -> Void) throws {
        var updated = index
        try change(&updated)
        try Self.writeIndex(updated, name: indexName, masterKey: masterKey, storage: storage)
        index = updated
    }

    /// Replaces the whole index (used by sync after merging).
    func replaceIndex(_ updated: VaultIndex) throws {
        try Self.writeIndex(updated, name: indexName, masterKey: masterKey, storage: storage)
        index = updated
    }

    static func writeIndex(_ index: VaultIndex, name: String, masterKey: SymmetricKey, storage: BlobStorage) throws {
        let key = KDF.subkey(masterKey, info: "strongroom.index.v1")
        let padded = Padding.pad(try JSONEncoder().encode(index), toMultipleOf: indexPadding)
        try storage.write(try Box.seal(padded, key: key, aad: indexAAD), to: name)
    }

    private func deleteBlobs(of items: [VaultIndex.Item]) {
        for item in items {
            storage.delete(item.blobName)
            if let thumb = item.thumbnailName { storage.delete(thumb) }
        }
    }
}

extension VaultIndex.Item {
    /// File name used for temporary decrypted copies and exports.
    var exportFileName: String {
        let base = name.replacingOccurrences(of: "/", with: "-")
        guard let ext = fileExtension, !ext.isEmpty else { return base }
        return base.lowercased().hasSuffix("." + ext.lowercased()) ? base : "\(base).\(ext)"
    }
}

extension SymmetricKey {
    var rawData: Data { withUnsafeBytes { Data($0) } }
}
