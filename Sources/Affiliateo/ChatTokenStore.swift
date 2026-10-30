import Foundation
#if os(iOS)
import Security
#endif

/// The visitor's key to their Live Chat thread, on this phone (4.15.4,
/// review S18). Whoever holds the key can read and write the thread, so it
/// lives in the Keychain, readable on this phone only and only after its
/// first unlock since a restart: it never goes into a backup that another
/// phone can restore, and never into iCloud. It used to sit in UserDefaults,
/// which every backup copies; a key found there moves over once and is
/// deleted.
///
/// Deleting the app still starts a new thread, as the server expects.
/// Keychain items outlive the app, so a key counts only while this install's
/// own note in UserDefaults (which deleting the app clears) says it saved
/// one; a key a deleted install left behind is removed instead of used.
struct ChatTokenStore {
    let secrets: ChatSecrets
    let defaults: UserDefaults

    static var standard: ChatTokenStore {
        ChatTokenStore(secrets: KeychainChatSecrets(), defaults: .standard)
    }

    /// "This install saved a key in the Keychain" (the key itself is never in UserDefaults).
    static func savedKey(_ appId: String) -> String { "affiliateo_chat_token_saved_\(appId)" }

    /// The key for this app's thread, or nil.
    func token(appId: String) -> String? {
        let oldKey = ChatRules.tokenKey(appId)
        if let old = defaults.string(forKey: oldKey) {
            guard ChatRules.isToken(old) else {
                defaults.removeObject(forKey: oldKey)
                return keychainToken(appId: appId)
            }
            // Out of UserDefaults once it is safely in the Keychain (save
            // takes it out). Until then it stays where it was, so the person
            // keeps their thread.
            save(old, appId: appId)
            return old
        }
        return keychainToken(appId: appId)
    }

    private func keychainToken(appId: String) -> String? {
        guard defaults.bool(forKey: Self.savedKey(appId)) else {
            // Left by an install of the app that was deleted since.
            if secrets.read(account: appId) != nil { secrets.delete(account: appId) }
            return nil
        }
        let token = secrets.read(account: appId)
        return ChatRules.isToken(token) ? token : nil
    }

    /// Keeps the key the chat page handed over. False when it was not kept.
    /// Once it is in the Keychain, no copy is left in UserDefaults, so an
    /// older key there can never come back over it.
    @discardableResult
    func save(_ token: String, appId: String) -> Bool {
        guard ChatRules.isToken(token), secrets.write(token, account: appId) else { return false }
        defaults.set(true, forKey: Self.savedKey(appId))
        defaults.removeObject(forKey: ChatRules.tokenKey(appId))
        return true
    }

    /// The person signed out (or another signed in): their key goes, wherever it was.
    func clear(appId: String) {
        secrets.delete(account: appId)
        defaults.removeObject(forKey: Self.savedKey(appId))
        defaults.removeObject(forKey: ChatRules.tokenKey(appId))
    }
}

/// Where the key itself is kept.
protocol ChatSecrets {
    func read(account: String) -> String?
    /// False when it could not be kept.
    func write(_ value: String, account: String) -> Bool
    func delete(account: String)
}

#if os(iOS)
/// The Keychain: this phone only, after its first unlock, never synced.
struct KeychainChatSecrets: ChatSecrets {
    static let service = "com.affiliateo.chat-token"

    private func item(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }

    func read(account: String) -> String? {
        var query = item(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String, account: String) -> Bool {
        let fields: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(item(account) as CFDictionary, fields as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        let added = item(account).merging(fields) { _, new in new }
        return SecItemAdd(added as CFDictionary, nil) == errSecSuccess
    }

    func delete(account: String) {
        SecItemDelete(item(account) as CFDictionary)
    }
}
#else
/// Live Chat is iPhone and iPad only: elsewhere no key is ever kept.
struct KeychainChatSecrets: ChatSecrets {
    func read(account: String) -> String? { nil }
    func write(_ value: String, account: String) -> Bool { false }
    func delete(account: String) {}
}
#endif
