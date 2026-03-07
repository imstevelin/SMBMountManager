import SwiftUI

/// Connection test sheet
struct ConnectionTestView: View {
    @ObservedObject var mountManager: MountManager
    @Environment(\.dismiss) private var dismiss

    @State private var serverAddress = ""
    @State private var testResult = ""
    @State private var isTesting = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "network")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.blue)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("伺服器連線測試")
                        .font(.title3.bold())
                    Text("測試 SMB 伺服器的連線狀態")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                // Input
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        TextField("伺服器位址 (例如: nas.local 或 192.168.1.100)", text: $serverAddress)
                            .textFieldStyle(.plain)
                            .onSubmit { runTest() }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

                    Button {
                        runTest()
                    } label: {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 60)
                        } else {
                            Text("測試")
                                .frame(width: 60)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(serverAddress.trimmingCharacters(in: .whitespaces).isEmpty || isTesting)
                }

                // Results
                if !testResult.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(icon: "checkmark.circle", title: "測試結果")

                        ScrollView {
                            Text(testResult)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .glassEffect(.regular, in: .rect(cornerRadius: 10))
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(.secondary)
                            .symbolEffect(.pulse, options: .repeating)
                        Text("輸入伺服器位址後按「測試」開始")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(20)

            Divider()

            HStack {
                Spacer()
                Button("關閉") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 560, height: 440)
    }

    private func runTest() {
        let server = serverAddress.trimmingCharacters(in: .whitespaces)
        guard !server.isEmpty else { return }
        isTesting = true
        testResult = ""

        Task.detached {
            let result = await MainActor.run {
                mountManager.testConnection(server: server)
            }
            await MainActor.run {
                testResult = result
                isTesting = false
            }
        }
    }
}
