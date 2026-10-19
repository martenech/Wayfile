import CoreServices
import Foundation

/// File-level FSEvents for whole folder trees. Changes are batched by `latency` and delivered
/// on the main queue as the paths that changed (created, renamed in, modified or removed).
final class FolderWatcher {
    struct Change: Hashable {
        let url: URL
        /// The item exists now and was created or renamed/moved in (not just modified or removed).
        let appeared: Bool
        let removed: Bool
        let isDirectory: Bool
    }

    private var stream: FSEventStreamRef?
    private let handler: ([Change]) -> Void

    init?(folders: [URL], latency: TimeInterval = 0.5, handler: @escaping ([Change]) -> Void) {
        self.handler = handler
        guard !folders.isEmpty else { return nil }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            var changes: [Change] = []
            for index in 0..<min(count, list.count) {
                let flag = Int(flags[index])
                let path = list[index]
                let exists = FileManager.default.fileExists(atPath: path)
                let created = flag & kFSEventStreamEventFlagItemCreated != 0
                let renamed = flag & kFSEventStreamEventFlagItemRenamed != 0
                changes.append(Change(
                    url: URL(fileURLWithPath: path),
                    appeared: exists && (created || renamed),
                    removed: !exists && (flag & kFSEventStreamEventFlagItemRemoved != 0 || renamed),
                    isDirectory: flag & kFSEventStreamEventFlagItemIsDir != 0
                ))
            }
            watcher.handler(changes)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, folders.map(\.path) as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit { stop() }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Files still being written by browsers and download tools; triggers wait for the final name.
    static func isPartialDownload(_ url: URL) -> Bool {
        ["crdownload", "download", "part", "partial", "tmp", "opdownload"].contains(url.pathExtension.lowercased())
            || url.lastPathComponent.hasPrefix(".")
    }
}

/// Watches one folder's items (added, removed, renamed, modified) — FSEvents on local disks,
/// kqueue on network volumes where FSEvents isn't delivered.
final class FolderMonitor {
    private var watcher: FolderWatcher?
    private var fallback: DirectoryWatcher?

    /// `recursive` also reports changes anywhere below the folder.
    init(_ folder: URL, recursive: Bool = false, onChange: @escaping () -> Void) {
        let isLocal = (try? folder.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal ?? true
        if isLocal {
            let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
            watcher = FolderWatcher(folders: [folder], latency: 0.25) { changes in
                let relevant = changes.contains { change in
                    let changed = change.url.standardizedFileURL.resolvingSymlinksInPath()
                    if recursive { return changed.path == path || changed.path.hasPrefix(path + "/") }
                    return changed.path == path || changed.deletingLastPathComponent().path == path
                }
                if relevant { onChange() }
            }
        }
        if watcher == nil { fallback = DirectoryWatcher(url: folder, onChange: onChange) }
    }

    /// Changes as a stream (for SwiftUI `.task`); ends when the task is cancelled.
    static func changes(of folder: URL) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let monitor = FolderMonitor(folder) { continuation.yield() }
            continuation.onTermination = { _ in _ = monitor }
        }
    }
}
