import Foundation
import Security

/// Manages SMB passwords in the macOS Keychain using Security.framework
struct KeychainService {
    static let servicePre = "smb_mount"
    static var allowUI: Bool = false

    /// Save a password to the Keychain. Returns nil on success, or error message on failure.
    static func savePassword(forMount name: String, username: String, password: String) -> String? {
        let service = "\(servicePre)_\(name)"
        guard let passwordData = password.data(using: .utf8) else {
            return "密碼編碼失敗"
        }

        // Delete ALL existing entries for this service (any username)
        deletePassword(forMount: name)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: username,
            kSecValueData as String: passwordData,
            kSecAttrLabel as String: "SMB Mount: \(name)",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        var status = SecItemAdd(query as CFDictionary, nil)

        // If it still exists somehow, update it instead
        if status == errSecDuplicateItem {
            let searchQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: username
            ]
            let updateAttrs: [String: Any] = [
                kSecValueData as String: passwordData,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]
            status = SecItemUpdate(searchQuery as CFDictionary, updateAttrs as CFDictionary)
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
        
        // Prevent system prompt until user clicks "Authorize" in our custom UI
        if !allowUI {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        } else {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIAllow
            query[kSecUseOperationPrompt as String] = "為確保後續背景連線不會被打斷，請點擊「永遠允許 (Always Allow)」授權 SMB 掛載管理器。"
        }
        
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
        
        if status == errSecSuccess, let items = result as? [[String: Any]] {
            for item in items {
                if let service = item[kSecAttrService as String] as? String,
                   let account = item[kSecAttrAccount as String] as? String {
                    if service.hasPrefix(servicePre) {
                        let mountName = service.replacingOccurrences(of: "\(servicePre)_", with: "")
                        // Force read to trigger prompt
                        let _ = getPassword(forMount: mountName, username: account)
                    }
                }
            }
        }
        
        return (true, true, nil)
    }
}
