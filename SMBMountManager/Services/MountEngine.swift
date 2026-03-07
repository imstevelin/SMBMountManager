import Foundation

/// In-process mount engine that replaces the external bash mount script.
/// Each MountPoint gets its own MountEngine running as a Swift Task.
actor MountEngine {
    let mount: MountPoint
    private var task: Task<Void, Never>?
    private(set) var isRunning = false

    // Retry parameters
    private let mountedCheckInterval: TimeInterval = 10
    private let postFailSleep: TimeInterval = 3
    private let maxBackoff: TimeInterval = 60
    private let passwordRetryInterval: TimeInterval = 60
    
    private var _failCount = 0
    var isFailing: Bool {
        return _failCount > 0
    }

    init(mount: MountPoint) {
        self.mount = mount
    }

    // MARK: - Lifecycle

    func start() {
        guard task == nil else { return }
        isRunning = true
        task = Task { [weak self] in
            guard let self = self else { return }
            await self.mountLoop()
        }
        log("Engine started for '\(mount.name)'")
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        if mount.createDesktopShortcut {
            removeDesktopAlias()
        }
        AppLogger.shared.info("Engine stopped for '\(mount.name)'")
    }

    // MARK: - Main Mount Loop

    private func mountLoop() async {
        _failCount = 0

        while !Task.isCancelled {
            // SSID check — skip mount attempts if not on allowed network
            if !mount.allowedSSIDs.isEmpty && !WiFiService.isOnAllowedNetwork(allowedSSIDs: mount.allowedSSIDs) {
                log("[INFO] Not on allowed SSID for '\(mount.name)', waiting…")
                try? await Task.sleep(for: .seconds(mountedCheckInterval))
                continue
            }

            // Already mounted? Just wait and re-check.
            if isMounted() {
                _failCount = 0
                if mount.createDesktopShortcut {
                    createDesktopAlias()
                }
                try? await Task.sleep(for: .seconds(mountedCheckInterval))
                continue
            } else {
                // If it suddenly became unmounted, ensure shortcut is removed only after a few confirmed failures
                // to prevent temporary network flapping from making the icon disappear constantly.
                if mount.createDesktopShortcut && _failCount > 1 {
                    removeDesktopAlias()
                }
            }

            // Prevent duplicate ghost mounts on wake-from-sleep: ensure target path is fully clear before any new mount attempt
            let targetPath = mount.mountPath
            let isOccupied = await withTaskGroup(of: Bool?.self) { group in
                group.addTask {
                    let fm = FileManager.default
                    if fm.fileExists(atPath: targetPath) {
                        let contents = (try? fm.contentsOfDirectory(atPath: targetPath)) ?? []
                        let filteredContents = contents.filter { $0 != ".DS_Store" }
                        
                        // If it only contained .DS_Store, it is not truly occupied.
                        // We actively wipe the ghost folder to provide a clean slate for the mount command.
                        if filteredContents.isEmpty && !contents.isEmpty {
                            try? fm.removeItem(atPath: targetPath)
                        }
                        
                        return !filteredContents.isEmpty
                    }
                    return false
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 sec timeout
                    return nil
                }
                let result = await group.next() ?? nil
                group.cancelAll()
                return result ?? true // If timeout, assume occupied to avoid infinite hangs
            }

            if isOccupied {
                log("[WARN] Mount path \(targetPath) is occupied by a stale session. Attempting OS cleanup...")
                let _ = await Task.detached { [weak self] in
                    let task = Process()
                    task.launchPath = "/bin/bash"
                    task.arguments = ["-c", "/sbin/umount -f \"\(targetPath)\" || /usr/sbin/diskutil unmount force \"\(targetPath)\" 2>/dev/null"]
                    task.standardOutput = FileHandle.nullDevice
                    task.standardError = FileHandle.nullDevice
                    
                    do {
                        try task.run()
                        
                        let deadline = Date().addingTimeInterval(15)
                        while task.isRunning && Date() < deadline {
                            Thread.sleep(forTimeInterval: 0.1)
                        }
                        
                        if task.isRunning {
                            self?.log("[ERROR] OS stale session cleanup timed out after 15 seconds. Terminating.")
                            task.terminate()
                        }
                    } catch {
                        self?.log("[ERROR] OS stale session cleanup failed: \(error.localizedDescription)")
                    }
                }.value
                
                _failCount += 1
                try? await Task.sleep(for: .seconds(mountedCheckInterval))
                continue
            }

            // Get password
            guard let password = getPassword() else {
                log("[ERROR] Cannot retrieve password for '\(mount.name)'")
                try? await Task.sleep(for: .seconds(passwordRetryInterval))
                continue
            }

            // Try each server
            var mounted = false
            for server in mount.servers {
                guard !Task.isCancelled else { return }

                // Check server reachability
                let reachable = await Task.detached { self.isServerReachable(server) }.value
                guard reachable else {
                    log("[WARN] Server \(server) not reachable")
                    continue
                }

                // Try mount_smbfs first
                let smbfsSuccess = await Task.detached { self.attemptMountSmbfs(server: server, password: password) }.value
                if smbfsSuccess {
                    log("[SUCCESS] Mounted \(mount.name) on \(server)")
                    mounted = true
                    _failCount = 0
                    
                    await MainActor.run {
                        DownloadManager.shared.resumeTasks(forMountId: mount.id)
                    }
                    break
                }

                // Fallback: Finder mount via osascript
                let finderSuccess = await Task.detached { self.attemptFinderMount(server: server, password: password) }.value
                if finderSuccess {
                    log("[SUCCESS] Finder mount succeeded for \(mount.name) on \(server)")
                    mounted = true
                    _failCount = 0
                    
                    await MainActor.run {
                        DownloadManager.shared.resumeTasks(forMountId: mount.id)
                    }
                    break
                }
            }

            if mounted {
                if mount.createDesktopShortcut {
                    createDesktopAlias()
                }
                try? await Task.sleep(for: .seconds(mountedCheckInterval))
            } else {
                _failCount += 1
                let delay = min(postFailSleep * pow(2, Double(min(_failCount, 5))), maxBackoff)
                log("[ERROR] Mount failed for '\(mount.name)' (attempt \(_failCount)); waiting \(Int(delay))s")
                try? await Task.sleep(for: .seconds(delay))
            }
        }
        
        // Loop exited (e.g. cancelled)
        if mount.createDesktopShortcut {
            removeDesktopAlias()
        }
    }

    // MARK: - Mount Methods

    nonisolated private func attemptMountSmbfs(server: String, password: String) -> Bool {
        let mountPath = mount.mountPath
        let fm = FileManager.default

        // Create mount point directory if needed
        var createdDir = false
        if !fm.fileExists(atPath: mountPath) {
            do {
                try fm.createDirectory(atPath: mountPath, withIntermediateDirectories: true)
                createdDir = true
            } catch {
                return false
            }
        }

        // Build mount_smbfs command
        let url = "//\(mount.username):\(password)@\(server)/\(mount.shareName)"
        var args: [String] = []
        var optionsParts = mount.mountOptions.components(separatedBy: ",").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        
        if !mount.showInSidebar && !optionsParts.contains("nobrowse") {
            optionsParts.append("nobrowse")
        }
        
        if !optionsParts.isEmpty {
            args.append(contentsOf: ["-o", optionsParts.joined(separator: ",")])
        }
        args.append(url)
        args.append(mountPath)

        log("[INFO] Attempting mount_smbfs on \(server)")

        let task = Process()
        task.launchPath = "/sbin/mount_smbfs"
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            
            // Implement a 15-second timeout to prevent deadlocks during network reconnects
            let deadline = Date().addingTimeInterval(15)
            while task.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            
            if task.isRunning {
                log("[ERROR] mount_smbfs timed out after 15 seconds. Terminating.")
                task.terminate()
                if createdDir { try? fm.removeItem(atPath: mountPath) }
                return false
            }
        } catch {
            log("[ERROR] mount_smbfs launch failed: \(error.localizedDescription)")
            if createdDir { try? fm.removeItem(atPath: mountPath) }
            return false
        }

        if task.terminationStatus == 0 && isMounted() {
            return true
        }

        log("[ERROR] mount_smbfs failed on \(server) (exit code: \(task.terminationStatus))")
        if createdDir {
            if let contents = try? fm.contentsOfDirectory(atPath: mountPath), contents.isEmpty {
                try? fm.removeItem(atPath: mountPath)
            }
        }
        return false
    }

    nonisolated private func attemptFinderMount(server: String, password: String) -> Bool {
        let url = "smb://\(mount.username):\(password)@\(server)/\(mount.shareName)"
        let script = "try\nmount volume \"\(url)\"\nend try"

        log("[INFO] Attempting Finder mount on \(server)")

        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            
            let deadline = Date().addingTimeInterval(15)
            while task.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            
            if task.isRunning {
                log("[ERROR] osascript (Finder mount) timed out after 15 seconds. Terminating.")
                task.terminate()
                return false
            }
        } catch {
            return false
        }

        // Wait briefly for Finder to complete
        Thread.sleep(forTimeInterval: 2)
        return isMounted()
    }

    // MARK: - Status Checks

    nonisolated func isMounted() -> Bool {
        let url = URL(fileURLWithPath: mount.mountPath)
        guard let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]
        ) else { return false }
        return volumes.contains(url)
    }

    nonisolated func isMountResponsive() -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/stat"
        task.arguments = [mount.mountPath]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do { try task.run() } catch { return false }

        let deadline = Date().addingTimeInterval(3)
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if task.isRunning {
            task.terminate()
            return false
        }
        return task.terminationStatus == 0
    }

    // MARK: - Helpers

    nonisolated private func isServerReachable(_ server: String) -> Bool {
        // Try ICMP ping first
        if processRun(path: "/sbin/ping", args: ["-c", "1", "-W", "1000", server]) {
            return true
        }
        // Try SMB port (445) via nc
        if processRun(path: "/usr/bin/nc", args: ["-z", "-w", "3", server, "445"]) {
            return true
        }
        return false
    }

    nonisolated private func getPassword() -> String? {
        if mount.useKeychain {
            return KeychainService.retrievePassword(forMount: mount.name, username: mount.username)
        }
        // For non-keychain mounts, password is not stored in the model for security.
        // We try to read it from keychain anyway as a fallback.
        return KeychainService.retrievePassword(forMount: mount.name, username: mount.username)
    }

    nonisolated private func processRun(path: String, args: [String]) -> Bool {
        let task = Process()
        task.launchPath = path
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Latency Measurement

    /// Measure ping latency to the first server. Returns milliseconds or nil if unreachable.
    nonisolated func measureLatency() -> Double? {
        guard let server = mount.servers.first else { return nil }
        
        // Clean up smb:// prefix if present
        var cleanServer = server.replacingOccurrences(of: "smb://", with: "", options: .caseInsensitive)
        cleanServer = cleanServer.replacingOccurrences(of: "cifs://", with: "", options: .caseInsensitive)
        // Remove username@ if present
        if let atIndex = cleanServer.firstIndex(of: "@") {
            cleanServer = String(cleanServer[cleanServer.index(after: atIndex)...])
        }
        // Extract just the host, removing paths or ports
        let host = cleanServer.components(separatedBy: "/").first?.components(separatedBy: ":").first ?? cleanServer
        
        let task = Process()
        task.launchPath = "/sbin/ping"
        task.arguments = ["-c", "1", "-W", "1000", host]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                let output = String(data: data, encoding: .utf8) ?? ""
                if let range = output.range(of: "time=") {
                    let after = output[range.upperBound...]
                    let msString = after.prefix(while: { $0.isNumber || $0 == "." })
                    if let ms = Double(msString) {
                        return ms
                    }
                }
            }
        } catch { }
        
        // Fallback: Measure TCP handshake time directly to SMB port 445
        let start = Date()
        let ncTask = Process()
        ncTask.launchPath = "/usr/bin/nc"
        ncTask.arguments = ["-z", "-w", "1", host, "445"] // 1s timeout
        ncTask.standardOutput = FileHandle.nullDevice
        ncTask.standardError = FileHandle.nullDevice
        do {
            try ncTask.run()
            ncTask.waitUntilExit()
            if ncTask.terminationStatus == 0 {
                let duration = Date().timeIntervalSince(start) * 1000.0
                return Double(round(100 * duration) / 100)
            }
        } catch { }

        return nil
    }

    // MARK: - Desktop Shortcut Helpers

    nonisolated private func createDesktopAlias() {
        let aliasName = mount.name
        let desktopPath = (NSSearchPathForDirectoriesInDomains(.desktopDirectory, .userDomainMask, true).first ?? "") + "/\(aliasName)"
        let targetPath = mount.mountPath
        
        // Only run if the alias doesn't already exist and the mount exists
        let fm = FileManager.default
        if !fm.fileExists(atPath: targetPath) { return }
        if fm.fileExists(atPath: desktopPath) { return }
        
        let script = """
        tell application "Finder"
            set theTarget to POSIX file "\(targetPath)" as alias
            make new alias file at desktop to theTarget with properties {name:"\(aliasName)"}
        end tell
        """
        
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            log("[INFO] Creating desktop shortcut for '\(mount.name)'")
            try task.run()
            task.waitUntilExit()
        } catch {
            log("[WARN] Failed to create desktop shortcut: \(error.localizedDescription)")
        }
    }

    nonisolated private func removeDesktopAlias() {
        let aliasName = mount.name
        let desktopPath = (NSSearchPathForDirectoriesInDomains(.desktopDirectory, .userDomainMask, true).first ?? "") + "/\(aliasName)"
        let fm = FileManager.default
        
        // Aliases resolve to directories, causing fileExists(isDirectory:) to return true.
        // We just verify it exists at all, then delete it.
        if fm.fileExists(atPath: desktopPath) {
            do {
                log("[INFO] Removing desktop shortcut for '\(mount.name)'")
                try fm.removeItem(atPath: desktopPath)
            } catch {
                log("[WARN] Failed to remove desktop shortcut: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Logging

    nonisolated func log(_ message: String) {
        AppLogger.shared.info("[\(mount.name)] \(message)")
    }
}
