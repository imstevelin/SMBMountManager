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
        guard run("/bin/chmod", arguments: ["755", fixerScriptPath]) else { return false }

        // Write fixer plist to /tmp, then move with admin privileges
        let tmpPlist = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(fixerLabel)-\(UUID().uuidString).plist").path
        let plist: [String: Any] = [
            "Label": fixerLabel,
            "ProgramArguments": ["/bin/bash", fixerScriptPath],
            "RunAtLoad": true
        ]
        guard let plistData = try? PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        ), (try? plistData.write(to: URL(fileURLWithPath: tmpPlist), options: .atomic)) != nil else {
            return false
        }
        defer { try? FileManager.default.removeItem(atPath: tmpPlist) }

        let tempArg = shellQuote(tmpPlist)
        let plistArg = shellQuote(fixerPlistPath)
        let adminCmd = "/bin/mv \(tempArg) \(plistArg) && "
            + "/usr/sbin/chown root:wheel \(plistArg) && "
            + "/bin/chmod 644 \(plistArg) && "
            + "(/bin/launchctl unload \(plistArg) >/dev/null 2>&1 || true); "
            + "/bin/launchctl load -w \(plistArg)"
        return shellWithAdmin(adminCmd)
    }

    /// Remove the fixer service (requires admin privileges)
    static func removeFixer() -> Bool {
        let plistArg = shellQuote(fixerPlistPath)
        let adminCmd = "(/bin/launchctl unload \(plistArg) >/dev/null 2>&1 || true); /bin/rm -f \(plistArg)"
        let ok = shellWithAdmin(adminCmd)
        try? FileManager.default.removeItem(atPath: fixerScriptPath)
        return ok
    }

    // MARK: - Shell Helpers

    private static func run(_ executable: String, arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run(); task.waitUntilExit(); return task.terminationStatus == 0 }
        catch { return false }
    }

    private static func shellWithAdmin(_ command: String) -> Bool {
        let script = """
        on run argv
            do shell script (item 1 of argv) with administrator privileges
        end run
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script, command]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run(); task.waitUntilExit(); return task.terminationStatus == 0 }
        catch { return false }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func writeFile(_ content: String, to path: String) -> Bool {
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch { return false }
    }
}
