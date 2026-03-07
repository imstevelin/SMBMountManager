import SwiftUI

struct DownloadManagerView: View {
    @StateObject private var downloadManager = DownloadManager.shared
    @State private var selectedTab: DownloadTab = .active

    enum DownloadTab: String, CaseIterable, Identifiable {
        case active = "處理中"
        case completed = "已完成"
        var id: Self { self }
    }

    var filteredTasks: [DownloadTaskModel] {
        if selectedTab == .active {
            return downloadManager.tasks.filter { $0.state != .completed }
        } else {
            return downloadManager.tasks.filter { $0.state == .completed }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                Text("下載任務")
                    .font(.title2.bold())
                
                Picker(selection: $selectedTab) {
                    ForEach(DownloadTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                
                // Live speed indicator — always rendered, opacity-toggled to prevent layout jump
                let isAnyTaskDownloading = downloadManager.tasks.contains { $0.state == .downloading }
                HStack(spacing: 5) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formatSpeed(downloadManager.currentSpeedBytesPerSecond))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .opacity(selectedTab == .active && isAnyTaskDownloading ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.4), value: isAnyTaskDownloading)
                
                Spacer()
                
                if selectedTab == .active && !filteredTasks.isEmpty {
                    HStack(spacing: 6) {
                        Button {
                            downloadManager.startAll()
                        } label: {
                            Label("全部繼續", systemImage: "play.fill")
                        }
                        .help("繼續所有任務")
                        .buttonStyle(.bordered)
                        
                        Button {
                            downloadManager.pauseAll()
                        } label: {
                            Label("全部暫停", systemImage: "pause.fill")
                        }
                        .help("暫停所有任務")
                        .buttonStyle(.bordered)
                        
                        Button(role: .destructive) {
                            downloadManager.deleteAllActive()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("刪除所有任務")
                        .buttonStyle(.bordered)
                    }
                } else if selectedTab == .completed && !filteredTasks.isEmpty {
                    Button(role: .destructive) {
                        downloadManager.clearAllCompleted()
                    } label: {
                        Label("清除紀錄", systemImage: "clear")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)
            
            // List
            if filteredTasks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredTasks) { task in
                            DownloadTaskRow(task: task)
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

            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 100, height: 100)
                    .glassEffect(.regular, in: .circle)
                Image(systemName: selectedTab == .active ? "tray" : "checkmark.seal")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
                    .symbolEffect(.pulse, options: .repeating)
            }

            Text(selectedTab == .active ? "目前沒有處理中的任務" : "目前沒有已完成的任務")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(selectedTab == .active ? "透過 Finder 右鍵選單「SMB 專用下載」即可開始下載" : "已完成的下載任務會出現在這裡")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func formatSpeed(_ bytesPerSecond: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytesPerSecond) + "/s"
    }
}

struct DownloadTaskRow: View {
    let task: DownloadTaskModel
    @ObservedObject private var manager = DownloadManager.shared
    @State private var isHovered = false
    
    var statusColor: Color {
        switch task.state {
        case .waiting: return .secondary
        case .downloading: return .accentColor
        case .paused: return .orange
        case .completed: return .green
        case .error: return .red
        }
    }
    
    var statusIcon: String {
        switch task.state {
        case .waiting: return "hourglass"
        case .downloading: return "arrow.down.circle.fill"
        case .paused: return "pause.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                // Status indicator
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.1))
                        .frame(width: 48, height: 48)
                    
                    // Animated ring for downloading state
                    if task.state == .downloading {
                        Circle()
                            .trim(from: 0, to: CGFloat(task.progress))
                            .stroke(
                                AngularGradient(
                                    colors: [statusColor.opacity(0.3), statusColor],
                                    center: .center
                                ),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round)
                            )
                            .frame(width: 48, height: 48)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.3), value: task.progress)
                    }
                    
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                        .font(.system(size: 22, weight: .medium))
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.pulse, options: .repeating, isActive: task.state == .downloading)
                }
                
                VStack(alignment: .leading, spacing: 5) {
                    Text(task.fileName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    HStack {
                        if task.state == .completed {
                            Label("已完成下載", systemImage: "checkmark")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Text(formatBytes(task.downloadedBytes) + " / " + (task.totalBytes > 0 ? formatBytes(task.totalBytes) : "計算中..."))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            
                            Spacer()
                            
                            if task.state == .error, let errorMsg = task.errorMessage {
                                Text(errorMsg)
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                    .lineLimit(1)
                            } else {
                                Text("\(Int(task.progress * 100))%")
                                    .font(.system(.caption, design: .monospaced).weight(.medium))
                                    .foregroundStyle(statusColor)
                            }
                        }
                    }
                    
                    // Progress Bar — gradient fill with animated shimmer
                    if task.state != .completed {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color(nsColor: .separatorColor).opacity(0.2))
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [statusColor.opacity(0.8), statusColor],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: max(0, geo.size.width * CGFloat(task.progress)))
                                    .animation(.easeInOut(duration: 0.3), value: task.progress)
                            }
                        }
                        .frame(height: 6)
                        .clipShape(Capsule())
                        .padding(.top, 2)
                    }
                }
                
                Spacer(minLength: 16)
                
                // Controls
                HStack(spacing: 8) {
                    if task.state == .downloading || task.state == .waiting {
                        Button {
                            manager.pauseTask(id: task.id)
                        } label: {
                            Image(systemName: "pause.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.hierarchical)
                        }
                        .buttonStyle(.borderless)
                        .help("暫停")
                    } else if task.state == .paused || task.state == .error {
                        Button {
                            manager.startTask(id: task.id)
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.hierarchical)
                        }
                        .buttonStyle(.borderless)
                        .help("繼續")
                    }
                    
                    if task.state == .completed {
                        Button {
                            NSWorkspace.shared.open(task.destinationURL.deletingLastPathComponent())
                        } label: {
                            Image(systemName: "folder.fill")
                                .font(.title3)
                                .symbolRenderingMode(.hierarchical)
                        }
                        .buttonStyle(.borderless)
                        .help("在 Finder 中打開")
                    }
                    
                    Button {
                        manager.cancelTask(id: task.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red.opacity(isHovered ? 1.0 : 0.7))
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.borderless)
                    .help(task.state == .completed ? "清除紀錄" : "取消下載並刪除暫存檔")
                }
            }
            .padding(14)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    task.state == .downloading
                        ? statusColor.opacity(0.5)
                        : Color(nsColor: .separatorColor).opacity(0.5),
                    lineWidth: 1
                )
        )
        .shadow(color: statusColor.opacity(task.state == .downloading ? 0.12 : 0.04), radius: task.state == .downloading ? 6 : 3, y: 2)
        .onHover { hovering in
            isHovered = hovering
        }
        .scaleEffect(isHovered ? 1.005 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
    
    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
