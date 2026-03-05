import SwiftUI

/// The dropdown content from the menu bar status icon
struct StatusMenuView: View {
    @ObservedObject var mountManager: MountManager
    @ObservedObject var networkMonitor: NetworkMonitorService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Mount points with quick actions
        if mountManager.mounts.isEmpty {
            Text("尚未設定任何掛載點")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ForEach(mountManager.mounts) { mount in
                let status = mountManager.statuses[mount.name] ?? MountStatus(name: mount.name)
                MenuBarMountItem(mount: mount, status: status, mountManager: mountManager)
            }
        }

        Divider()

        // System services (compact)
        Menu {
            let svc = mountManager.systemService
            Label(
                "權限修復: \(svc.fixerInstalled ? "已安裝" : "未安裝")",
                systemImage: svc.fixerInstalled ? "checkmark.circle.fill" : "xmark.circle"
            )
            if let ssid = networkMonitor.currentSSID {
                Label("目前 Wi-Fi: \(ssid)", systemImage: "wifi")
            }
        } label: {
            Label("系統服務狀態", systemImage: "gearshape.2")
        }

        Divider()

        // Quick actions — toggle between pause/resume
        if mountManager.isPaused {
            Button {
                mountManager.reconnectAll()
            } label: {
                Label("重新連接所有掛載", systemImage: "arrow.clockwise")
            }
        } else {
            Button {
                let _ = mountManager.unmountAll()
            } label: {
                Label("暫時退出所有掛載", systemImage: "eject")
            }
            .disabled(mountManager.mounts.isEmpty)
        }



        Divider()

        Button {
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                openWindow(id: "settings")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "settings" }) {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
            }
        } label: {
            Label("設定…", systemImage: "gearshape")
        }
        .keyboardShortcut(",", modifiers: .command)

        Button {
            AppLifecycle.shared.isTerminating = true
            // Force synchronous unmount before we even tell the OS to begin termination
            mountManager.unmountAllAndStopSync()
            NSApp.terminate(nil)
        } label: {
            Label("結束", systemImage: "power")
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

// MARK: - Individual mount item with submenu actions

struct MenuBarMountItem: View {
    let mount: MountPoint
    let status: MountStatus
    @ObservedObject var mountManager: MountManager

    var statusColor: Color {
        if !status.isNetworkUp { return .secondary }
        if status.isMounted && status.isResponsive { return .green }
        if status.isMounted { return .orange }
        if status.isPaused { return .orange }
        if status.isEngineRunning && !status.isFailing { return .yellow }
        return .red
    }

    var body: some View {
        Menu {
            if status.isMounted {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: mount.mountPath))
                } label: {
                    Label("在 Finder 中打開", systemImage: "folder")
                }

                Button {
                    mountManager.pauseMount(name: mount.name)
                } label: {
                    Label("強制退出", systemImage: "eject")
                }
            } else if mountManager.pausedMounts.contains(mount.name) {
                // Mount is paused — show reconnect option
                Button {
                    let _ = mountManager.restartEngine(name: mount.name)
                } label: {
                    Label("繼續掛載", systemImage: "play.fill")
                }
            }

            if !mountManager.pausedMounts.contains(mount.name) {
                Button {
                    let _ = mountManager.restartEngine(name: mount.name)
                } label: {
                    Label("重新連線", systemImage: "arrow.counterclockwise")
                }
            }

            Divider()

            Text("伺服器: \(mount.serversCSV)")
                .font(.callout)
            Text("帳號: \(mount.username)")
                .font(.callout)
            
            if status.isMounted, let desc = status.capacityDescription {
                Text("儲存空間: \(desc)")
                    .font(.callout)
            }
            if status.isEngineRunning {
                Text("回應延遲: \(status.latencyText)")
                    .font(.callout)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: status.overallIcon)
                    .foregroundStyle(statusColor)
                Text(mount.name)
                    .font(.system(.body, design: .monospaced))
                Spacer()
                if status.isPaused {
                    Text("已暫停")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    HStack(spacing: 4) {
                        if status.isEngineRunning || status.isMounted {
                            Text(status.latencyText)
                                .font(.system(.caption, design: .monospaced))
                        }
                        Text(status.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
