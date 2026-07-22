import Foundation

/// Pure helpers for normalizing SMB endpoints and constructing correctly
/// percent-encoded command-line URLs.
enum SMBConnection {
    static func normalizedHost(_ rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.hasPrefix("//") {
            value = "smb:\(value)"
        } else if !value.contains("://") {
            value = "smb://\(value)"
        }

        guard let components = URLComponents(string: value),
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else { return nil }
        return host
    }

    static func finderURL(username: String, password: String, server: String, shareName: String) -> String? {
        guard let host = normalizedHost(server),
              !username.isEmpty,
              !shareName.isEmpty,
              !shareName.contains("/") else { return nil }

        var components = URLComponents()
        components.scheme = "smb"
        components.host = host
        components.user = username
        components.password = password
        components.path = "/\(shareName)"
        return components.string
    }

    static func mountSource(username: String, password: String, server: String, shareName: String) -> String? {
        guard let finderURL = finderURL(
            username: username,
            password: password,
            server: server,
            shareName: shareName
        ), finderURL.hasPrefix("smb:") else { return nil }
        return String(finderURL.dropFirst("smb:".count))
    }

    static func mountSourceWithoutPassword(username: String, server: String, shareName: String) -> String? {
        guard let host = normalizedHost(server),
              !username.isEmpty,
              !shareName.isEmpty,
              !shareName.contains("/") else { return nil }

        var components = URLComponents()
        components.scheme = "smb"
        components.host = host
        components.user = username
        components.path = "/\(shareName)"
        guard let value = components.string, value.hasPrefix("smb:") else { return nil }
        return String(value.dropFirst("smb:".count))
    }

    static func serverViewSource(username: String, password: String, server: String) -> String? {
        guard let host = normalizedHost(server), !username.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "smb"
        components.host = host
        components.user = username
        components.password = password
        guard let value = components.string, value.hasPrefix("smb:") else { return nil }
        return String(value.dropFirst("smb:".count))
    }

    static func mountedPaths(fromMountOutput output: String) -> Set<String> {
        Set(output.split(whereSeparator: \.isNewline).compactMap { lineSlice in
            let line = String(lineSlice)
            guard let separator = line.range(of: " on "),
                  let options = line.range(of: " (", options: .backwards),
                  separator.upperBound <= options.lowerBound else { return nil }
            let encodedPath = String(line[separator.upperBound..<options.lowerBound])
            return decodeMountEscapes(encodedPath)
        })
    }

    static func isMounted(path: String, inMountOutput output: String) -> Bool {
        mountedPaths(fromMountOutput: output).contains(path)
    }

    static func childURL(rootPath: String, relativePath: String) -> URL? {
        guard !relativePath.hasPrefix("/") else { return nil }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let child = root.appendingPathComponent(relativePath).standardizedFileURL
        guard child.path != root.path,
              child.path.hasPrefix(root.path + "/") else { return nil }

        // A syntactically safe relative path can still escape through a
        // symlink contained inside the mount. Resolve both sides before
        // allowing upload/download code to access the result.
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let relativeComponents = child.path
            .dropFirst(root.path.count)
            .split(separator: "/")
            .map(String.init)
        guard !relativeComponents.isEmpty else { return nil }

        var resolvedChild = resolvedRoot
        for component in relativeComponents {
            let candidate = resolvedChild.appendingPathComponent(component).standardizedFileURL
            if (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path) else {
                    return nil
                }
                if destination.hasPrefix("/") {
                    resolvedChild = URL(fileURLWithPath: destination)
                        .resolvingSymlinksInPath()
                        .standardizedFileURL
                } else {
                    resolvedChild = candidate.deletingLastPathComponent()
                        .appendingPathComponent(destination)
                        .resolvingSymlinksInPath()
                        .standardizedFileURL
                }
            } else {
                resolvedChild = candidate
            }

            guard resolvedChild.path.hasPrefix(resolvedRoot.path + "/") else { return nil }
        }
        return resolvedChild
    }

    private static func decodeMountEscapes(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\040", with: " ")
            .replacingOccurrences(of: "\\011", with: "\t")
            .replacingOccurrences(of: "\\134", with: "\\")
    }
}
