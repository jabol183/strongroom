import CryptoKit
import XCTest
@testable import Strongroom

final class VaultLibraryTests: XCTestCase {
    private var storage: BlobStorage!
    private var vault: Vault!

    override func setUp() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        storage = try BlobStorage(root: dir)
        let pattern = Pattern(dots: [0, 1, 2, 7, 12, 17])
        guard case .notFound(let pending) = try Vault.locate(
            pattern: pattern, deviceSalt: Data(repeating: 1, count: 32), storage: storage, iterations: 1000
        ) else { return XCTFail("expected empty") }
        vault = try pending.create()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storage.root)
    }

    private func reopen() throws -> Vault {
        guard case .found(let reopened) = try Vault.locate(
            pattern: Pattern(dots: [0, 1, 2, 7, 12, 17]), deviceSalt: Data(repeating: 1, count: 32),
            storage: storage, iterations: 1000
        ) else { throw VaultError.corruptHeader }
        return reopened
    }

    func testFoldersNestingMoveAndCascadingDelete() async throws {
        let parent = try await vault.createFolder(named: "Trips", in: nil)
        let child = try await vault.createFolder(named: "2026", in: parent.id)
        let item = try await vault.importPhoto(Data("x".utf8))
        try await vault.move([item.id], to: child.id)

        do {
            try await vault.moveFolder(parent.id, to: child.id)
            XCTFail("moving a folder into its own child must fail")
        } catch {}

        let before = try storage.allNames().count
        try await vault.deleteFolder(parent.id)
        let snapshot = await vault.snapshot()
        XCTAssertTrue(snapshot.folders.isEmpty)
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertEqual(try storage.allNames().count, before - 1)  // item blob gone (no thumbnail for non-image)
        let tombstones = await vault.index.tombstones
        XCTAssertNotNil(tombstones[parent.id])
        XCTAssertNotNil(tombstones[child.id])
        XCTAssertNotNil(tombstones[item.id])
    }

    func testFolderOrderPersists() async throws {
        let a = try await vault.createFolder(named: "A", in: nil)
        let b = try await vault.createFolder(named: "B", in: nil)
        let c = try await vault.createFolder(named: "C", in: nil)
        try await vault.reorderFolders(in: nil, orderedIDs: [c.id, a.id, b.id])
        let reopened = try reopen()
        let names = await reopened.snapshot().folders(in: nil).map(\.name)
        XCTAssertEqual(names, ["C", "A", "B"])
    }

    func testNotesSaveAndUpdateReplacesBlob() async throws {
        let note = try await vault.saveNote(id: nil, title: "Ideas", text: "first", folderID: nil)
        let updated = try await vault.saveNote(id: note.id, title: "Ideas v2", text: "second draft", folderID: nil)
        XCTAssertEqual(updated.id, note.id)
        XCTAssertNotEqual(updated.blobName, note.blobName)
        XCTAssertFalse(storage.exists(note.blobName))
        let reopened = try reopen()
        let items = await reopened.items
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "Ideas v2")
        let text = try await reopened.contents(of: items[0])
        XCTAssertEqual(String(decoding: text, as: UTF8.self), "second draft")
    }

    func testFilePayloadAndTemporaryDecrypt() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        let data = Data((0..<(ChunkedCipher.defaultChunkSize + 999)).map { UInt8($0 % 233) })
        try data.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let item = try await vault.add(ImportSource(payload: .file(source), kind: .file, name: "Report", fileExtension: "pdf"))
        XCTAssertEqual(item.byteCount, data.count)
        XCTAssertEqual(item.exportFileName, "Report.pdf")
        let url = try await vault.decryptToTemporaryFile(item)
        XCTAssertEqual(url.lastPathComponent, "Report.pdf")
        XCTAssertEqual(try Data(contentsOf: url), data)
        TempFiles.wipe()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRenameAndDeleteRecordTombstone() async throws {
        let item = try await vault.importPhoto(Data("y".utf8))
        try await vault.rename(item.id, to: "Renamed")
        var items = await vault.items
        XCTAssertEqual(items.first?.name, "Renamed")
        try await vault.delete([item.id])
        items = await vault.items
        XCTAssertTrue(items.isEmpty)
        let tombstones = await vault.index.tombstones
        XCTAssertNotNil(tombstones[item.id])
    }

    func testIndexDecodingToleratesMissingKeys() throws {
        let json = #"{"items":[]}"#
        let index = try JSONDecoder().decode(VaultIndex.self, from: Data(json.utf8))
        XCTAssertTrue(index.folders.isEmpty)
        XCTAssertTrue(index.settings.backupEnabled)
        XCTAssertFalse(index.settings.isDuress)
    }
}
