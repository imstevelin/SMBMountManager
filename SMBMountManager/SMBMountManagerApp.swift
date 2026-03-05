import SwiftUI
import UserNotifications

@main
struct SMBMountManagerApp: App {
    @StateObject private var mountManager = MountManager()
    @StateObject private var networkMonitor = NetworkMonitorService()
    @StateObject private var settings = AppSettings.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu Bar Extra — always-visible status icon in top menu bar
        MenuBarExtra {
            StatusMenuView(mountManager: mountManager, networkMonitor: networkMonitor)
        } label: {
            MenuBarLabel(mountManager: mountManager, settings: settings)
                .onAppear {
                    setupAppLifecycle()
                }
        }

        // Settings Window
        Window("SMB 掛載管理器", id: "settings") {
            MainSettingsView(mountManager: mountManager, networkMonitor: networkMonitor)
                .environmentObject(settings)
                .frame(minWidth: 760, minHeight: 540)
        }
        .defaultSize(width: 860, height: 640)
    }

    private func setupAppLifecycle() {
        guard AppLifecycle.shared.mountManager == nil else { return }
        
        // Wire the lifecycle bridge immediately
        AppLifecycle.shared.mountManager = mountManager
        AppLifecycle.shared.networkMonitor = networkMonitor

        // Wire network change → remount
        networkMonitor.onNetworkChanged = { [weak mountManager] in
            Task { @MainActor in
                mountManager?.handleNetworkChange()
            }
        }

        // Start all engines
        mountManager.startAll()
    }
}

// MARK: - App Lifecycle Singleton (bridges AppDelegate ↔ SwiftUI)

class AppLifecycle {
    static let shared = AppLifecycle()
    weak var mountManager: MountManager?
    weak var networkMonitor: NetworkMonitorService?
}

// MARK: - Menu Bar Label (animated icon + connection count)

struct MenuBarLabel: View {
    @ObservedObject var mountManager: MountManager
    @ObservedObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: mountManager.overallStatusIcon)
            if settings.showMountCount && !mountManager.mounts.isEmpty {
                let connected = mountManager.statuses.values.filter { $0.isMounted && $0.isResponsive }.count
                let total = mountManager.mounts.count
                Text("\(connected)/\(total)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
            }
        }
    }
}

// MARK: - App Delegate for notifications + termination

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        NotificationService.requestPermission()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Block the main thread entirely to ensure SwiftUI does not kill the app mid-unmount
        AppLifecycle.shared.mountManager?.unmountAllAndStopSync()
        return .terminateNow
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
