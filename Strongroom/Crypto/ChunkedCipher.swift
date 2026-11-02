import CryptoKit
import Foundation

/// Streaming AES-256-GCM for file contents of any size (photos now, videos next).
///
/// Format:
///     header: "SRC1" | chunkSize (UInt32 BE) | noncePrefix (8 random bytes)
///     chunks: ciphertext | tag(16), each plaintext chunk is `chunkSize` bytes except the last
///
/// Chunk i uses nonce = noncePrefix || i (UInt32 BE) and AAD = i || isFinal.
/// Binding the index stops reordering; binding isFinal stops truncation and appending.
/// Every file gets its own random key, so the nonce space is never shared between files.
enum ChunkedCipher {
    static let magic = Data("SRC1".utf8)
    static let defaultChunkSize = 1 << 20
    static let maxChunkSize = 1 << 26
    static let tagSize = 16
    static let headerSize = 16

    typealias Reader = (_ maxCount: Int) throws -> Data
    typealias Writer = (_ data: Data) throws -> Void

    // MARK: Core

    static func encrypt(read: Reader, write: Writer, key: SymmetricKey, chunkSize: Int = defaultChunkSize) throws {
        precondition(chunkSize > 0 && chunkSize <= maxChunkSize)
        let prefix = try KDF.randomBytes(8)
        var header = magic
        header.append(bigEndian: UInt32(chunkSize))
        header.append(prefix)
        try write(header)

        var counter: UInt32 = 0
        var current = try readFully(read, chunkSize)
        while true {
            let next = current.count == chunkSize ? try readFully(read, chunkSize) : Data()
            let isFinal = next.isEmpty
            let sealed = try AES.GCM.seal(
                current,
                using: key,
                nonce: try nonce(prefix: prefix, counter: counter),
                authenticating: aad(counter: counter, isFinal: isFinal)
            )
            var out = Data(sealed.ciphertext)
            out.append(sealed.tag)
            try write(out)
            if isFinal { return }
            guard counter < UInt32.max else { throw VaultCryptoError.tooManyChunks }
            counter += 1
            current = next
        }
    }

    static func decrypt(read: Reader, write: Writer, key: SymmetricKey) throws {
        let header = try readFully(read, headerSize)
        guard header.count == headerSize, header.prefix(4) == magic else { throw VaultCryptoError.badHeader }
        let chunkSize = Int(header.subdata(in: header.startIndex + 4 ..< header.startIndex + 8)
            .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard chunkSize > 0, chunkSize <= maxChunkSize else { throw VaultCryptoError.badHeader }
        let prefix = header.subdata(in: header.startIndex + 8 ..< header.startIndex + 16)
        let sealedChunkSize = chunkSize + tagSize

        var counter: UInt32 = 0
        var current = try readFully(read, sealedChunkSize)
        while true {
            guard current.count >= tagSize else { throw VaultCryptoError.truncated }
            let next = current.count == sealedChunkSize ? try readFully(read, sealedChunkSize) : Data()
            let isFinal = next.isEmpty
            let box = try AES.GCM.SealedBox(
                nonce: try nonce(prefix: prefix, counter: counter),
                ciphertext: current.prefix(current.count - tagSize),
                tag: current.suffix(tagSize)
            )
            try write(try AES.GCM.open(box, using: key, authenticating: aad(counter: counter, isFinal: isFinal)))
            if isFinal { return }
            guard counter < UInt32.max else { throw VaultCryptoError.tooManyChunks }
            counter += 1
            current = next
        }
    }

    // MARK: Conveniences

    static func encrypt(_ data: Data, key: SymmetricKey, chunkSize: Int = defaultChunkSize) throws -> Data {
        let reader = DataReader(data)
        var out = Data()
        try encrypt(read: reader.read, write: { out.append($0) }, key: key, chunkSize: chunkSize)
        return out
    }

    static func decrypt(_ data: Data, key: SymmetricKey) throws -> Data {
        let reader = DataReader(data)
        var out = Data()
        try decrypt(read: reader.read, write: { out.append($0) }, key: key)
        return out
    }

    /// File → file, constant memory. Used for videos and large files.
    static func encryptFile(at source: URL, to destination: URL, key: SymmetricKey) throws {
        try streamFile(from: source, to: destination) { read, write in
            try encrypt(read: read, write: write, key: key)
        }
    }

    static func decryptFile(at source: URL, to destination: URL, key: SymmetricKey) throws {
        try streamFile(from: source, to: destination) { read, write in
            try decrypt(read: read, write: write, key: key)
        }
    }

    // MARK: Helpers

    private static func streamFile(from source: URL, to destination: URL, body: (Reader, Writer) throws -> Void) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(
            atPath: destination.path, contents: nil,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let output = try FileHandle(forWritingTo: destination)
        do {
            try body({ try input.read(upToCount: $0) ?? Data() }, { try output.write(contentsOf: $0) })
            try output.close()
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func readFully(_ read: Reader, _ count: Int) throws -> Data {
        var out = Data()
        while out.count < count {
            let piece = try read(count - out.count)
            if piece.isEmpty { break }
            out.append(piece)
        }
        return out
    }

    private static func nonce(prefix: Data, counter: UInt32) throws -> AES.GCM.Nonce {
        var data = prefix
        data.append(bigEndian: counter)
        return try AES.GCM.Nonce(data: data)
    }

    private static func aad(counter: UInt32, isFinal: Bool) -> Data {
        var data = Data()
        data.append(bigEndian: counter)
        data.append(isFinal ? 1 : 0)
        return data
    }
}

final class DataReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    func read(_ maxCount: Int) -> Data {
        let end = min(offset + maxCount, data.endIndex)
        defer { offset = end }
        return data.subdata(in: offset..<end)
    }
}

extension Data {
    mutating func append(bigEndian value: UInt32) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
}
