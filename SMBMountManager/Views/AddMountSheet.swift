import SwiftUI

/// Sheet view for adding a new SMB mount point with pre-validation
struct AddMountSheet: View {
    @ObservedObject var mountManager: MountManager
    var editingMount: MountPoint? = nil
    let onComplete: (_ success: Bool, _ message: String?) -> Void

    @Environment(\.dismiss) private var dismiss

    // State variables
    @State private var name = ""
    @State private var serversText = ""
    @State private var shareName = ""
    @State private var shareMatchesName = true
    @State private var username = ""
    @State private var password = ""
    @State private var useKeychain = true
    @State private var showInSidebar = true
    @State private var createDesktopShortcut = false
    @State private var testingServer = false
    @State private var connectionSuccess = false
    @State private var errorMessage: String?
    @State private var showNoWifiAlert = false
    @State private var optNobrowse = false
    @State private var optNoowners = false
    @State private var optSoft = false
    @State private var customOptions = ""
    @State private var nameError = ""
    @State private var allowedSSIDs: [String] = []
    @State private var ssidInput = ""

    // Validation state
    @State private var validationPhase: ValidationPhase = .editing
    @State private var validationResult: MountManager.ValidationResult?
    @State private var isValidating = false

    enum ValidationPhase {
        case editing        // User is filling out the form
        case validating     // Connection test in progress
        case validated      // Test done, showing results
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar
            Divider()

            // Content depends on phase
            switch validationPhase {
            case .editing:
                formContent
            case .validating:
                validatingContent
            case .validated:
                validatedContent
            }

            Divider()

            // Footer buttons
            footerButtons
        }
        .padding(24)
        .frame(width: 580, height: 680)
        .onAppear {
            if let edit = editingMount {
                name = edit.name
                serversText = edit.servers.joined(separator: "\n")
                shareName = edit.shareName
                username = edit.username
                if let pass = KeychainService.getPassword(forMount: edit.name, username: edit.username) {
                    password = pass
                }
                useKeychain = edit.useKeychain
                showInSidebar = edit.showInSidebar
                createDesktopShortcut = edit.createDesktopShortcut
                allowedSSIDs = edit.allowedSSIDs
                
                let opts = edit.mountOptions.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                optNobrowse = opts.contains("nobrowse")
                optNoowners = opts.contains("noowners")
                optSoft = opts.contains("soft")
                
                let knownOpts = Set(["nobrowse", "noowners", "soft"])
                customOptions = opts.filter { !knownOpts.contains($0) && !$0.isEmpty }.joined(separator: ",")
            }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(headerColor.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: headerIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(headerColor)
                    .symbolEffect(.pulse, options: .repeating, value: validationPhase == .validating)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(editingMount == nil ? "新增掛載點" : "編輯掛載點")
                    .font(.title2.bold())
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Header Properties

    private var headerIcon: String {
        switch validationPhase {
        case .editing: return "plus.circle.fill"
        case .validating: return "arrow.triangle.2.circlepath"
        case .validated:
            if let result = validationResult {
                return result.canProceed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            }
            return "checkmark.circle.fill"
        }
    }

    private var headerColor: Color {
        switch validationPhase {
        case .editing: return .blue
        case .validating: return .orange
        case .validated:
            return (validationResult?.canProceed ?? false) ? .green : .red
        }
    }

    private var headerTitle: String {
        switch validationPhase {
        case .editing: return "新增 SMB 掛載點"
        case .validating: return "正在驗證 …"
        case .validated:
            return (validationResult?.canProceed ?? false) ? "驗證通過" : "驗證失敗"
        }
    }

    private var headerSubtitle: String {
        switch validationPhase {
        case .editing: return "填寫伺服器與帳號資訊"
        case .validating: return "測試連線中，請稍候"
        case .validated:
            return (validationResult?.canProceed ?? false) ? "所有檢查通過" : "請檢查設定後重試"
        }
    }

    // MARK: - Form Content (Phase: editing)

    private var formContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Section 1: Basic Info
                formSection(icon: "server.rack", title: "基本資訊") {
                    VStack(alignment: .leading, spacing: 14) {
                        FormField(title: "掛載點名稱", hint: "僅限英數、底線、連字號") {
                            TextField("例如: nas_share", text: $name)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: name) { newValue in
                                    validateName(newValue)
                                    if shareMatchesName { shareName = newValue }
                                }
                            if !nameError.isEmpty {
                                Label(nameError, systemImage: "exclamationmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }

                        FormField(title: "SMB 伺服器位址", hint: "多個備援伺服器請換行") {
                            TextEditor(text: $serversText)
                                .font(.system(.body, design: .monospaced))
                                .frame(height: 56)
                                .padding(4)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }

                        Toggle("SMB 共享名稱與掛載名稱相同", isOn: $shareMatchesName)
                            .onChange(of: shareMatchesName) { matched in
                                if matched { shareName = name }
                            }

                        if !shareMatchesName {
                            FormField(title: "SMB 共享名稱", hint: "伺服器上的實際共享名稱") {
                                TextField("例如: SharedFolder", text: $shareName)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                }

                // Section 2: Credentials
                formSection(icon: "person.badge.key", title: "帳號設定") {
                    VStack(alignment: .leading, spacing: 14) {
                        FormField(title: "登入帳號") {
                            TextField("SMB 使用者名稱", text: $username)
                                .textFieldStyle(.roundedBorder)
                        }

                        FormField(title: "登入密碼") {
                            SecureField("密碼", text: $password)
                                .textFieldStyle(.roundedBorder)
                        }

                        Picker("密碼儲存方式", selection: $useKeychain) {
                            Label("Keychain (最安全)", systemImage: "lock.shield").tag(true)
                            Label("明文儲存 (不建議)", systemImage: "exclamationmark.triangle").tag(false)
                        }
                        .pickerStyle(.radioGroup)
                    }
                }

                // Section 3: Display Settings
                formSection(icon: "photo.tv", title: "顯示設定") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("顯示在 Finder 側邊欄「位置」與桌面上", isOn: $showInSidebar)
                            .help("關閉此選項會自動加入 nobrowse 掛載參數，隱藏該掛載點。")
                            .onChange(of: showInSidebar) { newValue in
                                if !newValue { optNobrowse = true }
                                else { optNobrowse = false }
                            }
                        if showInSidebar {
                           Toggle("掛載成功時自動在桌面建立捷徑", isOn: $createDesktopShortcut)
                        }
                    }
                }

                // Section 4: SSID Restriction
                formSection(icon: "wifi", title: "網路環境限制（選填）") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("只在指定的 Wi-Fi 網路下嘗試掛載，留空表示不限制")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "magnifyingglass")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                TextField("SSID 名稱", text: $ssidInput)
                                    .textFieldStyle(.plain)
                                    .onSubmit {
                                        addSSID()
                                    }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

                            Button {
                                addSSID()
                            } label: {
                                Image(systemName: "plus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .disabled(ssidInput.trimmingCharacters(in: .whitespaces).isEmpty)

                            Button {
                                if let ssid = WiFiService.currentSSID() {
                                    if !allowedSSIDs.contains(ssid) {
                                        allowedSSIDs.append(ssid)
                                    }
                                } else {
                                    showNoWifiAlert = true
                                }
                            } label: {
                                Label("偵測當前 Wi-Fi", systemImage: "antenna.radiowaves.left.and.right")
                            }
                            .controlSize(.small)
                            .alert("無法取得網路名稱", isPresented: $showNoWifiAlert) {
                                Button("確定", role: .cancel) { }
                            } message: {
                                Text("目前未連線到 Wi-Fi 或未授予「定位服務」權限，因此無法偵測。")
                            }

                            Button {
                                if !allowedSSIDs.contains("乙太網路") {
                                    allowedSSIDs.append("乙太網路")
                                }
                            } label: {
                                Label("加入乙太網路", systemImage: "network")
                            }
                            .controlSize(.small)
                        }

                        if !allowedSSIDs.isEmpty {
                            FlowLayout(spacing: 6) {
                                ForEach(allowedSSIDs, id: \.self) { ssid in
                                    HStack(spacing: 4) {
                                        Image(systemName: ssid == "乙太網路" ? "network" : "wifi")
                                            .font(.caption2)
                                        Text(ssid)
                                            .font(.caption)
                                        Button {
                                            allowedSSIDs.removeAll { $0 == ssid }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.caption2)
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.blue.opacity(0.1), in: Capsule())
                                }
                            }
                        }
                    }
                }

                // Section 5: Mount Options
                formSection(icon: "slider.horizontal.3", title: "進階掛載選項 (可略過)") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("nobrowse — 不在桌面或側邊欄顯示", isOn: $optNobrowse)
                            .onChange(of: optNobrowse) { newValue in
                                if newValue { showInSidebar = false }
                                else { showInSidebar = true }
                            }
                        Toggle("noowners — 忽略檔案擁有者", isOn: $optNoowners)
                        Toggle("soft — 允許中斷連線", isOn: $optSoft)

                        FormField(title: "其他選項", hint: "用逗號分隔") {
                            TextField("例如: dir_mode=0755", text: $customOptions)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Validating Content (Phase: validating)

    private var validatingContent: some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            VStack(spacing: 6) {
                Text("正在測試伺服器連線與帳號密碼…")
                    .font(.headline)
                Text("這可能需要數秒鐘")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Validated Content (Phase: validated)

    private var validatedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let result = validationResult {
                    // Test Results
                    formSection(icon: "checkmark.shield", title: "驗證結果") {
                        VStack(alignment: .leading, spacing: 10) {
                            ValidationRow(
                                icon: result.serverReachable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                color: result.serverReachable ? .green : .orange,
                                text: result.serverReachable ? "伺服器可連線 (\(result.reachableServer))" : "伺服器 ICMP 無回應 (可能被防火牆阻擋)"
                            )

                            ValidationRow(
                                icon: result.smbPortOpen ? "checkmark.circle.fill" : "xmark.circle.fill",
                                color: result.smbPortOpen ? .green : .red,
                                text: result.smbPortOpen ? "SMB 連接埠 (445) 開放" : "SMB 連接埠 (445) 無法連線"
                            )

                            if result.smbPortOpen {
                                ValidationRow(
                                    icon: result.mountTestPassed ? "checkmark.circle.fill" : "xmark.circle.fill",
                                    color: result.mountTestPassed ? .green : .red,
                                    text: result.mountTestPassed ? "掛載測試成功（帳號密碼正確）" : "掛載測試失敗"
                                )
                            }

                            if !result.errorDetail.isEmpty {
                                Divider()
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "info.circle")
                                        .foregroundStyle(.secondary)
                                    Text(result.errorDetail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }

                    // Summary
                    if result.canProceed {
                        formSection(icon: "checkmark.seal.fill", title: "驗證摘要") {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundStyle(.green)
                                    .font(.title3)
                                Text("所有檢查通過！點擊「建立掛載點」將正式建立並啟用服務。")
                                    .font(.callout)
                            }
                        }
                    } else {
                        formSection(icon: "exclamationmark.triangle.fill", title: "驗證摘要") {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 10) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.red)
                                        .font(.title3)
                                    Text("連線測試未完全通過")
                                        .font(.callout.bold())
                                }
                                Text("建議返回修改設定後重試。如果您確定設定正確，也可以選擇「強制建立」。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    // Config Summary
                    formSection(icon: "list.bullet.clipboard", title: "設定摘要") {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                            configGridRow("名稱", name)
                            configGridRow("伺服器", parsedServers.joined(separator: ", "))
                            configGridRow("共享名稱", shareName)
                            configGridRow("帳號", username)
                            configGridRow("密碼儲存", useKeychain ? "Keychain" : "明文")
                            configGridRow("顯示在側邊欄", showInSidebar ? "是" : "否")
                            configGridRow("建立桌面捷徑", createDesktopShortcut ? "是" : "否")
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Footer Buttons

    private var footerButtons: some View {
        HStack {
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Spacer()

            switch validationPhase {
            case .editing:
                Button {
                    startValidation()
                } label: {
                    Text("測試連線")
                        .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isFormValid)

            case .validating:
                EmptyView()

            case .validated:
                Button("返回修改") {
                    validationPhase = .editing
                    validationResult = nil
                }

                if let result = validationResult, result.canProceed {
                    Button {
                        createMount()
                    } label: {
                        Text(editingMount == nil ? "儲存並連線" : "儲存設定並重連")
                            .frame(minWidth: 100)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button {
                        createMount()
                    } label: {
                        Text("強制建立")
                            .frame(minWidth: 80)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Helpers

    private func formSection<Content: View>(icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(icon: icon, title: title)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
                )
        }
    }

    private func configGridRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .gridColumnAlignment(.leading)
        }
    }

    // MARK: - Validation

    private var isFormValid: Bool {
        !name.isEmpty && nameError.isEmpty
        && !serversText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !shareName.isEmpty && !username.isEmpty && !password.isEmpty
    }

    private var parsedServers: [String] {
        serversText
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func validateName(_ value: String) {
        if value.isEmpty { nameError = ""; return }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        if !value.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            nameError = "只能包含英數、底線和連字號"
        } else if value != editingMount?.name && mountManager.mounts.contains(where: { $0.name == value }) {
            nameError = "此名稱已被使用"
        } else {
            nameError = ""
        }
    }

    // MARK: - Actions

    private func startValidation() {
        validationPhase = .validating
        isValidating = true

        let servers = parsedServers
        let share = shareName
        let user = username
        let pass = password

        Task.detached {
            let result = mountManager.preValidateMount(
                servers: servers,
                shareName: share,
                username: user,
                password: pass
            )
            await MainActor.run {
                validationResult = result
                validationPhase = .validated
                isValidating = false
            }
        }
    }

    private func createMount() {
        var options: [String] = []
        if optNobrowse { options.append("nobrowse") }
        if optNoowners { options.append("noowners") }
        if optSoft { options.append("soft") }
        if !customOptions.trimmingCharacters(in: .whitespaces).isEmpty {
            options.append(contentsOf: customOptions.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }

        if let oldName = editingMount?.name {
            if oldName != name && mountManager.mounts.contains(where: { $0.name == name }) {
                onComplete(false, "掛載點 '\(name)' 的設定已存在。")
                return
            }
            let _ = mountManager.deleteMount(name: oldName)
        }

        let result = mountManager.createMount(
            name: name,
            servers: parsedServers,
            shareName: shareName,
            username: username,
            password: password,
            useKeychain: useKeychain,
            mountOptions: options.joined(separator: ","),
            showInSidebar: showInSidebar,
            createDesktopShortcut: showInSidebar ? createDesktopShortcut : false,
            allowedSSIDs: allowedSSIDs
        )

        if result.success {
            let msg = editingMount == nil ? "已成功建立並啟用掛載點 '\(name)'！\n系統將在背景自動進行掛載。" : "掛載點 '\(name)' 設定已更新！\n系統將重新進行連線。"
            onComplete(true, msg)
        } else {
            onComplete(false, result.error)
        }
    }

    private func addSSID() {
        let ssid = ssidInput.trimmingCharacters(in: .whitespaces)
        guard !ssid.isEmpty, !allowedSSIDs.contains(ssid) else { return }
        allowedSSIDs.append(ssid)
        ssidInput = ""
    }
}

// MARK: - Validation Result Row

struct ValidationRow: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            Text(text)
                .font(.callout)
        }
    }
}

// MARK: - Reusable Form Field

struct FormField<Content: View>: View {
    let title: String
    var hint: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.callout.weight(.medium))
                if let hint = hint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            content()
        }
    }
}
