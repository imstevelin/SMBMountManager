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
                DownloadManager.shared.startAll()
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
    @StateObject private var downloadManager = DownloadManager.shared
    @StateObject private var uploadManager = UploadManager.shared

    var body: some View {
        HStack(spacing: 3) {
            let activeDLTasks = downloadManager.tasks.filter { $0.state == .downloading || $0.state == .waiting || $0.state == .paused }
            let activeULTasks = uploadManager.tasks.filter { $0.state == .uploading || $0.state == .waiting || $0.state == .paused }
            
            let isDownloading = downloadManager.tasks.contains { $0.state == .downloading }
            let isUploading = uploadManager.tasks.contains { $0.state == .uploading }
            
            let isDlPaused = !isDownloading && activeDLTasks.contains { $0.state == .paused }
            let isUlPaused = !isUploading && activeULTasks.contains { $0.state == .paused }
            
            let hasActiveTasks = !activeDLTasks.isEmpty || !activeULTasks.isEmpty
            
            if !activeDLTasks.isEmpty {
                let totalBytes = activeDLTasks.reduce(0) { $0 + $1.totalBytes }
                let downloadedBytes = activeDLTasks.reduce(0) { $0 + $1.downloadedBytes }
                let progress = totalBytes > 0 ? (CGFloat(downloadedBytes) / CGFloat(totalBytes)) : 0.0
                
                Image(nsImage: .downloadProgressRing(progress: progress, isPaused: isDlPaused))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 14)
            }
            
            if !activeULTasks.isEmpty {
                let totalBytes = activeULTasks.reduce(0) { $0 + $1.totalBytes }
                let uploadedBytes = activeULTasks.reduce(0) { $0 + $1.uploadedBytes }
                let progress = totalBytes > 0 ? (CGFloat(uploadedBytes) / CGFloat(totalBytes)) : 0.0
                
                Image(nsImage: .downloadProgressRing(progress: progress, isPaused: isUlPaused))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 14)
            }
            
            if !hasActiveTasks {
                Image(systemName: mountManager.overallStatusIcon)
            }
            
            if settings.showMountCount && !mountManager.mounts.isEmpty && !hasActiveTasks {
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
    @objc(handleDownloadService:userData:error:)
    func handleDownloadService(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty else {
            error.pointee = "找不到檔案路徑" as NSString
            return
        }
        
        for url in urls {
            let path = url.path
            let logMsg = "[Services] Received download request for: \(path)"
            AppLogger.shared.info(logMsg)
            
            Task { @MainActor in
                // Try to match the path to a known mount
                if let mountManager = AppLifecycle.shared.mountManager {
                    if let mount = mountManager.mounts.first(where: { path.hasPrefix($0.mountPath) }) {
                        var isDirectory: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                            AppLogger.shared.error("[Services] File does not exist at path: \(path)")
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
                                                AppLogger.shared.error("[Services] Failed to process file in directory: \(error)")
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
                        }
                    } else {
                        AppLogger.shared.warn("[Services] Path does not belong to any monitored SMB mount: \(path)")
                        let alert = NSAlert()
                        alert.messageText = "不支援的檔案"
                        alert.informativeText = "此檔案/資料夾不在任何已知的 NAS 掛載點中，無法使用此下載工具。"
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "確定")
                        NSApp.activate(ignoringOtherApps: true)
                        alert.runModal()
                    }
                }
            }
        }
        
    @objc(handleUploadService:userData:error:)
    func handleUploadService(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty else {
            error.pointee = "找不到檔案路徑" as NSString
            return
        }
        
        Task { @MainActor in
            let openPanel = NSOpenPanel()
            openPanel.title = "選擇上傳目的地 (NAS 掛載點目錄)"
            openPanel.canChooseDirectories = true
            openPanel.canChooseFiles = false
            openPanel.canCreateDirectories = true
            openPanel.prompt = "上傳至此"
            
            if let volumesUrl = URL(string: "file:///Volumes") {
                openPanel.directoryURL = volumesUrl
            }
            
            NSApp.activate(ignoringOtherApps: true)
            let modalResult = openPanel.runModal()
            
            if modalResult == .OK, let destinationURL = openPanel.url {
                 guard let mountManager = AppLifecycle.shared.mountManager,
                       let mount = mountManager.mounts.first(where: { destinationURL.path.hasPrefix($0.mountPath) }) else {
                     let alert = NSAlert()
                     alert.messageText = "無效的目的地"
                     alert.informativeText = "您所選擇的目錄不屬於任何已知的 SMB 掛載點。"
                     alert.alertStyle = .warning
                     alert.addButton(withTitle: "確定")
                     alert.runModal()
                     return
                 }
                 
                 var batchTasks: [(sourceURL: URL, mountId: String, relativeSMBPath: String)] = []
                 
                 for localURL in urls {
                     var isDirectory: ObjCBool = false
                     guard FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory) else { continue }
                     
                     if isDirectory.boolValue {
                         if let enumerator = FileManager.default.enumerator(at: localURL, includingPropertiesForKeys: [.isRegularFileKey]) {
                             for case let fileURL as URL in enumerator {
                                 do {
                                     let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                                     if resourceValues.isRegularFile == true {
                                         let relativePathToFile = fileURL.path.replacingOccurrences(of: localURL.path + "/", with: "")
                                         let targetFolderURL = destinationURL.appendingPathComponent(localURL.lastPathComponent)
                                         let specificDestURL = targetFolderURL.appendingPathComponent(relativePathToFile)
                                         
                                         var relativeSMBPath = String(specificDestURL.path.dropFirst(mount.mountPath.count))
                                         if relativeSMBPath.hasPrefix("/") { relativeSMBPath.removeFirst() }
                                         
                                         batchTasks.append((sourceURL: fileURL, mountId: mount.id, relativeSMBPath: relativeSMBPath))
                                     }
                                 } catch {}
                             }
                         }
                     } else {
                         let specificDestURL = destinationURL.appendingPathComponent(localURL.lastPathComponent)
                         var relativeSMBPath = String(specificDestURL.path.dropFirst(mount.mountPath.count))
                         if relativeSMBPath.hasPrefix("/") { relativeSMBPath.removeFirst() }
                         batchTasks.append((sourceURL: localURL, mountId: mount.id, relativeSMBPath: relativeSMBPath))
                     }
                 }
                 
                 UploadManager.shared.addTasks(batch: batchTasks)
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
            UploadManager.shared.cancelAllAndShutdown()
        }
    }
    
    @objc private func macDidWake() {
        AppLifecycle.shared.isSleeping = false
        AppLifecycle.shared.lastWakeTime = Date()
        
        // Let's also proactively clear recent notifications on wake to start fresh
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        
        Task { @MainActor in
            DownloadManager.shared.startAll()
            UploadManager.shared.resumeAll()
        }
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

// MARK: - Progress Ring Graphics Context Extension

extension NSImage {
    static func downloadProgressRing(progress: CGFloat, isPaused: Bool = false) -> NSImage {
        let size = NSSize(width: isPaused ? 28 : 16, height: 16)
        let image = NSImage(size: size)
        
        image.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: 16, height: 16)
        let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 2.0
        NSColor.black.withAlphaComponent(0.3).setStroke()
        path.stroke()
        
        if progress > 0 {
            let progressPath = NSBezierPath()
            let center = NSPoint(x: 16 / 2, y: 16 / 2)
            let radius = (16.0 / 2) - 1.5
            
            let startAngle: CGFloat = 90.0
            let endAngle = 90.0 - (progress * 360.0)
            
            progressPath.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
            progressPath.lineWidth = 2.0
            progressPath.lineCapStyle = .round
            NSColor.black.setStroke()
            progressPath.stroke()
        }
        
        if isPaused {
            NSColor.black.setFill()
            let leftBar = NSBezierPath(roundedRect: NSRect(x: 20, y: 3, width: 2.5, height: 10), xRadius: 0.5, yRadius: 0.5)
            leftBar.fill()
            
            let rightBar = NSBezierPath(roundedRect: NSRect(x: 25.5, y: 3, width: 2.5, height: 10), xRadius: 0.5, yRadius: 0.5)
            rightBar.fill()
        }
        
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
