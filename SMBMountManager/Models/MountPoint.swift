import Foundation
import SwiftUI

/// Represents a configured SMB mount point
struct MountPoint: Identifiable, Codable, Hashable {
    var id: String { name }
    let name: String           // e.g. "nas_share" → /Volumes/nas_share
    let servers: [String]      // e.g. ["nas.local", "192.168.1.10"]
    let shareName: String      // SMB share name (can differ from mount name)
    let username: String
    let useKeychain: Bool
    let mountOptions: String   // e.g. "nobrowse,soft"
    var showInSidebar: Bool = true
    var createDesktopShortcut: Bool = false
    var allowedSSIDs: [String] = []  // Empty = allow all networks

    var mountPath: String { "/Volumes/\(name)" }
    var logPath: String {
        "\(NSHomeDirectory())/Library/Logs/mount_\(name).log"
    }
    var keychainService: String { "smb_mount_\(name)" }
    var serversCSV: String { servers.joined(separator: ",") }

    // Config persistence path (JSON)
    static var configDirectory: String {
        "\(NSHomeDirectory())/Library/Application Support/SMBMountManager/mounts"
    }

    var configPath: String {
        "\(Self.configDirectory)/\(name).json"
    }

    // MARK: - Persistence

    func save() throws {
        let dir = Self.configDirectory
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: URL(fileURLWithPath: configPath))
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: configPath)
    }

    static func loadAll() -> [MountPoint] {
        let dir = configDirectory
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return files
            .filter { $0.hasSuffix(".json") }
            .compactMap { file -> MountPoint? in
                let path = "\(dir)/\(file)"
                guard let data = fm.contents(atPath: path) else { return nil }
                do {
                    return try JSONDecoder().decode(MountPoint.self, from: data)
                } catch {
                    // Try decoding with missing newer properties backwards-compatibly if we need to.
                    // Swift's default Codable synthesis fails if a field is missing, even with default struct values.
                    return decodeLegacy(data: data)
                }
            }
            .sorted { $0.name < $1.name }
    }

    private static func decodeLegacy(data: Data) -> MountPoint? {
       // Temporary legacy struct that exactly matches the old format
       struct LegacyMountPoint: Codable {
           let name: String
           let servers: [String]
           let shareName: String
           let username: String
           let useKeychain: Bool
           let mountOptions: String
           var showInSidebar: Bool?
           var createDesktopShortcut: Bool?
       }
       guard let legacy = try? JSONDecoder().decode(LegacyMountPoint.self, from: data) else { return nil }
       return MountPoint(
           name: legacy.name,
           servers: legacy.servers,
           shareName: legacy.shareName,
           username: legacy.username,
           useKeychain: legacy.useKeychain,
           mountOptions: legacy.mountOptions,
           showInSidebar: legacy.showInSidebar ?? true,
           createDesktopShortcut: legacy.createDesktopShortcut ?? false,
           allowedSSIDs: []
       )
    }

    // MARK: - Export / Import

    /// Lightweight export model (no passwords)
    struct ExportProfile: Codable {
        let version: Int
        let exportDate: String
        let mounts: [MountPoint]
    }

    static func exportAll() -> Data? {
        let allMounts = loadAll()
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        let profile = ExportProfile(
            version: 1,
            exportDate: formatter.string(from: Date()),
            mounts: allMounts
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(profile)
    }

    static func importMounts(from data: Data) -> (imported: [MountPoint], skipped: [String], error: String?) {
        let existing = Set(loadAll().map(\.name))
        guard let profile = try? JSONDecoder().decode(ExportProfile.self, from: data) else {
            return ([], [], "無法解析設定檔，格式可能不正確。")
        }
        var imported: [MountPoint] = []
        var skipped: [String] = []
        for mount in profile.mounts {
            if existing.contains(mount.name) {
                skipped.append(mount.name)
                continue
            }
            do {
                try mount.save()
                imported.append(mount)
            } catch {
                skipped.append(mount.name)
            }
        }
        return (imported, skipped, nil)
    }
}

/// Runtime status of a mount point
struct MountStatus: Identifiable {
    var id: String { name }
    let name: String
    var isMounted: Bool = false
    var isResponsive: Bool = false
    var isEngineRunning: Bool = false
    var isFailing: Bool = false
    var isPaused: Bool = false
    var isNetworkUp: Bool = true
    var latencyMs: Double? = nil        // Ping latency in ms, nil = unknown
    var capacityTotal: Int64? = nil     // Total volume capacity in bytes
    var capacityAvailable: Int64? = nil // Available capacity in bytes

    var overallIcon: String {
        if !isNetworkUp { return "externaldrive.badge.xmark" }
        if isMounted && isResponsive { return "externaldrive.fill.badge.checkmark" }
        if isMounted && !isResponsive { return "externaldrive.fill.badge.exclamationmark" }
        if isPaused { return "pause.circle.fill" }
        if isEngineRunning && !isFailing { return "arrow.triangle.2.circlepath" }
        return "externaldrive.badge.xmark"
    }

    var statusText: String {
        if !isNetworkUp { return "未連線" }
        if isMounted && isResponsive { return "已連線" }
        if isMounted && !isResponsive { return "無回應" }
        if isPaused { return "暫停中" }
        if isEngineRunning && !isFailing { return "連線中…" }
        return "未連線"
    }

    var latencyColor: Color {
        guard let ms = latencyMs else { return .secondary }
        if ms <= 20 { return .green }
        if ms <= 100 { return .yellow }
        return .red
    }

    var latencyText: String {
        guard let ms = latencyMs else { return "--" }
        if ms < 1 { return "<1ms" }
        return "\(Int(ms))ms"
    }

    var capacityUsedFraction: Double? {
        guard let total = capacityTotal, let available = capacityAvailable, total > 0 else { return nil }
        return Double(total - available) / Double(total)
    }

    var capacityDescription: String? {
        guard let total = capacityTotal, let available = capacityAvailable else { return nil }
        return "\(Self.formatBytes(total - available)) / \(Self.formatBytes(total))"
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

/// Status of system services (only fixer now)
struct SystemServiceStatus {
    var fixerInstalled: Bool = false

    var fixerStatusText: String {
        fixerInstalled ? "已安裝" : "未安裝"
    }
}
