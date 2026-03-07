import Foundation
import AMSMB2

class ChunkDownloader {
    private var task: DownloadTaskModel
    private let onProgress: (DownloadTaskModel) -> Void
    private var isPaused = false
    private let chunkSize: UInt64 = 10 * 1024 * 1024 // 10MB per chunk
    private let maxConcurrentConnections = 4
    
    private let fileLock = NSLock()
    private let taskLock = NSLock()
    private var lastProgressUpdateTime: Date = Date()
    
    init(task: DownloadTaskModel, onProgress: @escaping (DownloadTaskModel) -> Void) {
        self.task = task
        self.onProgress = onProgress
    }
    
    func pause() async {
        isPaused = true
    }
    
    func start() async {
        guard !isPaused else { return }
        
        // Find credentials
        guard let mount = await MainActor.run(resultType: MountPoint?.self, body: {
            AppLifecycle.shared.mountManager?.mounts.first(where: { $0.id == task.mountId })
        }) else {
            fail(with: "找不到對應的掛載點資訊")
            return
        }
        
        let password = KeychainService.getPassword(forMount: mount.name, username: mount.username) ?? ""
        var serverString = mount.servers.first ?? ""
        if !serverString.starts(with: "smb://") {
            serverString = "smb://" + serverString
        }
        guard let serverURL = URL(string: serverString) else {
            fail(with: "無效的伺服器位址")
            return
        }
        
        let credential = URLCredential(user: mount.username, password: password, persistence: .none)
        
        // 1. If totalBytes is 0, we need to fetch file info to know the size
        if task.totalBytes == 0 {
            do {
                guard let initialClient = SMB2Manager(url: serverURL, credential: credential) else {
                    fail(with: "無法初始化連線客戶端")
                    return
                }
                try await initialClient.connectShare(name: mount.shareName)
                
                let stats = try await initialClient.attributesOfItem(atPath: task.relativeSMBPath)
                guard let size = stats[.fileSizeKey] as? UInt64 else {
                    throw NSError(domain: "AMSMB2", code: -2, userInfo: [NSLocalizedDescriptionKey: "無法取得檔案大小"])
                }
                
                // Update total size
                task.totalBytes = size
                
                // Create chunks
                var chunks: [DownloadChunk] = []
                var offset: UInt64 = 0
                var chunkId = 0
                while offset < size {
                    let expected = min(self.chunkSize, size - offset)
                    chunks.append(DownloadChunk(id: chunkId, startOffset: offset, expectedSize: expected, downloadedBytes: 0))
                    offset += expected
                    chunkId += 1
                }
                taskLock.lock()
                task.chunks = chunks
                task.state = .downloading
                let updatedTask = task
                taskLock.unlock()
                
                onProgress(updatedTask)
                
                // Pre-allocate local file
                let dest = task.destinationURL
                if !FileManager.default.fileExists(atPath: dest.path) {
                    FileManager.default.createFile(atPath: dest.path, contents: nil)
                }
                let handle = try FileHandle(forUpdating: dest)
                try handle.truncate(atOffset: size)
                try handle.close()
                
            } catch {
                fail(with: "初始化檔案失敗：\(error.localizedDescription)")
                return
            }
        } else {
            taskLock.lock()
            task.state = .downloading
            let updatedTask = task
            taskLock.unlock()
            
            onProgress(updatedTask)
        }
        
        // 2. Start concurrent download of pending chunks
        await downloadPendingChunks(serverURL: serverURL, credential: credential, shareName: mount.shareName)
    }
    
    private func downloadPendingChunks(serverURL: URL, credential: URLCredential, shareName: String) async {
        let pendingChunkIndices = task.chunks.indices.filter { !task.chunks[$0].isCompleted }
        
        if pendingChunkIndices.isEmpty {
            completeTask()
            return
        }
        
        do {
            let handle = try FileHandle(forUpdating: task.destinationURL)
            defer { try? handle.close() }
            
            try await withThrowingTaskGroup(of: Void.self) { group in
                var concurrentCount = 0
                
                for index in pendingChunkIndices {
                    if isPaused { break }
                    
                    // Throttle
                    if concurrentCount >= maxConcurrentConnections {
                        try await group.next()
                        concurrentCount -= 1
                    }
                    
                    if isPaused { break }
                    
                    concurrentCount += 1
                    group.addTask {
                        try await self.downloadChunk(at: index, serverURL: serverURL, credential: credential, shareName: shareName, writeHandle: handle)
                    }
                }
                
                // Wait for remaining
                while try await group.next() != nil {
                    // Do nothing wait to finish
                }
            }
            
            if !isPaused {
                completeTask()
            }
        } catch {
            if !isPaused {
                fail(with: "下載過程發生錯誤：\(error.localizedDescription)")
            }
        }
    }
    
    private func downloadChunk(at index: Int, serverURL: URL, credential: URLCredential, shareName: String, writeHandle: FileHandle) async throws {
        let chunk = task.chunks[index]
        if chunk.isCompleted { return }
        
        // 1. Create a dedicated client for this chunk thread
        guard let client = SMB2Manager(url: serverURL, credential: credential) else {
            throw NSError(domain: "AMSMB2", code: -3, userInfo: [NSLocalizedDescriptionKey: "初始化連線失敗"])
        }
        try await client.connectShare(name: shareName)
        
        // 2. Read loop
        var currentOffset = chunk.startOffset + chunk.downloadedBytes
        let endOffset = chunk.startOffset + chunk.expectedSize
        let bufferSize: UInt64 = 1024 * 1024 // 1MB buffer
        
        while currentOffset < endOffset && !isPaused {
            let readSize = Int(min(bufferSize, endOffset - currentOffset))
            
            // Read from SMB server directly at offset
            guard let data = try? await client.contents(atPath: task.relativeSMBPath, range: currentOffset..<(currentOffset + UInt64(readSize))) else {
                throw NSError(domain: "AMSMB2", code: -4, userInfo: [NSLocalizedDescriptionKey: "讀取伺服器資料失敗"])
            }
            
            if data.isEmpty { break }
            
            // Thread-safe write to local file
            fileLock.lock()
            try writeHandle.seek(toOffset: currentOffset)
            try writeHandle.write(contentsOf: data)
            fileLock.unlock()
            
            currentOffset += UInt64(data.count)
            let downloaded = currentOffset - chunk.startOffset
            
            // Thread-safe update task progress and Throttle UI
            let now = Date()
            taskLock.lock()
            self.task.chunks[index].downloadedBytes = downloaded
            let shouldUpdate = now.timeIntervalSince(self.lastProgressUpdateTime) > 0.25 || currentOffset >= endOffset
            if shouldUpdate {
                self.lastProgressUpdateTime = now
            }
            let updatedTask = self.task
            taskLock.unlock()
            
            if shouldUpdate {
                DispatchQueue.main.async {
                    self.onProgress(updatedTask)
                }
            }
        }
        
        try await client.disconnectShare()
    }
    
    private func fail(with message: String) {
        taskLock.lock()
        task.state = .error
        task.errorMessage = message
        let updatedTask = task
        taskLock.unlock()
        
        DispatchQueue.main.async {
            self.onProgress(updatedTask)
        }
    }
    
    private func completeTask() {
        taskLock.lock()
        task.state = .completed
        let updatedTask = task
        taskLock.unlock()
        
        DispatchQueue.main.async {
            self.onProgress(updatedTask)
        }
    }
}
