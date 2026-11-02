import XCTest
@testable import Strongroom

/// A CloudKit stand-in: manifests with versions (for compare-and-swap) and blob files.
final class InMemoryBackupStore: BackupStore, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var manifests: [String: (wrapped: Data, payload: Data, version: Int)] = [:]
    private(set) var blobs: [String: Data] = [:]
    /// When set, the next manifest save fails as if another device saved first.
    var injectConflict = false

    func fetchManifest(_ id: String) async throws -> RemoteManifest? {
        lock.withLock {
            manifests[id].map { RemoteManifest(wrapped: $0.wrapped, payload: $0.payload, token: ManifestToken($0.version)) }
        }
    }

    func saveManifest(_ id: String, wrapped: Data, payload: Data, replacing token: ManifestToken?) async throws {
        try lock.withLock {
            if injectConflict {
                injectConflict = false
                throw BackupError.conflict
            }
            let current = manifests[id]?.version
            if let token, (token.value as? Int) != current { throw BackupError.conflict }
            manifests[id] = (wrapped, payload, (current ?? 0) + 1)
        }
    }

    func deleteManifest(_ id: String) async throws {
        _ = lock.withLock { manifests.removeValue(forKey: id) }
    }

    func uploadBlobs(_ list: [(record: String, file: URL)]) async throws {
        for blob in list {
            let data = try Data(contentsOf: blob.file)
            lock.withLock { blobs[blob.record] = data }
        }
    }

    func downloadBlobs(_ records: [String], deliver: (String, URL) throws -> Void) async throws {
        for record in records {
            guard let data = lock.withLock({ blobs[record] }) else { throw BackupError.missingBlob(record) }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try data.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            try deliver(record, url)
        }
    }

    func deleteBlobs(_ records: [String]) async throws {
        lock.withLock { for record in records { blobs.removeValue(forKey: record) } }
    }
}

final class CloudSyncTests: XCTestCase {
    private let fast: UInt32 = 1000
    private let phrase = "orbit lantern velvet quarry mosaic thunder pebble canyon zephyr"
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
    }

    private func device() throws -> BlobStorage {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root)
        return try BlobStorage(root: root)
    }

    private func newVault(on storage: BlobStorage) async throws -> Vault {
        guard case .notFound(let pending) = try Vault.locate(
            pattern: Pattern(dots: [0, 1, 2, 7, 12, 17]), deviceSalt: Data(repeating: 3, count: 32),
            storage: storage, iterations: fast
        ) else { throw VaultError.patternInUse }
        let vault = try pending.create()
        try await vault.setRecoveryPhrase(phrase, iterations: fast)
        return vault
    }

    func testBackupThenRestoreOnNewDevice() async throws {
        let store = InMemoryBackupStore()
        let sync = CloudSync(store: store, iterations: fast)
        let phone = try device()
        let vault = try await newVault(on: phone)
        let folder = try await vault.createFolder(named: "Docs", in: nil)
        let photo = try await vault.importPhoto(Data("photo bytes".utf8))
        try await vault.move([photo.id], to: folder.id)
        _ = try await vault.saveNote(id: nil, title: "Note", text: "hello", folderID: nil)

        let revision = try await sync.sync(vault)
        XCTAssertEqual(revision, 1)
        XCTAssertEqual(store.manifests.count, 1)
        XCTAssertEqual(store.blobs.count, 2)  // photo blob + note blob (no thumbnails for non-images)

        // Nothing readable reaches the store.
        for data in store.blobs.values { XCTAssertNil(String(data: data, encoding: .utf8)?.range(of: "photo bytes")) }

        let tablet = try device()
        let restored = try await CloudSync.restore(phrase: phrase, storage: tablet, store: store, iterations: fast)
        let snapshot = try await XCTUnwrap(restored).snapshot()
        XCTAssertEqual(snapshot.items.count, 2)
        XCTAssertEqual(snapshot.folders.map(\.name), ["Docs"])
        let restoredPhoto = try XCTUnwrap(snapshot.items.first { $0.id == photo.id })
        let bytes = try await restored!.contents(of: restoredPhoto)
        XCTAssertEqual(bytes, Data("photo bytes".utf8))
        // The phrase also opens the restored copy locally now.
        XCTAssertNotNil(try Vault.recover(phrase: phrase, storage: tablet, iterations: fast))
    }

    func testRestoreWithUnknownPhraseReturnsNil() async throws {
        let restored = try await CloudSync.restore(
            phrase: "nothing here at all", storage: try device(), store: InMemoryBackupStore(), iterations: fast
        )
        XCTAssertNil(restored)
    }

    func testTwoDevicesConvergeIncludingDeletes() async throws {
        let store = InMemoryBackupStore()
        let sync = CloudSync(store: store, iterations: fast)
        let phone = try await newVault(on: try device())
        let shared = try await phone.importPhoto(Data("shared".utf8))
        try await sync.sync(phone)

        let tablet = try await XCTUnwrap(CloudSync.restore(phrase: phrase, storage: try device(), store: store, iterations: fast))

        // Concurrent edits: phone adds A and deletes the shared item; tablet adds B and renames nothing.
        let a = try await phone.importPhoto(Data("from phone".utf8))
        try await phone.delete([shared.id])
        let b = try await tablet.importPhoto(Data("from tablet".utf8))

        try await sync.sync(phone)
        try await sync.sync(tablet)
        try await sync.sync(phone)

        let phoneIDs = Set(await phone.items.map(\.id))
        let tabletIDs = Set(await tablet.items.map(\.id))
        XCTAssertEqual(phoneIDs, [a.id, b.id])
        XCTAssertEqual(tabletIDs, [a.id, b.id])
        // The deleted item's blob is gone from the tablet and from the store.
        XCTAssertFalse(tablet.storage.exists(shared.blobName))
        XCTAssertEqual(store.blobs.count, 2)
        let phoneItems = await phone.items
        let bOnPhone = try XCTUnwrap(phoneItems.first { $0.id == b.id })
        let fromTablet = try await phone.contents(of: bOnPhone)
        XCTAssertEqual(fromTablet, Data("from tablet".utf8))
    }

    func testConflictIsRetried() async throws {
        let store = InMemoryBackupStore()
        let sync = CloudSync(store: store, iterations: fast)
        let vault = try await newVault(on: try device())
        try await vault.importPhoto(Data("x".utf8))
        store.injectConflict = true
        let revision = try await sync.sync(vault)
        XCTAssertEqual(revision, 1)
        XCTAssertEqual(store.manifests.count, 1)
    }

    func testPhraseChangeRekeysBackup() async throws {
        let store = InMemoryBackupStore()
        let sync = CloudSync(store: store, iterations: fast)
        let vault = try await newVault(on: try device())
        try await vault.importPhoto(Data("x".utf8))
        try await sync.sync(vault)

        let oldKeys = try await vault.recoveryKeys(iterations: fast)
        let newPhrase = "brand new recovery words here"
        try await vault.setRecoveryPhrase(newPhrase, iterations: fast)
        try await sync.rekey(vault, from: oldKeys, to: vault.recoveryKeys(iterations: fast))

        let oldRestore = try await CloudSync.restore(phrase: phrase, storage: try device(), store: store, iterations: fast)
        XCTAssertNil(oldRestore, "the old phrase must no longer find the backup")
        let newRestore = try await CloudSync.restore(phrase: newPhrase, storage: try device(), store: store, iterations: fast)
        let count = await newRestore?.items.count
        XCTAssertEqual(count, 1)
    }

    func testMissingManifestAfterBackupMeansPhraseChangedElsewhere() async throws {
        let store = InMemoryBackupStore()
        let sync = CloudSync(store: store, iterations: fast)
        let vault = try await newVault(on: try device())
        try await sync.sync(vault)
        try await store.deleteManifest(store.manifests.keys.first!)
        do {
            try await sync.sync(vault)
            XCTFail("expected phraseChangedElsewhere")
        } catch BackupError.phraseChangedElsewhere {}
    }

    func testDeleteBackupRemovesEverything() async throws {
        let store = InMemoryBackupStore()
        let sync = CloudSync(store: store, iterations: fast)
        let vault = try await newVault(on: try device())
        try await vault.importPhoto(Data("x".utf8))
        try await sync.sync(vault)
        try await sync.deleteBackup(vault)
        XCTAssertTrue(store.manifests.isEmpty)
        XCTAssertTrue(store.blobs.isEmpty)
    }
}

final class VaultMergeTests: XCTestCase {
    private func item(_ name: String, at seconds: TimeInterval, folder: UUID? = nil, id: UUID = UUID()) -> VaultIndex.Item {
        VaultIndex.Item(
            id: id, kind: .photo, name: name, addedAt: Date(timeIntervalSince1970: seconds),
            modifiedAt: Date(timeIntervalSince1970: seconds), byteCount: 1, blobName: name, fileKey: Data(), folderID: folder
        )
    }

    func testNewerEditWinsAndMergeIsSymmetric() {
        let id = UUID()
        var a = VaultIndex(); a.items = [item("old", at: 10, id: id)]
        var b = VaultIndex(); b.items = [item("new", at: 20, id: id)]
        XCTAssertEqual(VaultMerge.merge(a, b).items.map(\.name), ["new"])
        XCTAssertEqual(VaultMerge.merge(b, a).items.map(\.name), ["new"])
    }

    func testTombstoneBeatsOlderEditButNotNewer() {
        let id = UUID()
        var a = VaultIndex(); a.items = [item("x", at: 10, id: id)]
        var b = VaultIndex(); b.tombstones[id] = Date(timeIntervalSince1970: 15)
        XCTAssertTrue(VaultMerge.merge(a, b).items.isEmpty)
        a.items = [item("x", at: 20, id: id)]
        XCTAssertEqual(VaultMerge.merge(a, b).items.count, 1)
    }

    func testOrphansMoveToTopAndCyclesBreak() {
        let f1 = UUID(), f2 = UUID(), gone = UUID()
        var a = VaultIndex()
        a.folders = [
            VaultIndex.Folder(id: f1, name: "One", parentID: f2, sortOrder: 0, modifiedAt: .now),
            VaultIndex.Folder(id: f2, name: "Two", parentID: f1, sortOrder: 1, modifiedAt: .now),
        ]
        a.items = [item("lost", at: 1, folder: gone)]
        let merged = VaultMerge.merge(a, VaultIndex())
        XCTAssertNil(merged.items[0].folderID)
        XCTAssertTrue(merged.folders.allSatisfy { $0.parentID == nil })
    }
}
