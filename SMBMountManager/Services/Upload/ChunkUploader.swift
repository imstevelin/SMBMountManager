import Foundation

class ChunkUploader {
    private var task: UploadTaskModel
    private let onProgress: (UploadTaskModel) -> Void
    private var isPaused = false
    
    // Chunk size: 1MB per chunk for optimal SMB transfer balance, allowing the kernel to interleave other commands
    private let chunkSize: UInt64 = 1 * 1024 * 1024 
    
    private let taskLock = NSLock()
    private var lastProgressUpdateTime: Date = Date()
    
    init(task: UploadTaskModel, onProgress: @escaping (UploadTaskModel) -> Void) {
        self.task = task
        self.onProgress = onProgress
    }
    
    func pause() async {
        isPaused = true
    }
    
    func start() async {
        guard !isPaused else { return }
        
        let localSourceURL = task.sourceURL
        
        // Find configuration and credentials
        guard let mount = await MainActor.run(resultType: MountPoint?.self, body: {
            AppLifecycle.shared.mountManager?.mounts.first(where: { $0.id == task.mountId })
        }) else {
            fail(with: "找不到對應的掛載點資訊")
            return
        }
        
        // Final destination path on the mounted volume
        let destURL = URL(fileURLWithPath: mount.mountPath).appendingPathComponent(task.relativeSMBPath)
        
        // Temporary upload path to protect incomplete files
        let uploadURL = destURL.appendingPathExtension("smbupload")
        
        do {
            // CRITICAL SAFETY CHECK: Verify the mount path is an actual mounted SMB volume,
            // not a rogue local directory. We use statfs() to inspect the filesystem type.
            // FileManager.fileExists is insufficient — it returns true for local rogue dirs too.
            guard Self.isMountPathActuallyMounted(mount.mountPath) else {
                fail(with: "掛載點尚未就緒（非有效掛載），為防止建立虛假路徑，已中止上傳。")
                return
            }
            
            // Check local file access and size
            if !FileManager.default.fileExists(atPath: localSourceURL.path) {
                fail(with: "本機來源檔案不存在")
                return
            }
            let localAttributes = try FileManager.default.attributesOfItem(atPath: localSourceURL.path)
            guard let totalSize = localAttributes[.size] as? UInt64 else {
                fail(with: "無法取得本機檔案大小")
                return
            }
            
            var remoteFileSize: UInt64 = 0
            
            // Check if temporary upload file exists for resuming
            if FileManager.default.fileExists(atPath: uploadURL.path) {
                let remoteAttributes = try FileManager.default.attributesOfItem(atPath: uploadURL.path)
                remoteFileSize = remoteAttributes[.size] as? UInt64 ?? 0
                
                // Rollback 1MB (or up to 0) to prevent EOF packet drops leading to corrupted boundary
                let rollbackAmount: UInt64 = 1 * 1024 * 1024
                if remoteFileSize > rollbackAmount {
                    remoteFileSize -= rollbackAmount
                } else {
                    remoteFileSize = 0
                }
            } else {
                // If the target completely doesn't exist, create an empty file
                let parentDir = uploadURL.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: parentDir.path) {
                    // Double-check mount is still alive before creating directories
                    guard Self.isMountPathActuallyMounted(mount.mountPath) else {
                        fail(with: "掛載點在傳輸準備期間斷開，為防止建立虛假路徑，已中止上傳。")
                        return
                    }
                    try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
                }
                FileManager.default.createFile(atPath: uploadURL.path, contents: nil)
            }
            
            // Validate local file modification date to prevent uploading changed files
            let localModificationDate = localAttributes[.modificationDate] as? Date
            if let savedDate = task.lastModificationDate, let currentDate = localModificationDate {
                if abs(savedDate.timeIntervalSince(currentDate)) > 1.0 {
                    // File modified! Start over for safety.
                    remoteFileSize = 0
                    try? FileManager.default.removeItem(at: uploadURL)
                    FileManager.default.createFile(atPath: uploadURL.path, contents: nil)
                }
            }
            
            taskLock.lock()
            task.totalBytes = totalSize
            task.uploadedBytes = remoteFileSize
            task.lastModificationDate = localModificationDate
            task.state = .uploading
            let updatedTask = task
            taskLock.unlock()
            
            DispatchQueue.main.async { self.onProgress(updatedTask) }
            
            // Start transfer
            try await performTransfer(localSourceURL: localSourceURL, uploadURL: uploadURL, finalDestURL: destURL, startOffset: remoteFileSize)
            
        } catch {
            if !isPaused {
                fail(with: "檔案初始化失敗：\(error.localizedDescription)")
            }
        }
    }
    
    private func performTransfer(localSourceURL: URL, uploadURL: URL, finalDestURL: URL, startOffset: UInt64) async throws {
        let readHandle = try FileHandle(forReadingFrom: localSourceURL)
        defer { try? readHandle.close() }
        
        let writeHandle = try FileHandle(forUpdating: uploadURL)
        defer { try? writeHandle.close() }
        
        var currentOffset = startOffset
        let totalSize = task.totalBytes
        
        try readHandle.seek(toOffset: currentOffset)
        try writeHandle.seek(toOffset: currentOffset)
        
        while currentOffset < totalSize && !isPaused {
            let readSize = Int(min(chunkSize, totalSize - currentOffset))
            
            // Read from local
            guard let data = try readHandle.read(upToCount: readSize), !data.isEmpty else { break }
            
            // Write to SMB mount
            try writeHandle.write(contentsOf: data)
            currentOffset += UInt64(data.count)
            
            let now = Date()
            taskLock.lock()
            self.task.uploadedBytes = currentOffset
            
            let shouldUpdate = now.timeIntervalSince(self.lastProgressUpdateTime) > 0.25 || currentOffset >= totalSize
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
            
            // Explicitly sleep for 10ms to give the macOS SMB kernel driver breathing room
            // for processing `stat` and directory enumeration queries concurrently.
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        
        if isPaused { return }
        
        // If we reached here without pausing, complete the task
        if currentOffset >= totalSize {
            // Rename from .smbupload to final name
            if FileManager.default.fileExists(atPath: finalDestURL.path) {
                try? FileManager.default.removeItem(at: finalDestURL)
            }
            try FileManager.default.moveItem(at: uploadURL, to: finalDestURL)
            
            completeTask()
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
    
    /// Verifies that a mount path is actually backed by a real mounted network filesystem,
    /// not a rogue local directory. Uses `statfs()` to inspect the filesystem type.
    static func isMountPathActuallyMounted(_ path: String) -> Bool {
        var stat = statfs()
        guard statfs(path, &stat) == 0 else {
            // Path doesn't exist or is inaccessible
            return false
        }
        
        // Extract the filesystem type name (e.g. "smbfs", "nfs", "webdavfs", "apfs", "hfs")
        let fsTypeName = withUnsafePointer(to: &stat.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                String(cString: $0)
            }
        }
        
        // Only network filesystem types are valid mount points
        let networkFSTypes: Set<String> = ["smbfs", "nfs", "webdavfs", "afpfs", "cifs"]
        return networkFSTypes.contains(fsTypeName.lowercased())
    }
}
