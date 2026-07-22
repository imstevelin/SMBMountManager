import Foundation
@preconcurrency import Combine
import AppKit
import Network

/// Central manager: owns in-process mount engines and built-in health monitor.
/// Replaces the previous launchd-agent-based architecture.
@MainActor
class MountManager: ObservableObject {
    @Published var mounts: [MountPoint] = []
    @Published var statuses: [String: MountStatus] = [:]
    @Published var systemService = SystemServiceStatus()
    @Published var isLoading = false
    @Published var isPaused = false
    /// Tracks individually paused mounts (via "強制退出")
    @Published var pausedMounts: Set<String> = []
    /// Tracks mounts paused automatically due to network restrictions
    @Published var networkPausedMounts: Set<String> = []
    /// Cached menu bar icon name — updated whenever statuses change, avoids computed-property re-evaluation in SwiftUI body
    @Published private(set) var overallStatusIcon: String = "externaldrive.badge.questionmark"

    /// Per-mount engines running in-process
    private var engines: [String: MountEngine] = [:]
    
    /// Track previous network interface to bounce connections when upgrading (e.g. WiFi -> Ethernet)
    private var lastKnownInterfaceType: NWInterface.InterfaceType?

    /// Health monitor timer
    private var monitorTimer: Timer?
    private var monitorInterval: TimeInterval {
        return 10.0
    }

    /// Stale mount tracking
    private var consecutiveFailures: [String: Int] = [:]
    private let staleThreshold = 2

    /// Auto-refresh timer for status updates (fix #3: faster updates)
    private var refreshTimer: Timer?
    private var refreshTickCounter: Int = 0
    private var isRefreshingStatuses = false
    private var pendingDeepRefresh = false
    
    /// Subscription to network connectivity changes
    private var networkCancellable: AnyCancellable?

    init() {
        ensureDirectories()
        refresh()
        startAutoRefresh()
    }

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshTickCounter += 1
                let isDeep = (self.refreshTickCounter % 5 == 1)
                self.refreshStatuses(isDeepCheck: isDeep)
            }
        }
    }

    func bindNetworkMonitor(_ monitor: NetworkMonitorService) {
        networkCancellable?.cancel()
        networkCancellable = monitor.$isConnected
            .dropFirst() // Ignore initial value on boot
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                guard let self = self, !isConnected else { return }
                // Network dropped completely. Instantly unmount all to avoid Finder popup timeouts.
                for mount in self.mounts {
                    if let _ = self.statuses[mount.name], MountManager.isMounted(mount.mountPath) {
                        self.forceUnmount(mount.mountPath)
                    }
                }
                self.refreshStatuses()
            }
    }

    // MARK: - Directories

    private func ensureDirectories() {
        let fm = FileManager.default
        let dirs = [
            MountPoint.configDirectory,
            "\(NSHomeDirectory())/Library/Logs"
        ]
        for dir in dirs {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Full Refresh

    func refresh() {
        mounts = MountPoint.loadAll()
        refreshStatuses()
        // Also check fixer
        systemService.fixerInstalled = LaunchdService.fixerInstalled
    }

    func refreshStatuses(isDeepCheck: Bool = true) {
        if isRefreshingStatuses {
            pendingDeepRefresh = pendingDeepRefresh || isDeepCheck
            return
        }
        isRefreshingStatuses = true

        // Run checks in a completely detached background thread so we NEVER block the main thread
        Task.detached { [weak self] in
            guard let self = self else { return }
            
            // Snapshot the state from MainActor
            let currentMounts = await MainActor.run { self.mounts }
            let oldStatuses = await MainActor.run { self.statuses }
            let currentIsPaused = await MainActor.run { self.isPaused }
            let currentPausedMounts = await MainActor.run { self.pausedMounts }
            let currentNetworkPausedMounts = await MainActor.run { self.networkPausedMounts }
            
            let isNetworkUp = await MainActor.run { AppLifecycle.shared.networkMonitor?.isConnected ?? true }
            let enginesMap = await MainActor.run { self.engines }
            let currentNames = Set(currentMounts.map(\.name))

            // Optimization: Get /sbin/mount output ONCE for all mounts instead of spawning a Process per mount
            let mountsOutput = isNetworkUp ? MountManager.getMountsOutput() : ""
            
            await withTaskGroup(of: Void.self) { group in
                for mount in currentMounts {
                    let engine = enginesMap[mount.name]
                    let oldStatus = oldStatuses[mount.name] ?? MountStatus(name: mount.name)
                    let isEngineRunning = engine != nil
                    let isUserPaused = currentIsPaused || currentPausedMounts.contains(mount.name)
                    let isNetPaused = currentNetworkPausedMounts.contains(mount.name)

                    group.addTask {
                        var status = oldStatus

                        if !isNetworkUp {
                            status.isMounted = false
                            status.isResponsive = false
                            status.capacityTotal = nil
                            status.capacityAvailable = nil
                            status.isNetworkUp = false
                            // Do not show "Paused" solely due to global network drops unless user explicitly paused it
                            status.isPaused = isUserPaused
                        } else {
                            status.isNetworkUp = true
                            status.isMounted = SMBConnection.isMounted(path: mount.mountPath, inMountOutput: mountsOutput)

                            if status.isMounted {
                                if isDeepCheck {
                                    status.isResponsive = await MountManager.isMountResponsive(mount.mountPath)

                                    // Only query file system attributes if the mount is proven responsive,
                                    // because `attributesOfFileSystem` can block indefinitely on a hung SMB share.
                                    if status.isResponsive {
                                        // Use Process to get capacity via `df` to avoid FileManager hanging the UI task group indefinitely
                                        let capacityData: (total: Int64, free: Int64)? = await {
                                            let path = mount.mountPath
                                            let task = Process()
                                            task.launchPath = "/bin/df"
                                            task.arguments = ["-k", path]
                                            let pipe = Pipe()
                                            task.standardOutput = pipe
                                            task.standardError = FileHandle.nullDevice

                                            var didTimeout = false
                                            do {
                                                try task.run()
                                                let deadline = Date().addingTimeInterval(2.0)
                                                while task.isRunning && Date() < deadline {
                                                    try? await Task.sleep(nanoseconds: 100_000_000)
                                                }
                                                if task.isRunning {
                                                    task.terminate()
                                                    didTimeout = true
                                                }
                                            } catch {
                                                return nil
                                            }

                                            if didTimeout { return nil }

                                            let data = pipe.fileHandleForReading.readDataToEndOfFile()
                                            if let output = String(data: data, encoding: .utf8) {
                                                let lines = output.components(separatedBy: .newlines)
                                                if lines.count >= 2 {
                                                    let components = lines[1].components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                                                    if components.count >= 4,
                                                       let totalKB = Int64(components[1]),
                                                       let freeKB = Int64(components[3]) {
                                                        return (totalKB * 1024, freeKB * 1024)
                                                    }
                                                }
                                            }
                                            return nil
                                        }()

                                        status.capacityTotal = capacityData?.total
                                        status.capacityAvailable = capacityData?.free
                                    } else {
                                        status.capacityTotal = nil
                                        status.capacityAvailable = nil
                                    }
                                }
                                // A shallow check deliberately keeps the previous responsiveness and capacity.
                            } else {
                                status.isResponsive = false
                                status.capacityTotal = nil
                                status.capacityAvailable = nil
                            }
                            status.isPaused = isUserPaused || isNetPaused
                        }
                        status.isEngineRunning = isEngineRunning && !status.isPaused
                        if isEngineRunning, let engine = engine {
                            status.isFailing = await engine.isFailing
                        } else {
                            status.isFailing = false
                        }

                        // Measure latency — only during deep checks to avoid spawning ping/nc processes every 3 seconds
                        if isDeepCheck {
                            if isEngineRunning, let engine = engine {
                                if let ms = engine.measureLatency() {
                                    status.latencyMs = ms
                                } else {
                                    status.latencyMs = oldStatus.latencyMs
                                }
                            } else {
                                status.latencyMs = nil
                            }
                        } else {
                            // Shallow check: preserve previous latency value
                            status.latencyMs = oldStatus.latencyMs
                        }
                        
                        let finalStatus = status
                        let name = mount.name
                        
                        await MainActor.run { [weak self] in
                            guard let self = self else { return }
                            
                            // Check for notifications on strictly serial source of truth.
                            if let realOld = self.statuses[name] {
                                // Rule 1: Do not send "connected" if the mount is artificially restricted/paused by the app,
                                // even if the OS still considers the directory practically mounted.
                                if !realOld.isMounted && finalStatus.isMounted && !finalStatus.isPaused {
                                    NotificationService.queueMountConnected(name: name)
                                    NotificationService.clearNotifications(for: name)
                                } else if realOld.isMounted && !finalStatus.isMounted && !self.isPaused && !self.pausedMounts.contains(name) && !self.networkPausedMounts.contains(name) {
                                    NotificationService.queueMountDisconnected(name: name)
                                }
                            }
                            
                            // OPTIMIZATION: Only write to @Published statuses when value actually changed,
                            // to prevent unnecessary SwiftUI re-evaluation when settings window is open
                            if self.statuses[name] != finalStatus {
                                self.statuses[name] = finalStatus
                            }
                        }
                    }
                }
            }
            
            await MainActor.run {
            // Flush coalesced mount notifications as a single batch
            NotificationService.flushMountEvents()
                
                // Self-healing explicitly guarded on MainActor to avoid repetitive overlaps
                for mount in currentMounts {
                    if self.networkPausedMounts.contains(mount.name) {
                        let isRestricted = self.isNetworkRestricted(for: mount)
                        if !isRestricted {
                            self.networkPausedMounts.remove(mount.name)
                            if !self.pausedMounts.contains(mount.name) {
                                let _ = self.restartEngine(name: mount.name)
                            }
                        }
                    }
                }
                
                // Clear out deleted mounts from the status dictionary — only reassign if there are stale entries
                let staleKeys = self.statuses.keys.filter { !currentNames.contains($0) }
                if !staleKeys.isEmpty {
                    for key in staleKeys { self.statuses.removeValue(forKey: key) }
                }
                self.updateOverallIcon()
                self.isRefreshingStatuses = false

                if self.pendingDeepRefresh {
                    self.pendingDeepRefresh = false
                    self.refreshStatuses(isDeepCheck: true)
                }
            }
        }
    }

    // MARK: - Engine Lifecycle

    /// Start all mount engines and the health monitor
    func startAll() {
        isPaused = false
        networkPausedMounts.removeAll()
        for mount in mounts {
            startEngine(for: mount)
        }
        startMonitor()
    }

    /// Stop all engines and the health monitor (keeps mounts mounted)
    func stopAll() {
        stopMonitor()
        let runningEngines = Array(engines.values)
        engines.removeAll()
        for engine in runningEngines {
            Task {
                await engine.stop()
            }
        }
    }

    /// Unmount everything AND stop engines (for app quit — synchronous, any thread)
    func unmountAllAndStop() {
        stopMonitor()
        refreshTimer?.invalidate()
        let runningEngines = Array(engines.values)
        engines.removeAll()
        for engine in runningEngines {
            Task { await engine.stop() }
        }
        for mount in mounts {
            let path = mount.mountPath
            Task.detached { [weak self] in
                if MountManager.isMounted(path) {
                    self?.forceUnmount(path)
                }
            }
        }
    }

    /// Bounded synchronous cleanup used during logout, shutdown, or an explicit quit.
    /// All unmounts run concurrently and share one five-second deadline so a dead
    /// network volume cannot prevent the Mac from logging out.
    @MainActor
    func unmountAllAndStopSync() {
        stopMonitor()
        refreshTimer?.invalidate()
        refreshTimer = nil
        networkCancellable?.cancel()

        let runningEngines = Array(engines.values)
        engines.removeAll()
        for engine in runningEngines {
            Task { await engine.stop() }
        }

        let mountedOutput = Self.getMountsOutput()
        var processes: [Process] = []
        for mount in mounts where SMBConnection.isMounted(path: mount.mountPath, inMountOutput: mountedOutput) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            task.arguments = ["unmount", "force", mount.mountPath]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                processes.append(task)
            } catch {
                AppLogger.shared.warn("[MountManager] Could not start final unmount for \(mount.name): \(error.localizedDescription)")
            }
        }

        let deadline = Date().addingTimeInterval(5)
        while processes.contains(where: \.isRunning), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        for task in processes where task.isRunning {
            task.terminate()
        }
    }

    /// Asynchronously force-unmount all SMB shares without blocking the MainActor
    func unmountAllAsync() async {
        let mountedOutput = Self.getMountsOutput()
        let paths = mounts
            .map(\.mountPath)
            .filter { SMBConnection.isMounted(path: $0, inMountOutput: mountedOutput) }
        
        // Spawn unmount processes concurrently off the main thread
        await withTaskGroup(of: Void.self) { group in
            for path in paths {
                group.addTask {
                    let firstSucceeded = await Self.runUnmountProcess(
                        executable: "/sbin/umount",
                        arguments: ["-f", path]
                    )
                    if !firstSucceeded {
                        _ = await Self.runUnmountProcess(
                            executable: "/usr/sbin/diskutil",
                            arguments: ["unmount", "force", path]
                        )
                    }
                }
            }
        }
    }

    /// Check if a mount is restricted by its allowed SSIDs on the current network
    func isNetworkRestricted(for mount: MountPoint) -> Bool {
        guard !mount.allowedSSIDs.isEmpty else { return false }
        
        // Special keyword "乙太網路" bypasses SSID check if currently on Ethernet
        if mount.allowedSSIDs.contains("乙太網路") {
            if AppLifecycle.shared.networkMonitor?.interfaceType == .wiredEthernet {
                return false // Allowed
            }
        }
        
        // Ensure "乙太網路" is not the only rule if we aren't actually on Ethernet
        // (If it is, and we aren't on Ethernet, we should restrict)
        let onlyEthernet = mount.allowedSSIDs.count == 1 && mount.allowedSSIDs.first == "乙太網路"
        if onlyEthernet {
            return true
        }
        
        // Otherwise fallback to normal SSID check
        let currentSSID = AppLifecycle.shared.networkMonitor?.currentSSID ?? WiFiService.currentSSID()
        if let ssid = currentSSID {
            if !mount.allowedSSIDs.contains(ssid) && !mount.allowedSSIDs.contains("乙太網路") {
                return true
            } else if !mount.allowedSSIDs.contains(ssid) && mount.allowedSSIDs.contains("乙太網路") && AppLifecycle.shared.networkMonitor?.interfaceType != .wiredEthernet {
                 return true
            }
            return false
        } else {
            return true // WiFi required but SSID nil
        }
    }

    /// Start engine for a single mount
    func startEngine(for mount: MountPoint) {
        guard AppStateManager.shared.isReadyToStartBackgroundEngines else { return }
        
        // Enforce network restriction BEFORE starting
        if isNetworkRestricted(for: mount) {
            networkPauseMount(name: mount.name)
            return
        }

        let existing = engines[mount.name]
        let engine = MountEngine(mount: mount)
        engines[mount.name] = engine
        Task { [weak self] in
            if let existing { await existing.stop() }
            guard await MainActor.run(body: { self?.engines[mount.name] === engine }) else { return }
            await engine.start()
        }
    }

    /// Stop engine for a single mount
    func stopEngine(name: String) {
        if let engine = engines.removeValue(forKey: name) {
            Task { await engine.stop() }
        }
    }

    /// Restart engine for a mount (used as "重新連線")
    func restartEngine(name: String) -> Bool {
        guard let mount = mounts.first(where: { $0.name == name }) else { return false }
        pausedMounts.remove(name)
        networkPausedMounts.remove(name)
        startEngine(for: mount)
        return true
    }

    /// Pause a single mount: stop its engine + unmount
    func pauseMount(name: String) {
        pausedMounts.insert(name)
        stopEngine(name: name)
        if let mount = mounts.first(where: { $0.name == name }) {
            let path = mount.mountPath
            Task.detached { [weak self] in
                if MountManager.isMounted(path) {
                    self?.forceUnmount(path)
                }
            }
        }
        refreshStatuses()
    }

    /// Pause a single mount automatically due to network changes
    func networkPauseMount(name: String) {
        networkPausedMounts.insert(name)
        stopEngine(name: name)
        if let mount = mounts.first(where: { $0.name == name }) {
            let path = mount.mountPath
            Task.detached { [weak self] in
                if MountManager.isMounted(path) {
                    self?.forceUnmount(path)
                }
            }
        }
        refreshStatuses()
    }

    // MARK: - Health Monitor (replaces external monitor script)

    private func startMonitor() {
        stopMonitor()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: monitorInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.performHealthCheck()
            }
        }
    }

    private func stopMonitor() {
        monitorTimer?.invalidate()
        monitorTimer = nil
    }

    private func performHealthCheck() {
        // Run health logic in a strictly detached background task to prevent main thread freezing
        Task.detached { [weak self] in
            guard let self = self else { return }
            
            // Don't auto-reconnect while paused
            let isCurrentlyPaused = await MainActor.run { self.isPaused }
            guard !isCurrentlyPaused else { return }

            let currentMounts = await MainActor.run { self.mounts }

            let paused = await MainActor.run { self.pausedMounts }
            let netPaused = await MainActor.run { self.networkPausedMounts }

            await withTaskGroup(of: Void.self) { group in
                for mount in currentMounts {
                    let isMountPaused = paused.contains(mount.name) || netPaused.contains(mount.name)
                    guard !isMountPaused else { continue }
                    
                    group.addTask {
                        let mountPath = mount.mountPath
                        if !MountManager.isMounted(mountPath) {
                            // Not mounted — engine should be reconnecting
                            await MainActor.run {
                                self.consecutiveFailures[mount.name] = 0
                                // Make sure engine is running
                                if self.engines[mount.name] == nil {
                                    self.startEngine(for: mount)
                                }
                            }
                        } else {
                            // Mounted — check responsiveness (background)
                            if await MountManager.isMountResponsive(mountPath) {
                                await MainActor.run { self.consecutiveFailures[mount.name] = 0 }
                            } else {
                                _ = await MainActor.run {
                                    let count = (self.consecutiveFailures[mount.name] ?? 0) + 1
                                    self.consecutiveFailures[mount.name] = count

                                    if count >= self.staleThreshold {
                                        // Stale mount detected — force unmount + restart engine
                                        Task.detached { [weak self] in
                                            self?.forceUnmount(mountPath)
                                        }
                                        let _ = self.restartEngine(name: mount.name)
                                        self.consecutiveFailures[mount.name] = 0

                                        // Queue stale notification (will be flushed at end of health monitor cycle)
                                        NotificationService.queueMountStale(name: mount.name)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            // Trigger UI update + flush any stale notifications
            await MainActor.run {
                NotificationService.flushMountEvents()
                self.refreshStatuses()
            }
        }
    }

    /// Handle network change — enforce network rules
    func handleNetworkChange() {
        // Enforce Wi-Fi policies inside a detached task to avoid blocking the MainActor UI
        Task.detached { [weak self] in
            guard let self = self else { return }
            let allMounts = await MainActor.run { self.mounts }
            let allPaused = await MainActor.run { self.pausedMounts }
            let netPaused = await MainActor.run { self.networkPausedMounts }
            let isNetworkUp = await MainActor.run { AppLifecycle.shared.networkMonitor?.isConnected ?? true }
            let currentInterfaceType = await MainActor.run { AppLifecycle.shared.networkMonitor?.interfaceType }
            let previousInterfaceType = await MainActor.run { self.lastKnownInterfaceType }
            
            let didInterfaceChange = (previousInterfaceType != nil && currentInterfaceType != nil && previousInterfaceType != currentInterfaceType)
            await MainActor.run { self.lastKnownInterfaceType = currentInterfaceType }
            
            await withTaskGroup(of: Void.self) { group in
                for mount in allMounts {
                    group.addTask {
                        let physicallyMounted = MountManager.isMounted(mount.mountPath) 
                        let isNetworkRestricted = await MainActor.run { self.isNetworkRestricted(for: mount) }
                        
                        let shouldBePausedDueToNetwork = isNetworkRestricted || !isNetworkUp
                        
                        if shouldBePausedDueToNetwork {
                            if !netPaused.contains(mount.name) {
                                await MainActor.run { self.networkPauseMount(name: mount.name) }
                            }
                            
                            // If the network interface completely dropped, the active smb mount becomes a completely dead socket immediately. Force unmount it to prevent OS hang loops.
                            if physicallyMounted && !isNetworkUp {
                                self.forceUnmount(mount.mountPath)
                            }
                        } else {
                            // Not restricted
                            let isMounted = physicallyMounted

                            if netPaused.contains(mount.name) {
                                _ = await MainActor.run { self.networkPausedMounts.remove(mount.name) }
                            }
                            
                            if isMounted {
                                if !allPaused.contains(mount.name) {
                                    let isEngineRunning = await MainActor.run { self.engines[mount.name] != nil }
                                    
                                    // Interface Transition Priority Bounce (e.g. Wi-Fi -> Ethernet)
                                    // Force-unmount the active connection. Since it's not in pausedMounts, 
                                    // the Health Monitor or restartEngine will immediately spin it back up, binding the new socket to the faster interface!
                                    if didInterfaceChange {
                                        AppLogger.shared.info("[MountManager] Interface transition detected. Bouncing mount '\(mount.name)'.")
                                        await MainActor.run {
                                            Task.detached { [weak self] in
                                                self?.forceUnmount(mount.mountPath)
                                            }
                                            let _ = self.restartEngine(name: mount.name)
                                        }
                                    } else if !isEngineRunning {
                                        await MainActor.run { let _ = self.restartEngine(name: mount.name) }
                                    }
                                }
                            } else {
                                if !allPaused.contains(mount.name) {
                                    await MainActor.run {
                                        let _ = self.restartEngine(name: mount.name)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            await MainActor.run { self.refreshStatuses() }
        }
    }

    // MARK: - Overall Status (for menu bar icon)

    private func computeOverallStatusIcon() -> String {
        let allStatuses = Array(statuses.values)
        if allStatuses.isEmpty { return "externaldrive.badge.questionmark" }
        if allStatuses.allSatisfy({ $0.isMounted && $0.isResponsive }) { return "externaldrive.fill.badge.checkmark" }
        if allStatuses.allSatisfy({ !$0.isMounted }) { return "externaldrive.badge.xmark" }
        return "externaldrive.fill.badge.exclamationmark"
    }

    private func updateOverallIcon() {
        let newIcon = computeOverallStatusIcon()
        if overallStatusIcon != newIcon {
            overallStatusIcon = newIcon
        }
    }

    // MARK: - Pre-validate Mount (test before creating)

    struct ValidationResult {
        var serverReachable = false
        var smbPortOpen = false
        var mountTestPassed = false
        var errorDetail = ""
        var reachableServer = ""

        var canProceed: Bool { smbPortOpen && mountTestPassed }

        var summary: String {
            var lines: [String] = []
            lines.append(serverReachable ? "✅ 伺服器可連線 (\(reachableServer))" : "⚠️ 伺服器 ICMP 無回應 (可能被防火牆阻擋)")
            lines.append(smbPortOpen ? "✅ SMB 連接埠 (445) 開放" : "❌ SMB 連接埠 (445) 無法連線")
            if smbPortOpen {
                lines.append(mountTestPassed ? "✅ 掛載測試成功（帳號密碼正確）" : "❌ 掛載測試失敗")
            }
            if !errorDetail.isEmpty {
                lines.append("\n詳細資訊: \(errorDetail)")
            }
            return lines.joined(separator: "\n")
        }
    }

    nonisolated func preValidateMount(servers: [String], shareName: String, username: String, password: String) -> ValidationResult {
        var result = ValidationResult()
        let normalizedServers = servers.compactMap(SMBConnection.normalizedHost)

        guard !normalizedServers.isEmpty else {
            result.errorDetail = "請至少輸入一個有效的伺服器名稱或 IP 位址。"
            return result
        }

        // 1. Find first reachable server (ICMP)
        for server in normalizedServers {
            if processRun(launchPath: "/sbin/ping", arguments: ["-c", "1", "-W", "1000", server]) {
                result.serverReachable = true
                result.reachableServer = server
                break
            }
        }

        // 2. Check SMB port (445)
        var targetServer = normalizedServers[0]
        for server in normalizedServers {
            if processRun(launchPath: "/usr/bin/nc", arguments: ["-z", "-w", "3", server, "445"]) {
                result.smbPortOpen = true
                targetServer = server
                if !result.serverReachable {
                    result.serverReachable = true
                    result.reachableServer = server
                }
                break
            }
        }

        guard result.smbPortOpen else {
            result.errorDetail = "所有伺服器的 SMB 連接埠 (445) 均無法連線。請確認伺服器已開啟 SMB 服務且網路可達。"
            return result
        }

        // 3. Use smbutil to verify authentication
        guard let smbViewURL = SMBConnection.serverViewSource(
            username: username,
            password: password,
            server: targetServer
        ) else {
            result.errorDetail = "SMB 帳號或伺服器格式不正確。"
            return result
        }
        let (viewOutput, viewExitCode) = processOutputWithExitCode(
            launchPath: "/usr/bin/smbutil",
            arguments: ["view", smbViewURL]
        )

        if viewExitCode == 0 {
            let shareNameLower = shareName.lowercased()
            let outputLines = viewOutput.components(separatedBy: "\n")
            let shareFound = outputLines.contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let components = trimmed.components(separatedBy: CharacterSet.whitespaces)
                guard let firstComponent = components.first else { return false }
                return firstComponent.lowercased() == shareNameLower
            }

            if shareFound {
                result.mountTestPassed = true
            } else {
                result.mountTestPassed = false
                let shareLines = outputLines
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("=") && !$0.lowercased().hasPrefix("share") }
                let shareList = shareLines.isEmpty ? "(無)" : shareLines.joined(separator: "\n")
                result.errorDetail = "帳號密碼驗證成功，但找不到共享資料夾 '\(shareName)'。\n\n伺服器上可用的共享：\n\(shareList)"
            }
        } else {
            result.mountTestPassed = false
            let lower = viewOutput.lowercased()
            if lower.contains("auth") || lower.contains("password") || lower.contains("logon") || lower.contains("credentials") {
                result.errorDetail = "帳號或密碼錯誤。請確認 SMB 登入憑證。"
            } else if lower.contains("connect") || lower.contains("network") {
                result.errorDetail = "無法連線到 SMB 服務。請確認伺服器已開啟 SMB 服務。"
            } else if !viewOutput.isEmpty {
                result.errorDetail = viewOutput
            } else {
                result.errorDetail = "SMB 驗證失敗 (結束碼 \(viewExitCode))。"
            }
        }

        return result
    }

    // MARK: - Create Mount

    func createMount(name: String, servers: [String], shareName: String, username: String, password: String, useKeychain: Bool, mountOptions: String, showInSidebar: Bool, createDesktopShortcut: Bool, allowedSSIDs: [String] = []) -> (success: Bool, error: String?) {
        if mounts.contains(where: { $0.name == name }) {
            return (false, "掛載點 '\(name)' 的設定已存在。")
        }

        let built = buildMount(
            name: name,
            servers: servers,
            shareName: shareName,
            username: username,
            useKeychain: true,
            mountOptions: mountOptions,
            showInSidebar: showInSidebar,
            createDesktopShortcut: createDesktopShortcut,
            allowedSSIDs: allowedSSIDs
        )
        guard let mount = built.mount else { return (false, built.error) }

        // Save password to Keychain
        if let error = KeychainService.savePassword(forMount: name, username: username, password: password) {
            return (false, "無法將密碼儲存到 Keychain：\(error)")
        }

        // Save config as JSON
        do {
            try mount.save()
        } catch {
            return (false, "無法儲存掛載設定：\(error.localizedDescription)")
        }

        // Start engine immediately
        refresh()
        startEngine(for: mount)

        return (true, nil)
    }

    /// Updates a profile without deleting the working configuration first.
    /// The new credential and JSON are committed before the old engine/profile
    /// is stopped, so a failed save cannot make an existing mount disappear.
    func updateMount(
        originalName: String,
        name: String,
        servers: [String],
        shareName: String,
        username: String,
        password: String,
        useKeychain: Bool,
        mountOptions: String,
        showInSidebar: Bool,
        createDesktopShortcut: Bool,
        allowedSSIDs: [String] = []
    ) -> (success: Bool, error: String?) {
        guard let oldMount = mounts.first(where: { $0.name == originalName }) else {
            return (false, "找不到原始掛載點 '\(originalName)'。")
        }
        if name != originalName && mounts.contains(where: { $0.name == name }) {
            return (false, "掛載點 '\(name)' 的設定已存在。")
        }

        let built = buildMount(
            name: name,
            servers: servers,
            shareName: shareName,
            username: username,
            useKeychain: true,
            mountOptions: mountOptions,
            showInSidebar: showInSidebar,
            createDesktopShortcut: createDesktopShortcut,
            allowedSSIDs: allowedSSIDs
        )
        guard let newMount = built.mount else { return (false, built.error) }

        if let error = KeychainService.savePassword(forMount: name, username: username, password: password) {
            return (false, "無法將密碼儲存到 Keychain：\(error)")
        }
        do {
            try newMount.save()
        } catch {
            return (false, "無法儲存掛載設定：\(error.localizedDescription)")
        }

        stopEngine(name: originalName)
        if MountManager.isMounted(oldMount.mountPath) {
            forceUnmount(oldMount.mountPath)
        }
        if originalName != name {
            oldMount.remove()
            KeychainService.deletePassword(forMount: originalName)
            pausedMounts.remove(originalName)
            networkPausedMounts.remove(originalName)
        }

        refresh()
        startEngine(for: newMount)
        return (true, nil)
    }

    private func buildMount(
        name: String,
        servers: [String],
        shareName: String,
        username: String,
        useKeychain: Bool,
        mountOptions: String,
        showInSidebar: Bool,
        createDesktopShortcut: Bool,
        allowedSSIDs: [String]
    ) -> (mount: MountPoint?, error: String?) {
        guard MountPoint.isValidName(name) else {
            return (nil, "掛載名稱格式錯誤！只能包含英數、底線和連字號。")
        }
        var seenServers = Set<String>()
        let normalizedServers = servers
            .compactMap(SMBConnection.normalizedHost)
            .filter { seenServers.insert($0).inserted }
        guard !normalizedServers.isEmpty else {
            return (nil, "請至少輸入一個有效的伺服器名稱或 IP 位址。")
        }
        let trimmedShare = shareName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedShare.isEmpty, !trimmedShare.contains("/") else {
            return (nil, "共享資料夾名稱不可為空或包含斜線。")
        }
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else { return (nil, "使用者名稱不可為空。") }

        return (MountPoint(
            name: name,
            servers: normalizedServers,
            shareName: trimmedShare,
            username: trimmedUsername,
            useKeychain: true,
            mountOptions: mountOptions,
            showInSidebar: showInSidebar,
            createDesktopShortcut: createDesktopShortcut,
            allowedSSIDs: allowedSSIDs
        ), nil)
    }

    // MARK: - Export / Import

    func exportMounts() -> URL? {
        guard let data = MountPoint.exportAll() else { return nil }
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBMountClientV3_export_\(UUID().uuidString).json")
        do {
            try data.write(to: tmpURL)
            return tmpURL
        } catch {
            return nil
        }
    }

    func importMounts(from url: URL) -> (success: Int, skipped: Int, error: String?) {
        guard let data = try? Data(contentsOf: url) else {
            return (0, 0, "無法讀取檔案。")
        }
        let result = MountPoint.importMounts(from: data)
        if let error = result.error {
            return (0, 0, error)
        }
        // Refresh and start engines for newly imported mounts
        refresh()
        for mount in result.imported {
            // If password is missing from Keychain, actively prompt the user during import
            if KeychainService.getPassword(forMount: mount.name, username: mount.username) == nil {
                var passwordCorrect = false
                while !passwordCorrect {
                    let alert = NSAlert()
                    alert.messageText = "輸入密碼"
                    alert.informativeText = "掛載點 '\(mount.name)' (帳號: \(mount.username)) 需要連線密碼："
                    let secureField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
                    alert.accessoryView = secureField
                    alert.addButton(withTitle: "驗證並連線")
                    alert.addButton(withTitle: "略過")
                    
                    NSApp.activate(ignoringOtherApps: true)
                    let response = alert.runModal()
                    DispatchQueue.main.async { NSApp.mainWindow?.makeKeyAndOrderFront(nil) }
                    
                    if response == .alertFirstButtonReturn {
                        let pass = secureField.stringValue
                        let valResult = self.preValidateMount(
                            servers: mount.servers,
                            shareName: mount.shareName,
                            username: mount.username,
                            password: pass
                        )
                        
                        if valResult.canProceed {
                            if let keychainError = KeychainService.savePassword(
                                forMount: mount.name,
                                username: mount.username,
                                password: pass
                            ) {
                                let errorAlert = NSAlert()
                                errorAlert.messageText = "無法儲存密碼"
                                errorAlert.informativeText = keychainError
                                errorAlert.runModal()
                            } else {
                                passwordCorrect = true
                            }
                        } else {
                            let errorAlert = NSAlert()
                            errorAlert.messageText = "密碼驗證或連線失敗"
                            errorAlert.informativeText = "無法使用此密碼連線到伺服器。\n\(valResult.errorDetail)"
                            NSApp.activate(ignoringOtherApps: true)
                            errorAlert.runModal()
                            DispatchQueue.main.async { NSApp.mainWindow?.makeKeyAndOrderFront(nil) }
                        }
                    } else {
                        break // User skipped
                    }
                }
                
                if !passwordCorrect {
                    // Do not start engine preventing infinite spin, mark as paused
                    self.pausedMounts.insert(mount.name)
                } else {
                    startEngine(for: mount)
                }
            } else {
                startEngine(for: mount)
            }
        }
        return (result.imported.count, result.skipped.count, nil)
    }

    // MARK: - Delete Mount

    func deleteMount(name: String) -> (success: Bool, error: String?) {
        guard let mount = mounts.first(where: { $0.name == name }) else {
            return (false, "找不到掛載點 '\(name)'。")
        }

        // Stop engine
        stopEngine(name: name)

        // Unmount if mounted
        let path = mount.mountPath
        Task.detached { [weak self] in
            if MountManager.isMounted(path) {
                self?.forceUnmount(path)
            }
        }

        // Remove config + keychain
        mount.remove()
        KeychainService.deletePassword(forMount: name)

        refresh()
        return (true, nil)
    }

    // MARK: - Unmount All (pauses engines)

    @discardableResult
    func unmountAll() -> Int {
        isPaused = true
        var count = 0
        // Stop all engines first to prevent auto-reconnect
        let runningEngines = Array(engines.values)
        engines.removeAll()
        for engine in runningEngines {
            Task { await engine.stop() }
        }
        // Then unmount
        for mount in mounts {
            if MountManager.isMounted(mount.mountPath) {
                let path = mount.mountPath
                Task.detached { [weak self] in
                    self?.forceUnmount(path)
                }
                count += 1
            }
        }
        refreshStatuses()
        return count
    }

    /// Resume all mounts after a pause
    func reconnectAll() {
        isPaused = false
        pausedMounts.removeAll()
        for mount in mounts {
            startEngine(for: mount)
        }
        refreshStatuses()
    }

    // MARK: - Mount Checking Utilities

    /// Returns the full output of /sbin/mount to check all mounts in one pass
    nonisolated static func getMountsOutput() -> String {
        let task = Process()
        task.launchPath = "/sbin/mount"
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    /// FIX #3: Parse `/sbin/mount` so we don't trigger `FileManager` hangs on disconnected networks
    nonisolated static func isMounted(_ path: String) -> Bool {
        SMBConnection.isMounted(path: path, inMountOutput: getMountsOutput())
    }

    /// Run stat asynchronously without freezing the thread via `usleep`
    nonisolated static func isMountResponsive(_ path: String) async -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/stat"
        task.arguments = [path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do { try task.run() } catch { return false }

        // Give stat up to 10 seconds to respond. 
        // Under heavy SMB bulk file transfer the smbfs driver queue delays stats severely.
        let deadline = Date().addingTimeInterval(10)
        while task.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 sec
        }
        if task.isRunning {
            task.terminate()
            return false
        }
        return task.terminationStatus == 0
    }

    @discardableResult
    nonisolated func forceUnmount(_ path: String) -> Bool {
        Task.detached {
            let firstSucceeded = await Self.runUnmountProcess(
                executable: "/sbin/umount",
                arguments: ["-f", path]
            )
            if !firstSucceeded {
                _ = await Self.runUnmountProcess(
                    executable: "/usr/sbin/diskutil",
                    arguments: ["unmount", "force", path]
                )
            }
        }
        return true
    }

    nonisolated private static func runUnmountProcess(executable: String, arguments: [String]) async -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }

        let deadline = Date().addingTimeInterval(8)
        while task.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if task.isRunning {
            task.terminate()
            return false
        }
        return task.terminationStatus == 0
    }

    // MARK: - Log Reading

    func readLog(for name: String, lines: Int = 30) -> String {
        if name == "monitor" {
            return AppLogger.shared.readLogs()
                .split(whereSeparator: \.isNewline)
                .suffix(lines)
                .joined(separator: "\n")
        }
        let marker = "[\(name)]"
        return AppLogger.shared.readLogs()
            .split(whereSeparator: \.isNewline)
            .filter { $0.contains(marker) }
            .suffix(lines)
            .joined(separator: "\n")
    }

    // MARK: - Connection Test

    func testConnection(server: String) -> String {
        guard let host = SMBConnection.normalizedHost(server) else {
            return "伺服器格式無效。"
        }
        var result = "伺服器連線測試: \(host)\n━━━━━━━━━━━━━━━━━━━━\n\n"

        result += "1️⃣ ICMP (Ping) 測試...\n"
        if processRun(launchPath: "/sbin/ping", arguments: ["-c", "3", "-W", "1000", host]) {
            result += "   ✅ ICMP (Ping) 回應正常。\n\n"
        } else {
            result += "   ❌ ICMP (Ping) 無回應。\n   (可能被防火牆阻擋，不影響 SMB 連線)\n\n"
        }

        result += "2️⃣ SMB 連接埠 (445) 測試...\n"
        if processRun(launchPath: "/usr/bin/nc", arguments: ["-z", "-w", "3", host, "445"]) {
            result += "   ✅ SMB 連接埠 (445) 開放。\n\n"
        } else {
            result += "   ❌ SMB 連接埠 (445) 無法連線。\n   (請檢查伺服器設定與防火牆)\n\n"
        }

        if IPv4Address(host) == nil && IPv6Address(host) == nil {
            result += "3️⃣ DNS 名稱解析測試...\n"
            let (hostOutput, exitCode) = processOutputWithExitCode(
                launchPath: "/usr/bin/dscacheutil",
                arguments: ["-q", "host", "-a", "name", host]
            )
            if exitCode == 0, hostOutput.contains("ip_address:") {
                result += "   ✅ DNS 解析成功。\n"
                if let addressLine = hostOutput.components(separatedBy: "\n").first(where: { $0.contains("ip_address:") }) {
                    result += "   \(addressLine.trimmingCharacters(in: .whitespaces))\n"
                }
            } else {
                result += "   ❌ DNS 解析失敗。\n   (請檢查您的網路設定或 DNS 伺服器)\n"
            }
        }

        return result
    }

    // MARK: - Process Helpers (nonisolated)

    nonisolated private func processRun(launchPath: String, arguments: [String]) -> Bool {
        let task = Process()
        task.launchPath = launchPath
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run(); task.waitUntilExit(); return task.terminationStatus == 0 }
        catch { return false }
    }

    nonisolated private func processOutputWithExitCode(launchPath: String, arguments: [String]) -> (output: String, exitCode: Int32) {
        let task = Process()
        task.launchPath = launchPath
        task.arguments = arguments
        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = outputPipe
        do {
            try task.run()
        } catch {
            return ("Process launch failed: \(error.localizedDescription)", -1)
        }
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let combined = (String(data: outputData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (combined, task.terminationStatus)
    }
}
