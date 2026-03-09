import Foundation
import UserNotifications

/// Manages native macOS notifications via UserNotifications framework.
/// Supports event coalescing (batching same-cycle mount events), transfer notifications,
/// and randomized humorous templates for a delightful user experience.
struct NotificationService {
    static let categoryReconnect = "MOUNT_RECONNECT"
    static let actionReconnect = "RECONNECT_ACTION"
    static let actionDismiss = "DISMISS_ACTION"

    // MARK: - Throttling
    private static var lastNotificationTimes: [String: Date] = [:]
    private static let throttleInterval: TimeInterval = 60.0

    // MARK: - Event Coalescing Buffers
    // Accumulate mount names within a single refresh cycle and flush once.
    private static var pendingConnected: Set<String> = []
    private static var pendingDisconnected: Set<String> = []
    private static var pendingStale: Set<String> = []
    private static let coalesceLock = NSLock()
    
    // MARK: - Humorous Template System
    
    private static let connectedTemplates: [(title: String, body: String)] = [
        ("🎉 上線啦！", "NAMES 已就位，隨時為您服務～"),
        ("✅ 連線成功", "NAMES 回來了！衝吧！🏃‍♂️"),
        ("🔗 握手成功", "跟 NAMES 接上線了，開始幹活！💼"),
        ("🚀 準備就緒", "NAMES 已經熱好引擎，出發！"),
        ("📂 歡迎回來", "NAMES 已成功歸隊，檔案們都想你了～"),
        ("🎊 搞定！", "NAMES 連線完成，NAS 就是您的後花園 🌿"),
    ]
    
    private static let disconnectedTemplates: [(title: String, body: String)] = [
        ("⚠️ 斷線了", "NAMES 走丟了，正在努力找回來中…🔍"),
        ("😱 連線中斷", "NAMES 突然離線了！別慌，後台搶救中 🚑"),
        ("📡 訊號中斷", "NAMES 暫時失聯，背景全力重連中～"),
        ("🔌 連線遺失", "NAMES 斷開了，正在默默幫您重新接線 🔧"),
        ("💨 消失了", "NAMES 神秘蒸發，偵探已出動偵查中 🕵️"),
    ]
    
    private static let staleTemplates: [(title: String, body: String)] = [
        ("🤔 掛載點沒反應", "NAMES 裝死了，正在幫您搖醒它 🔔"),
        ("🧊 凍住了", "NAMES 冷場中，系統正在重啟引擎 🔄"),
        ("😴 沒回應", "NAMES 好像睡著了…正在幫您拍拍它 👋"),
        ("⏳ 反應遲鈍", "NAMES 頭腦當機中，強制重啟搶救中！"),
    ]
    
    private static let downloadStartTemplates: [(title: String, body: String)] = [
        ("📥 開始下載", "NAMES 正在從 NAS 飛奔過來～ 🏃"),
        ("⬇️ 下載啟動", "NAMES 的傳送門已開啟！"),
        ("🚚 搬運中", "NAMES 正在打包寄出，請稍候 📦"),
        ("💾 下載中", "NAMES 傳輸啟動，安心等待就好～"),
    ]
    
    private static let downloadCompleteTemplates: [(title: String, body: String)] = [
        ("✅ 下載完成", "NAMES 已安全抵達！去看看吧 👀"),
        ("🎉 傳輸成功", "NAMES 全部到齊了！任務圓滿達成 🏆"),
        ("📁 已送達", "NAMES 下載完畢，檔案已就定位 📍"),
        ("💯 搞定啦", "NAMES 全數下載完成，效率滿分！"),
    ]
    
    private static let uploadStartTemplates: [(title: String, body: String)] = [
        ("📤 開始上傳", "NAMES 正在飛向 NAS 的路上～ ✈️"),
        ("⬆️ 上傳啟動", "NAMES 出發前往雲端儲存囉！☁️"),
        ("🚀 發射！", "NAMES 正在以光速上傳中… 💫"),
        ("📡 傳送中", "NAMES 已進入上傳軌道！"),
    ]
    
    private static let uploadCompleteTemplates: [(title: String, body: String)] = [
        ("✅ 上傳完成", "NAMES 已安全抵達 NAS！🏠"),
        ("🎊 傳輸成功", "NAMES 全部上傳完畢，任務達成 🎯"),
        ("📦 已送達", "NAMES 安全交付到 NAS 手中了～"),
        ("🏆 搞定！", "NAMES 上傳成功，檔案已安家落戶 🪴"),
    ]

    // MARK: - Permission Setup

    static func requestPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("[NotificationService] Permission error: \(error)")
            }
        }

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

    // MARK: - Throttling

    private static func shouldThrottle(key: String) -> Bool {
        let now = Date()
        if let lastTime = lastNotificationTimes[key], now.timeIntervalSince(lastTime) < throttleInterval {
            return true
        }
        lastNotificationTimes[key] = now
        return false
    }
    
    // MARK: - Random Template Selection
    
    private static func randomTemplate(from templates: [(title: String, body: String)], names: String) -> (title: String, body: String) {
        let template = templates.randomElement()!
        return (template.title, template.body.replacingOccurrences(of: "NAMES", with: names))
    }
    
    private static func formatNames(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return "「\(names[0])」"
        case 2: return "「\(names[0])」與「\(names[1])」"
        default:
            return "「\(names[0])」等 \(names.count) 個掛載點"
        }
    }

    // MARK: - Coalesced Mount Events (called per-mount, flushed once per cycle)

    /// Queue a mount-connected event. Call `flushMountEvents()` at the end of the refresh cycle.
    static func queueMountConnected(name: String) {
        coalesceLock.lock()
        pendingConnected.insert(name)
        // Mutex: remove any opposing events awaiting flush
        pendingDisconnected.remove(name)
        pendingStale.remove(name)
        coalesceLock.unlock()
    }

    /// Queue a mount-disconnected event. Call `flushMountEvents()` at the end of the refresh cycle.
    static func queueMountDisconnected(name: String) {
        coalesceLock.lock()
        pendingDisconnected.insert(name)
        // Mutex: remove any opposing matching connection
        pendingConnected.remove(name)
        coalesceLock.unlock()
    }

    /// Queue a mount-stale event. Call `flushMountEvents()` at the end of the refresh cycle.
    static func queueMountStale(name: String) {
        coalesceLock.lock()
        pendingStale.insert(name)
        // Mutex: remove opposing
        pendingConnected.remove(name)
        coalesceLock.unlock()
    }
    
    /// Completely discard any queued mount events. Call immediately when Mac wakes from sleep.
    static func clearPendingEvents() {
        coalesceLock.lock()
        pendingConnected.removeAll()
        pendingDisconnected.removeAll()
        pendingStale.removeAll()
        coalesceLock.unlock()
    }

    /// Flush all queued mount events into coalesced notifications.
    /// Should be called ONCE at the end of a complete `refreshStatuses()` / health monitor cycle.
    static func flushMountEvents() {
        if AppLifecycle.shared.isTerminating { return }
        if AppLifecycle.shared.isSleeping { return }
        if let wakeTime = AppLifecycle.shared.lastWakeTime, Date().timeIntervalSince(wakeTime) < 15.0 {
            return
        }

        coalesceLock.lock()
        let connected = Array(pendingConnected)
        let disconnected = Array(pendingDisconnected)
        let stale = Array(pendingStale)
        pendingConnected.removeAll()
        pendingDisconnected.removeAll()
        pendingStale.removeAll()
        coalesceLock.unlock()

        if !connected.isEmpty {
            let names = formatNames(connected)
            let t = randomTemplate(from: connectedTemplates, names: names)
            sendNotification(title: t.title, body: t.body, id: "mount_connected_batch")
            // Clear old disconnect notifications for newly re-connected mounts
            for name in connected {
                clearNotifications(for: name)
            }
        }

        if !disconnected.isEmpty {
            let throttleKey = "disconnect_batch"
            if !shouldThrottle(key: throttleKey) {
                let names = formatNames(disconnected)
                let t = randomTemplate(from: disconnectedTemplates, names: names)
                sendNotification(title: t.title, body: t.body, id: "mount_disconnected_batch", category: categoryReconnect)
            }
        }

        if !stale.isEmpty {
            let throttleKey = "stale_batch"
            if !shouldThrottle(key: throttleKey) {
                let names = formatNames(stale)
                let t = randomTemplate(from: staleTemplates, names: names)
                sendNotification(title: t.title, body: t.body, id: "mount_stale_batch", category: categoryReconnect)
            }
        }
    }

    // MARK: - Transfer Notifications

    /// Notify user that a download batch has started.
    /// `rootName` should be the top-level directory name or file name.
    /// `fileCount` is the number of files in the batch.
    static func sendDownloadStarted(rootName: String, fileCount: Int) {
        let displayName = fileCount > 1 ? "「\(rootName)」(\(fileCount) 個檔案)" : "「\(rootName)」"
        let t = randomTemplate(from: downloadStartTemplates, names: displayName)
        sendNotification(title: t.title, body: t.body, id: "dl_start_\(rootName)")
    }

    /// Notify user that a download batch has completed.
    static func sendDownloadCompleted(rootName: String, fileCount: Int) {
        let displayName = fileCount > 1 ? "「\(rootName)」(\(fileCount) 個檔案)" : "「\(rootName)」"
        let t = randomTemplate(from: downloadCompleteTemplates, names: displayName)
        sendNotification(title: t.title, body: t.body, id: "dl_done_\(rootName)")
    }
    
    /// Notify user that an upload batch has started.
    static func sendUploadStarted(rootName: String, fileCount: Int) {
        let displayName = fileCount > 1 ? "「\(rootName)」(\(fileCount) 個檔案)" : "「\(rootName)」"
        let t = randomTemplate(from: uploadStartTemplates, names: displayName)
        sendNotification(title: t.title, body: t.body, id: "ul_start_\(rootName)")
    }

    /// Notify user that an upload batch has completed.
    static func sendUploadCompleted(rootName: String, fileCount: Int) {
        let displayName = fileCount > 1 ? "「\(rootName)」(\(fileCount) 個檔案)" : "「\(rootName)」"
        let t = randomTemplate(from: uploadCompleteTemplates, names: displayName)
        sendNotification(title: t.title, body: t.body, id: "ul_done_\(rootName)")
    }
    
    // MARK: - Network Change

    static func sendNetworkChanged(newInterface: String) {
        let throttleKey = "network_change"
        guard !shouldThrottle(key: throttleKey) else { return }

        let templates: [(title: String, body: String)] = [
            ("🌐 網路換了", "切換到 \(newInterface)，正在重新建立連線 🔄"),
            ("📶 偵測到新網路", "已切到 \(newInterface)，正在幫您重連所有掛載點 🚀"),
            ("🔀 網路環境變動", "發現 \(newInterface)，後台已啟動重連作業 ⚡"),
        ]
        let t = templates.randomElement()!
        sendNotification(title: t.title, body: t.body, id: "network_changed")
    }

    // MARK: - Core Send

    private static func sendNotification(title: String, body: String, id: String, category: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let category = category {
            content.categoryIdentifier = category
        }
        let uniqueId = "\(id)_\(Date().timeIntervalSince1970)"
        let request = UNNotificationRequest(identifier: uniqueId, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Cleanup

    static func clearNotifications(for name: String) {
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
