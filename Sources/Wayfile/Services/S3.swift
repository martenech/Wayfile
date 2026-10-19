import CryptoKit
import Observation
import Foundation

/// An S3-compatible account: AWS, Cloudflare R2, MinIO, Backblaze B2, Wasabi… The secret key lives in the Keychain.
struct S3Account: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Service endpoint without a bucket, e.g. https://s3.eu-central-1.amazonaws.com
    var endpoint: URL
    var region: String
    var accessKey: String
    /// Buckets in the path (https://host/bucket/key) instead of the host name; needed by MinIO and most self-hosted servers.
    var pathStyle: Bool

    var keychainServer: String { "s3:" + (endpoint.host ?? endpoint.absoluteString) }
    var secret: String? { Keychain.password(server: keychainServer, account: accessKey) }

    static func aws(region: String) -> URL { URL(string: "https://s3.\(region).amazonaws.com")! }
}

struct S3Object: Identifiable, Hashable {
    let key: String
    let size: Int64
    let modified: Date?
    /// A "folder": a common prefix ending in "/".
    let isPrefix: Bool
    var id: String { key }
    var name: String {
        let trimmed = isPrefix ? String(key.dropLast()) : key
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
}

struct S3Error: LocalizedError {
    let status: Int
    let code: String?
    let message: String?
    var errorDescription: String? {
        let text = [code, message].compactMap { $0 }.joined(separator: ": ")
        return text.isEmpty ? String(localized: "S3 request failed (HTTP \(status)).") : String(localized: "\(text) (HTTP \(status))")
    }
}

// MARK: - Signature V4

enum SigV4 {
    static let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    static let unsignedPayload = "UNSIGNED-PAYLOAD"

    static func hex(_ data: some Sequence<UInt8>) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func sha256(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    /// RFC 3986 encoding of everything but unreserved characters (and "/" in paths).
    static func encode(_ text: String, keepSlash: Bool = false) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if keepSlash { allowed.insert("/") }
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    static func amzDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    /// Signs `request` in place (adds x-amz-date, x-amz-content-sha256 and Authorization).
    /// `path` must already be the encoded path; `query` items are encoded here.
    static func sign(_ request: inout URLRequest, path: String, query: [(String, String)], payloadHash: String,
                     accessKey: String, secret: String, region: String, service: String = "s3", date: Date = Date()) {
        let stamp = amzDate(date)
        let day = String(stamp.prefix(8))
        request.setValue(stamp, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        var host = request.url?.host ?? ""
        if let port = request.url?.port, ![80, 443].contains(port) { host += ":\(port)" }
        request.setValue(host, forHTTPHeaderField: "Host")

        var headers: [String: String] = [:]
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            let name = key.lowercased()
            if name == "host" || name.hasPrefix("x-amz-") || name == "range" || name == "content-md5" || name == "content-type" {
                headers[name] = value.trimmingCharacters(in: .whitespaces)
            }
        }
        let names = headers.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(headers[$0]!)\n" }.joined()
        let signedHeaders = names.joined(separator: ";")
        let canonicalQuery = query.map { (encode($0.0), encode($0.1)) }.sorted { $0 < $1 }.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let canonical = [request.httpMethod ?? "GET", path.isEmpty ? "/" : path, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash]
            .joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", stamp, scope, sha256(Data(canonical.utf8))].joined(separator: "\n")

        func hmac(_ key: Data, _ text: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key)))
        }
        let signingKey = hmac(hmac(hmac(hmac(Data("AWS4\(secret)".utf8), day), region), service), "aws4_request")
        let signature = hex(hmac(signingKey, toSign))
        request.setValue("AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
    }
}

// MARK: - Client

struct S3Client {
    let account: S3Account
    let secret: String
    var session: URLSession = .shared

    init(account: S3Account, secret: String, session: URLSession = .shared) {
        self.account = account
        self.secret = secret
        self.session = session
    }

    /// Request for an object key (or the bucket/service root), signed.
    func request(_ method: String, bucket: String?, key: String = "", query: [(String, String)] = [],
                 payloadHash: String = SigV4.emptyHash, headers: [String: String] = [:]) -> URLRequest {
        var components = URLComponents(url: account.endpoint, resolvingAgainstBaseURL: false)!
        var path = ""
        if let bucket {
            if account.pathStyle {
                path = "/" + SigV4.encode(bucket)
            } else {
                components.host = "\(bucket).\(components.host ?? "")"
            }
        }
        path += "/" + SigV4.encode(key, keepSlash: true)
        if path.hasPrefix("//") { path.removeFirst() }
        components.percentEncodedPath = path
        components.percentEncodedQuery = query.isEmpty ? nil
            : query.map { "\(SigV4.encode($0.0))=\(SigV4.encode($0.1))" }.joined(separator: "&")
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        SigV4.sign(&request, path: path, query: query, payloadHash: payloadHash,
                   accessKey: account.accessKey, secret: secret, region: account.region)
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        return data
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let xml = S3XML.parse(data)
            throw S3Error(status: http.statusCode, code: xml.first("Code"), message: xml.first("Message"))
        }
    }

    func buckets() async throws -> [String] {
        S3XML.parse(try await send(request("GET", bucket: nil))).all("Name")
    }

    /// One level of a bucket: folders (common prefixes) then files, following continuation tokens.
    func list(bucket: String, prefix: String) async throws -> [S3Object] {
        var objects: [S3Object] = []
        var token: String?
        repeat {
            var query = [("list-type", "2"), ("delimiter", "/"), ("prefix", prefix)]
            if let token { query.append(("continuation-token", token)) }
            let xml = S3XML.parse(try await send(request("GET", bucket: bucket, query: query)))
            objects += xml.prefixes.filter { $0 != prefix }.map { S3Object(key: $0, size: 0, modified: nil, isPrefix: true) }
            objects += xml.contents.filter { $0.key != prefix }.map { S3Object(key: $0.key, size: $0.size, modified: $0.modified, isPrefix: false) }
            token = xml.first("IsTruncated") == "true" ? xml.first("NextContinuationToken") : nil
        } while token != nil
        return objects
    }

    func download(bucket: String, key: String, to destination: URL) async throws {
        let (temp, response) = try await session.download(for: request("GET", bucket: bucket, key: key))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let data = (try? Data(contentsOf: temp)) ?? Data()
            try check(response, data)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    /// Single PUT (fine up to 5 GB). The payload isn't hashed (UNSIGNED-PAYLOAD, allowed over HTTPS).
    func upload(_ file: URL, bucket: String, key: String) async throws {
        let type = file.pathExtension.isEmpty ? "application/octet-stream" : (UTTypeHelper.mime(for: file.pathExtension) ?? "application/octet-stream")
        let hash = account.endpoint.scheme == "https" ? SigV4.unsignedPayload : SigV4.sha256(try Data(contentsOf: file))
        let request = request("PUT", bucket: bucket, key: key, payloadHash: hash, headers: ["Content-Type": type])
        let (data, response) = try await session.upload(for: request, fromFile: file)
        try check(response, data)
    }

    func createFolder(bucket: String, key: String) async throws {
        let folder = key.hasSuffix("/") ? key : key + "/"
        _ = try await send(request("PUT", bucket: bucket, key: folder))
    }

    func delete(bucket: String, key: String) async throws {
        _ = try await send(request("DELETE", bucket: bucket, key: key))
    }

    /// Deletes a "folder": every object under the prefix.
    func deletePrefix(bucket: String, prefix: String) async throws {
        var stack = [prefix]
        while let current = stack.popLast() {
            for object in try await list(bucket: bucket, prefix: current) {
                if object.isPrefix { stack.append(object.key) } else { try await delete(bucket: bucket, key: object.key) }
            }
            try? await delete(bucket: bucket, key: current)
        }
    }
}

import UniformTypeIdentifiers

enum UTTypeHelper {
    static func mime(for fileExtension: String) -> String? {
        UTType(filenameExtension: fileExtension)?.preferredMIMEType
    }
}

// MARK: - XML

/// Just enough XML for S3 listings and errors.
struct S3XML {
    struct Content { let key: String; let size: Int64; let modified: Date? }

    var values: [(String, String)] = []
    var prefixes: [String] = []
    var contents: [Content] = []

    func first(_ name: String) -> String? { values.first { $0.0 == name }?.1 }
    func all(_ name: String) -> [String] { values.filter { $0.0 == name }.map(\.1) }

    static func parse(_ data: Data) -> S3XML {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.result
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var result = S3XML()
        var stack: [String] = []
        var text = ""
        var key = "", size: Int64 = 0, modified: Date?
        let dates: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            stack.append(name)
            text = ""
            if name == "Contents" { key = ""; size = 0; modified = nil }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            stack.removeLast()
            let parent = stack.last
            switch (parent, name) {
            case ("Contents", "Key"): key = text
            case ("Contents", "Size"): size = Int64(text) ?? 0
            case ("Contents", "LastModified"): modified = dates.date(from: text) ?? ISO8601DateFormatter().date(from: text)
            case (_, "Contents"): result.contents.append(Content(key: key, size: size, modified: modified))
            case ("CommonPrefixes", "Prefix"): result.prefixes.append(text)
            default: result.values.append((name, text))
            }
            text = ""
        }
    }
}

// MARK: - Accounts

@MainActor
@Observable
final class S3Store {
    static let shared = S3Store()

    private(set) var accounts: [S3Account] { didSet { save() } }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        accounts = defaults.data(forKey: "s3.accounts").flatMap { try? JSONDecoder().decode([S3Account].self, from: $0) } ?? []
    }

    private func save() {
        if let data = try? JSONEncoder().encode(accounts) { defaults.set(data, forKey: "s3.accounts") }
    }

    func save(_ account: S3Account, secret: String?) throws {
        if let secret, !secret.isEmpty {
            try Keychain.save(password: secret, server: account.keychainServer, account: account.accessKey, label: "\(account.name) (Wayfile S3)")
        }
        if let index = accounts.firstIndex(where: { $0.id == account.id }) { accounts[index] = account } else { accounts.append(account) }
    }

    func remove(_ account: S3Account) {
        Keychain.delete(server: account.keychainServer, account: account.accessKey)
        accounts.removeAll { $0.id == account.id }
    }

    func client(for account: S3Account) throws -> S3Client {
        guard let secret = account.secret else { throw ShellError(message: "No secret key saved for “\(account.name)”.") }
        return S3Client(account: account, secret: secret)
    }
}
