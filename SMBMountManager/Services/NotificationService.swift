import Foundation
import UserNotifications

/// Manages native macOS notifications via UserNotifications framework
struct NotificationService {
    static let categoryReconnect = "MOUNT_RECONNECT"
    static let actionReconnect = "RECONNECT_ACTION"
    static let actionDismiss = "DISMISS_ACTION"

    // Throttling mechanism
    private static var lastNotificationTimes: [String: Date] = [:]
    private static let throttleInterval: TimeInterval = 60.0 // 60 seconds

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

    /// Check if a notification should be throttled
    private static func shouldThrottle(key: String) -> Bool {
        let now = Date()
        if let lastTime = lastNotificationTimes[key], now.timeIntervalSince(lastTime) < throttleInterval {
            return true
        }
        lastNotificationTimes[key] = now
        return false
    }

    /// Send a notification for mount disconnection
    static func sendMountDisconnected(name: String) {
        if AppLifecycle.shared.isTerminating { return }
        
        // Suppress notifications during sleep or immediately after waking (within 15 seconds)
        if AppLifecycle.shared.isSleeping { return }
        if let wakeTime = AppLifecycle.shared.lastWakeTime, Date().timeIntervalSince(wakeTime) < 15.0 {
            return
        }
        
        let throttleKey = "disconnect_\(name)"
        guard !shouldThrottle(key: throttleKey) else { return }

        let content = UNMutableNotificationContent()
        content.title = "⚠️ 哎呀！連線中斷"
        content.body = "找不到「\(name)」了。不過別擔心，我正在背景幫您嘗試重新連線喔！💪"
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
        if AppLifecycle.shared.isTerminating { return }
        
        // Suppress notifications during sleep or immediately after waking (within 15 seconds)
        if AppLifecycle.shared.isSleeping { return }
        if let wakeTime = AppLifecycle.shared.lastWakeTime, Date().timeIntervalSince(wakeTime) < 15.0 {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "🎉 掛載成功！"
        content.body = "「\(name)」已經成功連線囉，可以開始使用了！✨"
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
        if AppLifecycle.shared.isTerminating { return }
        
        let throttleKey = "stale_\(name)"
        guard !shouldThrottle(key: throttleKey) else { return }

        let content = UNMutableNotificationContent()
        content.title = "🤔 掛載點無回應"
        content.body = "「\(name)」似乎卡住了。系統正試著重新喚醒它，請稍候！🔄"
        content.sound = .default
        content.categoryIdentifier = categoryReconnect
        content.userInfo = ["mountName": name]

        let request = UNNotificationRequest(
            identifier: "mount_stale_\(name)_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Send a notification for network change
    static func sendNetworkChanged(newInterface: String) {
        let throttleKey = "network_change"
        guard !shouldThrottle(key: throttleKey) else { return }

        let content = UNMutableNotificationContent()
        content.title = "🌐 網路環境變了"
        content.body = "已經切換到 \(newInterface)。我正在為您重新檢查並建立所有的連線唷！🚀"
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
        // Find active notification identifiers that match this mount and remove them
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let idsToRemove = notifications.filter { notification in
                notification.request.identifier.contains(name)
            }.map { $0.request.identifier }
            
            if !idsToRemove.isEmpty {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: idsToRemove)
            }
        }
    }
}
