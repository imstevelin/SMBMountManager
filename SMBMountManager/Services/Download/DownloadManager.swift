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
    
    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let managerDir = appSupport.appendingPathComponent("SMBMountManager/Downloads")
        try? FileManager.default.createDirectory(at: managerDir, withIntermediateDirectories: true)
        self.storageURL = managerDir.appendingPathComponent("tasks.json")
        
        loadTasks()
    }
    
    private func loadTasks() {
        guard let data = try? Data(contentsOf: storageURL),
              let savedTasks = try? JSONDecoder().decode([DownloadTaskModel].self, from: data) else {
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
        Task { @MainActor in
            if let data = try? JSONEncoder().encode(tasks) {
                try? data.write(to: storageURL, options: .atomic)
            }
        }
    }
    
    func addTasks(batch: [(fileName: String, mountId: String, relativeSMBPath: String, destinationURL: URL)]) {
        var newTasks: [DownloadTaskModel] = []
        for item in batch {
            let task = DownloadTaskModel(
                fileName: item.fileName,
                mountId: item.mountId,
                relativeSMBPath: item.relativeSMBPath,
                destinationURL: item.destinationURL
            )
            newTasks.append(task)
        }
        tasks.append(contentsOf: newTasks)
        saveTasks()
        processQueue()
    }
    
    func addTask(fileName: String, mountId: String, relativeSMBPath: String, destinationURL: URL) {
        addTasks(batch: [(fileName, mountId, relativeSMBPath, destinationURL)])
    }
    
    private func processQueue() {
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
        
        let taskModel = tasks[index]
        let downloader = ChunkDownloader(task: taskModel) { [weak self] updatedTask in
            Task { @MainActor in
                self?.updateTask(updatedTask)
            }
        }
        downloaders[id] = downloader
        
        Task {
            await downloader.start()
        }
    }
    
    func pauseTask(id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].state = .paused
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
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        
        Task {
            await downloaders[id]?.pause()
            
            DispatchQueue.main.async {
                // Remove partial file
                let dest = self.tasks[index].destinationURL
                try? FileManager.default.removeItem(at: dest)
                
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
        for index in tasks.indices where tasks[index].state == .downloading || tasks[index].state == .waiting {
            tasks[index].state = .paused
            
            let id = tasks[index].id
            Task {
                await downloaders[id]?.pause()
                DispatchQueue.main.async {
                    self.downloaders.removeValue(forKey: id)
                }
            }
        }
        saveTasks()
    }
    
    func deleteAll() {
        // Snapshot to avoid index-out-of-bounds crashes during async deletion
        let tasksSnapshot = tasks
        tasks.removeAll()
        saveTasks()
        
        for task in tasksSnapshot {
            let id = task.id
            let dest = task.destinationURL
            Task {
                await downloaders[id]?.pause()
                
                DispatchQueue.main.async {
                    try? FileManager.default.removeItem(at: dest)
                    self.downloaders.removeValue(forKey: id)
                }
            }
        }
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
        if finalState == .completed || finalState == .error || finalState == .paused {
            saveTasks() // Ensure final state is saved
            if finalState == .completed || finalState == .error {
                downloaders.removeValue(forKey: task.id)
                processQueue() // Free up queue slot
            }
        }
    }
}
