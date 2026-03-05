import Foundation
import UserNotifications

/// Manages native macOS notifications via UserNotifications framework
struct NotificationService {
    static let categoryReconnect = "MOUNT_RECONNECT"
    static let actionReconnect = "RECONNECT_ACTION"
    static let actionDismiss = "DISMISS_ACTION"

    /// Request notification permissions
    static func requestPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("[NotificationService] Permission error: \(error)")
            }
        }

        // Register action category
        let reconnectAction = UNNotificationAction(
            identifier: actionReconnect,
            title: "重新連線",
            options: .foreground
        )
        let dismissAction = UNNotificationAction(
            identifier: actionDismiss,
            title: "忽略",
            options: .destructive
        )
        let category = UNNotificationCategory(
            identifier: categoryReconnect,
            actions: [reconnectAction, dismissAction],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])
    }

    /// Send a notification for mount disconnection
    static func sendMountDisconnected(name: String) {
        let content = UNMutableNotificationContent()
        content.title = "掛載點已斷線"
        content.body = "'\(name)' 已偵測為未連線，系統正在背景嘗試重連。"
        content.sound = .default
        content.categoryIdentifier = categoryReconnect
        content.userInfo = ["mountName": name]

        let request = UNNotificationRequest(
            identifier: "mount_disconnected_\(name)_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Send a notification for successful mount connection
    static func sendMountConnected(name: String) {
        let content = UNMutableNotificationContent()
        content.title = "掛載成功"
        content.body = "'\(name)' 已成功連線。"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "mount_connected_\(name)_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Send a notification for stale mount
    static func sendMountStale(name: String) {
        let content = UNMutableNotificationContent()
        content.title = "掛載點無回應"
        content.body = "'\(name)' 已連續多次無法存取，系統將嘗試自動修復。"
        content.sound = .default
        content.categoryIdentifier = categoryReconnect
        content.userInfo = ["mountName": name]

        let request = UNNotificationRequest(
            identifier: "mount_stale_\(name)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Send a notification for network change
    static func sendNetworkChanged(newInterface: String) {
        let content = UNMutableNotificationContent()
        content.title = "網路已變更"
        content.body = "已切換至 \(newInterface)，正在重新建立所有掛載連線…"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "network_changed_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Clear notifications for a specific mount
    static func clearNotifications(for name: String) {
        let ids = ["mount_disconnected_\(name)", "mount_stale_\(name)"]
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }
}
