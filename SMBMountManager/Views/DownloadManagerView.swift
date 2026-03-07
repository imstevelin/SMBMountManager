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
                Image(systemName: "arrow.down.circle")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("下載任務")
                    .font(.title2.bold())
                
                Spacer()
                
                Picker("任務狀態", selection: $selectedTab) {
                    ForEach(DownloadTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                
                Spacer()
                
                if selectedTab == .active && !filteredTasks.isEmpty {
                    HStack(spacing: 6) {
                        Button {
                            downloadManager.startAll()
                        } label: {
                            Label("繼續", systemImage: "play.fill")
                        }
                        .help("繼續所有任務")
                        .buttonStyle(.bordered)
                        
                        Button {
                            downloadManager.pauseAll()
                        } label: {
                            Label("暫停", systemImage: "pause.fill")
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
            Image(systemName: selectedTab == .active ? "tray" : "checkmark.seal")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, options: .repeating)
            Text(selectedTab == .active ? "目前沒有處理中的任務" : "目前沒有已完成的任務")
                .font(.title3)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct DownloadTaskRow: View {
    let task: DownloadTaskModel
    @ObservedObject private var manager = DownloadManager.shared
    
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
        case .paused: return "pause.circle"
        case .completed: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                // Status indicator with pulse animation
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                        .font(.system(size: 20, weight: .medium))
                        .symbolEffect(.pulse, options: .repeating, isActive: task.state == .downloading)
                }
                
                VStack(alignment: .leading, spacing: 5) {
                    Text(task.fileName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    HStack {
                        if task.state == .completed {
                            Text("已完成下載")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(statusColor)
                            }
                        }
                    }
                    
                    // Progress Bar
                    if task.state != .completed {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(nsColor: .separatorColor).opacity(0.3))
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(statusColor)
                                    .frame(width: geo.size.width * CGFloat(task.progress))
                                    .animation(.linear(duration: 0.2), value: task.progress)
                            }
                        }
                        .frame(height: 6)
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
                            Image(systemName: "pause.circle")
                                .font(.title3)
                        }
                        .buttonStyle(.borderless)
                        .help("暫停")
                    } else if task.state == .paused || task.state == .error {
                        Button {
                            manager.startTask(id: task.id)
                        } label: {
                            Image(systemName: "play.circle")
                                .font(.title3)
                        }
                        .buttonStyle(.borderless)
                        .help("繼續")
                    }
                    
                    if task.state == .completed {
                        Button {
                            NSWorkspace.shared.open(task.destinationURL.deletingLastPathComponent())
                        } label: {
                            Image(systemName: "folder")
                                .font(.title3)
                        }
                        .buttonStyle(.borderless)
                        .help("在 Finder 中打開")
                    }
                    
                    Button {
                        manager.cancelTask(id: task.id)
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.title3)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .help(task.state == .completed ? "清除紀錄" : "取消下載並刪除暫存檔")
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(task.state == .downloading ? statusColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .shadow(color: .primary.opacity(0.06), radius: 3, y: 1)
    }
    
    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
