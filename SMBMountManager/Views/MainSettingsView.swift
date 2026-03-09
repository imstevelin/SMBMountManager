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

            // Tab 2: Downloads
            DownloadManagerView()
                .tabItem { Label("下載任務", systemImage: "arrow.down.circle") }
                .tag(1)
                
            // Tab 3: Uploads
            UploadManagerView()
                .tabItem { Label("上傳任務", systemImage: "arrow.up.circle") }
                .tag(2)

            // Tab 4: Log Viewer
            LogViewerTab(mountManager: mountManager)
                .tabItem { Label("日誌", systemImage: "doc.text") }
                .tag(3)

            // Tab 5: Preferences
            PreferencesTabView(mountManager: mountManager)
                .tabItem { Label("設定", systemImage: "slider.horizontal.3") }
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
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenDownloadsTab"))) { _ in
            selectedTab = 1
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenUploadsTab"))) { _ in
            selectedTab = 2
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenMountsTab"))) { _ in
            selectedTab = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenMainWindow"))) { _ in
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "settings" || $0.title == "SMB 掛載管理器" }) {
                window.makeKeyAndOrderFront(nil)
            }
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
            
            if !mountManager.systemService.fixerInstalled {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("使用前請先安裝「權限修復服務」，以確保掛載功能正常運作。")
                        .font(.callout)
                    Spacer()
                    Button("安裝服務") {
                        let _ = LaunchdService.installFixer()
                        mountManager.refresh()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
            
            let isAuth = WiFiService.authorizationStatusString == "已授權"
            if !isAuth {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("使用前請先授予「定位服務權限」，以取得當前 Wi-Fi 名稱，否則「網路環境限制」功能將失效。")
                        .font(.callout)
                    Spacer()
                    Button("開啟設定") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }

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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(statusColor.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: statusColor.opacity(0.08), radius: 4, y: 2)
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



// MARK: - Tab 3: Log Viewer

struct LogViewerTab: View {
    @ObservedObject var mountManager: MountManager
    @State private var logContent = ""
    @State private var searchText = ""
    @State private var autoScroll = true
    @State private var hasInitialized = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                Text("應用程式全域日誌")
                    .font(.headline)
                    .foregroundStyle(.secondary)

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
                    let path = AppLogger.shared.logPath
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
        logContent = AppLogger.shared.readLogs()
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
    @State private var showRemoveConfirm = false
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    var body: some View {
        Form {
            Section("一般") {
                Toggle("開機時自動啟動", isOn: $settings.launchAtLogin)
                Toggle("啟動時自動檢查並更新", isOn: $settings.autoCheckUpdates)
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
                    Button("移除權限修復服務...") {
                        showRemoveConfirm = true
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
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
        .confirmationDialog("危險操作", isPresented: $showRemoveConfirm) {
            Button("確定移除", role: .destructive) {
                let ok = LaunchdService.removeFixer()
                mountManager.refresh()
                alertTitle = ok ? "操作成功" : "操作失敗"
                alertMessage = ok ? "權限修復服務已移除。" : "移除失敗，您可能取消了授權。"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSApp.activate(ignoringOtherApps: true)
                    showAlert = true
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("您確定要移除系統權限修復服務嗎？這可能會導致未來掛載點發生權限異常錯誤。")
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
