import Foundation

enum DownloadState: String, Codable, Equatable {
    case waiting
    case downloading
    case paused
    case completed
    case error
}

struct DownloadChunk: Codable, Identifiable, Equatable {
    var id: Int
    var startOffset: UInt64
    var expectedSize: UInt64
    var downloadedBytes: UInt64
    
    var isCompleted: Bool {
        return downloadedBytes >= expectedSize
    }
    
    var remainingBytes: UInt64 {
        return expectedSize > downloadedBytes ? expectedSize - downloadedBytes : 0
    }
}

struct DownloadTaskModel: Codable, Identifiable, Equatable {
    var id: UUID
    var fileName: String
    var mountId: String            // To fetch credentials and server info from MountManager
    var relativeSMBPath: String    // The path on the SMB share, e.g., "Movies/video.mp4"
    var destinationURL: URL        // Where to save on local Mac
    
    var totalBytes: UInt64
    var state: DownloadState
    var errorMessage: String?
    var chunks: [DownloadChunk]
    var creationDate: Date
    
    // Non-persisted transient UI properties can be calculated
    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(downloadedBytes) / Double(totalBytes)
    }
    
    var downloadedBytes: UInt64 {
        chunks.reduce(0) { $0 + $1.downloadedBytes }
    }
    
    init(id: UUID = UUID(), fileName: String, mountId: String, relativeSMBPath: String, destinationURL: URL, totalBytes: UInt64 = 0) {
        self.id = id
        self.fileName = fileName
        self.mountId = mountId
        self.relativeSMBPath = relativeSMBPath
        self.destinationURL = destinationURL
        self.totalBytes = totalBytes
        self.state = .waiting
        self.chunks = []
        self.creationDate = Date()
    }
}
