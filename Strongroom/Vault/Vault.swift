import CryptoKit
import Foundation

enum VaultError: Error {
    case corruptHeader
    case itemNotFound
}

/// An unlocked vault. Holds the master key in memory until the actor is released.
actor Vault {
    static let headerPadding = 1024
    static let indexPadding = 4096
    private static let headerAAD = Data("strongroom.header.v1".utf8)
    private static let indexAAD = Data("strongroom.index.v1".utf8)
    private static let thumbAAD = Data("strongroom.thumb.v1".utf8)

    private let storage: BlobStorage
    private let indexKey: SymmetricKey
    private let indexName: String
    private var index: VaultIndex

    private init(storage: BlobStorage, masterKey: SymmetricKey, indexName: String, index: VaultIndex) {
        self.storage = storage
        self.indexKey = KDF.subkey(masterKey, info: "strongroom.index.v1")
        self.indexName = indexName
        self.index = index
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
        let headerName = keys.headerName
        guard storage.exists(headerName) else {
            return .notFound(PendingVault(keys: keys, storage: storage))
        }
        let sealed = try storage.read(headerName)
        let header: VaultHeader
        do {
            let padded = try Box.open(sealed, key: keys.wrapKey, aad: headerAAD)
            header = try JSONDecoder().decode(VaultHeader.self, from: Padding.unpad(padded))
        } catch {
            throw VaultError.corruptHeader
        }
        let masterKey = SymmetricKey(data: header.masterKey)
        let indexKey = KDF.subkey(masterKey, info: "strongroom.index.v1")
        let indexPadded = try Box.open(storage.read(header.indexName), key: indexKey, aad: indexAAD)
        let index = try JSONDecoder().decode(VaultIndex.self, from: Padding.unpad(indexPadded))
        return .found(Vault(storage: storage, masterKey: masterKey, indexName: header.indexName, index: index))
    }

    /// A pattern with no vault yet. Creating it writes an empty index and a header.
    struct PendingVault: @unchecked Sendable {
        fileprivate let keys: PatternKeys
        fileprivate let storage: BlobStorage

        func create() throws -> Vault {
            let masterKeyData = try KDF.randomBytes(32)
            let masterKey = SymmetricKey(data: masterKeyData)
            let indexName = try BlobStorage.randomName()
            try Vault.writeIndex(
                VaultIndex(), name: indexName,
                key: KDF.subkey(masterKey, info: "strongroom.index.v1"), storage: storage
            )

            let header = VaultHeader(masterKey: masterKeyData, indexName: indexName, createdAt: Date())
            let padded = Padding.pad(try JSONEncoder().encode(header), toMultipleOf: Vault.headerPadding)
            try storage.write(try Box.seal(padded, key: keys.wrapKey, aad: Vault.headerAAD), to: keys.headerName)
            return Vault(storage: storage, masterKey: masterKey, indexName: indexName, index: VaultIndex())
        }
    }

    // MARK: Reading

    var items: [VaultIndex.Item] {
        index.items.sorted { $0.sortDate > $1.sortDate }
    }

    func thumbnail(for item: VaultIndex.Item) throws -> Data? {
        guard let name = item.thumbnailName else { return nil }
        return try Box.open(storage.read(name), key: SymmetricKey(data: item.fileKey), aad: Self.thumbAAD)
    }

    func contents(of item: VaultIndex.Item) throws -> Data {
        try ChunkedCipher.decrypt(storage.read(item.blobName), key: SymmetricKey(data: item.fileKey))
    }

    // MARK: Writing

    @discardableResult
    func importPhoto(_ data: Data, name: String? = nil) throws -> VaultIndex.Item {
        let fileKeyData = try KDF.randomBytes(32)
        let fileKey = SymmetricKey(data: fileKeyData)
        let blobName = try BlobStorage.randomName()
        try storage.write(try ChunkedCipher.encrypt(data, key: fileKey), to: blobName)

        var thumbnailName: String?
        if let thumb = ImageInfo.jpegThumbnail(from: data) {
            let thumbBlob = try BlobStorage.randomName()
            try storage.write(try Box.seal(thumb, key: fileKey, aad: Self.thumbAAD), to: thumbBlob)
            thumbnailName = thumbBlob
        }

        let info = ImageInfo.read(from: data)
        let item = VaultIndex.Item(
            kind: .photo,
            name: name ?? "Photo",
            takenAt: info?.takenAt,
            addedAt: Date(),
            byteCount: data.count,
            blobName: blobName,
            thumbnailName: thumbnailName,
            fileKey: fileKeyData,
            pixelWidth: info?.width,
            pixelHeight: info?.height
        )
        var updated = index
        updated.items.append(item)
        do {
            try persist(updated)
        } catch {
            storage.delete(blobName)
            if let thumbnailName { storage.delete(thumbnailName) }
            throw error
        }
        return item
    }

    func delete(_ item: VaultIndex.Item) throws {
        guard let position = index.items.firstIndex(where: { $0.id == item.id }) else {
            throw VaultError.itemNotFound
        }
        var updated = index
        updated.items.remove(at: position)
        try persist(updated)
        storage.delete(item.blobName)
        if let thumb = item.thumbnailName { storage.delete(thumb) }
    }

    /// Writes the index first, then swaps it in memory, so a failed write leaves both consistent.
    private func persist(_ updated: VaultIndex) throws {
        try Self.writeIndex(updated, name: indexName, key: indexKey, storage: storage)
        index = updated
    }

    private static func writeIndex(_ index: VaultIndex, name: String, key: SymmetricKey, storage: BlobStorage) throws {
        let padded = Padding.pad(try JSONEncoder().encode(index), toMultipleOf: indexPadding)
        try storage.write(try Box.seal(padded, key: key, aad: indexAAD), to: name)
    }
}
