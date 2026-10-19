import Foundation
import Observation

/// One logged operation. Survives restarts; can be undone/redone later if nothing changed since.
struct TimelineEntry: Codable, Identifiable, Equatable {
    enum Status: Codable, Equatable {
        case completed, cancelled
        case failed(String)

        @MainActor
        init(_ status: FileOperation.Status) {
            switch status {
            case .completed, .running, .queued: self = .completed
            case .cancelled: self = .cancelled
            case .failed(let message): self = .failed(message)
            }
        }
    }

    var id = UUID()
    var date = Date()
    let title: String
    /// Short verb used in menus ("Undo Move").
    let undoTitle: String
    let status: Status
    /// What to revert; nil for operations that can't be undone (permanent delete, git).
    var record: UndoRecord?
    /// After an undo: what reverting the undo does (i.e. redo).
    var inverse: UndoRecord?
    /// Paths touched by non-undoable operations, for display.
    var notes: [String] = []

    var isUndone: Bool { inverse != nil }
    var canUndo: Bool { record != nil && inverse == nil }
    var canRedo: Bool { inverse != nil }
}

struct TimelineError: LocalizedError {
    let problems: [String]
    var errorDescription: String? {
        String(localized: "Can’t undo this safely:\n") + problems.prefix(5).joined(separator: "\n") + (problems.count > 5 ? "\n…" : "")
    }
}

extension UndoRecord {
    /// Why reverting now would be unsafe (files moved, deleted or replaced since); empty when it's fine.
    func problems() -> [String] {
        let fm = FileManager.default
        func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
        switch self {
        case .created(let urls):
            return urls.filter { !exists($0) }.map { "“\($0.lastPathComponent)” is no longer at \($0.deletingLastPathComponent().path)" }
        case .trashed(let items):
            return items.flatMap { item -> [String] in
                var problems: [String] = []
                if !exists(item.trashed) { problems.append("“\(item.original.lastPathComponent)” is no longer in the Trash") }
                if exists(item.original) { problems.append("Something named “\(item.original.lastPathComponent)” is already at its original place") }
                return problems
            }
        case .moved(let items):
            return items.flatMap { item -> [String] in
                var problems: [String] = []
                if !exists(item.to) { problems.append("“\(item.to.lastPathComponent)” is no longer at \(item.to.deletingLastPathComponent().path)") }
                if exists(item.from) && item.from.path.lowercased() != item.to.path.lowercased() {
                    problems.append("Something named “\(item.from.lastPathComponent)” is already at \(item.from.deletingLastPathComponent().path)")
                }
                return problems
            }
        case .tagged(let changes):
            return changes.filter { !exists($0.url) }.map { "“\($0.url.lastPathComponent)” no longer exists" }
        case .permissions(let changes):
            return changes.filter { !exists($0.url) }.prefix(20).map { "“\($0.url.lastPathComponent)” no longer exists" }
        case .group(let records):
            return records.flatMap { $0.problems() }
        }
    }

    /// Human-readable lines for the Timeline view: what happened to which item.
    var lines: [TimelineLine] {
        switch self {
        case .created(let urls):
            return urls.map { TimelineLine(symbol: "plus.circle", text: $0.lastPathComponent, detail: $0.deletingLastPathComponent().path, url: $0) }
        case .trashed(let items):
            return items.map { TimelineLine(symbol: "trash", text: $0.original.lastPathComponent, detail: "from \($0.original.deletingLastPathComponent().path)", url: $0.trashed) }
        case .moved(let items):
            return items.compactMap { item in
                // Skip the hidden temporary names used by batch rename's first pass.
                if item.to.lastPathComponent.hasPrefix(".wayfile-rename-") { return nil }
                if item.from.lastPathComponent.hasPrefix(".wayfile-rename-") { return nil }
                let sameFolder = item.from.deletingLastPathComponent().path == item.to.deletingLastPathComponent().path
                return sameFolder
                    ? TimelineLine(symbol: "pencil", text: "\(item.from.lastPathComponent) → \(item.to.lastPathComponent)", detail: item.to.deletingLastPathComponent().path, url: item.to)
                    : TimelineLine(symbol: "arrow.right", text: item.to.lastPathComponent, detail: "\(item.from.deletingLastPathComponent().path) → \(item.to.deletingLastPathComponent().path)", url: item.to)
            }
        case .tagged(let changes):
            return changes.map { change in
                let added = change.new.filter { tag in !change.old.contains(tag) }.map(\.name)
                let removed = change.old.filter { tag in !change.new.contains(tag) }.map(\.name)
                let text = (added.map { "+\($0)" } + removed.map { "−\($0)" }).joined(separator: " ")
                return TimelineLine(symbol: "tag", text: "\(change.url.lastPathComponent)  \(text)", detail: change.url.deletingLastPathComponent().path, url: change.url)
            }
        case .permissions(let changes):
            return changes.prefix(200).map { change in
                TimelineLine(symbol: "lock", text: "\(change.url.lastPathComponent)  \(Permissions.symbolic(change.old)) → \(Permissions.symbolic(change.new))",
                             detail: change.url.deletingLastPathComponent().path, url: change.url)
            }
        case .group(let records):
            return Self.joinBatchRename(records)?.lines ?? records.flatMap(\.lines)
        }
    }

    /// Batch rename records two passes (name → temp, temp → new); show them as name → new.
    private static func joinBatchRename(_ records: [UndoRecord]) -> UndoRecord? {
        guard records.count == 2, case .moved(let first) = records[0], case .moved(let second) = records[1],
              first.count == second.count, first.allSatisfy({ $0.to.lastPathComponent.hasPrefix(".wayfile-rename-") }) else { return nil }
        let byTemp = Dictionary(second.map { ($0.from, $0.to) }, uniquingKeysWith: { a, _ in a })
        return .moved(first.compactMap { item in byTemp[item.to].map { MovedItem(from: item.from, to: $0) } })
    }

}

struct TimelineLine: Identifiable {
    let id = UUID()
    let symbol: String
    let text: String
    let detail: String
    let url: URL?
}

/// Persistent operation history (~/Library/Application Support/Wayfile/timeline.json).
@MainActor
@Observable
final class TimelineStore {
    static let shared = TimelineStore()

    private(set) var entries: [TimelineEntry] = []

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    static let maxEntries = 2000

    init(fileURL: URL = TimelineStore.defaultURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([TimelineEntry].self, from: data) {
            entries = decoded
        }
        prune()
    }

    nonisolated static var defaultURL: URL {
        // Unbundled dev runs (swift run, tests) keep their own file so they never touch real history.
        let name = Bundle.main.bundleIdentifier == nil ? "timeline-dev.json" : "timeline.json"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wayfile/\(name)")
    }

    /// How long entries are kept; 0 means forever.
    static var retentionDays: Int {
        get { UserDefaults.standard.object(forKey: "timelineRetentionDays") as? Int ?? 30 }
        set { UserDefaults.standard.set(newValue, forKey: "timelineRetentionDays") }
    }

    func entry(_ id: UUID) -> TimelineEntry? { entries.first { $0.id == id } }

    func add(_ entry: TimelineEntry) {
        entries.insert(entry, at: 0)
        prune()
        save()
    }

    /// Reverts one operation, however old, after checking nothing changed since.
    func undo(_ id: UUID) async throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), let record = entries[index].record,
              entries[index].canUndo else { return }
        let inverse = try await Task.detached { () throws -> UndoRecord in
            let problems = record.problems()
            guard problems.isEmpty else { throw TimelineError(problems: problems) }
            return try record.revert()
        }.value
        guard let current = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[current].inverse = inverse
        save()
    }

    func redo(_ id: UUID) async throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), let inverse = entries[index].inverse else { return }
        let record = try await Task.detached { () throws -> UndoRecord in
            let problems = inverse.problems()
            guard problems.isEmpty else { throw TimelineError(problems: problems) }
            return try inverse.revert()
        }.value
        guard let current = entries.firstIndex(where: { $0.id == id }) else { return }
        // Reverting the inverse yields an equivalent of the original (paths may differ, e.g. Trash names).
        entries[current].record = record
        entries[current].inverse = nil
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    func prune() {
        let days = Self.retentionDays
        if days > 0, let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) {
            entries.removeAll { $0.date < cutoff }
        }
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
    }

    /// Writes in the background, coalescing bursts of changes.
    private func save() {
        saveTask?.cancel()
        let snapshot = entries
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    /// Synchronous save, for tests and app termination.
    func saveNow() {
        saveTask?.cancel()
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: fileURL, options: .atomic) }
    }
}
