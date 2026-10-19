import Foundation

/// One changed path in a repository, split into its staged (index) and unstaged (worktree) parts.
struct GitChange: Hashable, Identifiable {
    /// Repo-relative path (the new path for renames).
    let path: String
    let originalPath: String?
    /// Index column of `git status` (" " when nothing is staged).
    let staged: Character
    /// Worktree column (" " when the working copy matches the index).
    let unstaged: Character

    var id: String { path }
    var isUntracked: Bool { staged == "?" }
    var hasStaged: Bool { staged != " " && staged != "?" }
    var hasUnstaged: Bool { unstaged != " " || isUntracked }
    var isConflicted: Bool { staged == "U" || unstaged == "U" || (staged == "A" && unstaged == "A") || (staged == "D" && unstaged == "D") }
    var status: GitStatus? { GitStatus(x: staged, y: unstaged) }
}

struct GitLogEntry: Hashable, Identifiable {
    let hash: String
    let shortHash: String
    let author: String
    let date: Date
    let subject: String
    /// Path of the file in that commit (differs from today's after a rename).
    let path: String?
    var id: String { hash }
}

extension Git {
    /// Every change in the repository (`git status` for the whole worktree).
    static func changes(in root: URL) async throws -> [GitChange] {
        let output = try await check(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: root)
        return parseChanges(output)
    }

    static func parseChanges(_ output: String) -> [GitChange] {
        var changes: [GitChange] = []
        var entries = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let entry = entries.popFirst() {
            guard entry.count > 3 else { continue }
            let chars = Array(entry)
            let x = chars[0], y = chars[1]
            if x == "!" { continue }
            let path = String(entry.dropFirst(3))
            var original: String?
            if x == "R" || x == "C" || y == "R" || y == "C" { original = entries.popFirst() }
            changes.append(GitChange(path: path, originalPath: original, staged: x, unstaged: y))
        }
        return changes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func stage(_ paths: [String], in root: URL) async throws {
        guard !paths.isEmpty else { return }
        try await check(["add", "--all", "--"] + paths, in: root)
    }

    static func unstage(_ paths: [String], in root: URL) async throws {
        guard !paths.isEmpty else { return }
        // `restore --staged` fails in a repository without commits; `rm --cached` covers that case.
        if (try? await check(["rev-parse", "--verify", "HEAD"], in: root)) != nil {
            try await check(["restore", "--staged", "--"] + paths, in: root)
        } else {
            try await check(["rm", "--cached", "-r", "--quiet", "--"] + paths, in: root)
        }
    }

    /// Throws away working-copy changes of tracked files (untracked files are moved to the Trash by the caller).
    static func discard(_ paths: [String], in root: URL) async throws {
        guard !paths.isEmpty else { return }
        try await check(["restore", "--worktree", "--"] + paths, in: root)
    }

    @discardableResult
    static func commit(message: String, amend: Bool = false, in root: URL) async throws -> String {
        var args = ["commit", "-m", message]
        if amend { args.append("--amend") }
        return try await check(args, in: root)
    }

    /// File contents at a revision: "HEAD", a commit hash, or "" for the index (staged version). Nil if absent.
    static func show(_ path: String, at revision: String, in root: URL) async -> String? {
        let output = await Shell.run("/usr/bin/git", ["-C", root.path, "show", "\(revision):\(path)"], environment: environment)
        return output.status == 0 ? output.stdout : nil
    }

    /// Commits touching a path (following renames), newest first.
    static func history(of path: String, in root: URL, limit: Int = 200) async throws -> [GitLogEntry] {
        let output = try await check(["log", "--follow", "-n", String(limit), "--format=%x1e%H%x1f%h%x1f%an%x1f%at%x1f%s", "--name-only", "--", path], in: root)
        return parseHistory(output)
    }

    /// Recent commits of the whole repository.
    static func log(in root: URL, limit: Int = 200) async throws -> [GitLogEntry] {
        let output = try await check(["log", "-n", String(limit), "--format=%x1e%H%x1f%h%x1f%an%x1f%at%x1f%s"], in: root)
        return parseHistory(output)
    }

    static func parseHistory(_ output: String) -> [GitLogEntry] {
        output.split(separator: "\u{1e}").compactMap { record in
            let lines = record.split(separator: "\n", omittingEmptySubsequences: true)
            guard let header = lines.first else { return nil }
            let fields = header.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5, let seconds = TimeInterval(fields[3]) else { return nil }
            return GitLogEntry(hash: fields[0], shortHash: fields[1], author: fields[2],
                               date: Date(timeIntervalSince1970: seconds), subject: fields[4...].joined(separator: "\u{1f}"),
                               path: lines.dropFirst().last.map(String.init))
        }
    }

    /// Files changed by a commit.
    static func filesChanged(in commit: String, root: URL) async throws -> [String] {
        let output = try await check(["show", "--format=", "--name-only", commit], in: root)
        return output.split(separator: "\n").map(String.init)
    }

    static func remoteURL(in root: URL, remote: String = "origin") async -> String? {
        let output = await Shell.run("/usr/bin/git", ["-C", root.path, "remote", "get-url", remote], environment: environment)
        let url = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.status == 0 && !url.isEmpty ? url : nil
    }
}
