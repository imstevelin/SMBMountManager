import SwiftUI

// MARK: - Liquid Glass Helpers

/// Reusable glass card container for consistent Liquid Glass styling
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 16
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.ultraThinMaterial)
            }
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}

/// Unified section header with icon and title
struct SectionHeader: View {
    let icon: String
    let title: String
    var iconColor: Color = .accentColor

    var body: some View {
        Label {
            Text(title)
                .font(.headline)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
        }
    }
}

// MARK: - Main Settings View

/// Main settings window with tab-based layout matching macOS system preferences style
struct MainSettingsView: View {
    @ObservedObject var mountManager: MountManager
    @ObservedObject var networkMonitor: NetworkMonitorService
    @EnvironmentObject var settings: AppSettings

    @State private var selectedTab = 0
    @State private var showAddSheet = false
    @State private var editingMount: MountPoint? = nil
    @State private var showConnectionTest = false
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    var body: some View {
        TabView(selection: $selectedTab) {
            // Tab 1: Mount Points
            MountsTabView(mountManager: mountManager, showAddSheet: $showAddSheet, editingMount: $editingMount)
                .tabItem { Label("掛載點", systemImage: "externaldrive.connected.to.line.below") }
                .tag(0)

            // Tab 2: System Services
            ServicesTabView(mountManager: mountManager, networkMonitor: networkMonitor)
                .tabItem { Label("系統服務", systemImage: "gearshape.2") }
                .tag(1)

            // Tab 3: Log Viewer
            LogViewerTab(mountManager: mountManager)
                .tabItem { Label("日誌", systemImage: "doc.text") }
                .tag(2)
                
            // Tab 4: Downloads
            DownloadManagerView()
                .tabItem { Label("下載", systemImage: "arrow.down.circle") }
                .tag(3)

            // Tab 5: Preferences
            PreferencesTabView(mountManager: mountManager)
                .tabItem { Label("偏好設定", systemImage: "slider.horizontal.3") }
                .tag(4)
        }
        .frame(minWidth: 760, minHeight: 540)
        .sheet(isPresented: $showAddSheet) {
            AddMountSheet(mountManager: mountManager, editingMount: editingMount) { success, message in
                showAddSheet = false
                editingMount = nil
                if let msg = message {
                    alertTitle = success ? "操作成功" : "發生錯誤"
                    alertMessage = msg
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        NSApp.activate(ignoringOtherApps: true)
                        showAlert = true
                    }
                }
            }
        }
        .onChange(of: showAddSheet) { isPresented in
            // Clear the editing mount state when dismissing the sheet via Cancel or swipe
            if !isPresented {
                editingMount = nil
            }
        }
        .sheet(isPresented: $showConnectionTest) {
            ConnectionTestView(mountManager: mountManager)
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("確定") {
                DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
            }
        } message: {
            Text(alertMessage)
        }
        .onAppear {
            mountManager.refresh()
        }
    }
}

// MARK: - Tab 1: Mounts

struct MountsTabView: View {
    @ObservedObject var mountManager: MountManager
    @Binding var showAddSheet: Bool
    @Binding var editingMount: MountPoint?

    var body: some View {
        VStack(spacing: 0) {
            // Header toolbar
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("掛載點管理")
                    .font(.title2.bold())

                Spacer()

                HStack(spacing: 6) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Label("新增", systemImage: "plus")
                    }
                    .help("新增掛載點")
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            if mountManager.mounts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(mountManager.mounts) { mount in
                            let status = mountManager.statuses[mount.name] ?? MountStatus(name: mount.name)
                            MountCard(
                                mount: mount,
                                status: status,
                                mountManager: mountManager,
                                showAddSheet: $showAddSheet,
                                editingMount: $editingMount
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, options: .repeating)
            Text("尚未設定任何掛載點")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("點擊下方按鈕新增您的第一個 SMB 掛載點")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Button {
                showAddSheet = true
            } label: {
                Label("新增掛載點", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Mount Card

struct MountCard: View {
    let mount: MountPoint
    let status: MountStatus
    @ObservedObject var mountManager: MountManager
    @Binding var showAddSheet: Bool
    @Binding var editingMount: MountPoint?

    @State private var isExpanded = false
    @State private var showDeleteConfirm = false
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    var statusColor: Color {
        if status.isMounted && status.isResponsive { return .green }
        if status.isMounted { return .orange }
        if status.isPaused { return .orange }
        if status.isEngineRunning { return .yellow }
        return .red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row — entire area is tappable to expand/collapse
            HStack(spacing: 12) {
                // Status indicator with pulse animation
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: status.overallIcon)
                        .foregroundStyle(statusColor)
                        .font(.system(size: 18, weight: .medium))
                        .symbolEffect(.pulse, options: .repeating, isActive: status.isEngineRunning && !status.isMounted)
                }
                .id(mount.name)

                VStack(alignment: .leading, spacing: 3) {
                    Text(mount.name)
                        .font(.system(.headline, design: .monospaced))
                        .fontWeight(.semibold)
                    HStack(spacing: 10) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 7, height: 7)
                            Text(status.statusText)
                                .font(.caption)
                                .foregroundStyle(statusColor)
                        }
                        if status.isEngineRunning {
                            Text("運行中")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                        if status.isEngineRunning || status.isMounted {
                            HStack(spacing: 4) {
                                Image(systemName: "timer")
                                    .font(.caption2)
                                Text(status.latencyText)
                                    .font(.system(.caption2, design: .monospaced))
                            }
                            .foregroundStyle(status.latencyColor)
                        }
                    }
                }

                Spacer()

                // Quick actions
                HStack(spacing: 6) {
                    if status.isMounted {
                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: mount.mountPath))
                        } label: {
                            Image(systemName: "folder")
                                .font(.body)
                        }
                        .help("在 Finder 中打開")
                        .buttonStyle(.borderless)
                    }

                    Button {
                        let ok = mountManager.restartEngine(name: mount.name)
                        alertTitle = ok ? "成功" : "失敗"
                        alertMessage = ok ? "已重新連線 '\(mount.name)'" : "重新連線失敗"
                        showAlert = true
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.body)
                    }
                    .help("重新連線")
                    .buttonStyle(.borderless)

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
            }
            .padding(14)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(duration: 0.35, bounce: 0.2)) {
                    isExpanded.toggle()
                }
            }

            // Expandable detail section
            if isExpanded {
                Divider()
                    .padding(.horizontal, 14)

                VStack(alignment: .leading, spacing: 10) {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                        mountDetailRow("伺服器", mount.servers.joined(separator: ", "))
                        mountDetailRow("共享名稱", mount.shareName)
                        mountDetailRow("帳號", mount.username)
                        mountDetailRow("密碼儲存", mount.useKeychain ? "🔒 Keychain" : "⚠️ 明文")
                        GridRow {
                            Text("網路限制")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 72, alignment: .trailing)
                                .gridColumnAlignment(.trailing)
                            
                            if mount.allowedSSIDs.isEmpty {
                                Text("無限制")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.leading)
                            } else {
                                FlowLayout(spacing: 4) {
                                    ForEach(mount.allowedSSIDs, id: \.self) { ssid in
                                        HStack(spacing: 3) {
                                            Image(systemName: ssid == "乙太網路" ? "network" : "wifi")
                                                .font(.caption2)
                                            Text(ssid)
                                        }
                                        .font(.caption)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.1), in: Capsule())
                                    }
                                }
                                .gridColumnAlignment(.leading)
                                .padding(.vertical, 2)
                            }
                        }
                        if !mount.mountOptions.isEmpty {
                            mountDetailRow("掛載選項", mount.mountOptions)
                        }
                        mountDetailRow("掛載路徑", mount.mountPath)
                    }

                    if status.isMounted, let frac = status.capacityUsedFraction, let desc = status.capacityDescription {
                        HStack(spacing: 14) { // match spacing from Grid
                            Text("儲存空間")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 72, alignment: .trailing)
                            
                            GeometryReader { geo in
                                ZStack(alignment: .center) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color(nsColor: .separatorColor).opacity(0.3))
                                        .frame(height: 6)
                                    HStack(spacing: 0) {
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(frac > 0.9 ? Color.red : Color.accentColor)
                                            .frame(width: geo.size.width * CGFloat(frac), height: 6)
                                        Spacer(minLength: 0)
                                    }
                                }
                            }
                            .frame(height: 6)
                            
                            Text(desc)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }

                    Divider()

                    HStack(spacing: 10) {
                        if mountManager.pausedMounts.contains(mount.name) {
                            Button {
                                let _ = mountManager.restartEngine(name: mount.name)
                            } label: {
                                Label("繼續掛載", systemImage: "play.fill")
                            }
                            .controlSize(.small)
                        } else if status.isMounted {
                            Button {
                                mountManager.pauseMount(name: mount.name)
                            } label: {
                                Label("強制退出", systemImage: "eject")
                            }
                            .controlSize(.small)
                        }

                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: mount.logPath))
                        } label: {
                            Label("檢視日誌", systemImage: "doc.text")
                        }
                        .controlSize(.small)

                        Spacer()

                        Button {
                            editingMount = mount
                            showAddSheet = true
                        } label: {
                            Label("編輯", systemImage: "pencil")
                        }
                        .controlSize(.small)

                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("刪除", systemImage: "trash")
                        }
                        .controlSize(.small)
                    }
                }
                .padding(14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(statusColor.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .primary.opacity(0.08), radius: 4, y: 2)
        .alert(alertTitle, isPresented: $showAlert) {
            Button("確定") {
                DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
            }
        } message: { Text(alertMessage) }
        .confirmationDialog("確認刪除", isPresented: $showDeleteConfirm) {
            Button("永久刪除 '\(mount.name)'", role: .destructive) {
                let _ = mountManager.deleteMount(name: mount.name)
            }
        } message: {
            Text("此操作將停止服務、刪除設定檔與 Keychain 密碼，無法復原。")
        }
    }

    private func mountDetailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .gridColumnAlignment(.leading)
        }
    }
}

// MARK: - Tab 2: System Services

struct ServicesTabView: View {
    @ObservedObject var mountManager: MountManager
    @ObservedObject var networkMonitor: NetworkMonitorService

    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: "gearshape.2")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    Text("系統服務")
                        .font(.title2.bold())
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)

                // Network Status
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(networkMonitor.isConnected ? Color.green.opacity(0.12) : Color.red.opacity(0.12))
                            .frame(width: 44, height: 44)
                        Image(systemName: networkMonitor.isConnected ? "wifi" : "wifi.slash")
                            .font(.title3)
                            .foregroundStyle(networkMonitor.isConnected ? .green : .red)
                            .symbolEffect(.pulse, options: .repeating, value: !networkMonitor.isConnected)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(networkMonitor.isConnected ? "網路已連線" : "網路已斷線")
                            .font(.headline)
                        Text("介面: \(networkMonitor.interfaceDescription)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let date = networkMonitor.lastChangeDate {
                            Text("上次變更: \(date.formatted(.dateTime.hour().minute().second()))")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                }
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .shadow(color: .primary.opacity(0.06), radius: 3, y: 1)
                .padding(.horizontal, 24)

                // Location Services Status
                HStack(spacing: 14) {
                    ZStack {
                        let isAuth = WiFiService.authorizationStatusString == "已授權"
                        Circle()
                            .fill(isAuth ? Color.blue.opacity(0.12) : Color.orange.opacity(0.12))
                            .frame(width: 44, height: 44)
                        Image(systemName: "location.fill")
                            .font(.title3)
                            .foregroundStyle(isAuth ? .blue : .orange)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("定位服務權限")
                            .font(.headline)
                        Text("狀態: \(WiFiService.authorizationStatusString)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("取得當前 Wi-Fi 名稱 (SSID) 需要定位服務權限，否則「網路環境限制」功能將失效。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .shadow(color: .primary.opacity(0.06), radius: 3, y: 1)
                .padding(.horizontal, 24)

                // In-Process Engine Status
                serviceCard(
                    icon: "eye",
                    title: "掛載引擎",
                    description: "應用程式內建的掛載與監控引擎，啟動時自動連線所有掛載點，持續監控健康狀態並自動修復失效連線。",
                    isInstalled: true,
                    isRunning: !mountManager.isPaused
                )

                // Fixer Service
                serviceCard(
                    icon: "wrench.and.screwdriver",
                    title: "系統權限修復服務",
                    description: "系統層級服務，開機時自動修復 /Volumes 目錄權限（chmod 1777, chown root:admin），需管理員授權安裝。",
                    isInstalled: mountManager.systemService.fixerInstalled,
                    isRunning: nil
                )

                // Action buttons
                HStack(spacing: 12) {
                    Button {
                        let ok = LaunchdService.installFixer()
                        mountManager.refresh()
                        alertTitle = ok ? "操作成功" : "操作失敗"
                        alertMessage = ok ? "權限修復服務已安裝！" : "安裝失敗，您可能取消了授權。"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            NSApp.activate(ignoringOtherApps: true)
                            showAlert = true
                        }
                    } label: {
                        Label("安裝權限修復服務", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)

                    Button(role: .destructive) {
                        let ok = LaunchdService.removeFixer()
                        mountManager.refresh()
                        alertTitle = ok ? "操作成功" : "操作失敗"
                        alertMessage = ok ? "權限修復服務已移除。" : "移除失敗，您可能取消了授權。"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            NSApp.activate(ignoringOtherApps: true)
                            showAlert = true
                        }
                    } label: {
                        Label("移除權限修復服務", systemImage: "trash")
                    }

                    Spacer()
                }
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 24)
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("確定") {
                DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
            }
        } message: { Text(alertMessage) }
        .onChange(of: showAlert) { newValue in
            if !newValue {
                DispatchQueue.main.async {
                    NSApp.mainWindow?.makeKeyAndOrderFront(nil)
                }
            }
        }
    }

    private func serviceCard(icon: String, title: String, description: String, isInstalled: Bool, isRunning: Bool?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(isInstalled ? Color.blue.opacity(0.12) : Color.secondary.opacity(0.08))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(isInstalled ? .blue : .secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(title)
                            .font(.headline)
                        Spacer()
                        if let running = isRunning {
                            statusBadge(running ? "運行中" : "已停止", color: running ? .green : .orange)
                        } else {
                            statusBadge(isInstalled ? "已安裝" : "未安裝", color: isInstalled ? .green : .red)
                        }
                    }
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .shadow(color: .primary.opacity(0.06), radius: 3, y: 1)
        .padding(.horizontal, 24)
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.08), in: Capsule())
    }
}

// MARK: - Tab 3: Log Viewer

struct LogViewerTab: View {
    @ObservedObject var mountManager: MountManager
    @State private var selectedLog = ""
    @State private var logContent = ""
    @State private var searchText = ""
    @State private var autoScroll = true
    @State private var hasInitialized = false

    private var logChoices: [(id: String, label: String)] {
        var choices: [(String, String)] = []
        for mount in mountManager.mounts {
            choices.append((mount.name, "📁 \(mount.name)"))
        }
        if choices.isEmpty {
            choices.append(("none", "無"))
        }
        return choices
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                Picker("日誌來源", selection: $selectedLog) {
                    ForEach(logChoices, id: \.id) { choice in
                        Text(choice.label).tag(choice.id)
                    }
                }
                .frame(width: 200)
                .onChange(of: selectedLog) { _ in refreshLog() }

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("搜尋…", text: $searchText)
                        .textFieldStyle(.plain)
                        .frame(width: 140)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

                Toggle("自動捲動", isOn: $autoScroll)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                Button {
                    refreshLog()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("重新載入")
                .buttonStyle(.borderless)

                Button {
                    let path = selectedLog == "monitor" ? "\(NSHomeDirectory())/Library/Logs/mount_monitor.log" : "\(NSHomeDirectory())/Library/Logs/mount_\(selectedLog).log"
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .help("在外部開啟")
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Log content
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let lines = filteredLines
                        ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                            LogLineView(line: line, lineNumber: idx + 1, searchText: searchText)
                                .id(idx)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: logContent) { _ in
                    if autoScroll {
                        let count = filteredLines.count
                        if count > 0 {
                            proxy.scrollTo(count - 1, anchor: .bottom)
                        }
                    }
                }
            }
            .background(.regularMaterial)
            .font(.system(.caption, design: .monospaced))
        }
        .onAppear {
            if !hasInitialized {
                hasInitialized = true
                // Auto-select first mount instead of old "monitor"
                if let first = logChoices.first {
                    selectedLog = first.id
                }
            }
            refreshLog()
        }
    }

    private var filteredLines: [String] {
        let lines = logContent.components(separatedBy: "\n")
        if searchText.isEmpty { return lines }
        return lines.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    private func refreshLog() {
        if selectedLog == "none" {
            logContent = "無"
        } else {
            logContent = mountManager.readLog(for: selectedLog, lines: 200)
        }
    }
}

struct LogLineView: View {
    let line: String
    let lineNumber: Int
    let searchText: String

    var lineColor: Color {
        if line.contains("[SUCCESS]") { return .green }
        if line.contains("[ERROR]") || line.contains("[CRITICAL]") { return .red }
        if line.contains("[WARN]") { return .orange }
        if line.contains("[INFO]") { return .primary.opacity(0.8) }
        return .secondary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("\(lineNumber)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .trailing)
                .padding(.trailing, 8)

            Text(line)
                .foregroundStyle(lineColor)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 1.5)
        .padding(.horizontal, 6)
        .background(
            !searchText.isEmpty && line.localizedCaseInsensitiveContains(searchText)
                ? Color.yellow.opacity(0.12)
                : Color.clear
        )
    }
}

// MARK: - Tab 4: Preferences

struct PreferencesTabView: View {
    @ObservedObject var mountManager: MountManager
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section("一般") {
                Toggle("開機時自動啟動", isOn: $settings.launchAtLogin)
                Toggle("啟動時自動檢查更新", isOn: $settings.autoCheckUpdates)
                Toggle("在選單列顯示連線數量", isOn: $settings.showMountCount)
            }

            Section("通知") {
                Toggle("顯示系统通知", isOn: $settings.showNotifications)
            }

            Section("資料管理") {
                HStack(spacing: 20) {
                    Button("匯出設定...") {
                        exportSettings()
                    }
                    Button("匯入設定...") {
                        importSettings()
                    }
                }
            }

            Section("關於") {
                HStack {
                    Text("版本")
                    Spacer()
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
                    Text(version)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("作者")
                    Spacer()
                    Text("林久翔")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("檢查更新...") {
                        UpdateService.shared.checkForUpdates(manual: true)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.blue)
                }
                HStack {
                    Spacer()
                    Text("© 2026 SMB 掛載管理器")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    // Pass environment mountmanager here or use notification.
    @Environment(\.openWindow) var openWindow

    private func exportSettings() {
        guard let tmpURL = mountManager.exportMounts() else {
            let alert = NSAlert()
            alert.messageText = "匯出失敗"
            alert.informativeText = "無法產生設定檔。"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            DispatchQueue.main.async { NSApp.mainWindow?.makeKeyAndOrderFront(nil) }
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        let dateStr = formatter.string(from: Date()).components(separatedBy: "T").first ?? ""
        panel.nameFieldStringValue = "SMBMountManager_Profile_\(dateStr).json"
        
        NSApp.activate(ignoringOtherApps: true)
        let result = panel.runModal()
        if result == .OK, let url = panel.url {
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                try FileManager.default.moveItem(at: tmpURL, to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                let alert = NSAlert()
                alert.messageText = "儲存失敗"
                alert.informativeText = error.localizedDescription
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
                DispatchQueue.main.async { NSApp.mainWindow?.makeKeyAndOrderFront(nil) }
            }
        } else {
            DispatchQueue.main.async { NSApp.mainWindow?.makeKeyAndOrderFront(nil) }
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        NSApp.activate(ignoringOtherApps: true)
        let result = panel.runModal()
        if result == .OK, let url = panel.url {
            let stats = mountManager.importMounts(from: url)
            let alert = NSAlert()
            if let error = stats.error {
                alert.messageText = "匯入失敗"
                alert.informativeText = error
                alert.alertStyle = .critical
            } else {
                alert.messageText = "匯入完成"
                alert.informativeText = "成功載入 \(stats.success) 個掛載點。\n跳過 \(stats.skipped) 個已存在的掛載點。"
            }
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            DispatchQueue.main.async { NSApp.mainWindow?.makeKeyAndOrderFront(nil) }
        } else {
            DispatchQueue.main.async { NSApp.mainWindow?.makeKeyAndOrderFront(nil) }
        }
    }
}
