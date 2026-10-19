import Foundation

/// Containers, images and volumes through the `docker` CLI (Docker Desktop, OrbStack, Colima…).
enum Docker {
    struct Container: Identifiable, Hashable {
        let id: String
        let name: String
        let image: String
        let state: String
        let status: String
        let ports: String
        let created: String
        let size: String
        let labels: [String: String]

        var isRunning: Bool { state == "running" }
        var composeProject: String? { labels["com.docker.compose.project"] }
        var composeService: String? { labels["com.docker.compose.service"] }
        /// Folder of the compose project on this Mac.
        var projectFolder: URL? { labels["com.docker.compose.project.working_dir"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
        /// Host folders bind-mounted into the container (Docker Desktop labels).
        var bindSources: [URL] {
            labels.filter { $0.key.hasPrefix("desktop.docker.io/binds/") && $0.key.hasSuffix("/Source") }
                .map { URL(fileURLWithPath: $0.value) }
                .sorted { $0.path < $1.path }
        }
        /// "http://localhost:8092" for every published TCP port.
        var localURLs: [URL] {
            let pattern = try! NSRegularExpression(pattern: #"(?:0\.0\.0\.0|\[::\]|127\.0\.0\.1):(\d+)->\d+/tcp"#)
            let matches = pattern.matches(in: ports, range: NSRange(ports.startIndex..., in: ports))
            var seen = Set<String>()
            return matches.compactMap { match -> URL? in
                guard let range = Range(match.range(at: 1), in: ports) else { return nil }
                let port = String(ports[range])
                guard seen.insert(port).inserted else { return nil }
                return URL(string: "http://localhost:\(port)")
            }
        }
    }

    struct Image: Identifiable, Hashable {
        let id: String
        let repository: String
        let tag: String
        let size: String
        let created: String
        let containers: Int?
        var reference: String { tag == "<none>" ? id : "\(repository):\(tag)" }
    }

    struct Volume: Identifiable, Hashable {
        let name: String
        let driver: String
        let mountpoint: String
        let labels: [String: String]
        var id: String { name }
        var composeProject: String? { labels["com.docker.compose.project"] }
    }

    static let candidates = ["/opt/homebrew/bin/docker", "/usr/local/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker",
                             NSHomeDirectory() + "/.orbstack/bin/docker", NSHomeDirectory() + "/.docker/bin/docker"]

    static var executable: String? { candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    /// The docker CLI finds credential helpers and plugins on PATH.
    private static var environment: [String: String] {
        let extra = "/opt/homebrew/bin:/usr/local/bin:/Applications/Docker.app/Contents/Resources/bin:" + NSHomeDirectory() + "/.orbstack/bin"
        return ["PATH": extra + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")]
    }

    @discardableResult
    static func run(_ args: [String]) async throws -> String {
        guard let executable else { throw ShellError(message: "Docker isn’t installed (no docker command found).") }
        return try await Shell.check(executable, args, environment: environment)
    }

    static func containers() async throws -> [Container] {
        parseContainers(try await run(["ps", "-a", "--no-trunc=false", "--format", "{{json .}}"]))
    }

    static func images() async throws -> [Image] {
        parseImages(try await run(["images", "--format", "{{json .}}"]))
    }

    static func volumes() async throws -> [Volume] {
        parseVolumes(try await run(["volume", "ls", "--format", "{{json .}}"]))
    }

    static func logs(_ container: Container, lines: Int = 300) async -> String {
        guard let executable else { return "" }
        let output = await Shell.run(executable, ["logs", "--tail", String(lines), "--timestamps", container.id], environment: environment)
        // Containers log to both streams; interleaving is lost, which is fine for a quick look.
        return [output.stdout, output.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: Parsing (one JSON object per line)

    private static func objects(_ output: String) -> [[String: Any]] {
        output.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    static func labels(_ text: String?) -> [String: String] {
        guard let text, !text.isEmpty else { return [:] }
        var result: [String: String] = [:]
        // Values may contain commas (depends_on lists); a new pair starts where "key=" follows a comma.
        var current = ""
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            let piece = String(part)
            let key = piece.firstIndex(of: "=").map { piece[..<$0] }
            if let key, !key.isEmpty, !key.contains(" "), !key.contains(":") {
                if !current.isEmpty, let e = current.firstIndex(of: "=") { result[String(current[..<e])] = String(current[current.index(after: e)...]) }
                current = piece
            } else {
                current += "," + piece
            }
        }
        if let e = current.firstIndex(of: "=") { result[String(current[..<e])] = String(current[current.index(after: e)...]) }
        return result
    }

    static func parseContainers(_ output: String) -> [Container] {
        objects(output).map { o in
            Container(id: o["ID"] as? String ?? "", name: o["Names"] as? String ?? "", image: o["Image"] as? String ?? "",
                      state: o["State"] as? String ?? "", status: o["Status"] as? String ?? "", ports: o["Ports"] as? String ?? "",
                      created: o["RunningFor"] as? String ?? "", size: o["Size"] as? String ?? "", labels: labels(o["Labels"] as? String))
        }
        .sorted { ($0.composeProject ?? "~", $0.name) < ($1.composeProject ?? "~", $1.name) }
    }

    static func parseImages(_ output: String) -> [Image] {
        objects(output).map { o in
            Image(id: o["ID"] as? String ?? "", repository: o["Repository"] as? String ?? "", tag: o["Tag"] as? String ?? "",
                  size: o["Size"] as? String ?? "", created: o["CreatedSince"] as? String ?? "",
                  containers: (o["Containers"] as? String).flatMap(Int.init))
        }
    }

    static func parseVolumes(_ output: String) -> [Volume] {
        objects(output).map { o in
            Volume(name: o["Name"] as? String ?? "", driver: o["Driver"] as? String ?? "",
                   mountpoint: o["Mountpoint"] as? String ?? "", labels: labels(o["Labels"] as? String))
        }
        .sorted { $0.name < $1.name }
    }
}
