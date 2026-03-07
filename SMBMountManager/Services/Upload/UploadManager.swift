import Foundation
import Combine

@MainActor
class UploadManager: ObservableObject {
    static let shared = UploadManager()
    
    @Published var tasks: [UploadTaskModel] = []
    
    private let storageURL: URL
    private let queue = DispatchQueue(label: "org.imstevelin.UploadManager", attributes: .concurrent)
    
    private let maxConcurrentTasks = 2 // SMB write concurrency should be lower than read to avoid directory locking
    private var uploaders: [UUID: ChunkUploader] = [:]
    
    // Upload speed tracking
    @Published var currentSpeedBytesPerSecond: Int64 = 0
    private var lastTotalBytesUploaded: Int64 = 0
    private var speedTimer: Timer?
    private var recentSpeeds: [Int64] = []
    private let maxRecentSpeeds = 3
    private var lastCalculatedSpeed: Int64 = 0
    
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
        Task { @MainActor in
            if let data = try? JSONEncoder().encode(tasks) {
                try? data.write(to: storageURL, options: .atomic)
            }
        }
    }
    
    func addTasks(batch: [(sourceURL: URL, mountId: String, relativeSMBPath: String)]) {
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
        
        if !newTasks.isEmpty {
            self.tasks.append(contentsOf: newTasks)
            self.saveTasks()
            
            for task in newTasks {
                processNextTasks()
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
        let taskIdsToPause = tasks.filter { $0.state == .uploading || $0.state == .waiting }.map { $0.id }
        
        for index in tasks.indices {
            if tasks[index].state == .uploading || tasks[index].state == .waiting {
                tasks[index].state = .paused
            }
        }
        self.saveTasks()
        
        for id in taskIdsToPause {
            if let uploader = uploaders[id] {
                Task { await uploader.pause() }
            }
        }
        
        processNextTasks()
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
            guard let self = self else { return }
            
            Task { @MainActor in
                if let index = self.tasks.firstIndex(where: { $0.id == updatedTask.id }) {
                    self.tasks[index] = updatedTask
                    
                    if updatedTask.state == .completed || updatedTask.state == .error || updatedTask.state == .paused {
                        self.uploaders.removeValue(forKey: updatedTask.id)
                        self.saveTasks()
                        self.processNextTasks()
                        
                        if updatedTask.state == .completed {
                            NotificationCenter.default.post(name: NSNotification.Name("UploadTaskCompleted"), object: nil, userInfo: ["fileName": updatedTask.sourceURL.lastPathComponent])
                        }
                    }
                }
            }
        }
        
        uploaders[task.id] = uploader
        Task {
            await uploader.start()
        }
    }
}
