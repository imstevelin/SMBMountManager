import Foundation
let p = "/Users/imstevelin/本地儲存"
if let attr = try? FileManager.default.attributesOfFileSystem(forPath: p) {
    if let free = attr[.systemFreeSize] as? NSNumber, let total = attr[.systemSize] as? NSNumber {
        print("total: \(total.int64Value), free: \(free.int64Value)")
    }
}
