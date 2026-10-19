import Foundation
import NetFS
import Network
import Observation
import Security

// MARK: - Addresses

/// A server address as typed ("nas.local", "smb://nas/share", "https://dav.example.com/files").
enum ServerAddress {
    static let schemes = ["smb", "afp", "nfs", "http", "https", "ftp", "vnc"]

    /// Adds `smb://` when no scheme is given; nil for anything unusable.
    static func normalize(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("\\\\") {
            // Windows UNC: \\server\share
            trimmed = "smb://" + trimmed.dropFirst(2).replacingOccurrences(of: "\\", with: "/")
        }
        if !trimmed.contains("://") { trimmed = "smb://" + trimmed }
        guard let url = URL(string: trimmed) ?? URL(string: trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""),
              let scheme = url.scheme?.lowercased(), schemes.contains(scheme), let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Protocol shown to the user.
    static func kind(_ url: URL) -> String {
        switch url.scheme?.lowercased() {
        case "smb": return "SMB"
        case "afp": return "AFP"
        case "nfs": return "NFS"
        case "http", "https": return "WebDAV"
        case "ftp": return "FTP"
        default: return url.scheme?.uppercased() ?? "?"
        }
    }

    /// "nas.local" from "smb://user@nas.local/share"; Bonjour names lose their service suffix.
    static func displayName(_ url: URL) -> String {
        var host = url.host ?? url.absoluteString
        for suffix in ["._smb._tcp.local", "._afpovertcp._tcp.local", "._webdav._tcp.local", "._webdavs._tcp.local"] where host.hasSuffix(suffix) {
            host = String(host.dropLast(suffix.count))
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? host : "\(host)/\(path)"
    }

    /// URL without credentials (what is saved and shown).
    static func stripCredentials(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.user = nil
        parts.password = nil
        return parts.url ?? url
    }
}

// MARK: - Keychain

/// Internet passwords in the login keychain (shared with Finder for the same server and account).
enum Keychain {
    private static func query(server: String, account: String?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassInternetPassword, kSecAttrServer as String: server]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    static func save(password: String, server: String, account: String, label: String? = nil) throws {
        let base = query(server: server, account: account)
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrLabel as String] = label ?? "\(server) (Wayfile)"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw keychainError(status) }
    }

    static func password(server: String, account: String) -> String? {
        var q = query(server: server, account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(server: String, account: String) {
        SecItemDelete(query(server: server, account: account) as CFDictionary)
    }

    private static func keychainError(_ status: OSStatus) -> Error {
        ShellError(message: (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)")
    }
}

// MARK: - Mounting

enum Mounter {
    /// Mounts with NetFS (SMB, AFP, NFS, WebDAV). Without a password the system may show its own
    /// login sheet (and its keychain); returns the mount points (one per share, usually one).
    static func mount(_ url: URL, user: String?, password: String?, allowUI: Bool = true) async throws -> [URL] {
        let open = NSMutableDictionary()
        if allowUI { open[kNAUIOptionKey] = kNAUIOptionAllowUI }
        if user == nil && password == nil && !allowUI { open[kNetFSUseGuestKey] = true }
        let mountOptions = NSMutableDictionary()
        return try await withCheckedThrowingContinuation { continuation in
            var requestID: AsyncRequestID?
            let status = NetFSMountURLAsync(url as CFURL, nil, user as CFString?, password as CFString?, open, mountOptions, &requestID, .main) { status, _, mountpoints in
                if status == 0 {
                    let paths = (mountpoints as? [String]) ?? []
                    continuation.resume(returning: paths.map { URL(fileURLWithPath: $0, isDirectory: true) })
                } else {
                    continuation.resume(throwing: mountError(status))
                }
            }
            if status != 0 { continuation.resume(throwing: mountError(status)) }
        }
    }

    static func mountError(_ status: Int32) -> Error {
        let message: String
        switch status {
        case Int32(ECANCELED), -128: message = "Connecting was cancelled."
        case Int32(EAUTH), Int32(EACCES), -6003: message = "The user name or password is wrong."
        case Int32(ENOENT), Int32(EHOSTUNREACH), Int32(ETIMEDOUT): message = "The server can’t be reached."
        case Int32(EEXIST): message = "The share is already mounted."
        default: message = String(cString: strerror(status)) + " (\(status))"
        }
        return ShellError(message: message)
    }

    /// Mount point of an already mounted share, so a reconnect just opens it.
    static func existingMount(for url: URL) -> URL? {
        let keys: Set<URLResourceKey> = [.volumeURLForRemountingKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        let wanted = normalizedKey(url)
        return volumes.first { volume in
            guard let remount = (try? volume.resourceValues(forKeys: keys))?.volumeURLForRemounting else { return false }
            return normalizedKey(remount) == wanted
        }
    }

    private static func normalizedKey(_ url: URL) -> String {
        let host = (url.host ?? "").lowercased()
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        return "\(url.scheme?.lowercased() ?? "")://\(host)/\(path)"
    }
}

// MARK: - Saved servers

struct SavedServer: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Without credentials.
    var url: URL
    var username: String?
    var lastConnected: Date?

    var keychainServer: String { url.host ?? url.absoluteString }
}

@MainActor
@Observable
final class ServerStore {
    static let shared = ServerStore()

    private(set) var servers: [SavedServer] {
        didSet { save() }
    }
    /// Discovered on the local network (Bonjour).
    private(set) var discovered: [DiscoveredServer] = []
    private var browsers: [NWBrowser] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        servers = defaults.data(forKey: "servers").flatMap { try? JSONDecoder().decode([SavedServer].self, from: $0) } ?? []
    }

    private func save() {
        if let data = try? JSONEncoder().encode(servers) { defaults.set(data, forKey: "servers") }
    }

    @discardableResult
    func remember(url: URL, username: String?, password: String?, savePassword: Bool) -> SavedServer {
        let clean = ServerAddress.stripCredentials(url)
        var server = servers.first { $0.url == clean } ?? SavedServer(name: ServerAddress.displayName(clean), url: clean)
        server.username = username?.isEmpty == true ? nil : username
        server.lastConnected = Date()
        if savePassword, let username = server.username, let password, !password.isEmpty {
            try? Keychain.save(password: password, server: server.keychainServer, account: username, label: "\(server.name) (Wayfile)")
        }
        servers.removeAll { $0.id == server.id }
        servers.insert(server, at: 0)
        return server
    }

    func remove(_ server: SavedServer) {
        servers.removeAll { $0.id == server.id }
        if let user = server.username { Keychain.delete(server: server.keychainServer, account: user) }
    }

    func rename(_ server: SavedServer, to name: String) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }), !name.isEmpty else { return }
        servers[index].name = name
    }

    /// Mounts (or reuses the mount of) a server; credentials come from the arguments, then the keychain,
    /// then the system's own prompt.
    func connect(_ url: URL, username: String? = nil, password: String? = nil, savePassword: Bool = false) async throws -> URL {
        let clean = ServerAddress.stripCredentials(url)
        if let mounted = Mounter.existingMount(for: clean) {
            remember(url: clean, username: username, password: nil, savePassword: false)
            return mounted
        }
        let saved = servers.first { $0.url == clean }
        let user = username ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?.user ?? saved?.username
        let pass = password ?? user.flatMap { Keychain.password(server: clean.host ?? "", account: $0) }
        let points = try await Mounter.mount(clean, user: user, password: pass)
        remember(url: clean, username: user, password: password, savePassword: savePassword)
        guard let first = points.first else { throw ShellError(message: "The server didn’t report a mount point.") }
        return first
    }

    // MARK: Discovery

    struct DiscoveredServer: Identifiable, Hashable {
        let name: String
        let type: String
        var id: String { "\(name)|\(type)" }
        var url: URL? {
            let scheme: String
            switch type {
            case "_smb._tcp": scheme = "smb"
            case "_afpovertcp._tcp": scheme = "afp"
            case "_webdav._tcp": scheme = "http"
            case "_webdavs._tcp": scheme = "https"
            default: return nil
            }
            // Finder's form: the Bonjour service name as host, resolved by the system.
            let host = (name + "." + type + ".local").addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? name
            return URL(string: "\(scheme)://\(host)")
        }
        var kind: String { url.map(ServerAddress.kind) ?? type }
    }

    func startDiscovery() {
        guard browsers.isEmpty else { return }
        for type in ["_smb._tcp", "_afpovertcp._tcp", "_webdav._tcp", "_webdavs._tcp"] {
            let browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let names = results.compactMap { result -> DiscoveredServer? in
                    if case .service(let name, _, _, _) = result.endpoint { return DiscoveredServer(name: name, type: type) }
                    return nil
                }
                Task { @MainActor in self?.update(type: type, with: names) }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    private func update(type: String, with found: [DiscoveredServer]) {
        // One row per machine: prefer SMB over AFP, and plain over secure WebDAV only when both exist.
        var all = discovered.filter { $0.type != type } + found
        let local = Host.current().localizedName ?? ""
        all.removeAll { $0.name == local }
        var seen = Set<String>()
        let order = ["_smb._tcp", "_afpovertcp._tcp", "_webdavs._tcp", "_webdav._tcp"]
        discovered = all.sorted { (order.firstIndex(of: $0.type) ?? 9) < (order.firstIndex(of: $1.type) ?? 9) }
            .filter { seen.insert($0.name).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
