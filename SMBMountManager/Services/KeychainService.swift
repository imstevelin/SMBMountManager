import Foundation
import Security

/// Manages SMB passwords in the macOS Keychain using Security.framework
struct KeychainService {
    static let servicePre = "smb_mount"

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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: username,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
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

    /// Quick diagnostic: check if we can read/write to the Keychain at all
    static func testKeychainAccess() -> (canWrite: Bool, canRead: Bool, error: String?) {
        let testService = "\(servicePre)_test_diagnostics"
        let testData = "test_\(Date().timeIntervalSince1970)".data(using: .utf8)!

        // Clean up any previous test
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Try writing
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService,
            kSecAttrAccount as String: "test",
            kSecValueData as String: testData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        let canWrite = (addStatus == errSecSuccess)

        // Try reading
        var canRead = false
        if canWrite {
            let readQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: testService,
                kSecAttrAccount as String: "test",
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: AnyObject?
            let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &result)
            canRead = (readStatus == errSecSuccess && result is Data)
        }

        // Clean up
        SecItemDelete(deleteQuery as CFDictionary)

        var error: String? = nil
        if !canWrite {
            let msg = SecCopyErrorMessageString(addStatus, nil) as String? ?? "未知"
            error = "Keychain 寫入失敗 (\(addStatus)): \(msg)"
        } else if !canRead {
            error = "Keychain 寫入成功但無法讀回"
        }

        return (canWrite, canRead, error)
    }
}
