import Foundation
import SwiftUI
import AppKit

/// Simple Decodable struct for GitHub Releases API
struct GitHubRelease: Decodable {
    let tagName: String
    let name: String
    let body: String
    let htmlUrl: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlUrl = "html_url"
        case assets
    }
}

struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadUrl: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }
}

class UpdateService {
    static let shared = UpdateService()
    private let repoURL = "https://api.github.com/repos/imstevelin/SMBMountManager/releases/latest"

    func checkForUpdates(manual: Bool = false) {
        guard let url = URL(string: repoURL) else { return }
        
        // Prevent multiple simultaneous update checks from causing issues
        if isUpdating { return }
        
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                AppLogger.shared.error("[UpdateService] Update check failed: \(error.localizedDescription)")
                if manual { self.showErrorAlert(message: "網路錯誤，無法檢查更新。") }
                return
            }
            
            guard let data = data else {
                if manual { self.showErrorAlert(message: "未收到更新伺服器回應。") }
                return
            }
            
            do {
                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
                let latestVersion = release.tagName.replacingOccurrences(of: "v", with: "")
                
                DispatchQueue.main.async {
                    if self.isNewerVersion(current: currentVersion, latest: latestVersion) {
                        self.showUpdateAlert(release: release)
                    } else if manual {
                        self.showUpToDateAlert(currentVersion: currentVersion)
                    }
                }
            } catch {
                AppLogger.shared.error("[UpdateService] Failed to parse GitHub API response: \(error)")
                if manual { self.showErrorAlert(message: "無法解析更新資料。") }
            }
        }
        task.resume()
    }
    
    private func isNewerVersion(current: String, latest: String) -> Bool {
        return current.compare(latest, options: .numeric) == .orderedAscending
    }
    
    private var isUpdating = false
    
    // MARK: - Auto Update Logic
    
    private func performAutoUpdate(release: GitHubRelease) {
        guard !isUpdating else { return }
        // Find the zip asset
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }),
              let downloadURL = URL(string: asset.browserDownloadUrl) else {
            showErrorAlert(message: "找不到適合的更新檔案。")
            return
        }
        
        isUpdating = true
        
        isUpdating = true
        
        // Removed the modal alert blocking the update process
        // to achieve silent downloading in the background.
        
        let session = URLSession(configuration: .default)
        let downloadTask = session.downloadTask(with: downloadURL) { [weak self] tempURL, response, error in
            guard let self = self else { return }
            
            defer { self.isUpdating = false }
            
            if let error = error {
                AppLogger.shared.error("[UpdateService] Download failed: \(error.localizedDescription)")
                DispatchQueue.main.async { self.showErrorAlert(message: "下載更新檔失敗。") }
                return
            }
            
            guard let tempURL = tempURL else {
                DispatchQueue.main.async { self.showErrorAlert(message: "下載更新檔失敗。") }
                return
            }
            
            self.installUpdate(fromZip: tempURL)
        }
        downloadTask.resume()
    }
    
    private func installUpdate(fromZip zipURL: URL) {
        let fm = FileManager.default
        let tempExtractDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        
        do {
            try fm.createDirectory(at: tempExtractDir, withIntermediateDirectories: true, attributes: nil)
            
            // 1. Unzip
            let process = Process()
            process.launchPath = "/usr/bin/unzip"
            process.arguments = ["-q", zipURL.path, "-d", tempExtractDir.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            
            guard process.terminationStatus == 0 else {
                DispatchQueue.main.async { self.showErrorAlert(message: "解壓縮更新檔案失敗。") }
                return
            }
            
            // 2. Find the extracted .app
            let contents = try fm.contentsOfDirectory(atPath: tempExtractDir.path)
            guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
                DispatchQueue.main.async { self.showErrorAlert(message: "更新檔案內找不到應用程式。") }
                return
            }
            
            let extractedAppPath = tempExtractDir.appendingPathComponent(appName).path
            let currentAppPath = Bundle.main.bundlePath
            
            // 3. Create a bash script to replace the app and restart it
            let scriptPath = fm.temporaryDirectory.appendingPathComponent("update_restart_\(UUID().uuidString).sh").path
            
            let scriptContent = """
            #!/bin/bash
            # Wait a second to allow the current app to exit
            sleep 1
            
            # Remove old app and replace with new
            rm -rf "\(currentAppPath)"
            mv "\(extractedAppPath)" "\(currentAppPath)"
            
            # Remove quarantine attribute (just in case)
            xattr -cr "\(currentAppPath)"
            
            # Clean up temp directories
            rm -rf "\(tempExtractDir.path)"
            rm -f "\(zipURL.path)"
            rm -f "$0" # Delete self
            
            # Relaunch the app
            open "\(currentAppPath)"
            """
            
            try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            
            // 4. Run the script in the background detached from this process
            let restartProcess = Process()
            restartProcess.launchPath = "/bin/bash"
            restartProcess.arguments = ["-c", "nohup \"\(scriptPath)\" >/dev/null 2>&1 &"]
            try restartProcess.run()
            
            // 5. Quit current app gracefully
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
            
        } catch {
            AppLogger.shared.error("[UpdateService] Install failed: \(error.localizedDescription)")
            DispatchQueue.main.async { self.showErrorAlert(message: "安裝更新失敗：\(error.localizedDescription)") }
        }
    }
    
    // MARK: - Alerts
    
    private func showUpdateAlert(release: GitHubRelease) {
        NSApp.activate(ignoringOtherApps: true)
        
        let alert = NSAlert()
        alert.messageText = "有新版本可用！"
        let formattedBody = release.body.replacingOccurrences(of: "\\n", with: "\n")
        alert.informativeText = "最新版本: \(release.tagName)\n\n更新內容：\n\(formattedBody.prefix(300))..."
        alert.addButton(withTitle: "自動下載並更新")
        alert.addButton(withTitle: "前往網頁下載")
        alert.addButton(withTitle: "取消")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Auto Update
            performAutoUpdate(release: release)
        } else if response == .alertSecondButtonReturn {
            // Manual Download
            if let url = URL(string: release.htmlUrl) {
                NSWorkspace.shared.open(url)
            }
        }
        
        DispatchQueue.main.async { NSApp.mainWindow?.makeKeyAndOrderFront(nil) }
    }
    
    private func showUpToDateAlert(currentVersion: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "已是最新版本"
        alert.informativeText = "您目前的版本 (v\(currentVersion)) 已是最新版。"
        alert.addButton(withTitle: "確定")
        alert.runModal()
        DispatchQueue.main.async { NSApp.mainWindow?.makeKeyAndOrderFront(nil) }
    }
    
    private func showErrorAlert(message: String) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "檢查更新失敗"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "確定")
            alert.runModal()
            DispatchQueue.main.async { NSApp.mainWindow?.makeKeyAndOrderFront(nil) }
        }
    }
}
