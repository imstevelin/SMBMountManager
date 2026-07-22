import AppKit
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
            // Use the manager's single policy implementation so Ethernet rules
            // and Wi-Fi SSID rules cannot disagree with the engine.
            let isRestricted = await MainActor.run {
                AppLifecycle.shared.mountManager?.isNetworkRestricted(for: mount) ?? false
            }
            if isRestricted {
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

            guard await prepareMountDirectory() else {
                _failCount += 1
                try? await Task.sleep(for: .seconds(mountedCheckInterval))
                continue
            }

            // Get password
            guard let password = getPassword() else {
                log("[ERROR] Cannot retrieve password for '\(mount.name)'")
                _failCount += 1
                try? await Task.sleep(for: .seconds(passwordRetryInterval))
                continue
            }

            // Try each server
            var mounted = false
            for server in mount.servers {
                guard !Task.isCancelled else { return }

                // Try mount_smbfs first
                let smbfsSuccess = await self.attemptMountSmbfs(server: server, password: password)
                if smbfsSuccess {
                    log("[SUCCESS] Mounted \(mount.name) on \(server)")
                    mounted = true
                    _failCount = 0
                    
                    await MainActor.run {
                        DownloadManager.shared.resumeTasks(forMountId: mount.id)
                        UploadManager.shared.resumeTasksForMount(mountId: mount.id)
                    }
                    break
                }

                // Finder chooses the volume name itself. It is only a valid
                // fallback when that name matches our configured mount path.
                let finderSuccess = mount.name == mount.shareName
                    ? await self.attemptFinderMount(server: server, password: password)
                    : false
                if finderSuccess {
                    log("[SUCCESS] Finder mount succeeded for \(mount.name) on \(server)")
                    mounted = true
                    _failCount = 0
                    
                    await MainActor.run {
                        DownloadManager.shared.resumeTasks(forMountId: mount.id)
                        UploadManager.shared.resumeTasksForMount(mountId: mount.id)
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

    nonisolated private func attemptMountSmbfs(server: String, password: String) async -> Bool {
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

        guard let source = SMBConnection.mountSourceWithoutPassword(
            username: mount.username,
            server: server,
            shareName: mount.shareName
        ) else {
            log("[ERROR] Invalid SMB server or share configuration")
            return false
        }

        var optionsParts = mount.mountOptions.components(separatedBy: ",").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        
        if !mount.showInSidebar && !optionsParts.contains("nobrowse") {
            optionsParts.append("nobrowse")
        }
        
        log("[INFO] Attempting mount_smbfs on \(server)")

        // mount_smbfs accepts a password only in argv or from a terminal.
        // Expect provides the terminal while reading the password from stdin,
        // keeping the secret out of process listings and log output.
        let expectScript = #"""
        set timeout 15
        log_user 1
        if {[gets stdin password] < 0} { exit 125 }
        set command [list /sbin/mount_smbfs]
        if {[info exists env(SMB_MOUNT_OPTIONS)] && $env(SMB_MOUNT_OPTIONS) ne ""} {
            lappend command -o $env(SMB_MOUNT_OPTIONS)
        }
        lappend command $env(SMB_MOUNT_SOURCE) $env(SMB_MOUNT_PATH)
        spawn -noecho {*}$command
        expect {
            -re {Password for [^:]+:} { send -- "$password\r"; exp_continue }
            eof { set result [wait]; exit [lindex $result 3] }
            timeout { close; wait; exit 124 }
        }
        """#

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
        task.arguments = ["-c", expectScript]
        var environment = ProcessInfo.processInfo.environment
        environment["SMB_MOUNT_SOURCE"] = source
        environment["SMB_MOUNT_PATH"] = mountPath
        environment["SMB_MOUNT_OPTIONS"] = optionsParts.joined(separator: ",")
        task.environment = environment
        let inputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardInput = inputPipe
        task.standardOutput = errorPipe
        task.standardError = errorPipe

        do {
            try task.run()
            inputPipe.fileHandleForWriting.write(Data((password + "\n").utf8))
            try? inputPipe.fileHandleForWriting.close()
            
            // Give Expect a little longer than its own timeout so it can reap
            // mount_smbfs and return the child status cleanly.
            let deadline = Date().addingTimeInterval(18)
            while task.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            
            if task.isRunning {
                log("[ERROR] mount_smbfs timed out after 18 seconds. Terminating.")
                task.terminate()
                if createdDir { try? fm.removeItem(atPath: mountPath) }
                return false
            }
        } catch {
            log("[ERROR] mount_smbfs launch failed: \(error.localizedDescription)")
            if createdDir { try? fm.removeItem(atPath: mountPath) }
            return false
        }

        if task.terminationStatus == 0 {
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if isMounted() { return true }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let rawDetail = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let detail = password.isEmpty
            ? rawDetail
            : rawDetail.replacingOccurrences(of: password, with: "[redacted]")
        let suffix = detail.isEmpty ? "" : ": \(detail)"
        log("[ERROR] mount_smbfs failed on \(server) (exit code: \(task.terminationStatus))\(suffix)")
        if createdDir {
            if let contents = try? fm.contentsOfDirectory(atPath: mountPath), contents.isEmpty {
                try? fm.removeItem(atPath: mountPath)
            }
        }
        return false
    }

    nonisolated private func attemptFinderMount(server: String, password: String) async -> Bool {
        guard let urlString = SMBConnection.finderURL(
            username: mount.username,
            password: password,
            server: server,
            shareName: mount.shareName
        ), let url = URL(string: urlString) else { return false }

        log("[INFO] Attempting Finder mount on \(server)")

        // Send the URL directly through Launch Services. Passing it as an
        // osascript argument would expose the credential URL in process lists.
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else { return false }

        // Wait briefly for Finder to complete
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        return isMounted()
    }

    // MARK: - Status Checks

    nonisolated func isMounted() -> Bool {
        MountManager.isMounted(mount.mountPath)
    }


    // MARK: - Helpers

    nonisolated private func getPassword() -> String? {
        if mount.useKeychain {
            return KeychainService.retrievePassword(forMount: mount.name, username: mount.username)
        }
        // For non-keychain mounts, password is not stored in the model for security.
        // We try to read it from keychain anyway as a fallback.
        return KeychainService.retrievePassword(forMount: mount.name, username: mount.username)
    }

    /// Makes sure the target is a real empty directory. A non-empty local
    /// directory is never removed or force-unmounted because it may contain
    /// user data. A directory operation that hangs is treated as a stale mount
    /// and handed to the OS unmount tools before the next retry.
    private func prepareMountDirectory() async -> Bool {
        let path = mount.mountPath
        if isMounted() { return true }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
            do {
                try fileManager.createDirectory(atPath: path, withIntermediateDirectories: false)
                return true
            } catch {
                log("[ERROR] Cannot create mount directory \(path): \(error.localizedDescription)")
                return false
            }
        }
        guard isDirectory.boolValue else {
            log("[ERROR] Mount path is occupied by a local file: \(path)")
            return false
        }

        // Ask `find` for at most one meaningful entry. Unlike `ls -A`, this
        // cannot fill a pipe and deadlock when a stale directory is very large.
        let listing = await Self.runProcess(
            path: "/usr/bin/find",
            arguments: [path, "-mindepth", "1", "-maxdepth", "1", "!", "-name", ".DS_Store", "-print", "-quit"],
            timeout: 2
        )
        if listing.timedOut {
            log("[WARN] Mount directory did not respond; requesting stale mount cleanup")
            await Self.unmount(path: path)
            return false
        }
        guard listing.exitCode == 0 else {
            log("[ERROR] Cannot inspect mount directory \(path)")
            return false
        }

        if listing.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? fileManager.removeItem(atPath: path + "/.DS_Store")
            return true
        }

        log("[ERROR] Mount path contains local files and was left untouched: \(path)")
        return false
    }

    private static func unmount(path: String) async {
        let first = await runProcess(path: "/sbin/umount", arguments: ["-f", path], timeout: 8)
        if first.exitCode != 0 {
            _ = await runProcess(path: "/usr/sbin/diskutil", arguments: ["unmount", "force", path], timeout: 8)
        }
    }

    private static func runProcess(path: String, arguments: [String], timeout: TimeInterval) async
        -> (exitCode: Int32, output: String, timedOut: Bool) {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, "", false)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            if Task.isCancelled {
                process.terminate()
                return (-1, "", true)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            process.terminate()
            return (-1, "", true)
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(data: data, encoding: .utf8) ?? "",
            false
        )
    }

    // MARK: - Latency Measurement

    /// Measure ping latency to the first server. Returns milliseconds or nil if unreachable.
    nonisolated func measureLatency() -> Double? {
        guard let server = mount.servers.first,
              let host = SMBConnection.normalizedHost(server) else { return nil }
        
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
        
        let desktopURL = URL(fileURLWithPath: desktopPath)
        let isFinderAlias = (try? desktopURL.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true
        if isFinderAlias {
            do {
                log("[INFO] Removing desktop shortcut for '\(mount.name)'")
                try fm.removeItem(at: desktopURL)
            } catch {
                log("[WARN] Failed to remove desktop shortcut: \(error.localizedDescription)")
            }
        } else if fm.fileExists(atPath: desktopPath) {
            log("[WARN] Desktop item '\(mount.name)' is not an alias and was left untouched")
        }
    }

    // MARK: - Logging

    nonisolated func log(_ message: String) {
        AppLogger.shared.info("[\(mount.name)] \(message)")
    }
}
