import Foundation
import Security
import LocalAuthentication

/// Manages SMB passwords in the macOS Keychain using Security.framework
struct KeychainService {
    static let servicePre = "smb_mount"
    private static let interactionLock = NSLock()
    nonisolated(unsafe) private static var interactionAllowed = false
    static var allowUI: Bool {
        get { interactionLock.withLock { interactionAllowed } }
        set { interactionLock.withLock { interactionAllowed = newValue } }
    }

    /// Save a password to the Keychain. Returns nil on success, or error message on failure.
    static func savePassword(forMount name: String, username: String, password: String) -> String? {
        let service = "\(servicePre)_\(name)"
        guard let passwordData = password.data(using: .utf8) else {
            return "密碼編碼失敗"
        }

        let itemQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: username
        ]
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: username,
            kSecValueData as String: passwordData,
            kSecAttrLabel as String: "SMB Mount: \(name)",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        // Update first so a failed write never destroys a working credential.
        let updateAttributes: [String: Any] = [
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrLabel as String: "SMB Mount: \(name)"
        ]
        var status = SecItemUpdate(itemQuery as CFDictionary, updateAttributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        if status == errSecSuccess {
            // Verify the saved password can be read back
            if let retrieved = getPassword(forMount: name, username: username), retrieved == password {
                return nil  // success
            } else {
                return "密碼已寫入 Keychain 但驗證讀取失敗"
            }
        } else {
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "未知錯誤"
            return "Keychain 儲存失敗 (OSStatus: \(status)): \(msg)"
        }
    }

    /// Retrieve a password from the Keychain
    static func getPassword(forMount name: String, username: String) -> String? {
        let service = "\(servicePre)_\(name)"
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: username,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        // Prevent a surprise system prompt during background reconnects. The
        // explicit authorization screen temporarily enables interaction.
        let context = LAContext()
        context.interactionNotAllowed = !allowUI
        context.localizedReason = "讀取 SMB 掛載密碼以重新連線"
        query[kSecUseAuthenticationContext as String] = context
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status != errSecSuccess && status != errSecItemNotFound {
            AppLogger.shared.error("[Keychain] Unexpected error or interaction not allowed for \(name). Status: \(status). Triggering UI prompt.")
            DispatchQueue.main.async {
                AppStateManager.shared.needsErrorAuthorization = true
            }
            return nil
        }
        
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Public alias for MountEngine
    static func retrievePassword(forMount name: String, username: String) -> String? {
        return getPassword(forMount: name, username: username)
    }

    /// Delete a password from the Keychain
    static func deletePassword(forMount name: String) {
        let service = "\(servicePre)_\(name)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Scan for all legacy passwords and preemptively trigger their authorization prompts
    static func testKeychainAccess() -> (canWrite: Bool, canRead: Bool, error: String?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        var unreadableMounts: [String] = []
        if status == errSecSuccess, let items = result as? [[String: Any]] {
            for item in items {
                if let service = item[kSecAttrService as String] as? String,
                   let account = item[kSecAttrAccount as String] as? String {
                    if service.hasPrefix(servicePre) {
                        let mountName = service.replacingOccurrences(of: "\(servicePre)_", with: "")
                        // Force read to trigger the authorization prompt and
                        // report the actual result instead of always succeeding.
                        if getPassword(forMount: mountName, username: account) == nil {
                            unreadableMounts.append(mountName)
                        }
                    }
                }
            }
        } else if status != errSecItemNotFound {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知錯誤"
            return (false, false, "無法讀取 Keychain：\(message)")
        }

        if unreadableMounts.isEmpty {
            return (true, true, nil)
        }
        return (true, false, "無法讀取：\(unreadableMounts.joined(separator: "、"))")
    }
}
