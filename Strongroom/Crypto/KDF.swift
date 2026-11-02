import CommonCrypto
import CryptoKit
import Foundation
import Security

enum VaultCryptoError: Error, Equatable {
    case kdfFailed(Int32)
    case randomFailed(Int32)
    case sealFailed
    case badHeader
    case truncated
    case tooManyChunks
    case badPadding
}

/// Key derivation for the vault key hierarchy.
///
///     deviceSalt  = 32 random bytes, Keychain, this-device-only
///     patternIKM  = PBKDF2-SHA256("pattern:v1:" + pattern, deviceSalt, 600k)
///     wrapKey     = HKDF(patternIKM, "strongroom.wrap.v1")     -> decrypts the vault header (holds masterKey)
///     locatorKey  = HKDF(patternIKM, "strongroom.locator.v1")  -> computes the header's opaque file name
///     indexKey    = HKDF(masterKey,  "strongroom.index.v1")    -> encrypts the vault index
enum KDF {
    static let productionIterations: UInt32 = 600_000

    static func pbkdf2SHA256(password: Data, salt: Data, iterations: UInt32, length: Int = 32) throws -> Data {
        var derived = Data(count: length)
        let status: Int32 = derived.withUnsafeMutableBytes { outPtr in
            password.withUnsafeBytes { pwPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwPtr.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        outPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), length
                    )
                }
            }
        }
        guard status == Int32(kCCSuccess) else { throw VaultCryptoError.kdfFailed(status) }
        return derived
    }

    static func subkey(_ input: SymmetricKey, info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: input,
            salt: Data(),
            info: Data(info.utf8),
            outputByteCount: 32
        )
    }

    static func randomBytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw VaultCryptoError.randomFailed(status) }
        return data
    }
}

struct PatternKeys: @unchecked Sendable {
    let wrapKey: SymmetricKey
    let locatorKey: SymmetricKey

    static func derive(patternEncoding: String, deviceSalt: Data, iterations: UInt32) throws -> PatternKeys {
        let password = Data(("pattern:v1:" + patternEncoding).utf8)
        let ikm = SymmetricKey(data: try KDF.pbkdf2SHA256(password: password, salt: deviceSalt, iterations: iterations))
        return PatternKeys(
            wrapKey: KDF.subkey(ikm, info: "strongroom.wrap.v1"),
            locatorKey: KDF.subkey(ikm, info: "strongroom.locator.v1")
        )
    }

    /// Opaque, deterministic file name of this pattern's vault header (16 bytes, hex).
    var headerName: String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("header".utf8), using: locatorKey)
        return Data(mac).prefix(16).hexString
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
