import CloudKit
import CryptoKit
import Foundation

enum ShareError: LocalizedError {
    case notFound
    case expired
    case exhausted
    case needsICloud

    var errorDescription: String? {
        switch self {
        case .notFound: "No shared vault matches that phrase."
        case .expired: "This shared vault has expired."
        case .exhausted: "This shared vault has been opened the maximum number of times."
        case .needsICloud: "Sign in to iCloud in the Settings app to open this shared vault."
        }
    }
}

/// How long and how often a share can be opened, and whether recipients may export.
struct SharePolicy: Sendable {
    var maxOpens: Int?
    var expiresAfter: TimeInterval?
    var allowExport: Bool
}

/// Keys for a share, all derived from its own 9-word phrase (unrelated to the recovery phrase).
///
///     shareIKM   = PBKDF2-SHA256("share:v1:" + phrase, "strongroom.share.v1", 200k)
///     key        = HKDF(shareIKM, "strongroom.share.key.v1")      → seals the share payload
///     locatorKey = HKDF(shareIKM, "strongroom.share.locator.v1")  → public record names
struct ShareKeys: @unchecked Sendable {
    static let productionIterations: UInt32 = 200_000

    let key: SymmetricKey
    let locatorKey: SymmetricKey

    static func derive(phrase: String, iterations: UInt32 = productionIterations) throws -> ShareKeys {
        let password = Data(("share:v1:" + RecoveryPhrase.normalize(phrase)).utf8)
        let ikm = SymmetricKey(data: try KDF.pbkdf2SHA256(password: password, salt: Data("strongroom.share.v1".utf8), iterations: iterations))
        return ShareKeys(
            key: KDF.subkey(ikm, info: "strongroom.share.key.v1"),
            locatorKey: KDF.subkey(ikm, info: "strongroom.share.locator.v1")
        )
    }

    private func name(_ label: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(label.utf8), using: locatorKey)).hexString
    }

    var manifestID: String { "s" + name("share-manifest").prefix(31) }

    /// Open receipts are records "o…-1" … "o…-N": claiming one is a create that fails if it exists,
    /// so the count needs no queries and no server code.
    func openRecordID(_ n: Int) -> String { "o" + name("share-open").prefix(23) + "-\(n)" }
}

/// What a recipient receives, sealed with the share key.
struct SharePayload: Codable {
    var createdAt: Date
    var expiresAt: Date?
    var maxOpens: Int?
    var allowExport: Bool
    var items: [VaultIndex.Item]
    var folders: [VaultIndex.Folder]
    /// Local blob name → public record name.
    var blobRecords: [String: String]
}

/// Public storage for shares (anyone with a record name can read; only the creator can change).
protocol ShareStore: Sendable {
    func saveShare(_ id: String, payload: Data, expiresAt: Date?, maxOpens: Int?) async throws
    func fetchShare(_ id: String) async throws -> Data?
    func uploadBlobs(_ blobs: [(record: String, file: URL)]) async throws
    func downloadBlobs(_ records: [String], deliver: (String, URL) throws -> Void) async throws
    func deleteRecords(_ ids: [String]) async throws
    /// How many of these records exist.
    func countExisting(_ ids: [String]) async throws -> Int
    /// Creates an empty marker record; false if it already exists.
    func createMarker(_ id: String) async throws -> Bool
}

struct ShareService: Sendable {
    let store: ShareStore
    var iterations: UInt32 = ShareKeys.productionIterations
    static let payloadAAD = Data("strongroom.share.payload.v1".utf8)

    /// Uploads a snapshot of the whole vault. Returns the phrase to give the recipient.
    func create(from vault: Vault, policy: SharePolicy, now: Date = Date()) async throws -> String {
        let snapshot = await vault.snapshot()
        let phrase = try RecoveryPhrase.generate()
        let keys = try ShareKeys.derive(phrase: phrase, iterations: iterations)

        var blobRecords: [String: String] = [:]
        for name in CloudSync.blobNames(of: VaultIndex.with(items: snapshot.items)) {
            let random = try BlobStorage.randomName()
            blobRecords[name] = "p" + random.prefix(31)
        }
        try await store.uploadBlobs(blobRecords.map { (record: $0.value, file: vault.storage.url(for: $0.key)) })

        let expiresAt = policy.expiresAfter.map { now.addingTimeInterval($0) }
        let payload = SharePayload(
            createdAt: now, expiresAt: expiresAt, maxOpens: policy.maxOpens, allowExport: policy.allowExport,
            items: snapshot.items, folders: snapshot.folders, blobRecords: blobRecords
        )
        let padded = Padding.pad(try JSONEncoder().encode(payload), toMultipleOf: Vault.indexPadding)
        try await store.saveShare(
            keys.manifestID, payload: try Box.seal(padded, key: keys.key, aad: Self.payloadAAD),
            expiresAt: expiresAt, maxOpens: policy.maxOpens
        )

        let record = VaultIndex.ShareRecord(
            id: keys.manifestID, createdAt: now, expiresAt: expiresAt, maxOpens: policy.maxOpens,
            allowExport: policy.allowExport, itemCount: snapshot.items.count,
            recordNames: [keys.manifestID] + blobRecords.values.sorted()
        )
        try await vault.updateSettings { $0.shares.append(record) }
        return phrase
    }

    /// Deletes the share's public records and forgets it.
    func revoke(_ share: VaultIndex.ShareRecord, in vault: Vault) async throws {
        try await store.deleteRecords(share.recordNames)
        try await vault.updateSettings { $0.shares.removeAll { $0.id == share.id } }
    }

    struct Opened: Sendable {
        let vault: Vault
        let allowExport: Bool
        let expiresAt: Date?
    }

    /// Opens a share into a throwaway, read-only vault in `storage` (a temporary folder).
    func open(phrase: String, into storage: BlobStorage, now: Date = Date(),
              progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> Opened {
        let keys = try ShareKeys.derive(phrase: phrase, iterations: iterations)
        guard let sealed = try await store.fetchShare(keys.manifestID) else { throw ShareError.notFound }
        let payload = try JSONDecoder().decode(
            SharePayload.self, from: Padding.unpad(Box.open(sealed, key: keys.key, aad: Self.payloadAAD))
        )
        if let expiresAt = payload.expiresAt, expiresAt <= now { throw ShareError.expired }
        if let maxOpens = payload.maxOpens { try await claimOpen(keys: keys, maxOpens: maxOpens) }

        let localByRecord = Dictionary(payload.blobRecords.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        var done = 0
        try await store.downloadBlobs(Array(localByRecord.keys)) { record, url in
            guard let local = localByRecord[record] else { return }
            try storage.importFile(from: url, as: local)
            done += 1
            progress(done, localByRecord.count)
        }

        var index = VaultIndex.with(items: payload.items)
        index.folders = payload.folders
        let masterKey = SymmetricKey(size: .bits256)
        let indexName = try BlobStorage.randomName()
        try Vault.writeIndex(index, name: indexName, masterKey: masterKey, storage: storage)
        let vault = Vault(storage: storage, masterKey: masterKey, indexName: indexName, index: index)
        return Opened(vault: vault, allowExport: payload.allowExport, expiresAt: payload.expiresAt)
    }

    private func claimOpen(keys: ShareKeys, maxOpens: Int) async throws {
        let ids = (1...max(maxOpens, 1)).map(keys.openRecordID)
        var used = try await store.countExisting(ids)
        while used < maxOpens {
            if try await store.createMarker(ids[used]) { return }
            used += 1  // someone else took that slot; try the next
        }
        throw ShareError.exhausted
    }
}

extension VaultIndex {
    static func with(items: [Item]) -> VaultIndex {
        var index = VaultIndex()
        index.items = items
        return index
    }
}

/// Shares in the iCloud public database of the app's container.
struct CloudKitShareStore: ShareStore {
    private var database: CKDatabase { CKContainer.default().publicCloudDatabase }
    private static let batchSize = 20

    func saveShare(_ id: String, payload: Data, expiresAt: Date?, maxOpens: Int?) async throws {
        let record = CKRecord(recordType: "VaultShare", recordID: CKRecord.ID(recordName: id))
        let url = try TempFiles.newURL(name: "share")
        defer { TempFiles.remove(url) }
        try payload.write(to: url)
        record["payload"] = CKAsset(fileURL: url)
        record["expiresAt"] = expiresAt.map { $0 as NSDate }
        record["maxOpens"] = maxOpens.map { NSNumber(value: $0) }
        _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
    }

    func fetchShare(_ id: String) async throws -> Data? {
        do {
            let record = try await database.record(for: CKRecord.ID(recordName: id))
            guard let asset = record["payload"] as? CKAsset, let url = asset.fileURL else { return nil }
            return try Data(contentsOf: url)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    func uploadBlobs(_ blobs: [(record: String, file: URL)]) async throws {
        for start in stride(from: 0, to: blobs.count, by: Self.batchSize) {
            try Task.checkCancellation()
            let records = blobs[start..<min(start + Self.batchSize, blobs.count)].map { blob -> CKRecord in
                let record = CKRecord(recordType: "VaultShareBlob", recordID: CKRecord.ID(recordName: blob.record))
                record["data"] = CKAsset(fileURL: blob.file)
                return record
            }
            let (results, _) = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys)
            for (_, result) in results {
                if case .failure(let error) = result { throw error }
            }
        }
    }

    func downloadBlobs(_ records: [String], deliver: (String, URL) throws -> Void) async throws {
        for start in stride(from: 0, to: records.count, by: Self.batchSize) {
            try Task.checkCancellation()
            let ids = records[start..<min(start + Self.batchSize, records.count)].map { CKRecord.ID(recordName: $0) }
            let results = try await database.records(for: ids)
            for id in ids {
                guard case .success(let record)? = results[id],
                      let asset = record["data"] as? CKAsset, let url = asset.fileURL
                else { throw BackupError.missingBlob(id.recordName) }
                try deliver(id.recordName, url)
            }
        }
    }

    func deleteRecords(_ ids: [String]) async throws {
        for start in stride(from: 0, to: ids.count, by: 200) {
            let batch = ids[start..<min(start + 200, ids.count)].map { CKRecord.ID(recordName: $0) }
            _ = try await database.modifyRecords(saving: [], deleting: batch)
        }
    }

    func countExisting(_ ids: [String]) async throws -> Int {
        var count = 0
        for start in stride(from: 0, to: ids.count, by: 200) {
            let batch = ids[start..<min(start + 200, ids.count)].map { CKRecord.ID(recordName: $0) }
            let results = try await database.records(for: batch, desiredKeys: [])
            count += results.values.filter { if case .success = $0 { return true } else { return false } }.count
        }
        return count
    }

    func createMarker(_ id: String) async throws -> Bool {
        let record = CKRecord(recordType: "VaultShareOpen", recordID: CKRecord.ID(recordName: id))
        do {
            let (results, _) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
            if case .failure(let error) = results[record.recordID] { throw error }
            return true
        } catch let error as CKError {
            switch error.code {
            case .serverRecordChanged, .permissionFailure, .constraintViolation: return false
            case .notAuthenticated: throw ShareError.needsICloud
            case .partialFailure:
                let codes = error.partialErrorsByItemID?.values.compactMap { ($0 as? CKError)?.code } ?? []
                if codes.contains(.notAuthenticated) { throw ShareError.needsICloud }
                return false
            default: throw error
            }
        }
    }
}
