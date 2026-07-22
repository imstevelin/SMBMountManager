import SwiftUI
import CoreLocation

/// Post-update authorization view.
/// A single "重新驗證並繼續" button sequentially:
/// 1. Triggers Keychain re-auth (system password dialogs if needed)
/// 2. Requests Location Services permission (system dialog)
/// 3. Proceeds to the main app
struct UpdateAuthorizationView: View {
    @ObservedObject var mountManager: MountManager
    @ObservedObject var appState: AppStateManager
    var onComplete: () -> Void

    @State private var isProcessing = false
    @State private var missingCredentialMessage: String?

    private var mountCount: Int { max(mountManager.mounts.count, 1) }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // ── App Icon ──
            if let appIcon = NSApplication.shared.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
            }

            Text("SMB 自動掛載工具已更新 🎉")
                .font(.system(size: 22, weight: .bold))
                .padding(.top, 16)

            Text("軟體已成功升級，請點擊下方按鈕完成必要的權限驗證。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .padding(.horizontal, 40)

            // ── Info Cards ──
            VStack(spacing: 10) {

                // Keychain info
                HStack(spacing: 12) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.blue)
                        .font(.system(size: 20))
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keychain 密碼驗證")
                            .font(.system(size: 13, weight: .semibold))
                        Text("系統將彈出 \(mountCount) 次密碼驗證框，請選擇「永遠允許」。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.blue.opacity(0.4), lineWidth: 1)
                )

                // Location info
                HStack(spacing: 12) {
                    Image(systemName: "location.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 20))
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("定位服務授權")
                            .font(.system(size: 13, weight: .semibold))
                        Text("允許讀取 Wi-Fi 名稱，實現智慧掛載與退出。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.orange.opacity(0.4), lineWidth: 1)
                )
            }
            .frame(maxWidth: 420)
            .padding(.top, 20)

            // Tip
            HStack(spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.system(size: 16))
                Text("完成驗證後，背景掛載服務將自動啟動。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .glassEffect(.regular, in: .rect(cornerRadius: 10))
            .padding(.top, 14)

            if let missingCredentialMessage {
                Text(missingCredentialMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)

                Button("前往設定重新輸入密碼") {
                    appState.completeUpdateAuthorization()
                    onComplete()
                }
                .buttonStyle(.bordered)
                .padding(.top, 6)
            }

            // Single action button
            Button(action: performFullVerification) {
                HStack(spacing: 6) {
                    if isProcessing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text("重新驗證並繼續")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 18)
            .disabled(isProcessing)

            Spacer()
        }
        .frame(width: 500, height: 520)
    }

    private func performFullVerification() {
        isProcessing = true
        missingCredentialMessage = nil
        KeychainService.allowUI = true

        Task {
            // Step 1: Keychain — sequentially query every stored password.
            // If already authorized, returns instantly; otherwise triggers system password dialogs.
            var missingMounts: [String] = []
            for mount in mountManager.mounts {
                if KeychainService.getPassword(forMount: mount.name, username: mount.username) == nil {
                    missingMounts.append(mount.name)
                }
            }

            if !missingMounts.isEmpty {
                await MainActor.run {
                    KeychainService.allowUI = false
                    isProcessing = false
                    missingCredentialMessage = "找不到以下掛載點的密碼：\(missingMounts.joined(separator: "、"))"
                }
                return
            }

            // Step 2: Location Services — request permission (triggers system dialog if not yet determined).
            await MainActor.run {
                WiFiService.requestPermission()
            }

            // Brief delay to allow the location dialog to appear and be dismissed
            try? await Task.sleep(nanoseconds: 500_000_000)

            // Step 3: Complete and proceed, bring app to front
            await MainActor.run {
                KeychainService.allowUI = false
                isProcessing = false
                appState.completeUpdateAuthorization()
                onComplete()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
