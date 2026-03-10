import SwiftUI
import CoreLocation

/// Post-update authorization view.
/// Shows the app icon, Keychain re-verification card, and an optional
/// Location Services re-authorization card. Matches Liquid Glass styling.
struct UpdateAuthorizationView: View {
    @ObservedObject var mountManager: MountManager
    @ObservedObject var appState: AppStateManager
    var onComplete: () -> Void

    @State private var isLocationAuthorized: Bool = {
        let status = CLLocationManager().authorizationStatus
        return status == .authorizedAlways || status == .authorized
    }()
    @State private var isProcessing = false

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

            Text("SMB 掛載管理器已更新 🎉")
                .font(.system(size: 22, weight: .bold))
                .padding(.top, 16)

            Text("軟體已成功升級，請確認以下項目以確保服務正常運作。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .padding(.horizontal, 40)

            // ── Authorization Cards ──
            VStack(spacing: 10) {

                // Keychain card
                HStack(spacing: 12) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.blue)
                        .font(.system(size: 20))
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keychain 密碼驗證")
                            .font(.system(size: 13, weight: .semibold))
                        Text("系統可能要求輸入電腦密碼，請選擇「永遠允許」。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 18))
                        .opacity(0) // Always present but invisible — keychain is verified on button click
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.blue.opacity(0.4), lineWidth: 1)
                )

                // Location card
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
                        Text(isLocationAuthorized ? "已授權 ✓" : "前往授權")
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
            .frame(maxWidth: 420)
            .padding(.top, 20)

            // Tip card
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

            Button(action: performVerification) {
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

    private func performVerification() {
        isProcessing = true
        KeychainService.allowUI = true

        Task {
            // Sequentially fetch every password.
            // If Keychain is already authorized, these return instantly without popping a system dialog.
            for mount in mountManager.mounts {
                let _ = KeychainService.getPassword(forMount: mount.name, username: mount.username)
            }

            await MainActor.run {
                isProcessing = false
                appState.completeUpdateAuthorization()
                mountManager.startAll()
                onComplete()
            }
        }
    }
}
