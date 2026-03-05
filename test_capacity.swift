import Foundation

let path = "/Users/imstevelin/本地儲存"
do {
    let attr = try FileManager.default.attributesOfFileSystem(forPath: path)
    if let systemSize = attr[.systemSize] as? NSNumber,
       let freeSize = attr[.systemFreeSize] as? NSNumber {
        print("Total: \(systemSize.int64Value), Free: \(freeSize.int64Value)")
    } else {
        print("Failed to cast attributes")
    }
} catch {
    print("Error: \(error)")
}
