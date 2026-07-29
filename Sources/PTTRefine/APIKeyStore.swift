import Foundation
import Security
import PTTSupport

/// Stores the Gemini API key in the login keychain.
///
/// The key is a secret, and the repository is public. `UserDefaults` would put it in a
/// plist under the user's Library — not in the repo, but readable by any process running
/// as the user and trivially visible in a backup. The keychain is where macOS expects a
/// credential to live, and it is the only store this app will keep one in.
///
/// The user enters the key themselves; the app never generates, guesses, or transmits it
/// anywhere except to Google's own endpoint.
public enum APIKeyStore {

    private static let service = "com.gzowo.PushToType"
    private static let account = "gemini-api-key"

    /// The stored key, or `nil` if none has been entered.
    public static var geminiKey: String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    /// `true` when a key is present, without copying it out of the keychain.
    public static var hasKey: Bool {
        SecItemCopyMatching(baseQuery as CFDictionary, nil) == errSecSuccess
    }

    /// Stores `key`, replacing any existing one. An empty or blank key clears the entry.
    @discardableResult
    public static func setGeminiKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return clear() }

        let data = Data(trimmed.utf8)

        // Update in place if it exists, add otherwise — SecItemAdd fails on a duplicate.
        if hasKey {
            let attributes = [kSecValueData as String: data]
            let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
            logResult(status, verb: "update")
            return status == errSecSuccess
        }

        var query = baseQuery
        query[kSecValueData as String] = data
        // Available only after first unlock, and never synced to iCloud — a local
        // credential for a local tool.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        logResult(status, verb: "add")
        return status == errSecSuccess
    }

    /// Removes the stored key.
    @discardableResult
    public static func clear() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func logResult(_ status: OSStatus, verb: String) {
        if status == errSecSuccess {
            Log.settings.info("Gemini key \(verb, privacy: .public)d in keychain")
        } else {
            Log.settings.error("Keychain \(verb, privacy: .public) failed: \(status)")
        }
    }
}
