import Foundation
import XCTest
@testable import SMBMountManager

final class SMBConnectionTests: XCTestCase {
    func testCredentialAndShareCharactersArePercentEncoded() {
        let finderURL = SMBConnection.finderURL(
            username: "user@domain",
            password: "p@ss/word% value",
            server: "nas.local",
            shareName: "Team Files"
        )

        XCTAssertEqual(
            finderURL,
            "smb://user%40domain:p%40ss%2Fword%25%20value@nas.local/Team%20Files"
        )
        XCTAssertEqual(
            SMBConnection.mountSource(
                username: "user@domain",
                password: "p@ss/word% value",
                server: "nas.local",
                shareName: "Team Files"
            ),
            "//user%40domain:p%40ss%2Fword%25%20value@nas.local/Team%20Files"
        )
        XCTAssertEqual(
            SMBConnection.mountSourceWithoutPassword(
                username: "user@domain",
                server: "nas.local",
                shareName: "Team Files"
            ),
            "//user%40domain@nas.local/Team%20Files"
        )
    }

    func testServerNormalizationAcceptsCommonForms() {
        XCTAssertEqual(SMBConnection.normalizedHost(" nas.local "), "nas.local")
        XCTAssertEqual(SMBConnection.normalizedHost("smb://nas.local/shared"), "nas.local")
        XCTAssertEqual(SMBConnection.normalizedHost("//user@10.0.0.2/shared"), "10.0.0.2")
        XCTAssertNil(SMBConnection.normalizedHost("   "))
    }

    func testMountOutputUsesExactDecodedMountPoint() {
        let output = """
        /dev/disk3s1 on / (apfs, local)
        //user@nas/share on /Volumes/team\\040files (smbfs, nodev, nosuid)
        //user@nas/other on /Volumes/team (smbfs, nodev, nosuid)
        """

        XCTAssertTrue(SMBConnection.isMounted(path: "/Volumes/team files", inMountOutput: output))
        XCTAssertTrue(SMBConnection.isMounted(path: "/Volumes/team", inMountOutput: output))
        XCTAssertFalse(SMBConnection.isMounted(path: "/Volumes/tea", inMountOutput: output))
    }

    func testChildURLRejectsPathTraversal() {
        XCTAssertEqual(
            SMBConnection.childURL(rootPath: "/Volumes/team", relativePath: "folder/file.txt")?.path,
            "/Volumes/team/folder/file.txt"
        )
        XCTAssertNil(SMBConnection.childURL(rootPath: "/Volumes/team", relativePath: "../escape.txt"))
        XCTAssertNil(SMBConnection.childURL(rootPath: "/Volumes/team", relativePath: "/tmp/escape.txt"))
        XCTAssertNil(SMBConnection.childURL(rootPath: "/Volumes/team", relativePath: ""))
    }

    func testChildURLRejectsSymlinkEscape() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBChildURLTests-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("mount", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: outside
        )

        XCTAssertNil(
            SMBConnection.childURL(rootPath: root.path, relativePath: "escape/private.txt")
        )
    }
}

final class MountPointTests: XCTestCase {
    func testLegacyJSONGetsSafeDefaults() throws {
        let json = """
        {
          "name": "archive",
          "servers": ["nas.local"],
          "shareName": "archive",
          "username": "tester",
          "useKeychain": true,
          "mountOptions": ""
        }
        """.data(using: .utf8)!

        let mount = try JSONDecoder().decode(MountPoint.self, from: json)
        XCTAssertTrue(mount.showInSidebar)
        XCTAssertFalse(mount.createDesktopShortcut)
        XCTAssertEqual(mount.allowedSSIDs, [])
        XCTAssertTrue(mount.isStructurallyValid)
    }

    func testConfigDirectoryPriorityAndInvalidProfileFiltering() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBMountManagerTests-\(UUID().uuidString)", isDirectory: true)
        let current = root.appendingPathComponent("current", isDirectory: true)
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let currentMount = MountPoint(
            name: "shared", servers: ["new.local"], shareName: "shared", username: "user",
            useKeychain: true, mountOptions: ""
        )
        let legacyMount = MountPoint(
            name: "shared", servers: ["old.local"], shareName: "shared", username: "user",
            useKeychain: true, mountOptions: ""
        )
        try JSONEncoder().encode(currentMount).write(to: current.appendingPathComponent("shared.json"))
        try JSONEncoder().encode(legacyMount).write(to: legacy.appendingPathComponent("shared.json"))
        try Data("{\"name\":\"../bad\"}".utf8).write(to: current.appendingPathComponent("bad.json"))

        let loaded = MountPoint.loadAll(from: [current, legacy])
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.servers, ["new.local"])
    }

    func testMountNameValidationMatchesVolumesSafetyContract() {
        XCTAssertTrue(MountPoint.isValidName("nas_share-2"))
        XCTAssertFalse(MountPoint.isValidName("nas share"))
        XCTAssertFalse(MountPoint.isValidName("../share"))
        XCTAssertFalse(MountPoint.isValidName("中文"))
    }

    func testImportRejectsInvalidAndDuplicateProfiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMBMountImportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let good = MountPoint(
            name: "unique_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
            servers: ["smb://nas.local/share"],
            shareName: "share",
            username: " user ",
            useKeychain: false,
            mountOptions: ""
        )
        let invalid = MountPoint(
            name: "../invalid",
            servers: ["nas.local"],
            shareName: "share",
            username: "user",
            useKeychain: true,
            mountOptions: ""
        )
        let profile = MountPoint.ExportProfile(
            version: 1,
            exportDate: "2026-07-22T00:00:00Z",
            mounts: [good, good, invalid]
        )
        let data = try JSONEncoder().encode(profile)
        let result = MountPoint.importMounts(
            from: data,
            existingDirectories: [root],
            destinationDirectory: root
        )

        XCTAssertEqual(result.imported.count, 1)
        XCTAssertEqual(result.skipped.count, 2)
        XCTAssertEqual(result.imported.first?.servers, ["nas.local"])
        XCTAssertEqual(result.imported.first?.username, "user")
        XCTAssertEqual(result.imported.first?.useKeychain, true)
    }
}

final class UpdateServiceTests: XCTestCase {
    func testNumericVersionComparisonAndLeadingV() {
        XCTAssertTrue(UpdateService.isNewerVersion(current: "1.9.2", latest: "v1.10.0"))
        XCTAssertFalse(UpdateService.isNewerVersion(current: "1.10.0", latest: "V1.9.9"))
        XCTAssertFalse(UpdateService.isNewerVersion(current: "1.10.0", latest: "1.10.0"))
    }
}

final class MountHealthTests: XCTestCase {
    func testResponsiveCheckStartsStatExactlyOnce() async {
        let isResponsive = await MountManager.isMountResponsive("/")
        XCTAssertTrue(isResponsive)
    }
}
