import Foundation

// MARK: - Text diff

/// Side-by-side line diff. Adjacent removals and insertions pair up as changed rows.
enum TextDiff {
    enum Kind: Hashable { case same, changed, removed, added }

    struct Row: Hashable, Identifiable {
        let id: Int
        let kind: Kind
        let left: (number: Int, text: String)?
        let right: (number: Int, text: String)?

        static func == (a: Row, b: Row) -> Bool {
            a.id == b.id && a.kind == b.kind && a.left?.number == b.left?.number && a.left?.text == b.left?.text
                && a.right?.number == b.right?.number && a.right?.text == b.right?.text
        }

        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// A row, or a fold of `count` unchanged lines hidden between hunks.
    enum Line: Identifiable, Hashable {
        case row(Row)
        case fold(id: Int, count: Int)
        var id: Int {
            switch self {
            case .row(let row): return row.id
            case .fold(let id, _): return -id - 1
            }
        }
    }

    struct Stats: Equatable {
        var added = 0, removed = 0, changed = 0
        var isIdentical: Bool { added == 0 && removed == 0 && changed == 0 }
    }

    static func lines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    static func rows(_ old: String, _ new: String, ignoreWhitespace: Bool = false) -> [Row] {
        let a = lines(old), b = lines(new)
        let key: (String) -> String = ignoreWhitespace ? { $0.filter { !$0.isWhitespace } } : { $0 }
        let diff = b.map(key).difference(from: a.map(key))
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var rows: [Row] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            let id = rows.count
            let leftRemoved = i < a.count && removed.contains(i)
            let rightInserted = j < b.count && inserted.contains(j)
            if leftRemoved && rightInserted {
                rows.append(Row(id: id, kind: .changed, left: (i + 1, a[i]), right: (j + 1, b[j]))); i += 1; j += 1
            } else if leftRemoved {
                rows.append(Row(id: id, kind: .removed, left: (i + 1, a[i]), right: nil)); i += 1
            } else if rightInserted {
                rows.append(Row(id: id, kind: .added, left: nil, right: (j + 1, b[j]))); j += 1
            } else if i < a.count && j < b.count {
                rows.append(Row(id: id, kind: .same, left: (i + 1, a[i]), right: (j + 1, b[j]))); i += 1; j += 1
            } else if i < a.count {
                rows.append(Row(id: id, kind: .removed, left: (i + 1, a[i]), right: nil)); i += 1
            } else {
                rows.append(Row(id: id, kind: .added, left: nil, right: (j + 1, b[j]))); j += 1
            }
        }
        return rows
    }

    static func stats(_ rows: [Row]) -> Stats {
        rows.reduce(into: Stats()) { stats, row in
            switch row.kind {
            case .same: break
            case .changed: stats.changed += 1
            case .removed: stats.removed += 1
            case .added: stats.added += 1
            }
        }
    }

    /// Keeps `context` unchanged lines around changes and folds the rest.
    static func hunks(_ rows: [Row], context: Int = 3) -> [Line] {
        let changed = rows.indices.filter { rows[$0].kind != .same }
        guard !changed.isEmpty else { return rows.isEmpty ? [] : [.fold(id: 0, count: rows.count)] }
        var keep = Set<Int>()
        for index in changed {
            for k in max(0, index - context)...min(rows.count - 1, index + context) { keep.insert(k) }
        }
        var lines: [Line] = []
        var hidden = 0
        for index in rows.indices {
            if keep.contains(index) {
                if hidden > 0 { lines.append(.fold(id: index, count: hidden)); hidden = 0 }
                lines.append(.row(rows[index]))
            } else {
                hidden += 1
            }
        }
        if hidden > 0 { lines.append(.fold(id: rows.count, count: hidden)) }
        return lines
    }
}

// MARK: - Project detection

struct ProjectInfo: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case swiftPackage, xcode, node, python, rust, go, ruby, maven, gradle, dotnet, php, docker, make

        var title: String {
            switch self {
            case .swiftPackage: return String(localized: "Swift Package")
            case .xcode: return String(localized: "Xcode Project")
            case .node: return String(localized: "Node.js")
            case .python: return String(localized: "Python")
            case .rust: return String(localized: "Rust")
            case .go: return String(localized: "Go")
            case .ruby: return String(localized: "Ruby")
            case .maven: return String(localized: "Maven")
            case .gradle: return String(localized: "Gradle")
            case .dotnet: return String(localized: ".NET")
            case .php: return String(localized: "PHP")
            case .docker: return String(localized: "Docker")
            case .make: return String(localized: "Make")
            }
        }

        var symbol: String {
            switch self {
            case .swiftPackage, .xcode: return "swift"
            case .node: return "n.square"
            case .python: return "p.square"
            case .rust: return "gearshape.2"
            case .go: return "g.square"
            case .ruby: return "diamond"
            case .maven, .gradle: return "cup.and.saucer"
            case .dotnet: return "number.square"
            case .php: return "chevron.left.forwardslash.chevron.right"
            case .docker: return "shippingbox"
            case .make: return "hammer"
            }
        }
    }

    struct Command: Hashable, Identifiable {
        let title: String
        let command: String
        var id: String { command }
    }

    let kind: Kind
    /// The file that identified it (Package.swift, package.json…).
    let manifest: URL
    var name: String?
    var version: String?
    var commands: [Command] = []

    var id: String { kind.rawValue }
}

enum ProjectDetector {
    static func detect(in folder: URL) -> [ProjectInfo] {
        let fm = FileManager.default
        let names = Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
        func file(_ name: String) -> URL { folder.appendingPathComponent(name) }
        func text(_ name: String) -> String? { try? String(contentsOf: file(name), encoding: .utf8) }
        var found: [ProjectInfo] = []

        if names.contains("Package.swift") {
            var info = ProjectInfo(kind: .swiftPackage, manifest: file("Package.swift"))
            info.name = text("Package.swift").flatMap { firstMatch(#"name:\s*"([^"]+)""#, in: $0) }
            info.commands = [.init(title: "Build", command: "swift build"), .init(title: "Test", command: "swift test"),
                             .init(title: "Run", command: "swift run")]
            found.append(info)
        }
        if let project = names.sorted().first(where: { $0.hasSuffix(".xcworkspace") }) ?? names.sorted().first(where: { $0.hasSuffix(".xcodeproj") }) {
            var info = ProjectInfo(kind: .xcode, manifest: file(project))
            info.name = (project as NSString).deletingPathExtension
            found.append(info)
        }
        if names.contains("package.json") {
            var info = ProjectInfo(kind: .node, manifest: file("package.json"))
            let json = (try? Data(contentsOf: file("package.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            info.name = json?["name"] as? String
            info.version = json?["version"] as? String
            let runner = names.contains("pnpm-lock.yaml") ? "pnpm" : names.contains("yarn.lock") ? "yarn" : names.contains("bun.lockb") || names.contains("bun.lock") ? "bun" : "npm"
            info.commands = [.init(title: "Install", command: "\(runner) install")]
            let scripts = (json?["scripts"] as? [String: Any])?.keys.sorted() ?? []
            info.commands += scripts.map { .init(title: $0, command: runner == "npm" ? "npm run \($0)" : "\(runner) \($0)") }
            found.append(info)
        }
        if let manifest = ["pyproject.toml", "setup.py", "requirements.txt", "Pipfile"].first(where: names.contains) {
            var info = ProjectInfo(kind: .python, manifest: file(manifest))
            if manifest == "pyproject.toml", let toml = text(manifest) {
                info.name = tomlValue("name", in: toml)
                info.version = tomlValue("version", in: toml)
            }
            if names.contains("requirements.txt") { info.commands.append(.init(title: "Install requirements", command: "python3 -m pip install -r requirements.txt")) }
            if names.contains("pyproject.toml") && names.contains("uv.lock") { info.commands.append(.init(title: "uv sync", command: "uv sync")) }
            if names.contains("tests") || names.contains("pytest.ini") { info.commands.append(.init(title: "Test", command: "python3 -m pytest")) }
            found.append(info)
        }
        if names.contains("Cargo.toml") {
            var info = ProjectInfo(kind: .rust, manifest: file("Cargo.toml"))
            if let toml = text("Cargo.toml") { info.name = tomlValue("name", in: toml); info.version = tomlValue("version", in: toml) }
            info.commands = [.init(title: "Build", command: "cargo build"), .init(title: "Test", command: "cargo test"), .init(title: "Run", command: "cargo run")]
            found.append(info)
        }
        if names.contains("go.mod") {
            var info = ProjectInfo(kind: .go, manifest: file("go.mod"))
            info.name = text("go.mod").flatMap { firstMatch(#"(?m)^module\s+(\S+)"#, in: $0) }
            info.commands = [.init(title: "Build", command: "go build ./..."), .init(title: "Test", command: "go test ./...")]
            found.append(info)
        }
        if names.contains("Gemfile") {
            found.append(ProjectInfo(kind: .ruby, manifest: file("Gemfile"), commands: [.init(title: "Bundle", command: "bundle install")]))
        }
        if names.contains("pom.xml") {
            found.append(ProjectInfo(kind: .maven, manifest: file("pom.xml"), commands: [.init(title: "Package", command: "mvn package")]))
        }
        if let gradle = ["build.gradle.kts", "build.gradle"].first(where: names.contains) {
            let wrapper = names.contains("gradlew") ? "./gradlew" : "gradle"
            found.append(ProjectInfo(kind: .gradle, manifest: file(gradle), commands: [.init(title: "Build", command: "\(wrapper) build")]))
        }
        if let csproj = names.sorted().first(where: { $0.hasSuffix(".csproj") || $0.hasSuffix(".sln") }) {
            found.append(ProjectInfo(kind: .dotnet, manifest: file(csproj), name: (csproj as NSString).deletingPathExtension,
                                     commands: [.init(title: "Build", command: "dotnet build"), .init(title: "Run", command: "dotnet run")]))
        }
        if names.contains("composer.json") {
            found.append(ProjectInfo(kind: .php, manifest: file("composer.json"), commands: [.init(title: "Install", command: "composer install")]))
        }
        if let compose = ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"].first(where: names.contains) {
            found.append(ProjectInfo(kind: .docker, manifest: file(compose), commands: [.init(title: "Up", command: "docker compose up -d"),
                                                                                       .init(title: "Down", command: "docker compose down")]))
        } else if names.contains("Dockerfile") {
            found.append(ProjectInfo(kind: .docker, manifest: file("Dockerfile"), commands: [.init(title: "Build image", command: "docker build .")]))
        }
        if let makefile = ["Makefile", "makefile", "GNUmakefile"].first(where: names.contains) {
            let targets = text(makefile).map(makeTargets) ?? []
            found.append(ProjectInfo(kind: .make, manifest: file(makefile),
                                     commands: targets.prefix(12).map { .init(title: $0, command: "make \($0)") }))
        }
        return found
    }

    static func makeTargets(_ text: String) -> [String] {
        var targets: [String] = []
        for line in text.split(separator: "\n") {
            guard let first = line.first, !first.isWhitespace, first != "#", first != "." else { continue }
            guard let colon = line.firstIndex(of: ":"), !line[colon...].hasPrefix(":="), !line.prefix(upTo: colon).contains("=") else { continue }
            for target in line[..<colon].split(separator: " ") {
                let name = String(target)
                if !name.contains("%") && !name.contains("$") && !targets.contains(name) { targets.append(name) }
            }
        }
        return targets
    }

    /// `key = "value"` in the first table that has it (enough for name/version).
    static func tomlValue(_ key: String, in toml: String) -> String? {
        firstMatch(#"(?m)^\s*"# + NSRegularExpression.escapedPattern(for: key) + #"\s*=\s*"([^"]*)""#, in: toml)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

// MARK: - Developer links

enum DevLinks {
    /// vscode://file/<path> (opens in VS Code; Cursor understands cursor://).
    static func editorURI(_ url: URL, scheme: String = "vscode") -> String {
        let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        return "\(scheme)://file\(path)"
    }

    /// Web URL of a file on GitHub / GitLab / Bitbucket from the remote URL, branch and repo-relative path.
    static func webURL(remote: String, branch: String, relativePath: String, isDirectory: Bool = false) -> String? {
        var base = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasPrefix("git@") {
            // git@github.com:owner/repo.git → https://github.com/owner/repo
            base = "https://" + base.dropFirst(4).replacingOccurrences(of: ":", with: "/")
        } else if base.hasPrefix("ssh://") {
            base = "https://" + base.dropFirst(6).replacingOccurrences(of: "git@", with: "")
        }
        guard base.hasPrefix("https://") || base.hasPrefix("http://") else { return nil }
        if base.hasSuffix(".git") { base.removeLast(4) }
        if let at = base.range(of: "@"), let scheme = base.range(of: "://"), at.lowerBound > scheme.upperBound {
            base = String(base[..<scheme.upperBound]) + base[at.upperBound...]   // strip user:token@
        }
        let path = relativePath.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        let encodedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        if base.contains("bitbucket.org") { return "\(base)/src/\(encodedBranch)/\(path)" }
        if base.contains("gitlab") { return "\(base)/-/\(isDirectory ? "tree" : "blob")/\(encodedBranch)/\(path)" }
        return "\(base)/\(isDirectory ? "tree" : "blob")/\(encodedBranch)/\(path)"
    }
}
