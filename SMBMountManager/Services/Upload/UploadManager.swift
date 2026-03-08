import Foundation
import Combine

@MainActor
class UploadManager: ObservableObject {
    static let shared = UploadManager()
    
    @Published var tasks: [UploadTaskModel] = []
    
    private let storageURL: URL
    private let queue = DispatchQueue(label: "org.imstevelin.UploadManager", attributes: .concurrent)
    
    // Limits concurrent SMB writes to 1 to prevent NAS storage locks and connection unresponsiveness
    private let maxConcurrentTasks = 1
    private var uploaders: [UUID: ChunkUploader] = [:]
    private var isPausingAll: Bool = false
    
    // Upload speed tracking
    @Published var currentSpeedBytesPerSecond: Int64 = 0
    private var lastTotalBytesUploaded: Int64 = 0
    private var speedTimer: Timer?
    private var recentSpeeds: [Int64] = []
    private let maxRecentSpeeds = 3
    private var lastCalculatedSpeed: Int64 = 0
    
    /// Tracks the tasks involved in the current active upload session to prevent progress percentage jumps.
    @Published var activeSessionTaskIDs: Set<UUID> = []
    
    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let managerDir = appSupport.appendingPathComponent("SMBMountManager/Uploads")
        try? FileManager.default.createDirectory(at: managerDir, withIntermediateDirectories: true)
        self.storageURL = managerDir.appendingPathComponent("tasks.json")
        
        loadTasks()
        startSpeedMeasurement()
    }
    
    private func startSpeedMeasurement() {
        speedTimer?.invalidate()
        speedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let currentTotal = self.tasks.reduce(UInt64(0)) { $0 + $1.uploadedBytes }
                
                var instantaneousSpeed: Int64 = 0
                if currentTotal >= UInt64(max(0, self.lastTotalBytesUploaded)) {
                    let diff = currentTotal - UInt64(max(0, self.lastTotalBytesUploaded))
                    instantaneousSpeed = Int64(diff)
                }
                self.lastTotalBytesUploaded = Int64(currentTotal)
                
                let isUploading = !self.tasks.filter { $0.state == .uploading }.isEmpty
                
                if isUploading {
                    self.recentSpeeds.append(instantaneousSpeed)
                    if self.recentSpeeds.count > self.maxRecentSpeeds {
                        self.recentSpeeds.removeFirst()
                    }
                    let avgSpeed = self.recentSpeeds.reduce(0, +) / Int64(self.recentSpeeds.count)
                    self.lastCalculatedSpeed = avgSpeed
                    self.currentSpeedBytesPerSecond = self.lastCalculatedSpeed
                } else {
                    self.recentSpeeds.removeAll()
                    self.currentSpeedBytesPerSecond = 0
                }
            }
        }
    }
    
    private func loadTasks() {
        guard let data = try? Data(contentsOf: storageURL),
              let savedTasks = try? JSONDecoder().decode([UploadTaskModel].self, from: data) else {
            AppLogger.shared.info("[UploadManager] No saved tasks found or failed to decode.")
            return
        }
        self.tasks = savedTasks
        
        // Auto-pause tasks that were uploading when app closed
        for i in tasks.indices {
            if tasks[i].state == .uploading || tasks[i].state == .waiting {
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
        let activeStates: [UploadState] = [.uploading, .waiting, .paused]
        let hasActive = tasks.contains { activeStates.contains($0.state) }
        
        if !hasActive {
            if !activeSessionTaskIDs.isEmpty {
                // All session tasks just finished — send a single completion notification
                let completedInSession = tasks.filter { activeSessionTaskIDs.contains($0.id) && $0.state == .completed }
                if !completedInSession.isEmpty {
                    let rootName = completedInSession.first?.sourceURL.lastPathComponent ?? "檔案"
                    NotificationService.sendUploadCompleted(rootName: rootName, fileCount: completedInSession.count)
                }
                activeSessionTaskIDs.removeAll()
            }
        } else {
            for task in tasks where activeStates.contains(task.state) && !activeSessionTaskIDs.contains(task.id) {
                activeSessionTaskIDs.insert(task.id)
            }
        }
    }
    
    func addTasks(batch: [(sourceURL: URL, mountId: String, relativeSMBPath: String)]) {
        Task.detached {
            var newTasks: [UploadTaskModel] = []
            for item in batch {
                // Read local file size and date
                if let attributes = try? FileManager.default.attributesOfItem(atPath: item.sourceURL.path),
                   let size = attributes[.size] as? UInt64 {
                    let modDate = attributes[.modificationDate] as? Date
                    
                    let task = UploadTaskModel(
                        sourceURL: item.sourceURL,
                        mountId: item.mountId,
                        relativeSMBPath: item.relativeSMBPath,
                        totalBytes: size,
                        lastModificationDate: modDate
                    )
                    newTasks.append(task)
                }
            }
            
            await MainActor.run {
                if !newTasks.isEmpty {
                    self.tasks.append(contentsOf: newTasks)
                    self.saveTasks()
                    
                    for _ in newTasks {
                        self.processNextTasks()
                    }
                }
            }
        }
    }
    
    func pauseTask(id: UUID) {
        if let index = tasks.firstIndex(where: { $0.id == id }) {
            self.tasks[index].state = .paused
            
            if let uploader = uploaders[id] {
                Task {
                    await uploader.pause()
                }
            }
            saveTasks()
            processNextTasks()
        }
    }
    
    func pauseAll() {
        isPausingAll = true
        let taskIdsToPause = tasks.filter { $0.state == .uploading || $0.state == .waiting }.map { $0.id }
        
        for index in tasks.indices {
            if tasks[index].state == .uploading || tasks[index].state == .waiting {
                tasks[index].state = .paused
            }
        }
        self.saveTasks()
        
        Task {
            await withTaskGroup(of: Void.self) { group in
                for id in taskIdsToPause {
                    if let uploader = self.uploaders[id] {
                        group.addTask { await uploader.pause() }
                    }
                }
            }
            await MainActor.run {
                self.isPausingAll = false
                self.processNextTasks()
            }
        }
    }
    
    func resumeTask(id: UUID) {
        if let index = tasks.firstIndex(where: { $0.id == id }) {
            tasks[index].state = .waiting
            tasks[index].errorMessage = nil
            saveTasks()
            processNextTasks()
        }
    }
    
    func resumeAll() {
        var changed = false
        for index in tasks.indices {
            if tasks[index].state == .paused || tasks[index].state == .error {
                tasks[index].state = .waiting
                tasks[index].errorMessage = nil
                changed = true
            }
        }
        if changed {
            saveTasks()
            processNextTasks()
        }
    }
    
    func deleteTask(id: UUID) {
        pauseTask(id: id)
        
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            let task = tasks[idx]
            tasks.remove(at: idx)
            saveTasks()
            
            // Note: we don't automatically delete the interrupted `.smbupload` file on the NAS to allow for manual recovery.
        }
        processNextTasks()
    }
    
    func deleteAllActive() {
        let activeTaskIds = tasks.filter { $0.state == .uploading || $0.state == .waiting || $0.state == .paused || $0.state == .error }.map { $0.id }
        
        Task.detached {
            try? await withThrowingTaskGroup(of: Void.self) { group in
                for taskId in activeTaskIds {
                    if let uploader = await self.uploaders[taskId] {
                        group.addTask { await uploader.pause() }
                    }
                }
                while try await group.next() != nil { }
            }
            
            await MainActor.run {
                self.tasks.removeAll { activeTaskIds.contains($0.id) }
                self.saveTasks()
                self.processNextTasks()
            }
        }
    }
    
    // Called when sleep is imminent
    func cancelAllAndShutdown() {
        for index in tasks.indices {
            if tasks[index].state == .uploading || tasks[index].state == .waiting {
                tasks[index].state = .paused
            }
        }
        saveTasks()
        
        for (_, uploader) in uploaders {
            Task {
                await uploader.pause()
            }
        }
    }
    
    private func processNextTasks() {
        guard !isPausingAll else { return }
        let uploadingCount = tasks.filter { $0.state == .uploading }.count
        let availableSlots = maxConcurrentTasks - uploadingCount
        
        if availableSlots > 0 {
            let waitingTasks = tasks.filter { $0.state == .waiting }
            let tasksToStart = waitingTasks.prefix(availableSlots)
            
            for task in tasksToStart {
                startUploading(task: task)
            }
        }
    }
    
    private func startUploading(task: UploadTaskModel) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index].state = .uploading
        }
        
        let uploader = ChunkUploader(task: task) { [weak self] updatedTask in
            Task { @MainActor in
                self?.updateTask(updatedTask)
            }
        }
        
        uploaders[task.id] = uploader
        Task {
            await uploader.start()
        }
    }
    
    // MARK: - Update Loop
    
    private func updateTask(_ task: UploadTaskModel) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        
        let currentState = tasks[index].state
        var updatedTask = task
        
        // Anti-bounce mechanism to prevent slow async packets from overwriting user UI intent
        if (currentState == .paused || currentState == .completed || currentState == .error) && task.state == .uploading {
            updatedTask.state = currentState
        }
        
        // Retain totalBytes if we already have it
        if updatedTask.totalBytes == 0 && tasks[index].totalBytes > 0 {
            updatedTask.totalBytes = tasks[index].totalBytes
        }
        
        tasks[index] = updatedTask
        
        let finalState = tasks[index].state
        if finalState != currentState {
            if finalState == .completed {
                AppLogger.shared.info("[UploadManager] Completed task: \(tasks[index].sourceURL.lastPathComponent)")
                NotificationCenter.default.post(name: NSNotification.Name("UploadTaskCompleted"), object: nil, userInfo: ["fileName": tasks[index].sourceURL.lastPathComponent])
            } else if finalState == .error {
                AppLogger.shared.error("[UploadManager] Task failed: \(tasks[index].sourceURL.lastPathComponent)")
            }
        }
        
        if finalState == .completed || finalState == .error || finalState == .paused {
            saveTasks()
            if finalState == .completed || finalState == .error {
                uploaders.removeValue(forKey: task.id)
                processNextTasks()
            }
        }
    }
}
