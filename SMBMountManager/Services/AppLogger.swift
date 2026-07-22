import Foundation

enum LogLevel: String {
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()
    private let logFileURL: URL
    private let queue = DispatchQueue(label: "org.imstevelin.SMBMountClientV3.logger")
    
    // DateFormatter setup based on MountEngine timestamp logic
    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let managerDir = appSupport.appendingPathComponent("SMBMountClientV3")
        
        try? fm.createDirectory(at: managerDir, withIntermediateDirectories: true)
        logFileURL = managerDir.appendingPathComponent("App.log")

        // Keep background reconnect failures from growing the log forever.
        if let size = (try? fm.attributesOfItem(atPath: logFileURL.path)[.size]) as? NSNumber,
           size.int64Value > 5 * 1024 * 1024 {
            let previousURL = managerDir.appendingPathComponent("App.previous.log")
            try? fm.removeItem(at: previousURL)
            try? fm.moveItem(at: logFileURL, to: previousURL)
        }
        
        // Check if file exists, if not create it
        if !fm.fileExists(atPath: logFileURL.path) {
            fm.createFile(atPath: logFileURL.path, contents: nil)
        }
        
        // Log app startup
        log("Logging initialized. Writing to \(logFileURL.path)", level: .info)
    }

    func log(_ message: String, level: LogLevel = .info) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            let timestamp = self.dateFormatter.string(from: Date())
            let logLine = "[\(timestamp)] [\(level.rawValue)] \(message)\n"
            
            // Output to console during debug
            #if DEBUG
            print(logLine, terminator: "")
            #endif
            
            if let handle = try? FileHandle(forWritingTo: self.logFileURL) {
                handle.seekToEndOfFile()
                if let data = logLine.data(using: .utf8) {
                    handle.write(data)
                }
                try? handle.close()
            } else {
                // Fallback attempt if file was manually deleted
                if let data = logLine.data(using: .utf8) {
                    try? data.write(to: self.logFileURL, options: .atomic)
                }
            }
        }
    }
    
    // Convenience methods
    func info(_ message: String) { log(message, level: .info) }
    func warn(_ message: String) { log(message, level: .warn) }
    func error(_ message: String) { log(message, level: .error) }
    
    // For reading by the LogViewerTab
    func readLogs() -> String {
        queue.sync {
            guard let data = try? Data(contentsOf: logFileURL),
                  let content = String(data: data, encoding: .utf8) else {
                return "Unable to read logs or no logs available."
            }
            return content
        }
    }
    
    // Gets the path directly for things like opening in standard apps
    var logPath: String {
        return logFileURL.path
    }
}
