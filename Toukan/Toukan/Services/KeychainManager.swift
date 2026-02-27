import Foundation
import Security
import os

// MARK: - KeychainError

enum KeychainError: Error, Sendable {
    case unexpectedStatus(OSStatus)
    case unexpectedData
    case encodingFailed
}

extension KeychainError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain error (\(status)): \(message)"
            }
            return "Keychain error: OSStatus \(status)"
        case .unexpectedData:
            return "Keychain error: retrieved item data had an unexpected format"
        case .encodingFailed:
            return "Keychain error: failed to encode value as UTF-8 data"
        }
    }
}

// MARK: - KeychainManager

/// A lightweight, stateless wrapper around the Security framework Keychain APIs.
///
/// All credentials are stored in the macOS Keychain under the service name
/// `"com.clevique.Toukan"`. Keys used by Toukan:
/// - `"notionToken"` — Notion Integration Token
struct KeychainManager: Sendable {

    // MARK: Constants

    private static let serviceName = "com.clevique.Toukan"
    private static let logger = Logger(subsystem: "com.clevique.Toukan", category: "Keychain")

    // MARK: Public API

    /// Saves (or updates) a string value in the Keychain for the given key.
    ///
    /// - Parameters:
    ///   - key:   The account identifier within the service namespace.
    ///   - value: The plaintext string to store securely.
    /// - Throws: ``KeychainError`` if the operation fails.
    static func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        // Try updating an existing item first.
        let query = baseQuery(for: key)
        let updateAttributes: [CFString: Any] = [kSecValueData: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            // Updated in-place — done.
            return

        case errSecItemNotFound:
            // Item does not exist yet; add it.
            var addQuery = baseQuery(for: key)
            addQuery[kSecValueData] = data

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }

        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    /// Loads a string value from the Keychain for the given key.
    ///
    /// - Parameter key: The account identifier within the service namespace.
    /// - Returns: The stored string, or `nil` if no matching item exists.
    static func load(key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = kCFBooleanTrue

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                logger.warning("load: unexpected Keychain status \(status, privacy: .public) for key '\(key, privacy: .public)'")
            }
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    /// Deletes the Keychain item for the given key, if it exists.
    ///
    /// Silently succeeds when no item is found.
    ///
    /// - Parameter key: The account identifier within the service namespace.
    static func delete(key: String) {
        let query = baseQuery(for: key)
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.warning("delete: unexpected Keychain status \(status, privacy: .public) for key '\(key, privacy: .public)'")
        }
    }

    // MARK: Private Helpers

    /// Constructs the base Keychain attribute dictionary shared by all operations.
    private static func baseQuery(for key: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: serviceName,
            kSecAttrAccount: key,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked,
        ]
    }
}
