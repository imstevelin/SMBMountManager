import Foundation
import AppKit

struct GitHubRelease: Decodable {
    let tagName: String
    let body: String
    let htmlUrl: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case htmlUrl = "html_url"
    }
}

/// Checks the official release feed without modifying the running application.
///
/// Replacing a running `.app` with an unverified archive is unsafe: an interrupted
/// move can destroy the installed copy, and GitHub assets are not an authenticated
/// update channel by themselves. Updates therefore require an explicit visit to
/// the release page, where the user can review and install the signed package.
@MainActor
final class UpdateService {
    static let shared = UpdateService()

    private let releasesAPI = URL(string: "https://api.github.com/repos/imstevelin/SMBMountManager/releases/latest")!
    private var isChecking = false

    private init() {}

    func checkForUpdates(manual: Bool = false, silent: Bool = false) {
        guard !isChecking else { return }
        isChecking = true

        var request = URLRequest(url: releasesAPI)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }
                self.isChecking = false

                if let error {
                    AppLogger.shared.error("[UpdateService] Update check failed: \(error.localizedDescription)")
                    if manual { self.showErrorAlert(message: "網路錯誤，無法檢查更新。") }
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode),
                      let data else {
                    AppLogger.shared.error("[UpdateService] Update server returned an invalid response")
                    if manual { self.showErrorAlert(message: "更新伺服器回應異常。") }
                    return
                }

                do {
                    let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                    if Self.isNewerVersion(current: current, latest: release.tagName) {
                        if silent {
                            AppLogger.shared.info("[UpdateService] Version \(release.tagName) is available")
                        } else {
                            self.showUpdateAlert(release: release)
                        }
                    } else if manual {
                        self.showUpToDateAlert(currentVersion: current)
                    }
                } catch {
                    AppLogger.shared.error("[UpdateService] Failed to parse release response: \(error.localizedDescription)")
                    if manual { self.showErrorAlert(message: "無法解析更新資料。") }
                }
            }
        }.resume()
    }

    nonisolated static func isNewerVersion(current: String, latest: String) -> Bool {
        func normalized(_ version: String) -> String {
            let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.first == "v" || trimmed.first == "V" {
                return String(trimmed.dropFirst())
            }
            return trimmed
        }
        return normalized(current).compare(normalized(latest), options: .numeric) == .orderedAscending
    }

    private func showUpdateAlert(release: GitHubRelease) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "有新版本可用"
        let notes = release.body.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = notes.isEmpty
            ? "最新版本：\(release.tagName)"
            : "最新版本：\(release.tagName)\n\n更新內容：\n\(notes.prefix(500))"
        alert.addButton(withTitle: "前往下載頁面")
        alert.addButton(withTitle: "稍後")

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: release.htmlUrl) {
            NSWorkspace.shared.open(url)
        }
    }

    private func showUpToDateAlert(currentVersion: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "已是最新版本"
        alert.informativeText = "您目前的版本（v\(currentVersion)）已是最新版。"
        alert.addButton(withTitle: "確定")
        alert.runModal()
    }

    private func showErrorAlert(message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "檢查更新失敗"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "確定")
        alert.runModal()
    }
}
