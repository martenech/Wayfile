import AppKit
import Observation
import Foundation

// MARK: - Extended attributes

struct ExtendedAttribute: Identifiable, Hashable {
    let name: String
    let data: Data
    var id: String { name }

    /// Readable form: UTF-8 text, a decoded property list, or hex.
    var displayValue: String {
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil), data.starts(with: Data("bplist".utf8)) {
            return Self.describe(plist)
        }
        if let text = String(data: data, encoding: .utf8), !text.contains("\0") || text.hasSuffix("\0") {
            return text.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        }
        return data.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ") + (data.count > 64 ? " …" : "")
    }

    var isSystem: Bool { name.hasPrefix("com.apple.") }

    private static func describe(_ value: Any) -> String {
        switch value {
        case let array as [Any]: return array.map(describe).joined(separator: ", ")
        case let dict as [String: Any]: return dict.map { "\($0.key): \(describe($0.value))" }.sorted().joined(separator: ", ")
        case let date as Date: return date.formatted()
        case let data as Data: return "\(data.count) bytes"
        default: return "\(value)"
        }
    }
}

enum XAttr {
    static func list(_ url: URL) -> [ExtendedAttribute] {
        let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        guard listxattr(url.path, &buffer, size, XATTR_NOFOLLOW) == size else { return [] }
        let names = buffer.split(separator: 0).map { String(cString: Array($0) + [0]) }
        return names.compactMap { name in value(name, of: url).map { ExtendedAttribute(name: name, data: $0) } }
            .sorted { $0.name < $1.name }
    }

    static func value(_ name: String, of url: URL) -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var data = Data(count: size)
        guard size == 0 || data.withUnsafeMutableBytes({ getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }) == size else { return nil }
        return data
    }

    static func set(_ name: String, _ data: Data, on url: URL) throws {
        let result = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        if result != 0 { throw ShellError(message: String(cString: strerror(errno))) }
    }

    static func remove(_ name: String, from url: URL) throws {
        if removexattr(url.path, name, XATTR_NOFOLLOW) != 0 && errno != ENOATTR { throw ShellError(message: String(cString: strerror(errno))) }
    }
}

// MARK: - Quarantine

/// The Gatekeeper download flag ("com.apple.quarantine": flags;hex time;agent;UUID).
struct Quarantine: Equatable {
    static let attribute = "com.apple.quarantine"

    let flags: String
    let date: Date?
    let agent: String

    /// User approved opening it once already (Gatekeeper's "user approved" bit 0x0040).
    var isApproved: Bool { (UInt32(flags, radix: 16) ?? 0) & 0x40 != 0 }

    static func read(_ url: URL) -> Quarantine? {
        guard let data = XAttr.value(attribute, of: url), let text = String(data: data, encoding: .utf8) else { return nil }
        return parse(text)
    }

    static func parse(_ text: String) -> Quarantine? {
        let parts = text.trimmingCharacters(in: CharacterSet(charactersIn: "\0\n")).split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard let flags = parts.first, !flags.isEmpty else { return nil }
        let date = parts.count > 1 ? UInt64(parts[1], radix: 16).map { Date(timeIntervalSince1970: TimeInterval($0)) } : nil
        return Quarantine(flags: flags, date: date, agent: parts.count > 2 ? parts[2] : "")
    }

    /// Removes the flag from the items (and everything inside folders / app bundles). Returns how many were cleared.
    @discardableResult
    static func remove(from urls: [URL]) throws -> Int {
        var cleared = 0
        func clear(_ url: URL) throws {
            if XAttr.value(attribute, of: url) != nil { try XAttr.remove(attribute, from: url); cleared += 1 }
        }
        for url in urls {
            try clear(url)
            if FileSystem.isDirectory(url), let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
                while let child = enumerator.nextObject() as? URL { try clear(child) }
            }
        }
        return cleared
    }
}

// MARK: - ACLs

/// Access-control list entries via `ls -le` / `chmod +a` / `chmod -a#`.
struct ACLEntry: Identifiable, Hashable {
    let index: Int
    let principal: String
    let allow: Bool
    let permissions: [String]
    let inherited: Bool
    var id: Int { index }
}

enum ACL {
    static let permissionNames = ["read", "write", "execute", "delete", "append", "readattr", "writeattr", "readextattr", "writeextattr",
                                  "readsecurity", "writesecurity", "chown", "list", "search", "add_file", "add_subdirectory", "delete_child",
                                  "file_inherit", "directory_inherit", "limit_inherit", "only_inherit"]

    static func entries(of url: URL) async -> [ACLEntry] {
        let output = await Shell.run("/bin/ls", ["-led", url.path], environment: ["LC_ALL": "C"])
        return parse(output.stdout)
    }

    /// Lines like " 0: user:admin allow read,write" (or "group:staff inherited deny delete").
    static func parse(_ output: String) -> [ACLEntry] {
        output.split(separator: "\n").dropFirst().compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let colon = text.firstIndex(of: ":"), let index = Int(text[..<colon]) else { return nil }
            var words = text[text.index(after: colon)...].split(separator: " ").map(String.init)
            guard words.count >= 3 else { return nil }
            let principal = words.removeFirst()
            var inherited = false
            if words.first == "inherited" { inherited = true; words.removeFirst() }
            guard let rule = words.first, rule == "allow" || rule == "deny" else { return nil }
            let perms = words.dropFirst().joined(separator: " ").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return ACLEntry(index: index, principal: principal, allow: rule == "allow", permissions: perms, inherited: inherited)
        }
    }

    static func add(principal: String, allow: Bool, permissions: [String], to url: URL) async throws {
        guard !permissions.isEmpty else { return }
        let entry = "\(principal) \(allow ? "allow" : "deny") \(permissions.joined(separator: ","))"
        try await Shell.check("/bin/chmod", ["+a", entry, url.path])
    }

    static func remove(index: Int, from url: URL) async throws {
        try await Shell.check("/bin/chmod", ["-a#", String(index), url.path])
    }
}

// MARK: - Recursive permissions

struct PermissionPlan {
    enum Mode: Equatable {
        /// Set exactly these bits.
        case set(UInt16)
        /// Add / remove bits ("u+x", "go-w").
        case adjust(add: UInt16, remove: UInt16)
    }

    var files: Mode?
    var folders: Mode?
    var recursive = true

    func newMode(_ old: UInt16, isDirectory: Bool) -> UInt16 {
        guard let mode = isDirectory ? folders : files else { return old }
        let special = old & 0o7000
        switch mode {
        case .set(let bits): return special | (bits & 0o777)
        case .adjust(let add, let remove): return (old | add) & ~remove
        }
    }

    /// The simulator: every item whose mode would change.
    func preview(_ roots: [URL], limit: Int = 200_000) -> [PermissionChange] {
        var changes: [PermissionChange] = []
        func consider(_ url: URL) {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  (attrs[.type] as? FileAttributeType) != .typeSymbolicLink,
                  let old = (attrs[.posixPermissions] as? NSNumber)?.uint16Value else { return }
            let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
            let new = newMode(old, isDirectory: isDir)
            if new != old { changes.append(PermissionChange(url: url, old: old, new: new)) }
        }
        for root in roots {
            consider(root)
            guard recursive, FileSystem.isDirectory(root),
                  let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in true })
            else { continue }
            while let url = enumerator.nextObject() as? URL, changes.count < limit { consider(url) }
        }
        return changes
    }

    static func apply(_ changes: [PermissionChange], progress: OperationProgress) throws {
        progress.setTotals(bytes: 0, items: changes.count)
        var done: [PermissionChange] = []
        defer { if !done.isEmpty { progress.record(.permissions(done)) } }
        for change in changes {
            try progress.checkCancelled()
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: change.new)], ofItemAtPath: change.url.path)
            done.append(change)
            if done.count % 500 == 0 { progress.begin(change.url.lastPathComponent) }
        }
        progress.finishItem(baseline: 0, size: 0)
    }

    /// Parses "755", "0644", "u+x", "go-w", "a+r", "+x".
    static func parse(_ text: String) -> Mode? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let value = UInt16(t, radix: 8), t.count >= 3, t.count <= 4, value <= 0o7777 { return .set(value & 0o777) }
        let pattern = try! NSRegularExpression(pattern: #"^([ugoa]*)([+-])([rwx]+)$"#)
        guard let match = pattern.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let who = Range(match.range(at: 1), in: t), let op = Range(match.range(at: 2), in: t), let what = Range(match.range(at: 3), in: t)
        else { return nil }
        var classes = String(t[who])
        if classes.isEmpty || classes.contains("a") { classes = "ugo" }
        var bits: UInt16 = 0
        for c in classes {
            let shift: UInt16 = c == "u" ? 6 : c == "g" ? 3 : 0
            for p in t[what] { bits |= (p == "r" ? 4 : p == "w" ? 2 : 1) << shift }
        }
        return t[op] == "+" ? .adjust(add: bits, remove: 0) : .adjust(add: 0, remove: bits)
    }
}

// MARK: - Encrypted vaults

/// An AES-256 encrypted sparse bundle (hdiutil) that mounts as a drive while unlocked.
struct Vault: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var url: URL
}

enum Vaults {
    static func create(name: String, in folder: URL, sizeGB: Int, password: String) async throws -> Vault {
        let url = FileOps.uniqueURL(folder.appendingPathComponent(name).appendingPathExtension("sparsebundle"))
        try await runWithPassword(["create", "-encryption", "AES-256", "-stdinpass", "-type", "SPARSEBUNDLE", "-fs", "APFS",
                                   "-volname", name, "-size", "\(sizeGB)g", url.path], password: password)
        return Vault(name: name, url: url)
    }

    static func unlock(_ vault: Vault, password: String) async throws -> URL {
        let output = try await runWithPassword(["attach", "-stdinpass", "-nobrowse", "-plist", vault.url.path], password: password, plist: true)
        guard let data = output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mount = entities.compactMap({ $0["mount-point"] as? String }).first
        else { throw ShellError(message: "The vault opened but no volume was mounted.") }
        return URL(fileURLWithPath: mount, isDirectory: true)
    }

    static func lock(_ mountPoint: URL) async throws {
        try await Shell.check("/usr/bin/hdiutil", ["detach", mountPoint.path])
    }

    /// Mount points of attached disk images, keyed by image path (from `hdiutil info`).
    static func attachedImages() -> [String: URL] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [:] }
        var result: [String: URL] = [:]
        for image in images {
            guard let path = image["image-path"] as? String,
                  let mount = (image["system-entities"] as? [[String: Any]] ?? []).compactMap({ $0["mount-point"] as? String }).first else { continue }
            result[URL(fileURLWithPath: path).standardizedFileURL.path] = URL(fileURLWithPath: mount, isDirectory: true)
        }
        return result
    }

    /// Image file behind a mounted volume (from `hdiutil info`).
    static func imagePath(ofVolume volume: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return nil }
        for image in images {
            let mounts = (image["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["mount-point"] as? String }
            if mounts.contains(volume.path), let path = image["image-path"] as? String { return URL(fileURLWithPath: path).standardizedFileURL.path }
        }
        return nil
    }

    /// hdiutil reads the passphrase from stdin; it never appears in the process list.
    @discardableResult
    private static func runWithPassword(_ args: [String], password: String, plist: Bool = false) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                process.arguments = args
                let input = Pipe(), output = Pipe(), error = Pipe()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = error
                do { try process.run() } catch { continuation.resume(throwing: error); return }
                input.fileHandleForWriting.write(Data(password.utf8))
                try? input.fileHandleForWriting.close()
                let out = output.fileHandleForReading.readDataToEndOfFile()
                let err = error.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: String(decoding: out, as: UTF8.self))
                } else {
                    let message = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    let friendly = message.contains("Authentication error") ? "Wrong password." : message
                    continuation.resume(throwing: ShellError(message: friendly.isEmpty ? "hdiutil failed (\(process.terminationStatus))" : friendly))
                }
            }
        }
    }
}

@MainActor
@Observable
final class VaultStore {
    static let shared = VaultStore()
    private(set) var vaults: [Vault] { didSet { save(); refresh() } }
    /// Mount points of unlocked vaults.
    private(set) var mounts: [UUID: URL] = [:]

    private init() {
        vaults = UserDefaults.standard.data(forKey: "vaults").flatMap { try? JSONDecoder().decode([Vault].self, from: $0) } ?? []
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    func mountPoint(of vault: Vault) -> URL? { mounts[vault.id] }

    func refresh() {
        let vaults = vaults
        Task {
            let attached = await Task.detached { Vaults.attachedImages() }.value
            var found: [UUID: URL] = [:]
            for vault in vaults { if let mount = attached[vault.url.standardizedFileURL.path] { found[vault.id] = mount } }
            mounts = found
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(vaults) { UserDefaults.standard.set(data, forKey: "vaults") }
    }

    func add(_ vault: Vault) {
        vaults.removeAll { $0.url == vault.url }
        vaults.append(vault)
    }

    func forget(_ vault: Vault) { vaults.removeAll { $0.id == vault.id } }
}

// MARK: - Administrator

/// Runs a command with administrator rights after the system's authentication dialog.
enum Admin {
    static func run(_ executable: String, _ arguments: [String]) async throws {
        let command = ([executable] + arguments).map(shellQuote).joined(separator: " ")
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        try await MainActor.run {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error {
                let number = error[NSAppleScript.errorNumber] as? Int ?? 0
                throw number == -128 ? CancellationError() as Error
                    : ShellError(message: error[NSAppleScript.errorMessage] as? String ?? "The command failed.")
            }
        }
    }

    static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Moves protected items to the Trash folder (no Put Back; the Timeline can't undo admin changes).
    static func trash(_ urls: [URL]) async throws {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        for url in urls {
            let target = FileOps.uniqueURL(trash.appendingPathComponent(url.lastPathComponent))
            try await run("/bin/mv", [url.path, target.path])
        }
    }

    static func chown(_ urls: [URL], owner: String, group: String?, recursive: Bool) async throws {
        let spec = group.map { "\(owner):\($0)" } ?? owner
        try await run("/usr/sbin/chown", (recursive ? ["-R"] : []) + [spec] + urls.map(\.path))
    }

    static func chmod(_ urls: [URL], mode: String, recursive: Bool) async throws {
        try await run("/bin/chmod", (recursive ? ["-R"] : []) + [mode] + urls.map(\.path))
    }

    static func copy(_ urls: [URL], to folder: URL) async throws {
        try await run("/bin/cp", ["-Rp"] + urls.map(\.path) + [folder.path])
    }
}
