import CryptoKit
import UIKit
import XCTest
@testable import Strongroom

final class CryptoTests: XCTestCase {
    // Published PBKDF2-HMAC-SHA256 test vectors.
    func testPBKDF2Vectors() throws {
        let one = try KDF.pbkdf2SHA256(password: Data("password".utf8), salt: Data("salt".utf8), iterations: 1)
        XCTAssertEqual(one.hexString, "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        let two = try KDF.pbkdf2SHA256(password: Data("password".utf8), salt: Data("salt".utf8), iterations: 2)
        XCTAssertEqual(two.hexString, "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
    }

    func testBoxRoundTripAndTamper() throws {
        let key = SymmetricKey(size: .bits256)
        var sealed = try Box.seal(Data("hello".utf8), key: key, aad: Data("a".utf8))
        XCTAssertEqual(try Box.open(sealed, key: key, aad: Data("a".utf8)), Data("hello".utf8))
        XCTAssertThrowsError(try Box.open(sealed, key: key, aad: Data("b".utf8)))
        sealed[sealed.startIndex + 13] ^= 0x01
        XCTAssertThrowsError(try Box.open(sealed, key: key, aad: Data("a".utf8)))
    }

    func testPaddingRoundTrip() throws {
        for size in [0, 1, 4091, 4092, 4093, 10_000] {
            let data = Data((0..<size).map { UInt8($0 & 0xff) })
            let padded = Padding.pad(data, toMultipleOf: 4096)
            XCTAssertEqual(padded.count % 4096, 0)
            XCTAssertEqual(try Padding.unpad(padded), data)
        }
    }

    func testChunkedRoundTripAllBoundaries() throws {
        let key = SymmetricKey(size: .bits256)
        let chunk = 64
        for size in [0, 1, chunk - 1, chunk, chunk + 1, chunk * 3, chunk * 3 + 7] {
            let data = Data((0..<size).map { _ in UInt8.random(in: 0...255) })
            let sealed = try ChunkedCipher.encrypt(data, key: key, chunkSize: chunk)
            let chunks = max(1, (size + chunk - 1) / chunk)
            XCTAssertEqual(sealed.count, ChunkedCipher.headerSize + size + chunks * ChunkedCipher.tagSize, "size \(size)")
            XCTAssertEqual(try ChunkedCipher.decrypt(sealed, key: key), data, "size \(size)")
        }
    }

    func testChunkedDetectsTamperTruncationAndWrongKey() throws {
        let key = SymmetricKey(size: .bits256)
        let chunk = 64
        let data = Data((0..<(chunk * 3)).map { UInt8($0 & 0xff) })
        let sealed = try ChunkedCipher.encrypt(data, key: key, chunkSize: chunk)
        let sealedChunk = chunk + ChunkedCipher.tagSize

        var flipped = sealed
        flipped[flipped.startIndex + ChunkedCipher.headerSize + 5] ^= 0x80
        XCTAssertThrowsError(try ChunkedCipher.decrypt(flipped, key: key))

        // Drop the last whole chunk: the new last chunk wasn't sealed as final.
        let truncated = sealed.prefix(sealed.count - sealedChunk)
        XCTAssertThrowsError(try ChunkedCipher.decrypt(Data(truncated), key: key))

        // Append a copy of a chunk: the real final chunk is no longer last.
        var extended = sealed
        extended.append(sealed.suffix(sealedChunk))
        XCTAssertThrowsError(try ChunkedCipher.decrypt(extended, key: key))

        XCTAssertThrowsError(try ChunkedCipher.decrypt(sealed, key: SymmetricKey(size: .bits256)))
    }

    func testChunkedFileStreaming() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appendingPathComponent("in"), enc = dir.appendingPathComponent("enc"), out = dir.appendingPathComponent("out")
        let data = Data((0..<(ChunkedCipher.defaultChunkSize * 2 + 123)).map { UInt8($0 % 251) })
        try data.write(to: plain)
        let key = SymmetricKey(size: .bits256)
        try ChunkedCipher.encryptFile(at: plain, to: enc, key: key)
        try ChunkedCipher.decryptFile(at: enc, to: out, key: key)
        XCTAssertEqual(try Data(contentsOf: out), data)
    }
}

final class PatternTests: XCTestCase {
    func testValidation() {
        XCTAssertThrowsError(try Pattern(dots: [0, 1, 2, 3, 4]).validate()) {
            XCTAssertEqual($0 as? Pattern.ValidationError, .tooShort)
        }
        XCTAssertThrowsError(try Pattern(dots: [0, 1, 2, 3, 4, 4]).validate()) {
            XCTAssertEqual($0 as? Pattern.ValidationError, .repeatedDot)
        }
        XCTAssertThrowsError(try Pattern(dots: [0, 1, 2, 3, 4, 25]).validate()) {
            XCTAssertEqual($0 as? Pattern.ValidationError, .invalidDot)
        }
        XCTAssertNoThrow(try Pattern(dots: [0, 1, 2, 3, 4, 9]).validate())
        XCTAssertEqual(Pattern(dots: [0, 6, 12]).encoded, "0-6-12")
    }

    func testDotsBetween() {
        XCTAssertEqual(Pattern.dotsBetween(0, 4), [1, 2, 3])
        XCTAssertEqual(Pattern.dotsBetween(0, 24), [6, 12, 18])
        XCTAssertEqual(Pattern.dotsBetween(20, 10), [15])
        XCTAssertEqual(Pattern.dotsBetween(0, 7), [])
        XCTAssertEqual(Pattern.dotsBetween(0, 1), [])
    }
}

final class VaultTests: XCTestCase {
    private var storage: BlobStorage!
    private let salt = Data(repeating: 7, count: 32)
    private let patternA = Pattern(dots: [0, 1, 2, 7, 12, 17])
    private let patternB = Pattern(dots: [4, 3, 2, 7, 12, 17])

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        storage = try BlobStorage(root: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storage.root)
    }

    private func locate(_ pattern: Pattern) throws -> Vault.LocateResult {
        try Vault.locate(pattern: pattern, deviceSalt: salt, storage: storage, iterations: 1000)
    }

    func testCreateImportReopen() async throws {
        guard case .notFound(let pending) = try locate(patternA) else { return XCTFail("expected empty") }
        let vault = try pending.create()
        let photo = Self.samplePNG()
        let item = try await vault.importPhoto(photo)
        XCTAssertEqual(item.pixelWidth, 40)
        let thumb = try await vault.thumbnail(for: item)
        XCTAssertNotNil(thumb)

        guard case .found(let reopened) = try locate(patternA) else { return XCTFail("expected vault") }
        let items = await reopened.items
        XCTAssertEqual(items.count, 1)
        let contents = try await reopened.contents(of: items[0])
        XCTAssertEqual(contents, photo)

        guard case .notFound = try locate(patternB) else { return XCTFail("other pattern must not open it") }
    }

    func testTwoVaultsAreIsolatedAndNamesAreOpaque() async throws {
        guard case .notFound(let pa) = try locate(patternA), case .notFound(let pb) = try locate(patternB) else {
            return XCTFail()
        }
        let a = try pa.create(), b = try pb.create()
        try await a.importPhoto(Self.samplePNG())
        try await b.importPhoto(Data("not an image".utf8))
        try await b.importPhoto(Data("also not".utf8))

        guard case .found(let a2) = try locate(patternA), case .found(let b2) = try locate(patternB) else {
            return XCTFail()
        }
        let aCount = await a2.items.count
        let bCount = await b2.items.count
        XCTAssertEqual(aCount, 1)
        XCTAssertEqual(bCount, 2)

        for name in try storage.allNames() {
            XCTAssertEqual(name.count, 32)
            XCTAssertNotNil(Data(hex: name))
        }
    }

    func testDeleteRemovesBlobs() async throws {
        guard case .notFound(let pending) = try locate(patternA) else { return XCTFail() }
        let vault = try pending.create()
        let before = try storage.allNames().count
        let item = try await vault.importPhoto(Self.samplePNG())
        XCTAssertEqual(try storage.allNames().count, before + 2)  // blob + thumbnail
        try await vault.delete(item)
        XCTAssertEqual(try storage.allNames().count, before)
    }

    private static func samplePNG() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }()).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
    }
}
