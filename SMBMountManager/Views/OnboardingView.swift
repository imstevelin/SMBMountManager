import SwiftUI

struct OnboardingView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var appState: AppStateManager
    @State private var currentStep = 0
    @State private var isFixerInstalled = LaunchdService.fixerInstalled
    @State private var isLocationAuthorized = false

    private let totalSteps = 6

    var body: some View {
        VStack(spacing: 0) {
            // Content
            Group {
                switch currentStep {
                case 0: pageWelcome
                case 1: pageAuthorization
                case 2: pageIcons
                case 3: pageMainUI
                case 4: pageFinderExtension
                case 5: pageAllSet
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.3), value: currentStep)

            // Bottom bar
            VStack(spacing: 14) {
                // Page dots
                HStack(spacing: 8) {
                    ForEach(0..<totalSteps, id: \.self) { i in
                        Circle()
                            .fill(currentStep == i ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                            .animation(.easeInOut(duration: 0.25), value: currentStep)
                    }
                }

                // Navigation
                HStack {
                    if currentStep > 0 {
                        Button(action: { withAnimation { currentStep -= 1 } }) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 12, weight: .medium))
                                Text("上一頁")
                            }
                        }
                        .controlSize(.large)
                    } else {
                        Spacer().frame(width: 80)
                    }

                    Spacer()

                    let isBlocked = (currentStep == 1 && !isFixerInstalled)
                    let isLastPage = currentStep == totalSteps - 1
                    Button(action: {
                        withAnimation {
                            if !isLastPage {
                                currentStep += 1
                            } else {
                                appState.completeOnboarding()
                                for window in NSApp.windows where window.identifier?.rawValue == "onboarding" { window.close() }
                                openWindow(id: "settings")
                            }
                        }
                    }) {
                        HStack(spacing: 4) {
                            Text(isLastPage ? "開始使用" : "下一頁")
                            if !isLastPage {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(isBlocked ? .gray : (isLastPage ? .green : .accentColor))
                    .disabled(isBlocked)
                }
                .padding(.horizontal, 32)
            }
            .padding(.bottom, 24)
        }
        .onAppear {
            let status = WiFiService.authorizationStatusString
            if status == "已授權" || status == "使用中授權" { isLocationAuthorized = true }
        }
    }

    // ────────────────────────────────────────
    // MARK: - Page 0 · 歡迎
    // ────────────────────────────────────────
    private var pageWelcome: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)

            Text("SMB 掛載管理器 🚀")
                .font(.system(size: 28, weight: .bold))

            Text("歡迎使用！從此告別網路硬碟斷線的煩惱 \n專為 macOS 打造，提供良好的自動掛載與背景傳輸體驗 ✨")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .frame(maxWidth: 420)

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    // ────────────────────────────────────────
    // MARK: - Page 1 · 授權
    // ────────────────────────────────────────
    private var pageAuthorization: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "lock.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            Text("授權與前置作業 🔐")
                .font(.system(size: 24, weight: .bold))

            Text("為了確保完整且穩定的體驗，請完成以下設定。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            // Permission cards using app's glass style
            VStack(spacing: 10) {
                // Fixer
                HStack(spacing: 12) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 20))
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("權限修復服務（必要）🛠️")
                            .font(.system(size: 13, weight: .semibold))
                        Text("確保目錄的權限正確可以順利掛載網路硬碟。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(action: {
                        let _ = LaunchdService.installFixer()
                        isFixerInstalled = LaunchdService.fixerInstalled
                    }) {
                        Text(isFixerInstalled ? "已完成 ✓" : "開始安裝")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isFixerInstalled ? .gray : .red)
                    .controlSize(.small)
                    .disabled(isFixerInstalled)
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isFixerInstalled ? Color.green.opacity(0.5) : Color.orange.opacity(0.5), lineWidth: 1)
                )

                // Location
                HStack(spacing: 12) {
                    Image(systemName: "location.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 20))
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("定位服務授權（建議）📍")
                            .font(.system(size: 13, weight: .semibold))
                        Text("允許讀取 Wi-Fi 名稱，實現智慧掛載與退出。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(action: {
                        WiFiService.requestPermission()
                        isLocationAuthorized = true
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        Text(isLocationAuthorized ? "已完成 ✓" : "前往授權")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isLocationAuthorized ? .gray : .orange)
                    .controlSize(.small)
                    .disabled(isLocationAuthorized)
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isLocationAuthorized ? Color.green.opacity(0.5) : Color.orange.opacity(0.5), lineWidth: 1)
                )
            }
            .frame(maxWidth: 500)

            if !isFixerInstalled {
                Label("必須完成「權限修復服務」安裝才能繼續", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    // ────────────────────────────────────────
    // MARK: - Page 2 · 圖示與選單列
    // ────────────────────────────────────────
    private var pageIcons: some View {
        VStack(spacing: 18) {
            Spacer()

            Text("圖示與選單列 🪟")
                .font(.system(size: 24, weight: .bold))

            Text("程式將常駐於MacOS的選單列，以下為不同狀態的圖示 💡")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            // Icon cards
            HStack(spacing: 16) {
                iconCard(label: "一般狀態", assetName: "選單圖示-一般樣式", fallback: "externaldrive.connected.to.line.below")
                iconCard(label: "傳輸中", assetName: "選單圖示-傳輸中", fallback: "arrow.up.arrow.down.circle.fill")
            }

            // Menu preview
            if let img = NSImage(named: NSImage.Name("選單樣式展示")) {
                VStack(spacing: 6) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 250) // Increased for better visibility
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text("選單列展開樣式")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    private func iconCard(label: String, assetName: String, fallback: String) -> some View {
        VStack(spacing: 8) {
            if let img = NSImage(named: NSImage.Name(assetName)) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 28)
                    .colorInvert(colorScheme == .light)
            } else {
                Image(systemName: fallback)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: 100, height: 70)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    // ────────────────────────────────────────
    // MARK: - Page 3 · 主程式介面
    // ────────────────────────────────────────
    private var pageMainUI: some View {
        VStack(spacing: 14) {
            Text("主程式介面 💻")
                .font(.system(size: 24, weight: .bold))

            Text("在這裡新增、管理您的 SMB 伺服器，並監看傳輸進度 👀")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            if let nsImage = NSImage(named: NSImage.Name("主介面展示-掛載點")) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 620, maxHeight: 400)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // ────────────────────────────────────────
    // MARK: - Page 4 · Finder 右鍵傳輸
    // ────────────────────────────────────────
    private var pageFinderExtension: some View {
        HStack(spacing: 24) {
            // Left: image
            if let nsImage = NSImage(named: NSImage.Name("右鍵選單展示-new-1")) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260, maxHeight: 380)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
            }

            // Right: info card
            VStack(alignment: .leading, spacing: 14) {
                Spacer()

                Text("SMB 專用傳輸 ⚡️")
                    .font(.system(size: 24, weight: .bold))

                Text("如左圖所示，在 Finder 中對檔案或目錄按右鍵，即可開始傳輸！\n傳輸支援斷點續傳、多線程加速，完美解決 Finder 原生 SMB 傳輸不穩定的問題！")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)

                VStack(alignment: .leading, spacing: 10) {
                    Label {
                        Text("選項也可能出現在名為「**服務**」的子選單中")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                    }

                    Label {
                        Text("找不到？請至\n**系統設定 → 鍵盤 → 鍵盤快速鍵 → 服務**\n中勾選，然後重新開機 🪄")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                    } icon: {
                        Image(systemName: "gearshape.fill").foregroundStyle(.orange)
                    }
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .glassEffect(.regular, in: .rect(cornerRadius: 12))

                Spacer()
            }
            .frame(maxWidth: 280)
        }
        .padding(.horizontal, 40)
    }

    // ────────────────────────────────────────
    // MARK: - Page 5 · 大功告成
    // ────────────────────────────────────────
    private var pageAllSet: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
                .symbolEffect(.pulse, options: .repeating)

            Text("大功告成 🎉")
                .font(.system(size: 28, weight: .bold))

            Text("恭喜！所有前置作業已設定完成。\n現在就開始新增您的掛載點吧 🥳")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .frame(maxWidth: 400)

            Spacer()
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - Color Invert Helper

extension View {
    @ViewBuilder
    func colorInvert(_ active: Bool) -> some View {
        if active {
            self.colorInvert()
        } else {
            self
        }
    }
}
