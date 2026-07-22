import Foundation
import SwiftUI

/// Represents a configured SMB mount point
struct MountPoint: Identifiable, Codable, Hashable, Sendable {
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
        "\(NSHomeDirectory())/Library/Application Support/SMBMountClientV3/App.log"
    }
    var keychainService: String { "smb_mount_\(name)" }
    var serversCSV: String { servers.joined(separator: ",") }

    // Config persistence path (JSON)
    static var configDirectory: String {
        "\(NSHomeDirectory())/Library/Application Support/SMBMountClientV3/mounts"
    }

    static var legacyConfigDirectory: String {
        "\(NSHomeDirectory())/Library/Application Support/SMBMountManager/mounts"
    }

    var configPath: String {
        "\(Self.configDirectory)/\(name).json"
    }

    // MARK: - Persistence

    func save() throws {
        guard Self.isValidName(name) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let dir = Self.configDirectory
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
    }

    func remove() {
        for directory in [Self.configDirectory, Self.legacyConfigDirectory] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("\(name).json", isDirectory: false)
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func loadAll() -> [MountPoint] {
        loadAll(from: [
            URL(fileURLWithPath: configDirectory, isDirectory: true),
            URL(fileURLWithPath: legacyConfigDirectory, isDirectory: true)
        ])
    }

    /// Loads configuration directories in priority order. The current directory
    /// is passed first so a migrated/edited profile wins over its legacy copy.
    static func loadAll(from directories: [URL]) -> [MountPoint] {
        let fm = FileManager.default
        var mountsByName: [String: MountPoint] = [:]

        for directory in directories {
            guard let files = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files where file.pathExtension.lowercased() == "json" {
                guard let data = try? Data(contentsOf: file),
                      let mount = try? JSONDecoder().decode(MountPoint.self, from: data),
                      mount.isStructurallyValid,
                      mountsByName[mount.name] == nil else { continue }
                mountsByName[mount.name] = mount
            }
        }

        return mountsByName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func isValidName(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0)
        }
    }

    var isStructurallyValid: Bool {
        Self.isValidName(name)
            && !servers.compactMap(SMBConnection.normalizedHost).isEmpty
            && !shareName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !shareName.contains("/")
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    static func importMounts(
        from data: Data,
        existingDirectories: [URL]? = nil,
        destinationDirectory: URL? = nil
    ) -> (imported: [MountPoint], skipped: [String], error: String?) {
        let existingMounts = existingDirectories.map(loadAll(from:)) ?? loadAll()
        var seenNames = Set(existingMounts.map(\.name))
        guard let profile = try? JSONDecoder().decode(ExportProfile.self, from: data) else {
            return ([], [], "無法解析設定檔，格式可能不正確。")
        }
        guard profile.version == 1 else {
            return ([], [], "不支援此設定檔版本（\(profile.version)）。")
        }
        var imported: [MountPoint] = []
        var skipped: [String] = []
        for mount in profile.mounts {
            guard mount.isStructurallyValid, seenNames.insert(mount.name).inserted else {
                skipped.append(mount.name)
                continue
            }
            let normalized = MountPoint(
                name: mount.name,
                servers: mount.servers.compactMap(SMBConnection.normalizedHost),
                shareName: mount.shareName.trimmingCharacters(in: .whitespacesAndNewlines),
                username: mount.username.trimmingCharacters(in: .whitespacesAndNewlines),
                useKeychain: true,
                mountOptions: mount.mountOptions,
                showInSidebar: mount.showInSidebar,
                createDesktopShortcut: mount.createDesktopShortcut,
                allowedSSIDs: Array(Set(mount.allowedSSIDs.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty })).sorted()
            )
            do {
                if let destinationDirectory {
                    try FileManager.default.createDirectory(
                        at: destinationDirectory,
                        withIntermediateDirectories: true
                    )
                    let destination = destinationDirectory
                        .appendingPathComponent("\(normalized.name).json", isDirectory: false)
                    try JSONEncoder().encode(normalized).write(to: destination, options: .atomic)
                } else {
                    try normalized.save()
                }
                imported.append(normalized)
            } catch {
                skipped.append(mount.name)
            }
        }
        return (imported, skipped, nil)
    }
}

extension MountPoint {
    private enum CodingKeys: String, CodingKey {
        case name, servers, shareName, username, useKeychain, mountOptions
        case showInSidebar, createDesktopShortcut, allowedSSIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        servers = try container.decode([String].self, forKey: .servers)
        shareName = try container.decode(String.self, forKey: .shareName)
        username = try container.decode(String.self, forKey: .username)
        useKeychain = try container.decodeIfPresent(Bool.self, forKey: .useKeychain) ?? true
        mountOptions = try container.decodeIfPresent(String.self, forKey: .mountOptions) ?? ""
        showInSidebar = try container.decodeIfPresent(Bool.self, forKey: .showInSidebar) ?? true
        createDesktopShortcut = try container.decodeIfPresent(Bool.self, forKey: .createDesktopShortcut) ?? false
        allowedSSIDs = try container.decodeIfPresent([String].self, forKey: .allowedSSIDs) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(servers, forKey: .servers)
        try container.encode(shareName, forKey: .shareName)
        try container.encode(username, forKey: .username)
        try container.encode(useKeychain, forKey: .useKeychain)
        try container.encode(mountOptions, forKey: .mountOptions)
        try container.encode(showInSidebar, forKey: .showInSidebar)
        try container.encode(createDesktopShortcut, forKey: .createDesktopShortcut)
        try container.encode(allowedSSIDs, forKey: .allowedSSIDs)
    }
}

/// Runtime status of a mount point
struct MountStatus: Identifiable, Equatable {
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
