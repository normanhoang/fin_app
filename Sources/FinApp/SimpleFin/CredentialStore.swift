import Foundation
import Security

/// Stores the SimpleFin access URL (which embeds credentials) in the Keychain.
/// Never persisted to SwiftData or UserDefaults.
struct CredentialStore {
    let service: String
    private let account = "simplefin-access-url"

    init(service: String = "com.normanhoang.finapp") {
        self.service = service
    }

    func saveAccessURL(_ url: URL) throws {
        let data = Data(url.absoluteString.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError(status: updateStatus) }

        var attributes = query
        attributes[kSecValueData as String] = data
        // WhenUnlocked (not AfterFirstUnlock): the credential is only readable while
        // the device is currently unlocked, and never leaves this device (no iCloud
        // Keychain sync). All syncs are user-initiated while the app is foreground.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func loadAccessURL() -> URL? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return URL(string: string)
    }

    @discardableResult
    func deleteAccessURL() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}

struct KeychainError: Error {
    let status: OSStatus
}
