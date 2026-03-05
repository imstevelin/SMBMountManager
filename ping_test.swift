import Foundation

func measureLatency(host: String) -> Double? {
    let task = Process()
    task.launchPath = "/sbin/ping"
    task.arguments = ["-c", "1", "-W", "1000", host]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        if task.terminationStatus == 0 {
            let output = String(data: data, encoding: .utf8) ?? ""
            if let range = output.range(of: "time=") {
                let after = output[range.upperBound...]
                let msString = after.prefix(while: { $0.isNumber || $0 == "." })
                print("Extracted msString: '\(msString)'")
                if let ms = Double(msString) {
                    return ms
                } else {
                    print("Failed to convert msString to Double")
                }
            } else {
                print("Missing time=")
                print(output)
            }
        } else {
            print("Ping failed with status: \(task.terminationStatus)")
        }
    } catch {
        print("Task run error: \(error)")
    }
    
    print("Fallback to nc")
    // Fallback: Measure TCP handshake time directly to SMB port 445
    let start = Date()
    let ncTask = Process()
    ncTask.launchPath = "/usr/bin/nc"
    ncTask.arguments = ["-z", "-w", "1", host, "445"] // 1s timeout
    ncTask.standardOutput = FileHandle.nullDevice
    ncTask.standardError = FileHandle.nullDevice
    do {
        try ncTask.run()
        ncTask.waitUntilExit()
        if ncTask.terminationStatus == 0 {
            let duration = Date().timeIntervalSince(start) * 1000.0
            return Double(round(100 * duration) / 100)
        } else {
            print("NC failed: \(ncTask.terminationStatus)")
        }
    } catch { 
        print("NC run error: \(error)")
    }

    return nil
}

print("Latency: \(String(describing: measureLatency(host: "10.0.1.1")))")
print("Latency: \(String(describing: measureLatency(host: "192.168.1.1")))")
