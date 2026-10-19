import Foundation
import Observation

// MARK: - Undo records

struct TrashedItem: Sendable, Codable, Equatable {
    let original: URL
    let trashed: URL
}

struct MovedItem: Sendable, Codable, Equatable {
    let from: URL
    let to: URL
}

/// POSIX mode bits of one item before and after a change.
struct PermissionChange: Sendable, Codable, Equatable {
    let url: URL
    let old: UInt16
    let new: UInt16
}

struct TagChange: Sendable, Codable, Equatable {
    let url: URL
    let old: [FileTag]
    let new: [FileTag]
}

/// What an operation did, in enough detail to reverse it. Reverting returns the inverse record,
/// which is what makes redo work: redo is just reverting the inverse.
indirect enum UndoRecord: Sendable, Codable, Equatable {
    case created([URL])
    case trashed([TrashedItem])
    case moved([MovedItem])
    case tagged([TagChange])
    case permissions([PermissionChange])
    case group([UndoRecord])

    static func combine(_ records: [UndoRecord]) -> UndoRecord? {
        switch records.count {
        case 0: return nil
        case 1: return records[0]
        default: return .group(records)
        }
    }

    func revert() throws -> UndoRecord {
        let fm = FileManager.default
        switch self {
        case .created(let urls):
            var trashed: [TrashedItem] = []
            for url in urls where fm.fileExists(atPath: url.path) {
                var result: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &result)
                if let result { trashed.append(TrashedItem(original: url, trashed: result as URL)) }
            }
            return .trashed(trashed)

        case .trashed(let items):
            for item in items {
                if fm.fileExists(atPath: item.original.path) {
                    throw FileOpError(message: "Can’t restore “\(item.original.lastPathComponent)” because an item with that name already exists.")
                }
                try fm.createDirectory(at: item.original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: item.trashed, to: item.original)
            }
            return .created(items.map(\.original))

        case .moved(let items):
            for item in items.reversed() {
                if fm.fileExists(atPath: item.from.path) {
                    throw FileOpError(message: "Can’t move “\(item.to.lastPathComponent)” back because “\(item.from.lastPathComponent)” already exists.")
                }
                try fm.moveItem(at: item.to, to: item.from)
            }
            return .moved(items.map { MovedItem(from: $0.to, to: $0.from) })

        case .tagged(let changes):
            for change in changes { try FileOps.setTags(change.old, on: change.url) }
            return .tagged(changes.map { TagChange(url: $0.url, old: $0.new, new: $0.old) })

        case .permissions(let changes):
            for change in changes.reversed() {
                try fm.setAttributes([.posixPermissions: NSNumber(value: change.old)], ofItemAtPath: change.url.path)
            }
            return .permissions(changes.map { PermissionChange(url: $0.url, old: $0.new, new: $0.old) })

        case .group(let records):
            let inverses = try records.reversed().map { try $0.revert() }
            return .group(inverses)
        }
    }
}

// MARK: - Operations

@MainActor
@Observable
final class FileOperation: Identifiable {
    enum Status: Equatable {
        /// Waiting for an earlier transfer to the same volume to finish.
        case queued
        case running, completed, cancelled
        case failed(String)
    }

    let id = UUID()
    let title: String
    let startedAt = Date()
    fileprivate(set) var status: Status = .running
    fileprivate(set) var snapshot = OperationProgress.Snapshot()
    @ObservationIgnored let progress = OperationProgress()

    init(title: String) { self.title = title }

    /// Still active: running or waiting in the queue.
    var isRunning: Bool { status == .running || status == .queued }
    var isPaused: Bool { snapshot.isPaused }

    /// Re-issues the original request (e.g. the same transfer); offered for failed or cancelled operations.
    @ObservationIgnored var retry: (() -> Void)?

    func cancel() {
        progress.setPaused(false)
        progress.cancel()
    }

    func pause() {
        progress.setPaused(true)
        snapshot = progress.snapshot
    }

    func resume() {
        progress.setPaused(false)
        snapshot = progress.snapshot
    }
}

/// App-wide file operation runner: progress for the Status Center plus the undo/redo stacks.
@MainActor
@Observable
final class OperationCenter {
    static let shared = OperationCenter()

    private(set) var operations: [FileOperation] = []
    /// This session's undo/redo order (Timeline entry ids). Older operations are undone from the Timeline.
    private(set) var undoStack: [UUID] = []
    private(set) var redoStack: [UUID] = []

    private static let historyLimit = 50

    var running: [FileOperation] { operations.filter(\.isRunning) }
    var undoTitle: String? { undoStack.last.flatMap { TimelineStore.shared.entry($0)?.undoTitle } }
    var redoTitle: String? { redoStack.last.flatMap { TimelineStore.shared.entry($0)?.undoTitle } }

    /// Runs `work` off the main thread and logs it to the Timeline. Whatever it recorded is undoable
    /// even when it fails or is cancelled halfway, so partial copies can still be undone.
    @discardableResult
    func run(
        _ title: String,
        undoTitle: String,
        lane: String? = nil,
        entryID: UUID = UUID(),
        retry: (() -> Void)? = nil,
        work: @escaping @Sendable (OperationProgress) async throws -> [URL]
    ) async throws -> [URL] {
        let operation = FileOperation(title: title)
        operation.retry = retry
        operations.insert(operation, at: 0)
        if operations.count > Self.historyLimit { operations.removeLast(operations.count - Self.historyLimit) }

        let progress = operation.progress
        // Transfers to the same volume run one after another: parallel copies to one disk are slower
        // and harder to follow. Others start right away.
        if let lane {
            if busyLanes.contains(lane) {
                operation.status = .queued
                await withCheckedContinuation { waiting[lane, default: []].append($0) }
            } else {
                busyLanes.insert(lane)
            }
            operation.status = .running
        }
        defer { if let lane { releaseLane(lane) } }
        if progress.isCancelled {
            operation.status = .cancelled
            throw CancellationError()
        }
        let poller = Task { @MainActor in
            while !Task.isCancelled {
                operation.snapshot = progress.snapshot
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer {
            poller.cancel()
            operation.snapshot = progress.snapshot
            let record = UndoRecord.combine(progress.records)
            let entry = TimelineEntry(
                id: entryID, title: title, undoTitle: undoTitle, status: TimelineEntry.Status(operation.status),
                record: record, notes: progress.notes.map(\.path)
            )
            TimelineStore.shared.add(entry)
            NotificationCenter.default.post(name: .operationRecorded, object: nil, userInfo: ["entry": entry.id])
            if record != nil {
                undoStack.append(entry.id)
                if undoStack.count > Self.historyLimit { undoStack.removeFirst() }
                redoStack.removeAll()
            }
        }

        do {
            // The work is detached, so cancelling the caller's task (e.g. Stop in the script console) is passed on via progress.
            let urls = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) { try await work(progress) }.value
            } onCancel: {
                progress.cancel()
            }
            operation.status = .completed
            return urls
        } catch is CancellationError {
            operation.status = .cancelled
            throw CancellationError()
        } catch {
            operation.status = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Logs changes made outside `run` (e.g. a plugin button) as one undoable Timeline entry; nothing when unchanged.
    func recordChanges(_ title: String, undoTitle: String, progress: OperationProgress) {
        guard let record = UndoRecord.combine(progress.records) else { return }
        let entry = TimelineEntry(title: title, undoTitle: undoTitle, status: .completed, record: record, notes: progress.notes.map(\.path))
        TimelineStore.shared.add(entry)
        NotificationCenter.default.post(name: .operationRecorded, object: nil, userInfo: ["entry": entry.id])
        undoStack.append(entry.id)
        if undoStack.count > Self.historyLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private var busyLanes: Set<String> = []
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Hands the lane to the next queued operation (it stays busy), or frees it.
    private func releaseLane(_ lane: String) {
        if var queue = waiting[lane], !queue.isEmpty {
            let next = queue.removeFirst()
            waiting[lane] = queue
            next.resume()
        } else {
            busyLanes.remove(lane)
            waiting[lane] = nil
        }
    }

    func undo() async throws {
        guard let id = undoStack.popLast() else { return }
        do {
            try await TimelineStore.shared.undo(id)
            redoStack.append(id)
        } catch {
            // Keep it on the stack only if it can still be undone later (e.g. a transient error).
            if TimelineStore.shared.entry(id)?.canUndo == true { undoStack.append(id) }
            throw error
        }
    }

    func redo() async throws {
        guard let id = redoStack.popLast() else { return }
        do {
            try await TimelineStore.shared.redo(id)
            undoStack.append(id)
        } catch {
            if TimelineStore.shared.entry(id)?.canRedo == true { redoStack.append(id) }
            throw error
        }
    }

    /// Keeps ⌘Z in step when an operation is undone or redone from the Timeline view.
    func timelineDidUndo(_ id: UUID) {
        undoStack.removeAll { $0 == id }
        if !redoStack.contains(id) { redoStack.append(id) }
    }

    func timelineDidRedo(_ id: UUID) {
        redoStack.removeAll { $0 == id }
        if !undoStack.contains(id) { undoStack.append(id) }
    }

    func clearFinished() {
        operations.removeAll { !$0.isRunning }
    }
}

extension Notification.Name {
    /// Posted when an operation lands in the Timeline; `userInfo["entry"]` is the TimelineEntry id.
    static let operationRecorded = Notification.Name("WayfileOperationRecorded")
}
