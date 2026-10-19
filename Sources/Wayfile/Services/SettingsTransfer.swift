import Foundation

/// Exports / imports Wayfile's preferences plus rules, scripts and templates as one property list.
/// Passwords and secret keys stay in the Keychain and are never exported.
enum SettingsTransfer {
    static let fileExtension = "wayfilesettings"

    /// App Support content that travels with the settings (relative to the Wayfile folder).
    static let includedPaths = ["rules.json", "Scripts", "Templates"]

    static var supportFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Wayfile")
    }

    /// Our own keys: system/AppKit state (window frames, split views…) is left out.
    static func isExported(_ key: String) -> Bool {
        let excludedPrefixes = ["NS", "Apple", "com.apple.", "WebKit", "AK", "WAYFILE", "MSApp", "SU", "_"]
        return !excludedPrefixes.contains(where: key.hasPrefix) && key != "settings.tab"
    }

    static func export(defaults: UserDefaults = .standard, domain: String? = Bundle.main.bundleIdentifier, support: URL = supportFolder) throws -> Data {
        let values = (domain.flatMap { defaults.persistentDomain(forName: $0) } ?? defaults.dictionaryRepresentation())
            .filter { isExported($0.key) }
        var files: [String: Data] = [:]
        let fm = FileManager.default
        for path in includedPaths {
            let url = support.appendingPathComponent(path)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                for child in (fm.enumerator(atPath: url.path)?.allObjects as? [String]) ?? [] {
                    let full = url.appendingPathComponent(child)
                    if !FileSystem.isDirectory(full), let data = try? Data(contentsOf: full), data.count < 5_000_000 {
                        files[path + "/" + child] = data
                    }
                }
            } else if let data = try? Data(contentsOf: url) {
                files[path] = data
            }
        }
        let payload: [String: Any] = ["format": 1, "exported": Date(), "defaults": values, "files": files]
        return try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
    }

    struct Summary: Equatable {
        let settings: Int
        let files: Int
    }

    static func summary(of data: Data) throws -> Summary {
        let payload = try decode(data)
        return Summary(settings: (payload["defaults"] as? [String: Any])?.count ?? 0, files: (payload["files"] as? [String: Data])?.count ?? 0)
    }

    /// Replaces matching preferences and files (existing scripts with other names are kept).
    static func `import`(_ data: Data, defaults: UserDefaults = .standard, support: URL = supportFolder) throws -> Summary {
        let payload = try decode(data)
        let values = (payload["defaults"] as? [String: Any] ?? [:]).filter { isExported($0.key) }
        for (key, value) in values { defaults.set(value, forKey: key) }
        let files = payload["files"] as? [String: Data] ?? [:]
        for (path, content) in files {
            // Only inside the Wayfile folder: no "..", no absolute paths.
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
                  includedPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
            let url = support.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, options: .atomic)
            if path.hasPrefix("Scripts/"), Script.Language(fileExtension: url.pathExtension)?.isExecutableFile == true {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }
        return Summary(settings: values.count, files: files.count)
    }

    private static func decode(_ data: Data) throws -> [String: Any] {
        guard let payload = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              payload["format"] as? Int == 1 else { throw ShellError(message: "This isn’t a Wayfile settings file.") }
        return payload
    }
}
