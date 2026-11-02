import XCTest
@testable import Strongroom

final class InMemoryShareStore: ShareStore, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var records: [String: Data] = [:]

    func saveShare(_ id: String, payload: Data, expiresAt: Date?, maxOpens: Int?) async throws {
        lock.withLock { records[id] = payload }
    }

    func fetchShare(_ id: String) async throws -> Data? {
        lock.withLock { records[id] }
    }

    func uploadBlobs(_ blobs: [(record: String, file: URL)]) async throws {
        for blob in blobs {
            let data = try Data(contentsOf: blob.file)
            lock.withLock { records[blob.record] = data }
        }
    }

    func downloadBlobs(_ ids: [String], deliver: (String, URL) throws -> Void) async throws {
        for id in ids {
            guard let data = lock.withLock({ records[id] }) else { throw BackupError.missingBlob(id) }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try data.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            try deliver(id, url)
        }
    }

    func deleteRecords(_ ids: [String]) async throws {
        lock.withLock { for id in ids { records.removeValue(forKey: id) } }
    }

    func countExisting(_ ids: [String]) async throws -> Int {
        lock.withLock { ids.filter { records[$0] != nil }.count }
    }

    func createMarker(_ id: String) async throws -> Bool {
        lock.withLock {
            guard records[id] == nil else { return false }
            records[id] = Data()
            return true
        }
    }
}

final class SharingTests: XCTestCase {
    private let fast: UInt32 = 1000
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
    }

    private func storage() throws -> BlobStorage {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root)
        return try BlobStorage(root: root)
    }

    private func vaultWithContent() async throws -> Vault {
        guard case .notFound(let pending) = try Vault.locate(
            pattern: Pattern(dots: [0, 1, 2, 7, 12, 17]), deviceSalt: Data(repeating: 5, count: 32),
            storage: try storage(), iterations: fast
        ) else { throw VaultError.patternInUse }
        let vault = try pending.create()
        let folder = try await vault.createFolder(named: "Trip", in: nil)
        let photo = try await vault.importPhoto(Data("beach".utf8))
        try await vault.move([photo.id], to: folder.id)
        _ = try await vault.saveNote(id: nil, title: "Plan", text: "day one", folderID: nil)
        return vault
    }

    func testShareRoundTripReadOnlyCopy() async throws {
        let store = InMemoryShareStore()
        let service = ShareService(store: store, iterations: fast)
        let vault = try await vaultWithContent()
        let phrase = try await service.create(from: vault, policy: SharePolicy(maxOpens: nil, expiresAfter: nil, allowExport: true))
        XCTAssertEqual(phrase.split(separator: " ").count, 9)
        let shares = await vault.snapshot().settings.shares
        XCTAssertEqual(shares.count, 1)

        let opened = try await service.open(phrase: phrase, into: try storage())
        XCTAssertTrue(opened.allowExport)
        let snapshot = await opened.vault.snapshot()
        XCTAssertEqual(snapshot.items.count, 2)
        XCTAssertEqual(snapshot.folders.map(\.name), ["Trip"])
        let note = try XCTUnwrap(snapshot.items.first { $0.kind == .note })
        let text = try await opened.vault.contents(of: note)
        XCTAssertEqual(String(decoding: text, as: UTF8.self), "day one")
    }

    func testWrongPhraseExpiryAndOpenLimit() async throws {
        let store = InMemoryShareStore()
        let service = ShareService(store: store, iterations: fast)
        let vault = try await vaultWithContent()

        do {
            _ = try await service.open(phrase: "not a real share phrase", into: try storage())
            XCTFail("expected notFound")
        } catch ShareError.notFound {}

        let limited = try await service.create(from: vault, policy: SharePolicy(maxOpens: 2, expiresAfter: nil, allowExport: false))
        _ = try await service.open(phrase: limited, into: try storage())
        let second = try await service.open(phrase: limited, into: try storage())
        XCTAssertFalse(second.allowExport)
        do {
            _ = try await service.open(phrase: limited, into: try storage())
            XCTFail("third open must be refused")
        } catch ShareError.exhausted {}

        let start = Date()
        let expiring = try await service.create(from: vault, policy: SharePolicy(maxOpens: nil, expiresAfter: 60, allowExport: true), now: start)
        _ = try await service.open(phrase: expiring, into: try storage(), now: start.addingTimeInterval(30))
        do {
            _ = try await service.open(phrase: expiring, into: try storage(), now: start.addingTimeInterval(61))
            XCTFail("expired share must be refused")
        } catch ShareError.expired {}
    }

    func testRevokeDeletesPublicRecords() async throws {
        let store = InMemoryShareStore()
        let service = ShareService(store: store, iterations: fast)
        let vault = try await vaultWithContent()
        let phrase = try await service.create(from: vault, policy: SharePolicy(maxOpens: nil, expiresAfter: nil, allowExport: true))
        let shares = await vault.snapshot().settings.shares
        let share = try XCTUnwrap(shares.first)
        try await service.revoke(share, in: vault)
        XCTAssertTrue(store.records.isEmpty)
        let remaining = await vault.snapshot().settings.shares
        XCTAssertTrue(remaining.isEmpty)
        do {
            _ = try await service.open(phrase: phrase, into: try storage())
            XCTFail("revoked share must not open")
        } catch ShareError.notFound {}
    }
}
