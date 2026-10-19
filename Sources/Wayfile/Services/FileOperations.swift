import AppKit
import Foundation

struct FileOpError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum FileSystem {
    static func list(_ dir: URL) throws -> [FileItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: FileItem.resourceKeys, options: []
        )
        return urls.compactMap(FileItem.init(url:))
    }

    enum ListEvent: Sendable {
        /// New items (quick pass).
        case items([FileItem])
        /// The same items again with type names and tags filled in.
        case details([FileItem])
    }

    /// The folder in two passes: all items with the cheap attributes first (~10× faster than everything),
    /// then type names and tags in one more update. Small growing batches looked nicer on paper but
    /// growing a SwiftUI Table from hundreds to tens of thousands of rows sent it into a layout loop
    /// that starved the main thread, so `firstBatch` is only for tests.
    static func listProgressively(_ dir: URL, firstBatch: Int = .max) -> AsyncThrowingStream<ListEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                // contentsOfDirectory reports unreadable folders as errors; the enumerator would just be empty.
                guard FileManager.default.isReadableFile(atPath: dir.path) else {
                    continuation.finish(throwing: CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: dir.path]))
                    return
                }
                guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: FileItem.basicKeys,
                                                                      options: [.skipsSubdirectoryDescendants], errorHandler: { _, _ in true }) else {
                    continuation.finish(throwing: CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: dir.path]))
                    return
                }
                var all: [FileItem] = []
                var batchStart = 0
                while let url = enumerator.nextObject() as? URL {
                    if Task.isCancelled { continuation.finish(); return }
                    if let item = FileItem(basicURL: url) { all.append(item) }
                    if batchStart == 0 && all.count == firstBatch {
                        continuation.yield(.items(all))
                        batchStart = all.count
                    }
                }
                if batchStart < all.count { continuation.yield(.items(Array(all[batchStart...]))) }

                // Details arrive in one update: every update re-sorts and re-diffs the whole list.
                // A second enumeration prefetches type names and tag names for the whole folder at once.
                let detailKeys: [URLResourceKey] = [.localizedTypeDescriptionKey, .tagNamesKey]
                var details: [String: (kind: String?, hasTags: Bool)] = [:]
                if let second = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: detailKeys,
                                                               options: [.skipsSubdirectoryDescendants], errorHandler: { _, _ in true }) {
                    while let url = second.nextObject() as? URL {
                        if Task.isCancelled { continuation.finish(); return }
                        let values = try? url.resourceValues(forKeys: Set(detailKeys))
                        details[url.lastPathComponent] = (values?.localizedTypeDescription, !(values?.tagNames ?? []).isEmpty)
                    }
                }
                for index in all.indices {
                    if let found = details[all[index].url.lastPathComponent] {
                        all[index].applyDetails(kind: found.kind, hasTags: found.hasTags)
                    } else {
                        all[index].loadDetails()
                    }
                }
                if !all.isEmpty { continuation.yield(.details(all)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let ka = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let kb = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        guard let ka, let kb else { return false }
        return ka.isEqual(kb)
    }

    static func availableSpace(at url: URL) -> Int64? {
        try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }
}

enum FileOps {
    /// Returns `desired`, or "name 2", "name 3"… when something already exists there.
    static func uniqueURL(_ desired: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: desired.path) else { return desired }
        let dir = desired.deletingLastPathComponent()
        let splitExtension = !FileSystem.isDirectory(desired) && !desired.pathExtension.isEmpty
        let ext = splitExtension ? desired.pathExtension : ""
        let base = splitExtension ? desired.deletingPathExtension().lastPathComponent : desired.lastPathComponent
        var i = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    enum TransferMode: Sendable {
        case copy, move
        /// Drag & drop semantics: move within a volume, copy across volumes.
        case automatic
    }

    enum ConflictPolicy: Sendable {
        case replace, keepBoth, skip
    }

    /// Sources that would collide with an existing item in `dir` (duplicating in place doesn't count).
    static func conflicts(_ sources: [URL], in dir: URL) -> [URL] {
        let destPath = dir.standardizedFileURL.path
        return sources.filter { src in
            src.deletingLastPathComponent().standardizedFileURL.path != destPath
                && FileManager.default.fileExists(atPath: dir.appendingPathComponent(src.lastPathComponent).path)
        }
    }

    /// Copies or moves `sources` into `dir` with progress, conflict handling and undo records.
    static func transfer(
        _ sources: [URL], to dir: URL, mode: TransferMode, policy: ConflictPolicy,
        overrides: [String: ConflictPolicy] = [:], verify: Bool = false, progress: OperationProgress
    ) throws -> [URL] {
        struct Step {
            let src: URL
            let dest: URL
            let isMove: Bool
            let needsCopy: Bool
            let replacing: URL?
            var size: Int64 = 0
        }

        let fm = FileManager.default
        let destPath = dir.standardizedFileURL.path
        var steps: [Step] = []
        for src in sources {
            let srcPath = src.standardizedFileURL.path
            let sameFolder = src.deletingLastPathComponent().standardizedFileURL.path == destPath
            let sameVolume = FileSystem.sameVolume(src, dir)
            let isMove: Bool
            switch mode {
            case .copy: isMove = false
            case .move: isMove = true
            case .automatic: isMove = sameVolume
            }
            if isMove && sameFolder { continue }
            if destPath == srcPath || destPath.hasPrefix(srcPath + "/") {
                throw FileOpError(message: "Can’t \(isMove ? "move" : "copy") “\(src.lastPathComponent)” into itself.")
            }
            var dest = dir.appendingPathComponent(src.lastPathComponent)
            var replacing: URL?
            if fm.fileExists(atPath: dest.path) {
                if sameFolder {
                    dest = uniqueURL(dest)
                } else {
                    switch overrides[src.standardizedFileURL.path] ?? policy {
                    case .skip: continue
                    case .keepBoth: dest = uniqueURL(dest)
                    case .replace: replacing = dest
                    }
                }
            }
            steps.append(Step(src: src, dest: dest, isMove: isMove, needsCopy: !isMove || !sameVolume, replacing: replacing))
        }

        for index in steps.indices where steps[index].needsCopy {
            try progress.checkCancelled()
            steps[index].size = CopyEngine.itemSize(steps[index].src)
        }
        progress.setTotals(bytes: steps.reduce(0) { $0 + $1.size }, items: steps.count)

        var results: [URL] = []
        for step in steps {
            try progress.waitWhilePaused()
            progress.begin(step.src.lastPathComponent)
            let baseline = progress.completedBytes
            if let replacing = step.replacing {
                var trashed: NSURL?
                try fm.trashItem(at: replacing, resultingItemURL: &trashed)
                if let trashed { progress.record(.trashed([TrashedItem(original: replacing, trashed: trashed as URL)])) }
            }
            if step.isMove {
                if step.needsCopy {
                    try CopyEngine.copy(step.src, to: step.dest, progress: progress)
                    // Verify before the original is removed: a bad copy must never cost the original.
                    if verify { try verifyCopy(step.src, step.dest, progress: progress) }
                    try fm.removeItem(at: step.src)
                } else {
                    try fm.moveItem(at: step.src, to: step.dest)
                }
                progress.record(.moved([MovedItem(from: step.src, to: step.dest)]))
            } else {
                try CopyEngine.copy(step.src, to: step.dest, progress: progress)
                // Recorded first so a copy that fails verification can still be undone (removed).
                progress.record(.created([step.dest]))
                if verify { try verifyCopy(step.src, step.dest, progress: progress) }
            }
            progress.finishItem(baseline: baseline, size: step.size)
            results.append(step.dest)
        }
        return results
    }

    /// Reads original and copy back and compares checksums.
    static func verifyCopy(_ original: URL, _ copy: URL, progress: OperationProgress) throws {
        progress.begin("Verifying \(copy.lastPathComponent)")
        let different = try Hashing.differences(between: original, and: copy, progress: progress)
        if !different.isEmpty {
            throw FileOpError(message: "Verification failed — these differ after copying: " + different.prefix(5).joined(separator: ", "))
        }
    }

    static func trash(_ urls: [URL], progress: OperationProgress) throws -> [URL] {
        progress.setTotals(bytes: 0, items: urls.count)
        for url in urls {
            try progress.checkCancelled()
            progress.begin(url.lastPathComponent)
            var trashed: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
            if let trashed { progress.record(.trashed([TrashedItem(original: url, trashed: trashed as URL)])) }
            progress.finishItem(baseline: 0, size: 0)
        }
        return []
    }

    /// Permanent delete — not undoable.
    static func delete(_ urls: [URL], progress: OperationProgress) throws -> [URL] {
        progress.setTotals(bytes: 0, items: urls.count)
        for url in urls {
            try progress.checkCancelled()
            progress.begin(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
            progress.note(url)
            progress.finishItem(baseline: 0, size: 0)
        }
        return []
    }

    static func createFolder(named name: String, in dir: URL) throws -> URL {
        let dest = uniqueURL(dir.appendingPathComponent(name))
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        return dest
    }

    static func createFile(named name: String, in dir: URL, contents: Data = Data()) throws -> URL {
        let dest = uniqueURL(dir.appendingPathComponent(name))
        guard FileManager.default.createFile(atPath: dest.path, contents: contents) else {
            throw FileOpError(message: "Could not create “\(name)”.")
        }
        return dest
    }

    static func rename(_ url: URL, to newName: String) throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            throw FileOpError(message: "“\(newName)” is not a valid name.")
        }
        let dest = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        if dest.path == url.path { return url }
        // Allow case-only renames on case-insensitive volumes.
        if FileManager.default.fileExists(atPath: dest.path),
           dest.path.lowercased() != url.path.lowercased() {
            throw FileOpError(message: "An item named “\(trimmed)” already exists.")
        }
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }

    static func compress(_ sources: [URL]) async throws -> [URL] {
        guard let first = sources.first else { return [] }
        let dir = first.deletingLastPathComponent()
        if sources.count == 1 {
            let dest = uniqueURL(dir.appendingPathComponent(first.lastPathComponent + ".zip"))
            try await Shell.check("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, dest.path])
            return [dest]
        }
        let dest = uniqueURL(dir.appendingPathComponent("Archive.zip"))
        try await Shell.check("/usr/bin/zip", ["-r", "-y", "-q", dest.path] + sources.map(\.lastPathComponent), cwd: dir)
        return [dest]
    }

    static func extract(_ archive: URL) async throws -> [URL] {
        var base = archive.deletingPathExtension()
        if base.pathExtension.lowercased() == "tar" { base = base.deletingPathExtension() }
        let dest = uniqueURL(base)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        do {
            if archive.pathExtension.lowercased() == "zip" {
                try await Shell.check("/usr/bin/ditto", ["-x", "-k", archive.path, dest.path])
            } else {
                try await Shell.check("/usr/bin/tar", ["-xf", archive.path, "-C", dest.path])
            }
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        return [dest]
    }

    static func setTags(_ tags: [FileTag], on url: URL) throws {
        try TagIO.write(tags, to: url)
    }
}

/// App-wide clipboard that mirrors file URLs onto the system pasteboard so Finder interop works.
@MainActor
final class FileClipboard {
    static let shared = FileClipboard()

    private var cutChangeCount: Int?

    func set(_ urls: [URL], cut: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        cutChangeCount = cut ? pasteboard.changeCount : nil
    }

    func contents() -> (urls: [URL], isCut: Bool) {
        let pasteboard = NSPasteboard.general
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return (urls, cutChangeCount == pasteboard.changeCount)
    }

    var hasContents: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    func clearCut() { cutChangeCount = nil }
}
