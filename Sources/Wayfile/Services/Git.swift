import AppKit
import Foundation
import SwiftUI

enum GitStatus: String, Hashable, CaseIterable {
    case conflicted, modified, added, deleted, renamed, untracked

    var letter: String {
        switch self {
        case .conflicted: return "!"
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "U"
        }
    }

    var title: String {
        switch self {
        case .conflicted: return String(localized: "Conflicted")
        case .modified: return String(localized: "Modified")
        case .added: return String(localized: "Added")
        case .deleted: return String(localized: "Deleted")
        case .renamed: return String(localized: "Renamed")
        case .untracked: return String(localized: "Untracked")
        }
    }

    var color: Color {
        switch self {
        case .conflicted: return .red
        case .modified: return .orange
        case .added: return .green
        case .deleted: return .red
        case .renamed: return .blue
        case .untracked: return .teal
        }
    }

    /// Lower is more important; used for sorting and for summarising a folder's contents.
    var rank: Int { GitStatus.allCases.firstIndex(of: self)! }

    /// Maps porcelain v1 "XY" codes.
    init?(x: Character, y: Character) {
        switch (x, y) {
        case ("?", "?"): self = .untracked
        case ("!", "!"): return nil
        case ("U", _), (_, "U"), ("A", "A"), ("D", "D"): self = .conflicted
        case ("R", _), (_, "R"): self = .renamed
        case ("A", _): self = .added
        case ("D", _), (_, "D"): self = .deleted
        default: self = .modified
        }
    }
}

struct GitCommit: Hashable {
    let hash: String
    let author: String
    let date: Date
    let subject: String
}

struct GitBranch: Hashable, Identifiable {
    let name: String
    let isCurrent: Bool
    let isRemote: Bool

    var id: String { (isRemote ? "remote/" : "local/") + name }
}

/// Git state for the folder a pane shows, keyed by the names of its direct children.
struct GitInfo: Equatable {
    let root: URL
    let branch: String
    let upstream: String?
    let ahead: Int
    let behind: Int
    let statuses: [String: GitStatus]
    let commits: [String: GitCommit]
    let changedCount: Int

    var repositoryName: String { root.lastPathComponent }
}

enum Git {
    /// Never block on a password prompt: fail fast and surface the error instead.
    static let environment = [
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_SSH_COMMAND": "ssh -o BatchMode=yes",
        "LC_ALL": "C",
    ]

    private static let executable = "/usr/bin/git"

    private static func run(_ args: [String], in dir: URL) async -> Shell.Output {
        await Shell.run(executable, ["-C", dir.path] + args, environment: environment)
    }

    @discardableResult
    static func check(_ args: [String], in dir: URL) async throws -> String {
        try await Shell.check(executable, ["-C", dir.path] + args, environment: environment)
    }

    static func root(of dir: URL) async -> URL? {
        let output = await run(["rev-parse", "--show-toplevel"], in: dir)
        guard output.status == 0 else { return nil }
        let path = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Everything a pane needs for `dir`, or nil outside a repository.
    static func info(for dir: URL) async -> GitInfo? {
        guard let root = await root(of: dir) else { return nil }
        let relative = relativePath(of: dir, in: root)
        let pathspec = relative.isEmpty ? "." : relative

        async let branchOutput = run(["status", "--porcelain=v2", "--branch", "--untracked-files=no"], in: root)
        async let statusOutput = run(["status", "--porcelain=v1", "-z", "--untracked-files=normal", "--", pathspec], in: root)
        async let logOutput = run(["log", "-n", "2000", "--no-renames", "--format=%x1e%h%x1f%an%x1f%at%x1f%s", "--name-only", "--", pathspec], in: root)

        let branch = parseBranch(await branchOutput.stdout)
        let status = await statusOutput.stdout
        let log = await logOutput.stdout
        return GitInfo(
            root: root,
            branch: branch.head,
            upstream: branch.upstream,
            ahead: branch.ahead,
            behind: branch.behind,
            statuses: parseStatus(status, relativeTo: relative),
            commits: parseLog(log, relativeTo: relative),
            changedCount: countEntries(status)
        )
    }

    static func branches(in root: URL) async -> [GitBranch] {
        let local = await run(["for-each-ref", "--format=%(HEAD)%00%(refname:short)", "refs/heads"], in: root).stdout
        let remote = await run(["for-each-ref", "--format=%(refname:short)", "refs/remotes"], in: root).stdout
        var result: [GitBranch] = local.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return GitBranch(name: String(parts[1]), isCurrent: parts[0] == "*", isRemote: false)
        }
        result += remote.split(separator: "\n")
            .map(String.init)
            .filter { !$0.hasSuffix("/HEAD") && $0.contains("/") }
            .map { GitBranch(name: $0, isCurrent: false, isRemote: true) }
        return result
    }

    // MARK: Parsing

    static func relativePath(of dir: URL, in root: URL) -> String {
        // Resolve symlinks (/tmp → /private/tmp) so the prefix comparison is reliable.
        let dirPath = dir.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard dirPath.hasPrefix(rootPath) else { return "" }
        return String(dirPath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// The direct child of the folder at `relative` that `path` (repo-relative) belongs to,
    /// and whether `path` is inside that child rather than the child itself.
    private static func child(of path: String, relativeTo relative: String) -> (name: String, nested: Bool)? {
        var remainder = path
        if !relative.isEmpty {
            guard path.hasPrefix(relative + "/") else { return nil }
            remainder = String(path.dropFirst(relative.count + 1))
        }
        let isDirectoryEntry = remainder.hasSuffix("/")
        let components = remainder.split(separator: "/")
        guard let first = components.first else { return nil }
        return (String(first), components.count > 1 || isDirectoryEntry)
    }

    static func parseStatus(_ output: String, relativeTo relative: String) -> [String: GitStatus] {
        var result: [String: GitStatus] = [:]
        var entries = output.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let entry = entries.next() {
            guard entry.count > 3 else { continue }
            let x = entry[entry.startIndex]
            let y = entry[entry.index(after: entry.startIndex)]
            let path = String(entry.dropFirst(3))
            if x == "R" || x == "C" { _ = entries.next() } // skip the original path of renames/copies
            guard let status = GitStatus(x: x, y: y), let child = child(of: path, relativeTo: relative) else { continue }
            // A folder summarises its contents: any tracked change inside reads as "modified",
            // and it's "untracked" only when everything changed inside is untracked.
            let effective: GitStatus = child.nested && status != .untracked && status != .conflicted ? .modified : status
            if effective.rank < (result[child.name]?.rank ?? .max) {
                result[child.name] = effective
            }
        }
        return result
    }

    private static func countEntries(_ output: String) -> Int {
        var count = 0
        var entries = output.split(separator: "\0").makeIterator()
        while let entry = entries.next() {
            count += 1
            if entry.first == "R" || entry.first == "C" { _ = entries.next() }
        }
        return count
    }

    static func parseLog(_ output: String, relativeTo relative: String) -> [String: GitCommit] {
        var result: [String: GitCommit] = [:]
        for record in output.split(separator: "\u{1e}") {
            let lines = record.split(separator: "\n", omittingEmptySubsequences: true)
            guard let header = lines.first else { continue }
            let fields = header.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count >= 4 else { continue }
            let commit = GitCommit(
                hash: String(fields[0]),
                author: String(fields[1]),
                date: Date(timeIntervalSince1970: TimeInterval(fields[2]) ?? 0),
                subject: fields[3...].joined(separator: "\u{1f}")
            )
            for line in lines.dropFirst() {
                guard let child = child(of: String(line), relativeTo: relative), result[child.name] == nil else { continue }
                result[child.name] = commit // log is newest first, so the first sighting wins
            }
        }
        return result
    }

    static func parseBranch(_ output: String) -> (head: String, upstream: String?, ahead: Int, behind: Int) {
        var head = "HEAD"
        var oid = ""
        var upstream: String?
        var ahead = 0
        var behind = 0
        for line in output.split(separator: "\n") where line.hasPrefix("# ") {
            let parts = line.split(separator: " ")
            guard parts.count >= 3 else { continue }
            switch parts[1] {
            case "branch.oid": oid = String(parts[2])
            case "branch.head": head = String(parts[2])
            case "branch.upstream": upstream = String(parts[2])
            case "branch.ab" where parts.count >= 4:
                ahead = Int(parts[2].dropFirst()) ?? 0
                behind = Int(parts[3].dropFirst()) ?? 0
            default: break
            }
        }
        if head == "(detached)" { head = String(oid.prefix(7)) }
        return (head, upstream, ahead, behind)
    }
}

/// Code editors / git clients that can open a repository, in preference order.
enum Editors {
    static let known: [(name: String, bundleID: String)] = [
        ("Visual Studio Code", "com.microsoft.VSCode"),
        ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("Zed", "dev.zed.Zed"),
        ("Xcode", "com.apple.dt.Xcode"),
        ("Sublime Text", "com.sublimetext.4"),
        ("Nova", "com.panic.Nova"),
        ("Fork", "com.DanPristupov.Fork"),
        ("Tower", "com.fournova.Tower3"),
        ("GitHub Desktop", "com.github.GitHubClient"),
    ]

    static var installed: [(name: String, url: URL)] {
        known.compactMap { editor in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleID).map { (editor.name, $0) }
        }
    }

    static func open(_ folder: URL, with app: URL) {
        NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
