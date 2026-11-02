import CloudKit
import Foundation

enum BackupError: LocalizedError {
    case conflict
    case unavailable(String)
    case missingBlob(String)
    case phraseChangedElsewhere

    var errorDescription: String? {
        switch self {
        case .conflict: "Another device changed the backup at the same time."
        case .unavailable(let reason): reason
        case .missingBlob: "Part of the backup is missing."
        case .phraseChangedElsewhere: "This vault's recovery phrase was changed on another device. Enter the new phrase under Recovery phrase → Custom phrase to resume backup."
        }
    }
}

/// Opaque handle to the manifest version that was read, used for compare-and-swap saves.
final class ManifestToken: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}

struct RemoteManifest: Sendable {
    /// VaultHeader sealed with the recovery wrap key (lets the phrase alone restore).
    var wrapped: Data
    /// BackupPayload sealed with the vault's backup key.
    var payload: Data
    var token: ManifestToken
}

/// Where encrypted backups live. CloudKit in the app; an in-memory store in tests.
/// Every byte handed to a store is already encrypted on the device.
protocol BackupStore: Sendable {
    func fetchManifest(_ id: String) async throws -> RemoteManifest?
    /// Saves the manifest. With a token, fails with `BackupError.conflict` if it changed since that read.
    func saveManifest(_ id: String, wrapped: Data, payload: Data, replacing token: ManifestToken?) async throws
    func deleteManifest(_ id: String) async throws
    /// Uploads files under the given record names (existing records are overwritten).
    func uploadBlobs(_ blobs: [(record: String, file: URL)]) async throws
    /// Downloads records; `deliver` receives each record name and a temporary file to copy from.
    func downloadBlobs(_ records: [String], deliver: (String, URL) throws -> Void) async throws
    func deleteBlobs(_ records: [String]) async throws
}

/// Encrypted backup in the user's private iCloud database (default zone, fetched by record ID only,
/// so no indexes or queries need configuring in the CloudKit Dashboard).
struct CloudKitBackupStore: BackupStore {
    static let manifestType = "VaultManifest"
    static let blobType = "VaultBlob"
    private static let batchSize = 20

    /// CloudKit needs the iCloud entitlement; set CLOUDKIT_ENABLED = NO in project.yml to build without it.
    static var isConfigured: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "StrongroomCloudKit") as? String)?.uppercased() == "YES"
    }

    static func checkAvailable() async throws {
        guard isConfigured else { throw BackupError.unavailable("iCloud backup isn't enabled in this build.") }
        let status = try await CKContainer.default().accountStatus()
        switch status {
        case .available: return
        case .noAccount: throw BackupError.unavailable("Sign in to iCloud in the Settings app to back up.")
        case .restricted: throw BackupError.unavailable("iCloud is restricted on this device.")
        case .temporarilyUnavailable: throw BackupError.unavailable("iCloud is temporarily unavailable.")
        default: throw BackupError.unavailable("iCloud isn't available right now.")
        }
    }

    private var database: CKDatabase { CKContainer.default().privateCloudDatabase }

    func fetchManifest(_ id: String) async throws -> RemoteManifest? {
        let record: CKRecord
        do {
            record = try await database.record(for: CKRecord.ID(recordName: id))
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
        guard let wrapped = record["wrapped"] as? Data,
              let asset = record["payload"] as? CKAsset, let url = asset.fileURL
        else { throw BackupError.missingBlob(id) }
        return RemoteManifest(wrapped: wrapped, payload: try Data(contentsOf: url), token: ManifestToken(record))
    }

    func saveManifest(_ id: String, wrapped: Data, payload: Data, replacing token: ManifestToken?) async throws {
        let record = (token?.value as? CKRecord) ?? CKRecord(recordType: Self.manifestType, recordID: CKRecord.ID(recordName: id))
        let payloadURL = try TempFiles.newURL(name: "payload")
        defer { TempFiles.remove(payloadURL) }
        try payload.write(to: payloadURL)
        record["wrapped"] = wrapped as CKRecordValue
        record["payload"] = CKAsset(fileURL: payloadURL)
        do {
            let (saveResults, _) = try await database.modifyRecords(
                saving: [record], deleting: [],
                savePolicy: token == nil ? .allKeys : .ifServerRecordUnchanged
            )
            if case .failure(let error) = saveResults[record.recordID] { throw error }
        } catch let error as CKError where Self.isConflict(error) {
            throw BackupError.conflict
        }
    }

    private static func isConflict(_ error: CKError) -> Bool {
        if error.code == .serverRecordChanged { return true }
        if error.code == .partialFailure, let partial = error.partialErrorsByItemID {
            return partial.values.contains { ($0 as? CKError)?.code == .serverRecordChanged }
        }
        return false
    }

    func deleteManifest(_ id: String) async throws {
        do {
            _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: id))
        } catch let error as CKError where error.code == .unknownItem {}
    }

    func uploadBlobs(_ blobs: [(record: String, file: URL)]) async throws {
        for start in stride(from: 0, to: blobs.count, by: Self.batchSize) {
            try Task.checkCancellation()
            let batch = blobs[start..<min(start + Self.batchSize, blobs.count)]
            let records = batch.map { blob -> CKRecord in
                let record = CKRecord(recordType: Self.blobType, recordID: CKRecord.ID(recordName: blob.record))
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

    func deleteBlobs(_ records: [String]) async throws {
        for start in stride(from: 0, to: records.count, by: 200) {
            let ids = records[start..<min(start + 200, records.count)].map { CKRecord.ID(recordName: $0) }
            _ = try await database.modifyRecords(saving: [], deleting: ids)
        }
    }
}
