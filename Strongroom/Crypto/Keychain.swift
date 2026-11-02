import Foundation
import Security

enum KeychainError: Error {
    case unexpectedStatus(OSStatus)
}

/// Generic-password items, readable only while the device is unlocked and never
/// migrated to another device (not in iCloud Keychain, not restored from backups).
enum Keychain {
    private static let service = "app.strongroom.device"

    static func read(_ account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError.unexpectedStatus(status)
        }
    }

    static func write(_ data: Data, account: String) throws {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(match as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// The per-install salt every pattern is stretched with. Without it, a copied
    /// storage folder can't be brute-forced off the device.
    static func deviceSalt() throws -> Data {
        if let existing = try read("device-salt") { return existing }
        let salt = try KDF.randomBytes(32)
        try write(salt, account: "device-salt")
        return salt
    }
}
