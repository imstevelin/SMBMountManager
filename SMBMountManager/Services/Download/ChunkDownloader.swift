import Foundation

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
        
        // Find configuration and credentials
        guard let mount = await MainActor.run(resultType: MountPoint?.self, body: {
            AppLifecycle.shared.mountManager?.mounts.first(where: { $0.id == task.mountId })
        }) else {
            fail(with: "找不到對應的掛載點資訊")
            return
        }
        
        // Use local mount path since it's already mounted by the OS
        let sourceURL = URL(fileURLWithPath: mount.mountPath).appendingPathComponent(task.relativeSMBPath)
        
        if task.totalBytes == 0 {
            do {
                if !FileManager.default.fileExists(atPath: sourceURL.path) {
                    fail(with: "來源檔案不存在或尚未連線")
                    return
                }
                
                let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
                guard let size = attributes[.size] as? UInt64 else {
                    fail(with: "無法取得檔案大小")
                    return
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
        
        await downloadPendingChunks(sourceURL: sourceURL)
    }
    
    private func downloadPendingChunks(sourceURL: URL) async {
        let pendingChunkIndices = task.chunks.indices.filter { !task.chunks[$0].isCompleted }
        
        if pendingChunkIndices.isEmpty {
            completeTask()
            return
        }
        
        do {
            let writeHandle = try FileHandle(forUpdating: task.destinationURL)
            defer { try? writeHandle.close() }
            
            try await withThrowingTaskGroup(of: Void.self) { group in
                var concurrentCount = 0
                
                for index in pendingChunkIndices {
                    if isPaused { break }
                    
                    if concurrentCount >= maxConcurrentConnections {
                        try await group.next()
                        concurrentCount -= 1
                    }
                    
                    if isPaused { break }
                    
                    concurrentCount += 1
                    group.addTask {
                        try await self.downloadChunk(at: index, sourceURL: sourceURL, writeHandle: writeHandle)
                    }
                }
                
                while try await group.next() != nil {
                    // completion
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
    
    private func downloadChunk(at index: Int, sourceURL: URL, writeHandle: FileHandle) async throws {
        let chunk = task.chunks[index]
        if chunk.isCompleted { return }
        
        let readHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? readHandle.close() }
        
        var currentOffset = chunk.startOffset + chunk.downloadedBytes
        let endOffset = chunk.startOffset + chunk.expectedSize
        let bufferSize: UInt64 = 1024 * 1024 // 1MB buffer
        
        while currentOffset < endOffset && !isPaused {
            let readSize = Int(min(bufferSize, endOffset - currentOffset))
            
            try readHandle.seek(toOffset: currentOffset)
            guard let data = try readHandle.read(upToCount: readSize), !data.isEmpty else { break }
            
            fileLock.lock()
            try writeHandle.seek(toOffset: currentOffset)
            try writeHandle.write(contentsOf: data)
            fileLock.unlock()
            
            currentOffset += UInt64(data.count)
            let downloaded = currentOffset - chunk.startOffset
            
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
            
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
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
