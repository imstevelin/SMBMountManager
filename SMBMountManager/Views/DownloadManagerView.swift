import SwiftUI

struct DownloadManagerView: View {
    @StateObject private var downloadManager = DownloadManager.shared
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("下載任務列")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Spacer()
                
                if !downloadManager.tasks.isEmpty {
                    Button(action: {
                        downloadManager.startAll()
                    }) {
                        Image(systemName: "play.circle.fill")
                        Text("全部開始")
                    }
                    .buttonStyle(BorderedButtonStyle())
                    .tint(.green)
                    
                    Button(action: {
                        downloadManager.pauseAll()
                    }) {
                        Image(systemName: "pause.circle.fill")
                        Text("全部暫停")
                    }
                    .buttonStyle(BorderedButtonStyle())
                    .tint(.orange)
                    
                    Button(action: {
                        downloadManager.deleteAll()
                    }) {
                        Image(systemName: "trash.fill")
                        Text("全部刪除")
                    }
                    .buttonStyle(BorderedButtonStyle())
                    .tint(.red)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // List
            if downloadManager.tasks.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("目前沒有下載任務")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(downloadManager.tasks) { task in
                        DownloadTaskRow(task: task)
                            .padding(.vertical, 4)
                    }
                }
                .listStyle(PlainListStyle())
            }
        }
    }
}

struct DownloadTaskRow: View {
    let task: DownloadTaskModel
    @ObservedObject private var manager = DownloadManager.shared
    
    var body: some View {
        HStack(spacing: 16) {
            // Icon
            Image(systemName: iconForState(task.state))
                .font(.system(size: 24))
                .foregroundColor(colorForState(task.state))
                .frame(width: 40)
            
            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(task.fileName)
                    .font(.headline)
                    .lineLimit(1)
                
                HStack {
                    Text(formatBytes(task.downloadedBytes) + " / " + (task.totalBytes > 0 ? formatBytes(task.totalBytes) : "計算中..."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text("\(Int(task.progress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                
                // Progress Bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.2))
                            .frame(height: 6)
                            .cornerRadius(3)
                            
                        Rectangle()
                            .fill(colorForState(task.state))
                            .frame(width: geo.size.width * CGFloat(task.progress), height: 6)
                            .cornerRadius(3)
                            .animation(.linear(duration: 0.2), value: task.progress)
                    }
                }
                .frame(height: 6)
                
                if let error = task.errorMessage, task.state == .error {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(1)
                }
            }
            
            // Controls
            HStack(spacing: 8) {
                if task.state == .downloading || task.state == .waiting {
                    Button(action: {
                        manager.pauseTask(id: task.id)
                    }) {
                        Image(systemName: "pause.circle.fill")
                            .font(.title2)
                            .foregroundColor(.orange)
                    }
                    .buttonStyle(PlainButtonStyle())
                } else if task.state == .paused || task.state == .error {
                    Button(action: {
                        manager.startTask(id: task.id)
                    }) {
                        Image(systemName: "play.circle.fill")
                            .font(.title2)
                            .foregroundColor(.green)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                
                Button(action: {
                    manager.cancelTask(id: task.id)
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.red)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
    
    private func iconForState(_ state: DownloadState) -> String {
        switch state {
        case .waiting: return "hourglass"
        case .downloading: return "arrow.down.circle.fill"
        case .paused: return "pause.circle"
        case .completed: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
    
    private func colorForState(_ state: DownloadState) -> Color {
        switch state {
        case .waiting: return .gray
        case .downloading: return .blue
        case .paused: return .orange
        case .completed: return .green
        case .error: return .red
        }
    }
    
    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
