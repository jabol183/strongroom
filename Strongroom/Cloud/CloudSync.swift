import CryptoKit
import Foundation

/// The encrypted backup's table of contents. Sealed with the vault's backup key.
struct BackupPayload: Codable {
    var revision: Int
    /// Local names of every blob the backup contains (item files and thumbnails).
    var blobNames: [String]
    /// The vault's index blob exactly as stored on disk (already encrypted with the index key).
    var index: Data
    var updatedAt: Date
}

/// Encrypted backup, device sync and restore.
///
///     manifest ID   = "m" + HMAC(recovery locator key, "backup-manifest")   (found from the phrase alone)
///     manifest      = { wrapped: AES-GCM(recovery wrap key, header{masterKey, indexName}),
///                       payload: AES-GCM(backupKey, BackupPayload) }
///     backupKey     = HKDF(masterKey, "strongroom.backup.v1")
///     blob record   = "b" + HMAC(backupKey, local blob name) → the local blob file, uploaded as-is
///
/// Sync = pull (merge the cloud index into the local one, download missing blobs),
/// then push (upload new blobs, compare-and-swap the manifest, delete blobs nobody references).
struct CloudSync: Sendable {
    let store: BackupStore
    var iterations: UInt32 = KDF.productionIterations

    static let wrappedAAD = Data("strongroom.backup.header.v1".utf8)
    static let payloadAAD = Data("strongroom.backup.payload.v1".utf8)

    static func manifestID(_ keys: RecoveryKeys) -> String {
        "m" + keys.locatorName("backup-manifest").prefix(31)
    }

    static func backupKey(_ masterKey: SymmetricKey) -> SymmetricKey {
        KDF.subkey(masterKey, info: "strongroom.backup.v1")
    }

    static func blobRecordName(_ localName: String, backupKey: SymmetricKey) -> String {
        "b" + Data(HMAC<SHA256>.authenticationCode(for: Data(localName.utf8), using: backupKey)).hexString.prefix(31)
    }

    // MARK: Sync

    /// Returns the revision written.
    @discardableResult
    func sync(_ vault: Vault) async throws -> Int {
        let keys = try await vault.recoveryKeys(iterations: iterations)
        let id = Self.manifestID(keys)
        let masterKey = vault.masterKey
        let bkey = Self.backupKey(masterKey)
        // Read once: a retry after a failed first save must not look like a vanished backup.
        let hadBackup = await vault.index.settings.lastBackupRevision > 0

        for _ in 0..<3 {
            try Task.checkCancellation()
            let remote = try await store.fetchManifest(id)
            var remotePayload: BackupPayload?

            if let remote {
                let payload = try Self.openPayload(remote.payload, backupKey: bkey)
                remotePayload = payload
                let indexName = vault.indexName
                let remoteIndex = try Self.decodeIndex(payload.index, masterKey: masterKey, indexName: indexName)
                // Download blobs the merged index needs but this device lacks.
                let merged = VaultMerge.merge(await vault.index, remoteIndex)
                let needed = Self.blobNames(of: merged).filter { !vault.storage.exists($0) }
                try await download(Array(needed), backupKey: bkey, into: vault.storage)
                try await vault.absorb(remoteIndex)
            } else if hadBackup {
                throw BackupError.phraseChangedElsewhere
            }

            let revision = (remotePayload?.revision ?? 0) + 1
            let (indexData, blobs) = try await vault.prepareBackup(revision: revision)
            let remoteBlobs = Set(remotePayload?.blobNames ?? [])
            let uploads = blobs.subtracting(remoteBlobs).sorted().map {
                (record: Self.blobRecordName($0, backupKey: bkey), file: vault.storage.url(for: $0))
            }
            try await store.uploadBlobs(uploads)

            let payload = BackupPayload(revision: revision, blobNames: blobs.sorted(), index: indexData, updatedAt: Date())
            do {
                try await store.saveManifest(
                    id,
                    wrapped: try Self.sealHeader(masterKey: masterKey, indexName: vault.indexName, keys: keys),
                    payload: try Self.sealPayload(payload, backupKey: bkey),
                    replacing: remote?.token
                )
            } catch BackupError.conflict {
                continue  // someone else synced; pull their changes and try again
            }
            let stale = remoteBlobs.subtracting(blobs).map { Self.blobRecordName($0, backupKey: bkey) }
            if !stale.isEmpty { try? await store.deleteBlobs(stale) }
            return revision
        }
        throw BackupError.conflict
    }

    // MARK: Restore

    /// Restores a vault from its backup using only the recovery phrase. Returns nil if there's no backup.
    static func restore(
        phrase: String,
        storage: BlobStorage,
        store: BackupStore,
        iterations: UInt32 = KDF.productionIterations,
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> Vault? {
        let keys = try RecoveryKeys.derive(phrase: phrase, iterations: iterations)
        guard let remote = try await store.fetchManifest(manifestID(keys)) else { return nil }
        let header = try openHeader(remote.wrapped, keys: keys)
        let masterKey = SymmetricKey(data: header.masterKey)
        let bkey = Self.backupKey(masterKey)
        let payload = try openPayload(remote.payload, backupKey: bkey)

        let sync = CloudSync(store: store, iterations: iterations)
        try await sync.download(payload.blobNames, backupKey: bkey, into: storage, progress: progress)
        try storage.write(payload.index, to: header.indexName)
        try Vault.writeHeader(masterKey: masterKey, indexName: header.indexName, wrapKey: keys.wrapKey, name: keys.headerName, storage: storage)
        let index = try Vault.readIndex(name: header.indexName, masterKey: masterKey, storage: storage)
        return Vault(storage: storage, masterKey: masterKey, indexName: header.indexName, index: index)
    }

    // MARK: Phrase change and removal

    /// Moves the backup to the manifest ID of a new phrase. Blob records are reused.
    func rekey(_ vault: Vault, from old: RecoveryKeys, to new: RecoveryKeys) async throws {
        let oldID = Self.manifestID(old)
        guard let remote = try await store.fetchManifest(oldID) else { return }
        let masterKey = vault.masterKey
        try await store.saveManifest(
            Self.manifestID(new),
            wrapped: try Self.sealHeader(masterKey: masterKey, indexName: vault.indexName, keys: new),
            payload: remote.payload,
            replacing: nil
        )
        try await store.deleteManifest(oldID)
    }

    /// Deletes the vault's cloud copy (manifest and every blob record).
    func deleteBackup(_ vault: Vault) async throws {
        let keys = try await vault.recoveryKeys(iterations: iterations)
        let id = Self.manifestID(keys)
        guard let remote = try await store.fetchManifest(id) else { return }
        let bkey = Self.backupKey(vault.masterKey)
        if let payload = try? Self.openPayload(remote.payload, backupKey: bkey) {
            try await store.deleteBlobs(payload.blobNames.map { Self.blobRecordName($0, backupKey: bkey) })
        }
        try await store.deleteManifest(id)
    }

    // MARK: Helpers

    func download(
        _ names: [String],
        backupKey: SymmetricKey,
        into storage: BlobStorage,
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws {
        guard !names.isEmpty else { return }
        let byRecord = Dictionary(names.map { (Self.blobRecordName($0, backupKey: backupKey), $0) }, uniquingKeysWith: { a, _ in a })
        var done = 0
        try await store.downloadBlobs(Array(byRecord.keys)) { record, url in
            guard let local = byRecord[record] else { return }
            try storage.importFile(from: url, as: local)
            done += 1
            progress(done, byRecord.count)
        }
    }

    static func blobNames(of index: VaultIndex) -> Set<String> {
        var names = Set<String>()
        for item in index.items {
            names.insert(item.blobName)
            if let thumb = item.thumbnailName { names.insert(thumb) }
        }
        return names
    }

    static func decodeIndex(_ sealed: Data, masterKey: SymmetricKey, indexName: String) throws -> VaultIndex {
        let key = KDF.subkey(masterKey, info: "strongroom.index.v1")
        let padded = try Box.open(sealed, key: key, aad: Vault.indexAAD)
        return try JSONDecoder().decode(VaultIndex.self, from: Padding.unpad(padded))
    }

    static func sealHeader(masterKey: SymmetricKey, indexName: String, keys: RecoveryKeys) throws -> Data {
        let header = VaultHeader(masterKey: masterKey.rawData, indexName: indexName, createdAt: Date())
        let padded = Padding.pad(try JSONEncoder().encode(header), toMultipleOf: Vault.headerPadding)
        return try Box.seal(padded, key: keys.wrapKey, aad: wrappedAAD)
    }

    static func openHeader(_ sealed: Data, keys: RecoveryKeys) throws -> VaultHeader {
        let padded = try Box.open(sealed, key: keys.wrapKey, aad: wrappedAAD)
        return try JSONDecoder().decode(VaultHeader.self, from: Padding.unpad(padded))
    }

    static func sealPayload(_ payload: BackupPayload, backupKey: SymmetricKey) throws -> Data {
        let padded = Padding.pad(try JSONEncoder().encode(payload), toMultipleOf: Vault.indexPadding)
        return try Box.seal(padded, key: backupKey, aad: payloadAAD)
    }

    static func openPayload(_ sealed: Data, backupKey: SymmetricKey) throws -> BackupPayload {
        let padded = try Box.open(sealed, key: backupKey, aad: payloadAAD)
        return try JSONDecoder().decode(BackupPayload.self, from: Padding.unpad(padded))
    }
}

// MARK: - Vault support

extension Vault {
    /// Merges another copy of this vault's index in, writes the result, and deletes local blobs
    /// that no item references any more (items deleted on another device).
    func absorb(_ other: VaultIndex) throws {
        let before = CloudSync.blobNames(of: index)
        let merged = VaultMerge.merge(index, other)
        try replaceIndex(merged)
        let after = CloudSync.blobNames(of: merged)
        for name in before.subtracting(after) { storage.delete(name) }
    }

    /// Records the revision and returns the encrypted index bytes plus every blob it references,
    /// read together so they're consistent.
    func prepareBackup(revision: Int) throws -> (indexData: Data, blobs: Set<String>) {
        if index.settings.lastBackupRevision != revision {
            try mutate { $0.settings.lastBackupRevision = revision }
        }
        let blobs = CloudSync.blobNames(of: index).filter { storage.exists($0) }
        return (try storage.read(indexName), blobs)
    }
}
