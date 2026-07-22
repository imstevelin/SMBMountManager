import Foundation
import SwiftUI
import ServiceManagement

/// Persistent app settings using @AppStorage
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("showNotifications") var showNotifications: Bool = true
    @AppStorage("showMountCount") var showMountCount: Bool = true
    @AppStorage("autoCheckUpdates") var autoCheckUpdates: Bool = true
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = true {
        didSet { updateLoginItem() }
    }

    private init() {
        let current = UserDefaults.standard
        guard let legacy = UserDefaults(suiteName: "org.imstevelin.SMBMountManager") else { return }
        for key in ["showNotifications", "showMountCount", "autoCheckUpdates", "launchAtLogin"]
            where current.object(forKey: key) == nil {
            if let value = legacy.object(forKey: key) {
                current.set(value, forKey: key)
            }
        }
    }

    private func updateLoginItem() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("[AppSettings] Login item error: \(error)")
        }
    }

    /// Check actual login item status from system
    func syncLoginItemStatus() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }
}
