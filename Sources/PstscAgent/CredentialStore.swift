import Foundation
import Security
import ServiceManagement

/// Saved login for automatic connection: host and user in UserDefaults, the password in the Keychain.
enum CredentialStore {
    private static let service = "com.pstsc.agent"
    private enum Key {
        static let host = "host"
        static let user = "username"
        static let autoConnect = "autoConnect"
    }

    /// Credentials to connect with right after launch, if the user chose to remember them.
    static func savedForAutoConnect() -> Credentials? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Key.autoConnect),
              let host = defaults.string(forKey: Key.host), !host.isEmpty,
              let user = defaults.string(forKey: Key.user), !user.isEmpty,
              let password = password(host: host, user: user) else { return nil }
        return Credentials(host: host, username: user, password: password)
    }

    static func remember(_ credentials: Credentials) {
        let account = account(credentials.host, credentials.username)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(credentials.password.utf8)
        item[kSecAttrLabel as String] = "Pstsc — \(credentials.host)"
        let saved = SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        UserDefaults.standard.set(saved, forKey: Key.autoConnect)
    }

    /// Wrong password or the user turned auto-connect off: drop the saved password.
    static func forget(host: String, user: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account(host, user)]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.set(false, forKey: Key.autoConnect)
    }

    private static func password(host: String, user: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account(host, user),
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func account(_ host: String, _ user: String) -> String { "\(user)@\(host)" }
}

/// "Open Pstsc at login" through the system login items (only works for the installed Pstsc.app).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns an error message when macOS refuses, e.g. when running outside an app bundle.
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
