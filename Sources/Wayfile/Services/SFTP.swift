import Citadel
import Crypto
import Foundation
import Logging
import NIOCore
import NIOSSH
import Observation

/// A saved SFTP server. Passwords live in the Keychain; keys are read from the file when connecting.
struct SFTPServer: Codable, Identifiable, Hashable {
    enum Auth: String, Codable, CaseIterable { case password, key }

    var id = UUID()
    var name: String
    var host: String
    var port = 22
    var username: String
    var auth: Auth = .password
    /// Private key file (OpenSSH format, ed25519 or RSA) for key authentication.
    var keyPath: String = NSHomeDirectory() + "/.ssh/id_ed25519"
    var initialPath = ""

    var keychainServer: String { "sftp:\(host):\(port)" }
    var address: String { "\(username)@\(host)" + (port == 22 ? "" : ":\(port)") }
}

struct SFTPItem: Identifiable, Hashable {
    let path: String
    let name: String
    let size: Int64
    let modified: Date?
    let isDirectory: Bool
    let isSymlink: Bool
    var id: String { path }
}

struct SFTPErrorMessage: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Host keys seen before ("trust on first use", like ssh's known_hosts). A changed key refuses the connection.
enum SFTPKnownHosts {
    static let key = "sftp.knownHosts"

    static func known(_ host: String, port: Int) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?["\(host):\(port)"]
    }

    static func remember(_ publicKey: String, host: String, port: Int) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        all["\(host):\(port)"] = publicKey
        UserDefaults.standard.set(all, forKey: key)
    }

    static func forget(host: String, port: Int) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        all["\(host):\(port)"] = nil
        UserDefaults.standard.set(all, forKey: key)
    }

    /// SHA-256 fingerprint in ssh's format ("SHA256:…").
    static func fingerprint(_ openSSHKey: String) -> String {
        let parts = openSSHKey.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return openSSHKey }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:" + digest
    }

    final class Validator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
        let host: String
        let port: Int
        init(host: String, port: Int) { self.host = host; self.port = port }

        func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
            let presented = String(openSSHPublicKey: hostKey)
            if let known = SFTPKnownHosts.known(host, port: port) {
                if known == presented {
                    validationCompletePromise.succeed(())
                } else {
                    validationCompletePromise.fail(SFTPErrorMessage(message:
                        "The server’s identity changed (\(SFTPKnownHosts.fingerprint(presented))). This can mean someone is intercepting the connection. If the server was reinstalled, use “Forget Host Key” and connect again."))
                }
            } else {
                SFTPKnownHosts.remember(presented, host: host, port: port)
                validationCompletePromise.succeed(())
            }
        }
    }
}

/// One connection: SSH client plus its SFTP channel.
final class SFTPConnection: @unchecked Sendable {
    let server: SFTPServer
    private let client: SSHClient
    let sftp: SFTPClient
    let home: String

    private init(server: SFTPServer, client: SSHClient, sftp: SFTPClient, home: String) {
        self.server = server
        self.client = client
        self.sftp = sftp
        self.home = home
    }

    /// Citadel logs every request at "info" to stdout; keep only real problems.
    private static let quietLogging: Void = {
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = .error
            return handler
        }
    }()

    static func connect(_ server: SFTPServer, password: String?) async throws -> SFTPConnection {
        _ = quietLogging
        let auth: SSHAuthenticationMethod
        switch server.auth {
        case .password:
            guard let password, !password.isEmpty else { throw SFTPErrorMessage(message: "Enter the password for \(server.address).") }
            auth = .passwordBased(username: server.username, password: password)
        case .key:
            let path = (server.keyPath as NSString).expandingTildeInPath
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw SFTPErrorMessage(message: "Can’t read the key file \(server.keyPath).")
            }
            let passphrase = password.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
            if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: passphrase) {
                auth = .ed25519(username: server.username, privateKey: key)
            } else if let key = try? Insecure.RSA.PrivateKey(sshRsa: text, decryptionKey: passphrase) {
                auth = .rsa(username: server.username, privateKey: key)
            } else {
                throw SFTPErrorMessage(message: "The key file isn’t a supported OpenSSH ed25519 or RSA key, or its passphrase is wrong.")
            }
        }
        do {
            let client = try await SSHClient.connect(host: server.host, port: server.port, authenticationMethod: auth,
                                                     hostKeyValidator: .custom(SFTPKnownHosts.Validator(host: server.host, port: server.port)),
                                                     reconnect: .never, connectTimeout: .seconds(15))
            let sftp = try await client.openSFTP()
            let home = (try? await sftp.getRealPath(atPath: ".")) ?? "/"
            return SFTPConnection(server: server, client: client, sftp: sftp, home: home)
        } catch let error as SFTPErrorMessage {
            throw error
        } catch {
            throw SFTPErrorMessage(message: friendly(error))
        }
    }

    static func friendly(_ error: Error) -> String {
        let text = String(describing: error)
        if text.localizedCaseInsensitiveContains("allAuthenticationOptionsFailed") || text.localizedCaseInsensitiveContains("authentication") {
            return "The user name, password or key was rejected."
        }
        if text.localizedCaseInsensitiveContains("connectTimeout") || text.localizedCaseInsensitiveContains("timed out") {
            return "The server didn’t answer (timeout)."
        }
        if text.localizedCaseInsensitiveContains("refused") { return "The server refused the connection (is SSH running on that port?)." }
        if text.localizedCaseInsensitiveContains("nodename") || text.localizedCaseInsensitiveContains("resolve") { return "The server name couldn’t be found." }
        return error.localizedDescription == "The operation couldn’t be completed." ? text : error.localizedDescription
    }

    func close() async {
        try? await sftp.close()
        try? await client.close()
    }

    // MARK: Files

    func list(_ path: String) async throws -> [SFTPItem] {
        let names = try await sftp.listDirectory(atPath: path)
        return names.flatMap(\.components).compactMap { component in
            guard component.filename != ".", component.filename != ".." else { return nil }
            let mode = component.attributes.permissions ?? 0
            let type = mode & 0o170000
            return SFTPItem(path: Self.join(path, component.filename), name: component.filename,
                            size: Int64(component.attributes.size ?? 0),
                            modified: component.attributes.accessModificationTime?.modificationTime,
                            isDirectory: type == 0o040000 || (type == 0 && component.longname.hasPrefix("d")),
                            isSymlink: type == 0o120000 || component.longname.hasPrefix("l"))
        }
        .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }

    /// Downloads a file or folder (recursively) into a local folder.
    func download(_ item: SFTPItem, to folder: URL, progress: OperationProgress) async throws -> URL {
        let target = FileOps.uniqueURL(folder.appendingPathComponent(item.name))
        if item.isDirectory {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for child in try await list(item.path) where !child.isSymlink {
                try progress.checkCancelled()
                _ = try await download(child, to: target, progress: progress)
            }
            return target
        }
        progress.begin(item.name)
        let file = try await sftp.openFile(filePath: item.path, flags: .read)
        defer { Task { try? await file.close() } }
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        var offset: UInt64 = 0
        let chunk: UInt32 = 256 * 1024
        // Servers may return fewer bytes than asked (OpenSSH caps reads at ~255 KB): a short read isn't
        // the end — keep going until the known size is reached or a read comes back empty.
        while item.size <= 0 || offset < UInt64(item.size) {
            try progress.checkCancelled()
            var buffer: ByteBuffer
            do {
                buffer = try await file.read(from: offset, length: chunk)
            } catch {
                if offset > 0 && item.size <= 0 { break }   // EOF reported as an error by some servers
                throw error
            }
            guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else { break }
            try handle.write(contentsOf: bytes)
            offset += UInt64(bytes.count)
            progress.finishFile(bytes: Int64(bytes.count))
        }
        if let modified = item.modified { try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: target.path) }
        return target
    }

    /// Uploads a local file or folder (recursively) into a remote folder.
    func upload(_ url: URL, to remoteFolder: String, progress: OperationProgress) async throws {
        let remote = Self.join(remoteFolder, url.lastPathComponent)
        if FileSystem.isDirectory(url) {
            try? await sftp.createDirectory(atPath: remote)
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                try progress.checkCancelled()
                try await upload(child, to: remote, progress: progress)
            }
            return
        }
        progress.begin(url.lastPathComponent)
        let file = try await sftp.openFile(filePath: remote, flags: [.write, .create, .truncate])
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var offset: UInt64 = 0
        while let data = try handle.read(upToCount: 256 * 1024), !data.isEmpty {
            try progress.checkCancelled()
            try await file.write(ByteBuffer(bytes: data), at: offset)
            offset += UInt64(data.count)
            progress.finishFile(bytes: Int64(data.count))
        }
        try await file.close()
    }

    func makeFolder(_ path: String) async throws { try await sftp.createDirectory(atPath: path) }

    func rename(_ item: SFTPItem, to name: String) async throws {
        let parent = (item.path as NSString).deletingLastPathComponent
        try await sftp.rename(at: item.path, to: Self.join(parent, name))
    }

    /// Deletes a file, or a folder with everything in it.
    func delete(_ item: SFTPItem) async throws {
        if item.isDirectory && !item.isSymlink {
            for child in try await list(item.path) { try await delete(child) }
            try await sftp.rmdir(at: item.path)
        } else {
            try await sftp.remove(at: item.path)
        }
    }

    /// Reads a small file (for previews / opening a copy).
    func readSmall(_ path: String, limit: UInt32 = 8 * 1024 * 1024) async throws -> Data {
        let file = try await sftp.openFile(filePath: path, flags: .read)
        defer { Task { try? await file.close() } }
        var buffer = try await file.read(from: 0, length: limit)
        return Data(buffer.readBytes(length: buffer.readableBytes) ?? [])
    }

    static func join(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }
}

@MainActor
@Observable
final class SFTPStore {
    static let shared = SFTPStore()
    private(set) var servers: [SFTPServer] { didSet { save() } }

    private init() {
        servers = UserDefaults.standard.data(forKey: "sftp.servers").flatMap { try? JSONDecoder().decode([SFTPServer].self, from: $0) } ?? []
    }

    private func save() {
        if let data = try? JSONEncoder().encode(servers) { UserDefaults.standard.set(data, forKey: "sftp.servers") }
    }

    func save(_ server: SFTPServer, password: String?) throws {
        if let password, !password.isEmpty {
            try Keychain.save(password: password, server: server.keychainServer, account: server.username, label: "\(server.name) (Wayfile SFTP)")
        }
        if let index = servers.firstIndex(where: { $0.id == server.id }) { servers[index] = server } else { servers.append(server) }
    }

    func remove(_ server: SFTPServer) {
        Keychain.delete(server: server.keychainServer, account: server.username)
        servers.removeAll { $0.id == server.id }
    }

    func password(for server: SFTPServer) -> String? {
        Keychain.password(server: server.keychainServer, account: server.username)
    }
}
