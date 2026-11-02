import CryptoKit
import Foundation

/// Nine words from the BIP-39 English list (99 bits), or a phrase the user chooses.
/// The phrase alone (no device salt) re-opens the vault, so it works on a new phone.
///
///     recoveryIKM = PBKDF2-SHA256("recovery:v1:" + normalized phrase, "strongroom.recovery.v1", 600k)
///     wrapKey     = HKDF(recoveryIKM, "strongroom.recovery.wrap.v1")
///     locatorKey  = HKDF(recoveryIKM, "strongroom.recovery.locator.v1")
///     headerName  = HMAC(locatorKey, "recovery-header")[0..16]
enum RecoveryPhrase {
    static let wordCount = 9
    static let minimumCustomWords = 4
    static let minimumCustomLength = 16

    enum ValidationError: Error, Equatable {
        case tooShort

        var message: String {
            "Use at least \(RecoveryPhrase.minimumCustomWords) words and \(RecoveryPhrase.minimumCustomLength) characters."
        }
    }

    static let wordlist: [String] = {
        guard let url = Bundle.main.url(forResource: "bip39-english", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").map(String.init)
    }()

    static func generate() throws -> String {
        precondition(wordlist.count == 2048, "BIP-39 wordlist missing from the app bundle")
        let bytes = try KDF.randomBytes(wordCount * 2)
        return (0..<wordCount).map { i in
            let value = (Int(bytes[bytes.startIndex + 2 * i]) << 8 | Int(bytes[bytes.startIndex + 2 * i + 1])) & 0x7FF
            return wordlist[value]
        }.joined(separator: " ")
    }

    /// Lowercased, single-spaced, trimmed. Typing variations still derive the same key.
    static func normalize(_ phrase: String) -> String {
        phrase.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func validateCustom(_ phrase: String) throws {
        let normalized = normalize(phrase)
        guard normalized.split(separator: " ").count >= minimumCustomWords,
              normalized.count >= minimumCustomLength
        else { throw ValidationError.tooShort }
    }
}

struct RecoveryKeys: @unchecked Sendable {
    let wrapKey: SymmetricKey
    let locatorKey: SymmetricKey

    static func derive(phrase: String, iterations: UInt32 = KDF.productionIterations) throws -> RecoveryKeys {
        let password = Data(("recovery:v1:" + RecoveryPhrase.normalize(phrase)).utf8)
        let salt = Data("strongroom.recovery.v1".utf8)
        let ikm = SymmetricKey(data: try KDF.pbkdf2SHA256(password: password, salt: salt, iterations: iterations))
        return RecoveryKeys(
            wrapKey: KDF.subkey(ikm, info: "strongroom.recovery.wrap.v1"),
            locatorKey: KDF.subkey(ikm, info: "strongroom.recovery.locator.v1")
        )
    }

    var headerName: String { locatorName("recovery-header") }

    /// Deterministic, opaque names for other records found from the phrase (e.g. cloud backup).
    func locatorName(_ label: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(label.utf8), using: locatorKey)).prefix(16).hexString
    }
}
