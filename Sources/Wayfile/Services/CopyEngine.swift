import Darwin
import Foundation

/// Thread-safe progress counters shared between a background operation and the UI.
final class OperationProgress: @unchecked Sendable {
    struct Snapshot {
        var totalBytes: Int64 = 0
        var completedBytes: Int64 = 0
        var totalItems = 0
        var completedItems = 0
        var currentName = ""
        var isPaused = false

        var fraction: Double? {
            if totalBytes > 0 { return min(Double(completedBytes) / Double(totalBytes), 1) }
            if totalItems > 0 { return Double(completedItems) / Double(totalItems) }
            return nil
        }
    }

    private let lock = NSLock()
    private var snapshotValue = Snapshot()
    private var currentFileBytes: Int64 = 0
    private var cancelled = false
    private var recorded: [UndoRecord] = []

    /// Undo records for the steps completed so far.
    var records: [UndoRecord] { lock.withLock { recorded } }

    func record(_ record: UndoRecord) { lock.withLock { recorded.append(record) } }

    private var noted: [URL] = []

    /// Items an operation touched that can't be undone (e.g. permanent deletes), shown in the Timeline.
    var notes: [URL] { lock.withLock { noted } }

    func note(_ url: URL) { lock.withLock { noted.append(url) } }

    var snapshot: Snapshot {
        lock.withLock {
            var s = snapshotValue
            s.completedBytes += currentFileBytes
            s.isPaused = paused
            return s
        }
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() { lock.withLock { cancelled = true } }

    private var paused = false

    var isPaused: Bool { lock.withLock { paused } }

    func setPaused(_ value: Bool) { lock.withLock { paused = value } }

    /// Blocks the worker thread while paused; throws if cancelled meanwhile. Safe to call from
    /// copyfile's callback, which pauses even in the middle of a large file.
    func waitWhilePaused() throws {
        while isPaused {
            if isCancelled { throw CancellationError() }
            usleep(100_000)
        }
        try checkCancelled()
    }

    func setTotals(bytes: Int64, items: Int) {
        lock.withLock {
            snapshotValue.totalBytes = bytes
            snapshotValue.totalItems = items
        }
    }

    func begin(_ name: String) { lock.withLock { snapshotValue.currentName = name } }

    func setCurrentFileBytes(_ bytes: Int64) { lock.withLock { currentFileBytes = bytes } }

    func finishFile(bytes: Int64) {
        lock.withLock {
            snapshotValue.completedBytes += bytes
            currentFileBytes = 0
        }
    }

    /// Marks a top-level item done and corrects the byte count to exactly `baseline + size`.
    func finishItem(baseline: Int64, size: Int64) {
        lock.withLock {
            snapshotValue.completedItems += 1
            snapshotValue.completedBytes = baseline + size
            currentFileBytes = 0
        }
    }

    var completedBytes: Int64 { lock.withLock { snapshotValue.completedBytes } }

    func checkCancelled() throws {
        if isCancelled { throw CancellationError() }
    }
}

enum CopyEngine {
    /// Total size of a file or directory tree (without following symlinks).
    static func itemSize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard values.isDirectory == true, values.isSymbolicLink != true else { return Int64(values.fileSize ?? 0) }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: nil)
        while let child = enumerator?.nextObject() as? URL {
            total += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private final class Context {
        let progress: OperationProgress
        init(progress: OperationProgress) { self.progress = progress }
    }

    /// Copies a file or folder with byte-level progress, cloning on APFS when possible. Cancellable.
    static func copy(_ src: URL, to dest: URL, progress: OperationProgress) throws {
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        let context = Unmanaged.passRetained(Context(progress: progress))
        defer { context.release() }

        let callback: copyfile_callback_t = { what, stage, state, src, _, raw in
            let context = Unmanaged<Context>.fromOpaque(raw!).takeUnretainedValue()
            if (try? context.progress.waitWhilePaused()) == nil { return COPYFILE_QUIT }
            if stage == COPYFILE_ERR { return COPYFILE_QUIT }
            if what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS {
                var copied: off_t = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                context.progress.setCurrentFileBytes(Int64(copied))
            } else if what == COPYFILE_RECURSE_FILE && stage == COPYFILE_FINISH {
                var info = stat()
                let size = (src.map { lstat($0, &info) } == 0) ? Int64(info.st_size) : 0
                context.progress.finishFile(bytes: size)
            }
            return COPYFILE_CONTINUE
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), context.toOpaque())

        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW_SRC | COPYFILE_CLONE)
        if copyfile(src.path, dest.path, state, flags) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: dest)
            try progress.checkCancelled()
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
