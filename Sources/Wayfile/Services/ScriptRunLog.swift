import Foundation
import Observation

/// One script run as kept on disk: what ran, why, how it ended, what it printed and changed.
struct ScriptRunRecord: Codable, Identifiable, Hashable {
    enum Outcome: Codable, Hashable {
        case running, succeeded, exited(Int32), failed(String), cancelled
        /// Still "running" when Wayfile quit or crashed.
        case interrupted

        var title: String {
            switch self {
            case .running: return String(localized: "Running")
            case .succeeded: return String(localized: "Succeeded")
            case .exited(let status): return String(localized: "Exit \(status)")
            case .failed: return String(localized: "Failed")
            case .cancelled: return String(localized: "Cancelled")
            case .interrupted: return String(localized: "Interrupted")
            }
        }

        var symbol: String {
            switch self {
            case .running: return "hourglass"
            case .succeeded: return "checkmark.circle"
            case .exited, .failed: return "xmark.octagon"
            case .cancelled: return "stop.circle"
            case .interrupted: return "exclamationmark.triangle"
            }
        }

        var isFailure: Bool {
            switch self {
            case .exited, .failed, .interrupted: return true
            default: return false
            }
        }
    }

    var id = UUID()
    let scriptName: String
    /// Script file, or empty for Shortcuts and project commands.
    let scriptPath: String
    let language: String
    let trigger: String
    let dryRun: Bool
    var started = Date()
    var finished: Date?
    var outcome: Outcome = .running
    /// The tail of the output (stderr lines start with "! "), capped so logs stay small.
    var output: [String] = []
    /// Files changed through the Wayfile API (undoable from the Timeline entry).
    var changedPaths: [String] = []
    var timelineEntry: UUID?

    var duration: TimeInterval? { finished.map { $0.timeIntervalSince(started) } }

    /// "Dry run" wins over the outcome for display: nothing was changed.
    var statusTitle: String { dryRun && outcome == .succeeded ? "Simulated" : outcome.title }
}

/// Persisted history of script runs (~/Library/Application Support/Wayfile/script-runs.json).
@MainActor
@Observable
final class ScriptRunLog {
    static let shared = ScriptRunLog(fileURL: ScriptRunLog.defaultURL)

    private(set) var records: [ScriptRunRecord] = []
    private let fileURL: URL
    private var saveScheduled = false
    nonisolated static let limit = 500
    nonisolated static let outputLines = 200
    nonisolated static let lineLength = 500
    nonisolated static let changedLimit = 500

    nonisolated static var defaultURL: URL {
        let name = Bundle.main.bundleIdentifier == nil ? "script-runs-dev.json" : "script-runs.json"
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Wayfile/\(name)")
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        let stored = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([ScriptRunRecord].self, from: $0) } ?? []
        records = Self.recovered(stored)
        if records != stored { save() }
    }

    /// Runs that never finished (the app quit or crashed meanwhile) are marked interrupted.
    nonisolated static func recovered(_ records: [ScriptRunRecord]) -> [ScriptRunRecord] {
        records.map { record in
            guard record.outcome == .running else { return record }
            var fixed = record
            fixed.outcome = .interrupted
            fixed.finished = fixed.finished ?? fixed.started
            return fixed
        }
    }

    /// Keeps the last `outputLines` lines, each at most `lineLength` characters.
    nonisolated static func capped(_ lines: [String]) -> [String] {
        lines.suffix(outputLines).map { $0.count > lineLength ? String($0.prefix(lineLength)) + "…" : $0 }
    }

    func record(_ id: UUID) -> ScriptRunRecord? { records.first { $0.id == id } }

    func start(_ record: ScriptRunRecord) {
        records.insert(record, at: 0)
        if records.count > Self.limit { records.removeLast(records.count - Self.limit) }
        // Written right away: a crash during the run must leave a record to mark interrupted.
        saveNow()
    }

    func finish(_ id: UUID, outcome: ScriptRunRecord.Outcome, output: [ScriptOutputLine], changedPaths: [String] = [], timelineEntry: UUID? = nil) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].finished = Date()
        records[index].outcome = outcome
        records[index].output = Self.capped(output.map { $0.stream == .stderr ? "! " + $0.text : $0.text })
        records[index].changedPaths = Array(changedPaths.prefix(Self.changedLimit))
        records[index].timelineEntry = timelineEntry
        save()
    }

    func clear() {
        records.removeAll { $0.outcome != .running }
        save()
    }

    func runs(of scriptPath: String) -> [ScriptRunRecord] { records.filter { $0.scriptPath == scriptPath } }

    private func save() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            saveScheduled = false
            saveNow()
        }
    }

    func saveNow() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: fileURL, options: .atomic) }
    }
}

// MARK: - Operation hooks

extension ScriptAfter {
    init?(_ kind: ActivityKind) {
        switch kind {
        case .copied: self = .copy
        case .moved: self = .move
        case .renamed: self = .rename
        case .deleted: self = .trash
        case .created: self = .create
        default: return nil
        }
    }
}

extension Script {
    /// The items an `@after` script runs on for a finished operation's changes; empty when it doesn't apply.
    /// Trashed items are passed by their original path (they no longer exist there).
    func afterInput(_ events: [ActivityEvent]) -> [URL] {
        let urls = events.filter { event in ScriptAfter(event.kind).map(after.contains) ?? false }.map(\.url)
        let accepted = urls.filter { url in
            FileManager.default.fileExists(atPath: url.path) ? accepts(url) : (extensions.isEmpty || extensions.contains(url.pathExtension.lowercased()))
        }
        guard !accepted.isEmpty, count.contains(accepted.count) || count.max == nil else { return [] }
        return accepted
    }
}
