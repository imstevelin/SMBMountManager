import Foundation
import Combine

@MainActor
class DownloadManager: ObservableObject {
    static let shared = DownloadManager()
    
    @Published var tasks: [DownloadTaskModel] = []
    
    private let storageURL: URL
    private let queue = DispatchQueue(label: "org.imstevelin.DownloadManager", attributes: .concurrent)
    
    // Add max concurrent task limit
    private let maxConcurrentTasks = 5
    private var downloaders: [UUID: ChunkDownloader] = [:]
    private var isPausingAll: Bool = false
    
    // Download speed tracking — Exponential Moving Average (EMA) for smooth display
    @Published var currentSpeedBytesPerSecond: Int64 = 0
    private var lastTotalBytesDownloaded: UInt64 = 0
    private var speedTimer: Timer?
    private var emaSpeed: Double = 0.0
    private let emaSmoothingFactor: Double = 0.3  // α: higher = more responsive, lower = smoother
    private var lastSpeedSampleTime: Date = Date()
    
    /// Tracks the tasks involved in the current active download session to prevent progress percentage jumps.
    @Published var activeSessionTaskIDs: Set<UUID> = []
    
    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let managerDir = appSupport.appendingPathComponent("SMBMountManager/Downloads")
        try? FileManager.default.createDirectory(at: managerDir, withIntermediateDirectories: true)
        self.storageURL = managerDir.appendingPathComponent("tasks.json")
        
        loadTasks()
        startSpeedMeasurement()
    }
    
    private func startSpeedMeasurement() {
        speedTimer?.invalidate()
        lastSpeedSampleTime = Date()
        lastTotalBytesDownloaded = tasks.reduce(UInt64(0)) { $0 + $1.downloadedBytes }
        
        speedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let now = Date()
                let elapsed = now.timeIntervalSince(self.lastSpeedSampleTime)
                guard elapsed > 0.1 else { return }
                self.lastSpeedSampleTime = now
                
                let currentTotal = self.tasks.reduce(UInt64(0)) { $0 + $1.downloadedBytes }
                let isDownloading = self.tasks.contains { $0.state == .downloading }
                
                if isDownloading {
                    let bytesDelta = currentTotal >= self.lastTotalBytesDownloaded
                        ? Double(currentTotal - self.lastTotalBytesDownloaded)
                        : 0.0
                    let instantSpeed = bytesDelta / elapsed
                    
                    if self.emaSpeed == 0 && instantSpeed > 0 {
                        self.emaSpeed = instantSpeed
                    } else {
                        self.emaSpeed = self.emaSmoothingFactor * instantSpeed + (1.0 - self.emaSmoothingFactor) * self.emaSpeed
                    }
                    self.currentSpeedBytesPerSecond = Int64(self.emaSpeed)
                } else {
                    self.emaSpeed *= 0.4
                    if self.emaSpeed < 1024 {
                        self.emaSpeed = 0
                    }
                    self.currentSpeedBytesPerSecond = Int64(self.emaSpeed)
                }
                
                self.lastTotalBytesDownloaded = currentTotal
            }
        }
    }
    
    private func loadTasks() {
        guard let data = try? Data(contentsOf: storageURL),
              let savedTasks = try? JSONDecoder().decode([DownloadTaskModel].self, from: data) else {
            AppLogger.shared.info("[DownloadManager] No saved tasks found or failed to decode.")
            return
        }
        self.tasks = savedTasks
        
        // Auto-pause tasks that were downloading when app closed
        for i in tasks.indices {
            if tasks[i].state == .downloading || tasks[i].state == .waiting {
                tasks[i].state = .paused
            }
        }
        saveTasks()
    }
    
    func saveTasks() {
        updateSession()
        Task { @MainActor in
            if let data = try? JSONEncoder().encode(tasks) {
                try? data.write(to: storageURL, options: .atomic)
            }
        }
    }
    
    private func updateSession() {
        let activeStates: [DownloadState] = [.downloading, .waiting, .paused]
        let hasActive = tasks.contains { activeStates.contains($0.state) }
        
        if !hasActive {
            if !activeSessionTaskIDs.isEmpty {
                // All session tasks just finished — send a single completion notification
                let completedInSession = tasks.filter { activeSessionTaskIDs.contains($0.id) && $0.state == .completed }
                if !completedInSession.isEmpty {
                    // Use the first file name as the representative root name
                    let rootName = completedInSession.first?.fileName ?? "檔案"
                    NotificationService.sendDownloadCompleted(rootName: rootName, fileCount: completedInSession.count)
                }
                activeSessionTaskIDs.removeAll()
            }
        } else {
            for task in tasks where activeStates.contains(task.state) && !activeSessionTaskIDs.contains(task.id) {
                activeSessionTaskIDs.insert(task.id)
            }
        }
    }
    
    func addTasks(batch: [(fileName: String, mountId: String, relativeSMBPath: String, destinationURL: URL, totalBytes: UInt64)]) {
        var newTasks: [DownloadTaskModel] = []
        for item in batch {
            let task = DownloadTaskModel(
                fileName: item.fileName,
                mountId: item.mountId,
                relativeSMBPath: item.relativeSMBPath,
                destinationURL: item.destinationURL,
                totalBytes: item.totalBytes
            )
            newTasks.append(task)
            AppLogger.shared.info("[DownloadManager] Queued download for file: \(item.fileName)")
        }
        tasks.append(contentsOf: newTasks)
        saveTasks()
        processQueue()
    }
    
    func addTask(fileName: String, mountId: String, relativeSMBPath: String, destinationURL: URL, totalBytes: UInt64 = 0) {
        addTasks(batch: [(fileName, mountId, relativeSMBPath, destinationURL, totalBytes)])
    }
    
    private func processQueue() {
        guard !isPausingAll else { return }
        let activeTaskCount = tasks.filter { $0.state == .downloading }.count
        guard activeTaskCount < maxConcurrentTasks else { return }
        
        // Find tasks that are waiting
        let waitingTasks = tasks.filter { $0.state == .waiting }
        let availableSlots = maxConcurrentTasks - activeTaskCount
        
        // Start up to 'availableSlots' tasks
        for task in waitingTasks.prefix(availableSlots) {
            _startTask(id: task.id)
        }
    }
    
    func startTask(id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].state = .waiting
        saveTasks() // Save state before evaluating queue
        processQueue()
    }
    
    private func _startTask(id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].state = .downloading
        AppLogger.shared.info("[DownloadManager] Started downloading: \(tasks[index].fileName)")
        
        let taskModel = tasks[index]
        let downloader = ChunkDownloader(task: taskModel) { [weak self] updatedTask in
            DispatchQueue.main.async {
                self?.updateTask(updatedTask)
            }
        }
        downloaders[id] = downloader
        
        Task.detached {
            await downloader.start()
        }
    }
    
    func pauseTask(id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].state = .paused
        AppLogger.shared.info("[DownloadManager] Paused task: \(tasks[index].fileName)")
        saveTasks()
        
        Task {
            await downloaders[id]?.pause()
            DispatchQueue.main.async {
                self.downloaders.removeValue(forKey: id)
                self.processQueue() // Pick up another task if available
            }
        }
    }
    
    func cancelTask(id: UUID) {
        Task {
            await downloaders[id]?.pause()
            
            DispatchQueue.main.async {
                guard let index = self.tasks.firstIndex(where: { $0.id == id }) else { return }
                
                // Only remove partial file if it's not completed
                if self.tasks[index].state != .completed {
                    let dest = self.tasks[index].destinationURL
                    try? FileManager.default.removeItem(at: dest)
                }
                
                self.tasks.remove(at: index)
                self.downloaders.removeValue(forKey: id)
                self.saveTasks()
                self.processQueue() // Pick up next queued task
            }
        }
    }
    
    // MARK: - Global Controls
    
    func startAll() {
        for index in tasks.indices where tasks[index].state == .paused || tasks[index].state == .error {
            tasks[index].state = .waiting
        }
        saveTasks()
        processQueue()
    }
    
    func pauseAll() {
        isPausingAll = true
        let taskIdsToPause = tasks.filter { $0.state == .downloading || $0.state == .waiting }.map { $0.id }
        
        for index in tasks.indices where tasks[index].state == .downloading || tasks[index].state == .waiting {
            tasks[index].state = .paused
        }
        self.saveTasks()
        
        Task {
            await withTaskGroup(of: Void.self) { group in
                for id in taskIdsToPause {
                    if let downloader = self.downloaders[id] {
                        group.addTask { await downloader.pause() }
                    }
                }
            }
            await MainActor.run {
                for id in taskIdsToPause {
                    self.downloaders.removeValue(forKey: id)
                }
                self.isPausingAll = false
                self.processQueue()
            }
        }
    }
    
    func deleteAllActive() {
        let activeTasks = tasks.filter { $0.state != .completed }
        guard !activeTasks.isEmpty else { return }
        
        Task {
            // Pause all active downloads concurrently
            await withTaskGroup(of: Void.self) { group in
                for task in activeTasks {
                    if let downloader = downloaders[task.id] {
                        group.addTask {
                            await downloader.pause()
                        }
                    }
                }
            }
            
            // Perform batch update on the main thread
            DispatchQueue.main.async {
                for task in activeTasks {
                    let dest = task.destinationURL
                    try? FileManager.default.removeItem(at: dest)
                    self.downloaders.removeValue(forKey: task.id)
                }
                
                self.tasks.removeAll { $0.state != .completed }
                self.saveTasks()
                self.processQueue()
            }
        }
    }
    
    func clearAllCompleted() {
        tasks.removeAll { $0.state == .completed }
        saveTasks()
    }
    
    func resumeTasks(forMountId mountId: String) {
        var didResume = false
        for index in tasks.indices where tasks[index].mountId == mountId {
            if tasks[index].state == .paused || tasks[index].state == .error {
                tasks[index].state = .waiting
                didResume = true
            }
        }
        if didResume {
            saveTasks()
            processQueue()
        }
    }
    
    // MARK: - Update Loop
    
    private func updateTask(_ task: DownloadTaskModel) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        
        let currentState = tasks[index].state
        var updatedTask = task
        
        // Anti-bounce mechanism to prevent slow async packets from overwriting user UI intent
        if (currentState == .paused || currentState == .completed || currentState == .error) && task.state == .downloading {
            updatedTask.state = currentState
        }
        
        // Critical: Structural merging to prevent Background TCP thread overwrite wiping out chunks during concurrent startup
        if updatedTask.chunks.isEmpty && !tasks[index].chunks.isEmpty {
            updatedTask.chunks = tasks[index].chunks
        }
        
        if updatedTask.totalBytes == 0 && tasks[index].totalBytes > 0 {
            updatedTask.totalBytes = tasks[index].totalBytes
        }
        
        tasks[index] = updatedTask
        
        let finalState = tasks[index].state
        if finalState != currentState {
            if finalState == .completed {
                AppLogger.shared.info("[DownloadManager] Completed task: \(tasks[index].fileName)")
            } else if finalState == .error {
                AppLogger.shared.error("[DownloadManager] Task failed: \(tasks[index].fileName)")
            }
        }
        
        if finalState == .completed || finalState == .error || finalState == .paused {
            saveTasks() // Ensure final state is saved
            if finalState == .completed || finalState == .error {
                downloaders.removeValue(forKey: task.id)
                processQueue() // Free up queue slot
            }
        }
    }
}
