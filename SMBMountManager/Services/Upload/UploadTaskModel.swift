import Foundation

enum UploadState: String, Codable, Equatable {
    case waiting
    case uploading
    case paused
    case completed
    case error
}

struct UploadTaskModel: Codable, Identifiable, Equatable {
    var id: UUID
    var sourceURL: URL               // The local file path on the Mac
    var mountId: String              // To fetch credentials and server info from MountManager
    var relativeSMBPath: String      // The path on the SMB share, e.g., "Movies/video.mp4"
    var totalBytes: UInt64
    
    var state: UploadState
    var errorMessage: String?
    var uploadedBytes: UInt64        // Current bytes uploaded
    var creationDate: Date
    var lastModificationDate: Date?  // To check if the local file changed during pauses
    
    // Non-persisted transient UI properties
    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(uploadedBytes) / Double(totalBytes)
    }
    
    init(id: UUID = UUID(), sourceURL: URL, mountId: String, relativeSMBPath: String, totalBytes: UInt64 = 0, lastModificationDate: Date? = nil) {
        self.id = id
        self.sourceURL = sourceURL
        self.mountId = mountId
        self.relativeSMBPath = relativeSMBPath
        self.totalBytes = totalBytes
        self.state = .waiting
        self.uploadedBytes = 0
        self.creationDate = Date()
        self.lastModificationDate = lastModificationDate
    }
}
