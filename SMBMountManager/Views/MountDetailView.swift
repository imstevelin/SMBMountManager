import SwiftUI

/// Detail view for a selected mount point — shows config, status, logs, and actions
struct MountDetailView: View {
    @ObservedObject var mountManager: MountManager
    let mount: MountPoint

    @State private var logContent = ""
    @State private var showDeleteConfirm = false
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    private var status: MountStatus {
        mountManager.statuses[mount.name] ?? MountStatus(name: mount.name)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                headerSection

                // Status Cards
                HStack(spacing: 12) {
                    statusCard(
                        icon: status.overallIcon,
                        title: "掛載狀態",
                        value: status.statusText,
                        color: statusColor
                    )
                    statusCard(
                        icon: status.isEngineRunning ? "play.circle.fill" : "stop.circle",
                        title: "服務狀態",
                        value: status.isEngineRunning ? "運行中" : "已停止",
                        color: status.isEngineRunning ? .green : .red
                    )
                    statusCard(
                        icon: "timer",
                        title: "回應延遲",
                        value: status.latencyText,
                        color: status.latencyColor
                    )
                }

                if status.isMounted, let frac = status.capacityUsedFraction, let desc = status.capacityDescription {
                    HStack(spacing: 12) {
                        Text("儲存空間")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        GeometryReader { geo in
                            ZStack(alignment: .center) { // Center visually aligns better
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(nsColor: .separatorColor).opacity(0.3))
                                    .frame(height: 8)
                                HStack(spacing: 0) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(frac > 0.9 ? Color.red : Color.accentColor)
                                        .frame(width: geo.size.width * CGFloat(frac), height: 8)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .frame(height: 8) // Fixed height constraints for GeometryReader inside HStack
                        
                        Text(desc)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color(nsColor: .windowBackgroundColor))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
                    )
                }

                // Configuration
                configSection

                // Actions
                actionSection

                // Log Viewer
                logSection
            }
            .padding(24)
        }
        .onAppear { refreshLog() }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("確定") {}
        } message: {
            Text(alertMessage)
        }
        .confirmationDialog("確認刪除", isPresented: $showDeleteConfirm) {
            Button("永久刪除", role: .destructive) { deleteMount() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("確定要永久刪除掛載點 '\(mount.name)' 嗎？\n\n此操作將停止並移除相關服務、刪除設定檔與腳本、從 Keychain 中刪除密碼。\n\n此操作無法復原。")
        }
    }

    // MARK: - Sections

    private var statusColor: Color {
        if !status.isNetworkUp { return .secondary }
        if status.isMounted && status.isResponsive { return .green }
        if status.isMounted { return .orange }
        if status.isPaused { return .orange }
        if status.isEngineRunning && !status.isFailing { return .yellow }
        return .red
    }

    private var headerSection: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 52, height: 52)
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.system(size: 24))
                    .foregroundStyle(.blue)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(mount.name)
                    .font(.title.bold())
                    .fontDesign(.monospaced)
                Text(mount.mountPath)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(icon: "info.circle", title: "設定資訊")

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                configRow("伺服器", mount.servers.joined(separator: ", "))
                configRow("共享名稱", mount.shareName)
                configRow("帳號", mount.username)
                configRow("密碼儲存", mount.useKeychain ? "🔒 Keychain" : "⚠️ 明文")
                configRow("側邊欄顯示", mount.showInSidebar ? "開啟" : "關閉")
                if mount.showInSidebar {
                    configRow("建立桌面捷徑", mount.createDesktopShortcut ? "開啟" : "關閉")
                }

                GridRow {
                    Text("網路限制")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    
                    if mount.allowedSSIDs.isEmpty {
                        Text("無限制")
                            .font(.body)
                    } else {
                        FlowLayout(spacing: 6) {
                            ForEach(mount.allowedSSIDs, id: \.self) { ssid in
                                HStack(spacing: 4) {
                                    Image(systemName: "wifi")
                                        .font(.caption2)
                                    Text(ssid)
                                }
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.1), in: Capsule())
                            }
                        }
                    }
                }

                if !mount.mountOptions.isEmpty {
                    configRow("掛載選項", mount.mountOptions)
                }
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
        }
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(icon: "gearshape.2", title: "操作")

            HStack(spacing: 12) {
                Button {
                    let success = mountManager.restartEngine(name: mount.name)
                    alertTitle = success ? "操作成功" : "操作失敗"
                    alertMessage = success ? "已重新連線 '\(mount.name)'。" : "重新連線失敗，請檢查日誌。"
                    showAlert = true
                } label: {
                    Label("重新連線", systemImage: "arrow.counterclockwise")
                }

                if mountManager.pausedMounts.contains(mount.name) {
                    Button {
                        let _ = mountManager.restartEngine(name: mount.name)
                    } label: {
                        Label("繼續掛載", systemImage: "play.fill")
                    }
                } else if status.isMounted {
                    Button {
                        mountManager.pauseMount(name: mount.name)
                    } label: {
                        Label("強制退出", systemImage: "eject")
                    }
                }

                Spacer()

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("刪除掛載點", systemImage: "trash")
                }
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(icon: "doc.text", title: "執行日誌")

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("最近記錄")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button {
                        refreshLog()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)

                    Button("開啟完整日誌") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: mount.logPath))
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }

                ScrollView {
                    Text(logContent.isEmpty ? "(日誌為空)" : logContent)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
        }
    }

    // MARK: - Helpers

    private func configRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .fontDesign(.monospaced)
                .textSelection(.enabled)
        }
    }

    private func statusCard(icon: String, title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .symbolEffect(.pulse, options: .repeating, value: color == .yellow)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.callout.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private func refreshLog() {
        logContent = mountManager.readLog(for: mount.name)
    }

    private func deleteMount() {
        let result = mountManager.deleteMount(name: mount.name)
        if !result.success {
            alertTitle = "刪除失敗"
            alertMessage = result.error ?? "未知錯誤"
            showAlert = true
        }
    }
}
