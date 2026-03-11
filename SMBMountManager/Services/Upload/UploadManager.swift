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
    
    // Global and Per-Task Speed Tracking
    @Published var currentSpeedBytesPerSecond: Int64 = 0
    @Published var taskSpeeds: [UUID: Int64] = [:]
    @Published var taskETASpeeds: [UUID: Int64] = [:]
    
    private var speedTrackers: [UUID: SpeedTracker] = [:]
    private var speedTimer: Timer?
    
    private let emaSmoothingFactor: Double = 0.3  // α: higher = more responsive, lower = smoother
    private let etaSmoothingFactor: Double = 0.02  // Much slower α for a stable ETA that represents the last ~50 seconds
    private let emaWarmUpFactor: Double = 0.5       // α for the first N samples (fast ramp)
    private let emaWarmUpSamples: Int = 5           // Use warm-up α for this many samples
    private var lastSpeedSampleTime: Date = Date()
    
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
    
    /// Reset speed tracking state. Call when uploads start or resume for instant accurate readings.
    // (Removed resetSpeedTracking as trackers self-manage via the timer loop)
    
    private func startSpeedMeasurement() {
        speedTimer?.invalidate()
        lastSpeedSampleTime = Date()
        
        // Ensure trackers exist for currently uploading tasks
        for task in tasks where task.state == .uploading {
            if speedTrackers[task.id] == nil {
                speedTrackers[task.id] = SpeedTracker(lastBytes: task.uploadedBytes, lastTrackedTime: Date())
            }
        }
        
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            // Use DispatchQueue.main.async instead of Task { @MainActor } to avoid
            // event loop starvation when the window is inactive.
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                var totalGlobalSpeed: Int64 = 0
                var activeTaskIds = Set<UUID>()
                let now = Date()
                
                for task in self.tasks {
                    if task.state == .uploading {
                        activeTaskIds.insert(task.id)
                        var tracker = self.speedTrackers[task.id] ?? SpeedTracker(lastBytes: task.uploadedBytes, lastTrackedTime: now)
                        
                        let elapsed = now.timeIntervalSince(tracker.lastTrackedTime)
                        
                        // Only update if at least roughly 1 second has passed
                        if elapsed >= 0.5 {
                            let bytesDelta = task.uploadedBytes >= tracker.lastBytes
                                ? Double(task.uploadedBytes - tracker.lastBytes)
                                : 0.0
                            let instantSpeed = bytesDelta / elapsed
                            
                            let alpha = tracker.emaSampleCount < self.emaWarmUpSamples ? self.emaWarmUpFactor : self.emaSmoothingFactor
                            let etaAlpha = tracker.emaSampleCount < self.emaWarmUpSamples ? 0.3 : self.etaSmoothingFactor
                            
                            if tracker.emaSpeed == 0 && instantSpeed > 0 {
                                tracker.emaSpeed = instantSpeed
                                tracker.etaEmaSpeed = instantSpeed
                            } else {
                                tracker.emaSpeed = alpha * instantSpeed + (1.0 - alpha) * tracker.emaSpeed
                                tracker.etaEmaSpeed = etaAlpha * instantSpeed + (1.0 - etaAlpha) * tracker.etaEmaSpeed
                            }
                            
                            tracker.emaSampleCount += 1
                            
                            // Bounds clamp
                            if tracker.etaEmaSpeed > 0 && tracker.emaSpeed > 0 {
                                if tracker.etaEmaSpeed < tracker.emaSpeed * 0.3 {
                                    tracker.etaEmaSpeed = tracker.emaSpeed * 0.5
                                } else if tracker.etaEmaSpeed > tracker.emaSpeed * 3.0 {
                                    tracker.etaEmaSpeed = tracker.emaSpeed * 2.0
                                }
                            }
                            
                            tracker.lastBytes = task.uploadedBytes
                            tracker.lastTrackedTime = now
                            self.speedTrackers[task.id] = tracker
                            
                            let currentTaskSpeed = Int64(tracker.emaSpeed)
                            self.taskSpeeds[task.id] = currentTaskSpeed
                            self.taskETASpeeds[task.id] = Int64(tracker.etaEmaSpeed)
                        }
                        
                        totalGlobalSpeed += self.taskSpeeds[task.id] ?? 0
                    }
                }
                
                // Cleanup trackers for non-uploading tasks
                let toRemove = self.speedTrackers.keys.filter { !activeTaskIds.contains($0) }
                for id in toRemove {
                    self.speedTrackers.removeValue(forKey: id)
                    self.taskSpeeds.removeValue(forKey: id)
                    self.taskETASpeeds.removeValue(forKey: id)
                }
                
                self.currentSpeedBytesPerSecond = totalGlobalSpeed
                
                // Coalesce all the dictionary changes above into a single objectWillChange
                self.objectWillChange.send()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        speedTimer = timer
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
                // Only resume if the mount point is actually mounted
                if let mount = AppLifecycle.shared.mountManager?.mounts.first(where: { $0.id == tasks[index].mountId }) {
                    guard MountManager.isMounted(mount.mountPath) else {
                        continue  // Skip — mount not ready
                    }
                }
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
    
    /// Resume only tasks belonging to a specific mount point (called when a mount comes online).
    func resumeTasksForMount(mountId: String) {
        var changed = false
        for index in tasks.indices where tasks[index].mountId == mountId {
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
            
            // Note: User requested to explicitly delete `.smbupload` when a task is cancelled.
            if let mount = AppLifecycle.shared.mountManager?.mounts.first(where: { $0.id == task.mountId }) {
                let destURL = URL(fileURLWithPath: mount.mountPath).appendingPathComponent(task.relativeSMBPath)
                let uploadURL = destURL.appendingPathExtension("smbupload")
                try? FileManager.default.removeItem(at: uploadURL)
            }
            
            tasks.remove(at: idx)
            saveTasks()
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
                for task in self.tasks where activeTaskIds.contains(task.id) {
                    if let mount = AppLifecycle.shared.mountManager?.mounts.first(where: { $0.id == task.mountId }) {
                        let destURL = URL(fileURLWithPath: mount.mountPath).appendingPathComponent(task.relativeSMBPath)
                        let uploadURL = destURL.appendingPathExtension("smbupload")
                        try? FileManager.default.removeItem(at: uploadURL)
                    }
                }
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
        // Pre-flight check: verify the mount point is actually mounted before starting
        if let mount = AppLifecycle.shared.mountManager?.mounts.first(where: { $0.id == task.mountId }) {
            guard MountManager.isMounted(mount.mountPath) else {
                // Mount is not ready — keep task in waiting state so it can be retried later
                AppLogger.shared.info("[UploadManager] Mount \(mount.name) not ready, deferring task \(task.sourceURL.lastPathComponent)")
                if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                    tasks[index].state = .paused
                    tasks[index].errorMessage = "掛載點尚未就緒，請在掛載完成後手動繼續。"
                    saveTasks()
                }
                return
            }
        }
        
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index].state = .uploading
        }
        
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        
        // CRITICAL: Must pass tasks[index] which has the .uploading state,
        // not the stale 'task' parameter which still has .waiting state!
        let uploader = ChunkUploader(task: tasks[index]) { [weak self] updatedTask in
            DispatchQueue.main.async {
                self?.updateTask(updatedTask)
            }
        }
        
        uploaders[task.id] = uploader
        Task.detached {
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
        
        // Only mutate the @Published array if something actually changed,
        // to avoid redundant SwiftUI state graph updates that can crash AttributeGraph.
        let existing = tasks[index]
        if existing.uploadedBytes != updatedTask.uploadedBytes || existing.state != updatedTask.state || existing.errorMessage != updatedTask.errorMessage || existing.totalBytes != updatedTask.totalBytes {
            tasks[index] = updatedTask
        }
        
        let finalState = tasks[index].state
        if finalState != currentState {
            if finalState == .completed {
                AppLogger.shared.info("[UploadManager] Completed task: \(tasks[index].sourceURL.lastPathComponent)")
                NotificationCenter.default.post(name: NSNotification.Name("UploadTaskCompleted"), object: nil, userInfo: ["fileName": tasks[index].sourceURL.lastPathComponent])
            } else if finalState == .error {
                AppLogger.shared.error("[UploadManager] Task failed: \(tasks[index].sourceURL.lastPathComponent)")
                // Note: We deliberately DO NOT remove `.smbupload` upon error.
                // Keeping the `.smbupload` file allows the backend engine to auto-resume
                // from the last acknowledged byte when the network reconnects.
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
