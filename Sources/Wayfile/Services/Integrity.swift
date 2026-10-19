import Foundation

/// Folder fingerprints (SHA-256 of every file) and checks against them, to spot silent changes.
enum Integrity {
    struct Baseline: Codable {
        let folder: String
        let created: Date
        let files: [String: String] // relative path → SHA-256
    }

    struct Report {
        var changed: [String] = []
        var added: [String] = []
        var removed: [String] = []
        let baselineDate: Date
        var isClean: Bool { changed.isEmpty && added.isEmpty && removed.isEmpty }
    }

    static var storeURL: URL {
        let name = Bundle.main.bundleIdentifier == nil ? "integrity-dev.json" : "integrity.json"
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Wayfile/\(name)")
    }

    static func hashes(of folder: URL, progress: OperationProgress) throws -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(atPath: folder.path)
        var paths: [String] = []
        while let relative = enumerator?.nextObject() as? String {
            guard enumerator?.fileAttributes?[.type] as? FileAttributeType == .typeRegular,
                  (relative as NSString).lastPathComponent != ".DS_Store" else { continue }
            paths.append(relative)
        }
        progress.setTotals(bytes: 0, items: paths.count)
        for relative in paths {
            try progress.waitWhilePaused()
            progress.begin(relative)
            result[relative] = try Hashing.sha256(of: folder.appendingPathComponent(relative))
            progress.finishItem(baseline: 0, size: 0)
        }
        return result
    }

    static func loadAll(from url: URL = storeURL) -> [String: Baseline] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Baseline].self, from: data)) ?? [:]
    }

    static func save(_ baseline: Baseline, to url: URL = storeURL) throws {
        var all = loadAll(from: url)
        all[baseline.folder] = baseline
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(all).write(to: url, options: .atomic)
    }

    static func baseline(for folder: URL, from url: URL = storeURL) -> Baseline? {
        loadAll(from: url)[folder.standardizedFileURL.path]
    }

    static func compare(_ baseline: Baseline, with current: [String: String]) -> Report {
        var report = Report(baselineDate: baseline.created)
        for (path, hash) in current {
            if let old = baseline.files[path] {
                if old != hash { report.changed.append(path) }
            } else {
                report.added.append(path)
            }
        }
        report.removed = baseline.files.keys.filter { current[$0] == nil }
        report.changed.sort(); report.added.sort(); report.removed.sort()
        return report
    }
}
