import CryptoKit
import Foundation

/// Single-shot AES-256-GCM for small records (headers, index, thumbnails).
/// Output layout: nonce(12) | ciphertext | tag(16).
enum Box {
    static func seal(_ plaintext: Data, key: SymmetricKey, aad: Data = Data()) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        guard let combined = sealed.combined else { throw VaultCryptoError.sealFailed }
        return combined
    }

    static func open(_ combined: Data, key: SymmetricKey, aad: Data = Data()) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: key, authenticating: aad)
    }
}

/// Length-prefixed zero padding to a multiple of `block`, so record sizes leak less.
enum Padding {
    static func pad(_ data: Data, toMultipleOf block: Int) -> Data {
        var out = Data()
        var length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(data)
        let remainder = out.count % block
        if remainder != 0 { out.append(Data(count: block - remainder)) }
        return out
    }

    static func unpad(_ data: Data) throws -> Data {
        guard data.count >= 4 else { throw VaultCryptoError.badPadding }
        let length = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length <= data.count - 4 else { throw VaultCryptoError.badPadding }
        let start = data.startIndex + 4
        return data.subdata(in: start..<(start + length))
    }
}
