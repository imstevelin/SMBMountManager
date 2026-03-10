import SwiftUI

struct UploadManagerView: View {
    @StateObject private var uploadManager = UploadManager.shared
    @State private var selectedTab: UploadTab = .active
    @State private var refreshTick: UInt = 0

    enum UploadTab: String, CaseIterable, Identifiable {
        case active = "處理中"
        case completed = "已完成"
        var id: Self { self }
    }

    var filteredTasks: [UploadTaskModel] {
        if selectedTab == .active {
            return uploadManager.tasks.filter { $0.state != .completed }
        } else {
            return uploadManager.tasks.filter { $0.state == .completed }.reversed()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                Text("上傳任務")
                    .font(.title2.bold())
                
                Picker(selection: $selectedTab) {
                    ForEach(UploadTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                
                // Live speed indicator — always rendered, opacity-toggled to prevent layout jump
                let isAnyTaskUploading = uploadManager.tasks.contains { $0.state == .uploading }
                HStack(spacing: 5) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formatSpeed(uploadManager.currentSpeedBytesPerSecond))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .opacity(selectedTab == .active && isAnyTaskUploading ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.4), value: isAnyTaskUploading)
                
                Spacer()
                
                if selectedTab == .active && !filteredTasks.isEmpty {
                    HStack(spacing: 6) {
                        Button {
                            uploadManager.resumeAll()
                        } label: {
                            Label("全部繼續", systemImage: "play.fill")
                        }
                        .help("繼續所有任務")
                        .buttonStyle(.bordered)
                        
                        Button {
                            uploadManager.pauseAll()
                        } label: {
                            Label("全部暫停", systemImage: "pause.fill")
                        }
                        .help("暫停所有任務")
                        .buttonStyle(.bordered)
                        
                        Button(role: .destructive) {
                            uploadManager.deleteAllActive()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("刪除所有任務")
                        .buttonStyle(.bordered)
                    }
                } else if selectedTab == .completed && !filteredTasks.isEmpty {
                    Button(role: .destructive) {
                        // clearAllCompleted for uploads
                        uploadManager.tasks.removeAll { $0.state == .completed }
                        uploadManager.saveTasks()
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
                            UploadTaskRow(task: task)
                                .id("\(task.id)-\(refreshTick)")
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                }
            }
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            // Force SwiftUI to re-render by mutating @State.
            // An empty .onReceive is optimized away by SwiftUI since no state changes.
            if uploadManager.tasks.contains(where: { $0.state == .uploading || $0.state == .waiting }) {
                refreshTick &+= 1
                uploadManager.objectWillChange.send()
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
                Image(systemName: selectedTab == .active ? "tray.and.arrow.up" : "checkmark.seal")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
                    .symbolEffect(.pulse, options: .repeating)
            }

            Text(selectedTab == .active ? "目前沒有處理中的上傳任務" : "目前沒有已完成的上傳任務")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(selectedTab == .active ? "透過 Finder 右鍵選單「SMB 專用上傳」即可開始上傳" : "已完成的上傳任務會出現在這裡")
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

struct UploadTaskRow: View {
    let task: UploadTaskModel
    @ObservedObject private var manager = UploadManager.shared
    @State private var isHovered = false
    
    var statusColor: Color {
        switch task.state {
        case .waiting: return .secondary
        case .uploading: return .accentColor
        case .paused: return .orange
        case .completed: return .green
        case .error: return .red
        }
    }
    
    var statusIcon: String {
        switch task.state {
        case .waiting: return "hourglass"
        case .uploading: return "arrow.up.circle.fill"
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
                    
                    // Animated ring for uploading state
                    if task.state == .uploading {
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
                        .symbolEffect(.pulse, options: .repeating, isActive: task.state == .uploading)
                }
                
                VStack(alignment: .leading, spacing: 5) {
                    Text(task.sourceURL.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    HStack {
                        if task.state == .completed {
                            Label("已完成上傳", systemImage: "checkmark")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Text(formatBytes(task.uploadedBytes) + " / " + (task.totalBytes > 0 ? formatBytes(task.totalBytes) : "計算中..."))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            
                            Spacer()
                            
                            if task.state == .error, let errorMsg = task.errorMessage {
                                Text(errorMsg)
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                    .lineLimit(1)
                            } else if task.state == .uploading {
                                HStack(spacing: 8) {
                                    let taskSpeed = manager.taskSpeeds[task.id] ?? 0
                                    let taskETASpeed = manager.taskETASpeeds[task.id] ?? 0
                                    
                                    if taskSpeed > 0 {
                                        Text(formatSpeed(taskSpeed))
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                        
                                        let remaining = task.totalBytes > task.uploadedBytes ? task.totalBytes - task.uploadedBytes : 0
                                        if taskETASpeed > 0 {
                                            let secondsLeft = Double(remaining) / Double(taskETASpeed)
                                            Text(formatTime(secondsLeft))
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Text("\(Int(task.progress * 100))%")
                                        .font(.system(.caption, design: .monospaced).weight(.medium))
                                        .foregroundStyle(statusColor)
                                }
                            } else {
                                Text("\(Int(task.progress * 100))%")
                                    .font(.system(.caption, design: .monospaced).weight(.medium))
                                    .foregroundStyle(statusColor)
                            }
                        }
                    }
                    
                    // Progress Bar
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
                    if task.state == .uploading || task.state == .waiting {
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
                            manager.resumeTask(id: task.id)
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
                            // Can't easily open remote Finder unless we reconstruct the fileURL path
                            guard let mount = AppLifecycle.shared.mountManager?.mounts.first(where: { $0.id == task.mountId }) else { return }
                            let url = URL(fileURLWithPath: mount.mountPath).appendingPathComponent(task.relativeSMBPath).deletingLastPathComponent()
                            NSWorkspace.shared.open(url)
                        } label: {
                            Image(systemName: "folder.fill")
                                .font(.title3)
                                .symbolRenderingMode(.hierarchical)
                        }
                        .buttonStyle(.borderless)
                        .help("在 Finder 中打開遠端位置")
                    }
                    
                    Button {
                        manager.deleteTask(id: task.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red.opacity(isHovered ? 1.0 : 0.7))
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.borderless)
                    .help(task.state == .completed ? "清除紀錄" : "取消上傳並保留暫存檔")
                }
            }
            .padding(14)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    task.state == .uploading
                        ? statusColor.opacity(0.5)
                        : Color(nsColor: .separatorColor).opacity(0.5),
                    lineWidth: 1
                )
        )
        .shadow(color: statusColor.opacity(task.state == .uploading ? 0.12 : 0.04), radius: task.state == .uploading ? 6 : 3, y: 2)
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

    private func formatSpeed(_ bytesPerSecond: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytesPerSecond) + "/s"
    }
    
    private func formatTime(_ seconds: Double) -> String {
        if seconds <= 0 || seconds.isNaN || seconds.isInfinite { return "計算中..." }
        if seconds < 60 {
            return "\(Int(seconds)) 秒"
        } else if seconds < 3600 {
            return "\(Int(seconds/60)) 分鐘"
        } else {
            return String(format: "%.1f 小時", seconds/3600)
        }
    }
}
