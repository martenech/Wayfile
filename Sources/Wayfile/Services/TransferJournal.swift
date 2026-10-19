import Foundation

/// Transfers in flight, written to disk so ones cut short by a crash, force quit or power loss
/// can be finished on the next launch.
struct TransferJob: Codable, Identifiable, Hashable {
    enum Mode: String, Codable { case copy, move }

    var id = UUID()
    let sources: [URL]
    let destination: URL
    let mode: Mode
    let started: Date

    var title: String {
        let what = sources.count == 1 ? "“\(sources[0].lastPathComponent)”" : String(localized: "\(sources.count) items")
        return mode == .copy ? String(localized: "Copy \(what) to “\(destination.lastPathComponent)”")
            : String(localized: "Move \(what) to “\(destination.lastPathComponent)”")
    }
}

final class TransferJournal: @unchecked Sendable {
    static let shared = TransferJournal(url: TransferJournal.defaultURL)

    private let url: URL
    private let lock = NSLock()

    static var defaultURL: URL {
        let name = Bundle.main.bundleIdentifier == nil ? "transfers-dev.json" : "transfers.json"
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Wayfile/\(name)")
    }

    init(url: URL) { self.url = url }

    var jobs: [TransferJob] {
        lock.withLock { read() }
    }

    func begin(_ job: TransferJob) {
        lock.withLock {
            var all = read()
            all.append(job)
            write(all)
        }
    }

    func finish(_ id: UUID) {
        lock.withLock {
            var all = read()
            all.removeAll { $0.id == id }
            write(all)
        }
    }

    func clear() { lock.withLock { write([]) } }

    private func read() -> [TransferJob] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([TransferJob].self, from: $0) } ?? []
    }

    private func write(_ jobs: [TransferJob]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if jobs.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? JSONEncoder().encode(jobs) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// How to finish an interrupted job: sources still present (moves remove them when done), and
    /// per-source conflict choices — finished items are skipped, half-written ones replaced (the partial
    /// copy goes to the Trash, so nothing is lost).
    static func resumePlan(for job: TransferJob) -> (sources: [URL], overrides: [String: FileOps.ConflictPolicy]) {
        let fm = FileManager.default
        let remaining = job.sources.filter { fm.fileExists(atPath: $0.path) }
        var overrides: [String: FileOps.ConflictPolicy] = [:]
        for source in remaining {
            let target = job.destination.appendingPathComponent(source.lastPathComponent)
            guard fm.fileExists(atPath: target.path) else { continue }
            overrides[source.standardizedFileURL.path] = isComplete(source, copy: target) ? .skip : .replace
        }
        return (remaining, overrides)
    }

    /// Same structure, sizes and modification dates (copies keep dates) for every file.
    static func isComplete(_ source: URL, copy: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        func signature(_ root: URL) -> [String: String]? {
            var result: [String: String] = [:]
            func add(_ url: URL, relative: String) {
                guard let v = try? url.resourceValues(forKeys: keys) else { return }
                if v.isDirectory == true { result[relative + "/"] = "dir"; return }
                let date = Int(v.contentModificationDate?.timeIntervalSince1970 ?? 0)
                result[relative] = "\(v.fileSize ?? -1)@\(date)"
            }
            add(root, relative: "")
            if FileSystem.isDirectory(root) {
                guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return nil }
                while let path = enumerator.nextObject() as? String { add(root.appendingPathComponent(path), relative: path) }
            }
            return result
        }
        guard let a = signature(source), let b = signature(copy) else { return false }
        return a == b
    }
}
