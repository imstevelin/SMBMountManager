import Foundation
import SwiftUI
import ServiceManagement

/// Persistent app settings using @AppStorage
class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("showNotifications") var showNotifications: Bool = true
    @AppStorage("showMountCount") var showMountCount: Bool = true
    @AppStorage("autoCheckUpdates") var autoCheckUpdates: Bool = true
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false {
        didSet { updateLoginItem() }
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
