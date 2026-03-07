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
    var isTerminating: Bool = false
    var isSleeping: Bool = false
    var lastWakeTime: Date? = nil
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

@objc class MacServicesProvider: NSObject {
    @objc func handleDownloadService(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty else {
            error.pointee = "找不到檔案路徑" as NSString
            return
        }
        
        for url in urls {
            let path = url.path
            let logMsg = "[Services] Received download request for: \(path)"
            print(logMsg)
            
            Task { @MainActor in
                // Try to match the path to a known mount
                if let mountManager = AppLifecycle.shared.mountManager {
                    if let mount = mountManager.mounts.first(where: { path.hasPrefix($0.mountPath) }) {
                        var isDirectory: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                            print("[Services] File does not exist at path: \(path)")
                            return
                        }
                        
                        var modalResult: NSApplication.ModalResponse
                        var destinationURL: URL?
                        
                        if isDirectory.boolValue {
                            let openPanel = NSOpenPanel()
                            openPanel.title = "選擇下載儲存目錄"
                            openPanel.canChooseDirectories = true
                            openPanel.canChooseFiles = false
                            openPanel.canCreateDirectories = true
                            openPanel.prompt = "下載至此"
                            
                            NSApp.activate(ignoringOtherApps: true)
                            modalResult = openPanel.runModal()
                            destinationURL = openPanel.url
                        } else {
                            let savePanel = NSSavePanel()
                            savePanel.title = "選擇下載儲存位置"
                            savePanel.nameFieldStringValue = url.lastPathComponent
                            savePanel.prompt = "下載"
                            
                            NSApp.activate(ignoringOtherApps: true)
                            modalResult = savePanel.runModal()
                            destinationURL = savePanel.url
                        }
                        
                        if modalResult == .OK, let destinationURL = destinationURL {
                            if isDirectory.boolValue {
                                // Create the base folder at destination
                                let targetFolderURL = destinationURL.appendingPathComponent(url.lastPathComponent)
                                try? FileManager.default.createDirectory(at: targetFolderURL, withIntermediateDirectories: true)
                                
                                Task.detached {
                                    var batchTasks: [(fileName: String, mountId: String, relativeSMBPath: String, destinationURL: URL)] = []
                                    
                                    // Recursively find all files
                                    if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) {
                                        for case let fileURL as URL in enumerator {
                                            do {
                                                let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                                                if resourceValues.isRegularFile == true {
                                                    // Extract relative path from base URL
                                                    let relativePathToFile = fileURL.path.replacingOccurrences(of: url.path + "/", with: "")
                                                    
                                                    // Calculate SMB Path
                                                    var relativeSMBPath = String(fileURL.path.dropFirst(mount.mountPath.count))
                                                    if relativeSMBPath.hasPrefix("/") { relativeSMBPath.removeFirst() }
                                                    
                                                    // Calculate destination path
                                                    let specificDestURL = targetFolderURL.appendingPathComponent(relativePathToFile)
                                                    
                                                    // Ensure specific subfolder exists
                                                    try? FileManager.default.createDirectory(at: specificDestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                                                    
                                                    batchTasks.append((
                                                        fileName: fileURL.lastPathComponent,
                                                        mountId: mount.id,
                                                        relativeSMBPath: relativeSMBPath,
                                                        destinationURL: specificDestURL
                                                    ))
                                                }
                                            } catch {
                                                print("[Services] Failed to process file in directory: \(error)")
                                            }
                                        }
                                    }
                                    
                                    await MainActor.run {
                                        DownloadManager.shared.addTasks(batch: batchTasks)
                                        print("[Services] Started folder download for \(url.lastPathComponent) to \(targetFolderURL.path) with \(batchTasks.count) items")
                                    }
                                }
                            } else {
                                // Extract relative path for single file
                                var relativeSMBPath = String(path.dropFirst(mount.mountPath.count))
                                if relativeSMBPath.hasPrefix("/") {
                                    relativeSMBPath.removeFirst()
                                }
                                
                                DownloadManager.shared.addTask(
                                    fileName: url.lastPathComponent,
                                    mountId: mount.id,
                                    relativeSMBPath: relativeSMBPath,
                                    destinationURL: destinationURL
                                )
                                print("[Services] Started download for \(url.lastPathComponent) to \(destinationURL.path)")
                            }
                        }
                    } else {
                        print("[Services] Path does not belong to any monitored SMB mount: \(path)")
                    }
                }
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.servicesProvider = MacServicesProvider()
        NSUpdateDynamicServices()
        
        UNUserNotificationCenter.current().delegate = self
        NotificationService.requestPermission()
        
        if AppSettings.shared.autoCheckUpdates {
            UpdateService.shared.checkForUpdates(manual: false)
        }
        
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(macDidSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(macDidWake), name: NSWorkspace.didWakeNotification, object: nil)
    }
    
    @objc private func macDidSleep() {
        AppLifecycle.shared.isSleeping = true
        
        // Protect AMSMB2 sockets from OS suspension crashing:
        // Forcefully pause all TCP chunk downloads immediately.
        // NSWorkspace notifications are delivered on the main thread, so we must 
        // NEVER use DispatchQueue.main.sync here (it causes a libdispatch trap).
        Task { @MainActor in
            DownloadManager.shared.pauseAll()
        }
    }
    
    @objc private func macDidWake() {
        AppLifecycle.shared.isSleeping = false
        AppLifecycle.shared.lastWakeTime = Date()
        
        // Let's also proactively clear recent notifications on wake to start fresh
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppLifecycle.shared.isTerminating = true
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
