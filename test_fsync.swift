import Foundation
import Darwin

func testFsync() throws {
    let url = URL(fileURLWithPath: "/tmp/test.txt")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let fileHandle = try FileHandle(forUpdating: url)
    
    // Test F_NOCACHE
    fcntl(fileHandle.fileDescriptor, F_NOCACHE, 1)
    
    // Test synchronize
    try fileHandle.synchronize()
}
