import Foundation

/// Manages only the system-level permission fixer LaunchDaemon.
/// All mount-agent and monitor-agent logic has been moved in-process.
struct LaunchdService {
    static let home = NSHomeDirectory()
    static let fixerLabel = "com.user.smb_fix_volumes"
    static let fixerPlistPath = "/Library/LaunchDaemons/\(fixerLabel).plist"
    static let fixerScriptPath = "\(home)/scripts/smb_manager_fix_volumes.sh"
    static let scriptDir = "\(home)/scripts"

    /// Check if system fixer plist exists
    static var fixerInstalled: Bool {
        FileManager.default.fileExists(atPath: fixerPlistPath)
    }

    /// Install the fixer service (requires admin privileges)
    static func installFixer() -> Bool {
        // Ensure script dir
        try? FileManager.default.createDirectory(atPath: scriptDir, withIntermediateDirectories: true)

        // Write fixer script
        let fixerScript = """
        #!/bin/bash
        sleep 5
        /bin/chmod 1777 /Volumes
        /usr/sbin/chown root:admin /Volumes
        exit 0
        """
        guard writeFile(fixerScript, to: fixerScriptPath) else { return false }
        shell("chmod 755 \"\(fixerScriptPath)\"")

        // Write fixer plist to /tmp, then move with admin privileges
        let tmpPlist = "/tmp/\(fixerLabel).plist"
        let fixerPlistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(fixerLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/bin/bash</string>
                <string>\(fixerScriptPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """
        guard writeFile(fixerPlistContent, to: tmpPlist) else { return false }

        let adminCmd = """
        mv '\(tmpPlist)' '\(fixerPlistPath)' && \
        chown root:wheel '\(fixerPlistPath)' && \
        chmod 644 '\(fixerPlistPath)' && \
        launchctl unload '\(fixerPlistPath)' 2>/dev/null; \
        launchctl load -w '\(fixerPlistPath)'
        """
        return shellWithAdmin(adminCmd)
    }

    /// Remove the fixer service (requires admin privileges)
    static func removeFixer() -> Bool {
        let adminCmd = """
        launchctl unload '\(fixerPlistPath)' 2>/dev/null; \
        rm -f '\(fixerPlistPath)'
        """
        let ok = shellWithAdmin(adminCmd)
        try? FileManager.default.removeItem(atPath: fixerScriptPath)
        return ok
    }

    // MARK: - Shell Helpers

    @discardableResult
    private static func shell(_ command: String) -> Bool {
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", command]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run(); task.waitUntilExit(); return task.terminationStatus == 0 }
        catch { return false }
    }

    private static func shellWithAdmin(_ command: String) -> Bool {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run(); task.waitUntilExit(); return task.terminationStatus == 0 }
        catch { return false }
    }

    private static func writeFile(_ content: String, to path: String) -> Bool {
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch { return false }
    }
}
