import SwiftUI
import UserNotifications
import Combine

@main
struct SMBMountManagerApp: App {
    @StateObject private var mountManager = MountManager()
    @StateObject private var networkMonitor = NetworkMonitorService()
    @StateObject private var settings = AppSettings.shared
    @StateObject private var appState = AppStateManager.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Menu Bar Extra — always-visible status icon in top menu bar
        MenuBarExtra {
            StatusMenuView(mountManager: mountManager, networkMonitor: networkMonitor)
        } label: {
            MenuBarLabel(mountManager: mountManager, settings: settings)
                .onAppear {
                    setupAppLifecycle()
                    if appState.needsOnboarding || appState.needsUpdateAuthorization || appState.needsErrorAuthorization {
                        openWindow(id: "onboarding")
                        NSApp.activate(ignoringOtherApps: true)
                    } else if appState.isReadyToStartBackgroundEngines {
                        mountManager.startAll()
                    }
                }
                .onChange(of: appState.isReadyToStartBackgroundEngines) { ready in
                    if ready {
                        mountManager.startAll()
                    }
                }
                .onChange(of: appState.needsErrorAuthorization) { needsAuth in
                    if needsAuth {
                        openWindow(id: "onboarding")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
                .onChange(of: appState.needsUpdateAuthorization) { needsUpdate in
                    if needsUpdate {
                        openWindow(id: "onboarding")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
        }

        // Onboarding / Authorization Window (Exclusive & Disconnected from Settings)
        Window("SMB 掛載管理器", id: "onboarding") {
            if appState.needsOnboarding {
                OnboardingView()
                    .environmentObject(appState)
                    .frame(width: 700, height: 600)
            } else if appState.needsUpdateAuthorization {
                UpdateAuthorizationView(mountManager: mountManager, appState: appState) {
                    checkAndTransitionToSettings()
                }
            } else if appState.needsErrorAuthorization {
                VStack(spacing: 0) {
                    Spacer()

                    // App icon
                    if let appIcon = NSApplication.shared.applicationIconImage {
                        Image(nsImage: appIcon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 96, height: 96)
                    }

                    Text("SMB 掛載管理器：密碼讀取異常 ⚠️")
                        .font(.system(size: 22, weight: .bold))
                        .padding(.top, 16)

                    Text("無法從 Keychain 中讀取伺服器密碼，可能是權限被重置。\n點擊下方按鈕後，若系統彈出密碼框，\n請輸入「電腦登入密碼」並選擇「**永遠允許**」。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .padding(.top, 10)
                        .padding(.horizontal, 40)

                    Button(action: {
                        KeychainService.allowUI = true
                        appState.completeErrorAuthorization()
                        checkAndTransitionToSettings()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "wrench.and.screwdriver.fill")
                            Text("修復權限")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                    .padding(.top, 20)

                    Spacer()
                }
                .frame(width: 480, height: 380)
            }
        }
        .windowResizability(.contentSize)

        // Main Settings Window
        Window("SMB 掛載管理器", id: "settings") {
            MainSettingsView(mountManager: mountManager, networkMonitor: networkMonitor)
                .environmentObject(settings)
                .environmentObject(appState)
                .frame(minWidth: 760, minHeight: 540)
        }
        .defaultSize(width: 860, height: 640)
    }
    
    /// Called when an onboarding or auth flow finishes to see if we should open settings
    private func checkAndTransitionToSettings() {
        if appState.isReadyToStartBackgroundEngines {
            // macOS UI standard is to dismiss the utility window and open the main window
            for window in NSApp.windows where window.identifier?.rawValue == "onboarding" {
                window.close()
            }
            openWindow(id: "settings")
        }
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

// MARK: - Dedicated Monotonic Progress Manager

@MainActor
class TransferProgressManager: ObservableObject {
    static let shared = TransferProgressManager()
    
    @Published var overallProgress: Double = 0.0
    @Published var isActive: Bool = false
    @Published var isPaused: Bool = false
    @Published var hasSessionTasks: Bool = false
    
    // Core monotonic state variables to prevent progress bar jumps
    private var highestProgress: Double = 0.0
    private var lastTotalBytes: UInt64 = 0
    private var cancellables = Set<AnyCancellable>()
    private var activityToken: NSObjectProtocol?
    
    private init() {
        Publishers.CombineLatest(DownloadManager.shared.$tasks, UploadManager.shared.$tasks)
            .receive(on: RunLoop.main)
            .sink { [weak self] dlTasks, ulTasks in
                self?.recalculate(dlTasks: dlTasks, ulTasks: ulTasks)
            }
            .store(in: &cancellables)
    }
    
    private func recalculate(dlTasks: [DownloadTaskModel], ulTasks: [UploadTaskModel]) {
        let downloadManager = DownloadManager.shared
        let uploadManager = UploadManager.shared
        
        let sessionDLTasks = dlTasks.filter { downloadManager.activeSessionTaskIDs.contains($0.id) }
        let sessionULTasks = ulTasks.filter { uploadManager.activeSessionTaskIDs.contains($0.id) }
        
        let isDownloading = dlTasks.contains { $0.state == .downloading }
        let isUploading = ulTasks.contains { $0.state == .uploading }
        let currentIsActive = isDownloading || isUploading
        
        // Anti-App Nap: Prevent macOS from completely stopping the main thread UI updates when the mouse is idle.
        if currentIsActive && activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Active network transfer requiring UI updates"
            )
        } else if !currentIsActive, let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
        
        let isDlPaused = !isDownloading && sessionDLTasks.contains { $0.state == .paused }
        let isUlPaused = !isUploading && sessionULTasks.contains { $0.state == .paused }
        let currentIsPaused = !currentIsActive && (isDlPaused || isUlPaused)
        
        let currentHasSessionTasks = !sessionDLTasks.isEmpty || !sessionULTasks.isEmpty
        
        if currentHasSessionTasks {
            let dlTotal = sessionDLTasks.reduce(UInt64(0)) { $0 + $1.totalBytes }
            let dlDone = sessionDLTasks.reduce(UInt64(0)) { $0 + ($1.state == .completed ? $1.totalBytes : $1.downloadedBytes) }
            
            let ulTotal = sessionULTasks.reduce(UInt64(0)) { $0 + $1.totalBytes }
            let ulDone = sessionULTasks.reduce(UInt64(0)) { $0 + ($1.state == .completed ? $1.totalBytes : $1.uploadedBytes) }
            
            let totalBytes = dlTotal + ulTotal
            let totalDone = dlDone + ulDone
            
            var rawProgress = totalBytes > 0 ? (Double(totalDone) / Double(totalBytes)) : 0.0
            rawProgress = min(max(rawProgress, 0.0), 1.0)
            
            // Core logic: Enforce strictly monotonic progress (never decreasing)
            if totalBytes > lastTotalBytes {
                highestProgress = rawProgress
            } else if totalBytes < lastTotalBytes {
                highestProgress = rawProgress
            } else {
                if rawProgress > highestProgress {
                    highestProgress = rawProgress
                }
            }
            
            self.lastTotalBytes = totalBytes
            self.overallProgress = highestProgress
            self.isActive = currentIsActive
            self.isPaused = currentIsPaused
            self.hasSessionTasks = true
        } else {
            self.isActive = false
            self.isPaused = false
            self.overallProgress = 0.0
            self.highestProgress = 0.0
            self.lastTotalBytes = 0
            self.hasSessionTasks = false
        }
    }
}

// MARK: - Menu Bar Label (animated icon + connection count)

struct MenuBarLabel: View {
    @ObservedObject var mountManager: MountManager
    @ObservedObject var settings: AppSettings
    @StateObject private var progressManager = TransferProgressManager.shared

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            if progressManager.hasSessionTasks {
                Image(nsImage: .downloadProgressRing(progress: progressManager.overallProgress, isPaused: progressManager.isPaused))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 14)
                
                if progressManager.isActive {
                    Text("\(Int(progressManager.overallProgress * 100))%")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                }
            } else {
                Image(systemName: mountManager.overallStatusIcon)
                
                if settings.showMountCount && !mountManager.mounts.isEmpty {
                    let connected = mountManager.statuses.values.filter { $0.isMounted && $0.isResponsive }.count
                    let total = mountManager.mounts.count
                    Text("\(connected)/\(total)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenMainWindow"))) { _ in
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
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
                                    var batchTasks: [(fileName: String, mountId: String, relativeSMBPath: String, destinationURL: URL, totalBytes: UInt64)] = []
                                    
                                    // Recursively find all files
                                    if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
                                        for case let fileURL as URL in enumerator {
                                            do {
                                                let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                                                if resourceValues.isRegularFile == true && fileURL.lastPathComponent != ".DS_Store" {
                                                    let fileSize = UInt64(resourceValues.fileSize ?? 0)
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
                                                        destinationURL: specificDestURL,
                                                        totalBytes: fileSize
                                                    ))
                                                }
                                            } catch {
                                                AppLogger.shared.error("[Services] Failed to process file in directory: \(error)")
                                            }
                                        }
                                    }
                                    
                                    await MainActor.run {
                                        DownloadManager.shared.addTasks(batch: batchTasks)
                                        NotificationService.sendDownloadStarted(rootName: url.lastPathComponent, fileCount: batchTasks.count)
                                        print("[Services] Started folder download for \(url.lastPathComponent) to \(targetFolderURL.path) with \(batchTasks.count) items")
                                    }
                                }
                            } else {
                                // Extract relative path for single file
                                var relativeSMBPath = String(path.dropFirst(mount.mountPath.count))
                                if relativeSMBPath.hasPrefix("/") {
                                    relativeSMBPath.removeFirst()
                                }
                                
                                
                                Task.detached {
                                    let size: UInt64
                                    if let attr = try? FileManager.default.attributesOfItem(atPath: path) {
                                        size = attr[.size] as? UInt64 ?? 0
                                    } else {
                                        size = 0
                                    }
                                    
                                    await MainActor.run {
                                        DownloadManager.shared.addTask(
                                            fileName: url.lastPathComponent,
                                            mountId: mount.id,
                                            relativeSMBPath: relativeSMBPath,
                                            destinationURL: destinationURL,
                                            totalBytes: size
                                        )
                                        NotificationService.sendDownloadStarted(rootName: url.lastPathComponent, fileCount: 1)
                                        print("[Services] Started download for \(url.lastPathComponent) to \(destinationURL.path)")
                                    }
                                }
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
                 
                 // Use detached task to avoid blocking the Main Thread 
                 // when iterating through potentially thousands of files recursively.
                 Task.detached {
                     var batchTasks: [(sourceURL: URL, mountId: String, relativeSMBPath: String)] = []
                     
                     for localURL in urls {
                         var isDirectory: ObjCBool = false
                         guard FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory) else { continue }
                         
                         if isDirectory.boolValue {
                             if let enumerator = FileManager.default.enumerator(at: localURL, includingPropertiesForKeys: [.isRegularFileKey]) {
                                 for case let fileURL as URL in enumerator {
                                     do {
                                         let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                                         if resourceValues.isRegularFile == true && fileURL.lastPathComponent != ".DS_Store" {
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
                     
                     await MainActor.run {
                         UploadManager.shared.addTasks(batch: batchTasks)
                         // Send a single notification for the entire batch
                         let rootNames = urls.map { $0.lastPathComponent }
                         let displayName = rootNames.count == 1 ? rootNames[0] : rootNames[0]
                         NotificationService.sendUploadStarted(rootName: displayName, fileCount: batchTasks.count)
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
            UpdateService.shared.checkForUpdates(silent: true)
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
            
            // Stop engines to prevent them from trying to reconnect during network teardown
            AppLifecycle.shared.mountManager?.stopAll()
            
            // VITAL: Aggressively and synchronously force-unmount all SMB shares BEFORE the system fully sleeps.
            // This prevents the kernel `mount_smbfs` daemon from deadlocking if the Mac wakes up on a different Wi-Fi network.
            // Using `unmountAllAndStopSync()` which calls `diskutil unmount force` blindly.
            AppLifecycle.shared.mountManager?.unmountAllAndStopSync()
        }
    }
    
    @objc private func macDidWake() {
        AppLifecycle.shared.isSleeping = false
        AppLifecycle.shared.lastWakeTime = Date()
        
        // Clear coalesced queues to stop pre-sleep notifications from exploding post-wake
        NotificationService.clearPendingEvents()
        
        // Let's also proactively clear recent notifications on wake to start fresh
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        
        // Step 1: Forcefully wipe any "ghost mounts" that might have snuck in or survived.
        // Doing this before starting the network ensures a clean slate.
        Task { @MainActor in
            AppLifecycle.shared.mountManager?.unmountAllAndStopSync()
        }
        
        // Step 2: Restart engines and downloads with a delay.
        // The Mac network stack takes a moment to establish routing on the new Wi-Fi network.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds delay
            
            AppLifecycle.shared.mountManager?.startAll()
            DownloadManager.shared.startAll()
            
            // Note: Upload tasks are NOT resumed here blindly.
            // They will auto-resume per-mount when MountEngine confirms mounts are online.
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
        
        let id = response.notification.request.identifier
        
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("OpenMainWindow"), object: nil)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if id.starts(with: "dl_") {
                    NotificationCenter.default.post(name: NSNotification.Name("OpenDownloadsTab"), object: nil)
                } else if id.starts(with: "ul_") {
                    NotificationCenter.default.post(name: NSNotification.Name("OpenUploadsTab"), object: nil)
                } else {
                    NotificationCenter.default.post(name: NSNotification.Name("OpenMountsTab"), object: nil)
                }
            }
        }
        
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
