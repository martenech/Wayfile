import Foundation

/// Compares two folder trees and plans one-way or two-way syncs between them.
enum DirectoryDiff {
    enum Status: String, Codable, CaseIterable {
        case leftOnly, rightOnly, leftNewer, rightNewer, different, same

        var title: String {
            switch self {
            case .leftOnly: return String(localized: "Only left")
            case .rightOnly: return String(localized: "Only right")
            case .leftNewer: return String(localized: "Left newer")
            case .rightNewer: return String(localized: "Right newer")
            case .different: return String(localized: "Different")
            case .same: return String(localized: "Same")
            }
        }

        var symbol: String {
            switch self {
            case .leftOnly: return "arrow.left.to.line"
            case .rightOnly: return "arrow.right.to.line"
            case .leftNewer: return "chevron.left.2"
            case .rightNewer: return "chevron.right.2"
            case .different: return "not.equal"
            case .same: return "equal"
            }
        }
    }

    struct Meta: Equatable {
        let size: Int64
        let modified: Date
        let isDirectory: Bool
    }

    struct Entry: Identifiable, Equatable {
        /// Path relative to both roots, e.g. "assets/logo.png".
        let path: String
        let status: Status
        let left: Meta?
        let right: Meta?

        var id: String { path }
        var isDirectory: Bool { (left ?? right)?.isDirectory ?? false }
        var name: String { (path as NSString).lastPathComponent }
    }

    /// Two dates closer than this count as equal (FAT/exFAT and some network shares round timestamps).
    static let dateTolerance: TimeInterval = 2

    static func compare(left: URL, right: URL, byContent: Bool = false, includeHidden: Bool = false,
                        progress: OperationProgress? = nil) throws -> [Entry] {
        let leftTree = try tree(left, includeHidden: includeHidden, progress: progress)
        let rightTree = try tree(right, includeHidden: includeHidden, progress: progress)

        var entries: [Entry] = []
        // A folder that exists on one side only is listed once; its contents travel with it.
        var skippedPrefixes: [String] = []
        func underSkipped(_ path: String) -> Bool { skippedPrefixes.contains { path.hasPrefix($0 + "/") } }

        for path in Set(leftTree.keys).union(rightTree.keys).sorted() {
            if underSkipped(path) { continue }
            try progress?.checkCancelled()
            let l = leftTree[path], r = rightTree[path]
            let status: Status
            switch (l, r) {
            case (let l?, nil):
                status = .leftOnly
                if l.isDirectory { skippedPrefixes.append(path) }
            case (nil, let r?):
                status = .rightOnly
                if r.isDirectory { skippedPrefixes.append(path) }
            case (let l?, let r?):
                if l.isDirectory || r.isDirectory {
                    if l.isDirectory != r.isDirectory { status = .different } else { continue } // folders: compare contents
                } else {
                    status = try compareFiles(l, r, left.appendingPathComponent(path), right.appendingPathComponent(path), byContent: byContent)
                }
            case (nil, nil):
                continue
            }
            entries.append(Entry(path: path, status: status, left: l, right: r))
        }
        return entries
    }

    private static func compareFiles(_ l: Meta, _ r: Meta, _ leftURL: URL, _ rightURL: URL, byContent: Bool) throws -> Status {
        let timeDelta = l.modified.timeIntervalSince(r.modified)
        if l.size == r.size {
            if byContent {
                return try Hashing.sha256(of: leftURL) == Hashing.sha256(of: rightURL) ? .same : newer(timeDelta) ?? .different
            }
            if abs(timeDelta) <= dateTolerance { return .same }
        }
        return newer(timeDelta) ?? .different
    }

    private static func newer(_ delta: TimeInterval) -> Status? {
        if delta > dateTolerance { return .leftNewer }
        if delta < -dateTolerance { return .rightNewer }
        return nil
    }

    static func tree(_ root: URL, includeHidden: Bool, progress: OperationProgress?) throws -> [String: Meta] {
        var result: [String: Meta] = [:]
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return [:] }
        while let relative = enumerator.nextObject() as? String {
            try progress?.checkCancelled()
            let name = (relative as NSString).lastPathComponent
            if name == ".DS_Store" { continue }
            if !includeHidden, relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                if enumerator.fileAttributes?[.type] as? FileAttributeType == .typeDirectory { enumerator.skipDescendants() }
                continue
            }
            guard let attributes = enumerator.fileAttributes else { continue }
            let type = attributes[.type] as? FileAttributeType
            if type == .typeSymbolicLink || type == .typeRegular || type == .typeDirectory {
                result[relative] = Meta(
                    size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                    modified: attributes[.modificationDate] as? Date ?? .distantPast,
                    isDirectory: type == .typeDirectory
                )
            }
        }
        return result
    }

    // MARK: Sync

    enum SyncMode: String, CaseIterable, Identifiable {
        case updateRight, updateLeft, mirrorToRight, mirrorToLeft, twoWay

        var id: String { rawValue }

        var title: String {
            switch self {
            case .updateRight: return String(localized: "Update right (copy new & newer →)")
            case .updateLeft: return String(localized: "Update left (← copy new & newer)")
            case .mirrorToRight: return String(localized: "Mirror left → right (also remove extras on the right)")
            case .mirrorToLeft: return String(localized: "Mirror right → left (also remove extras on the left)")
            case .twoWay: return String(localized: "Two-way (copy newer both ways, remove nothing)")
            }
        }
    }

    enum Side: String { case left, right }

    struct Action: Identifiable, Equatable {
        enum Kind: Equatable {
            /// Copy the item from `from` side to the other side (replacing what's there — moved to the Trash).
            case copy(from: Side)
            /// Move the item on `side` to the Trash.
            case trash(side: Side)
        }

        let path: String
        let kind: Kind
        let bytes: Int64

        var id: String { path + "\(kind)" }
    }

    static func plan(_ entries: [Entry], mode: SyncMode) -> [Action] {
        entries.compactMap { entry in
            let leftBytes = entry.left?.size ?? 0, rightBytes = entry.right?.size ?? 0
            func copy(_ side: Side) -> Action { Action(path: entry.path, kind: .copy(from: side), bytes: side == .left ? leftBytes : rightBytes) }
            func trash(_ side: Side) -> Action { Action(path: entry.path, kind: .trash(side: side), bytes: 0) }
            switch (mode, entry.status) {
            case (_, .same): return nil
            case (.updateRight, .leftOnly), (.updateRight, .leftNewer): return copy(.left)
            case (.updateLeft, .rightOnly), (.updateLeft, .rightNewer): return copy(.right)
            case (.mirrorToRight, .leftOnly), (.mirrorToRight, .leftNewer), (.mirrorToRight, .rightNewer), (.mirrorToRight, .different): return copy(.left)
            case (.mirrorToRight, .rightOnly): return trash(.right)
            case (.mirrorToLeft, .rightOnly), (.mirrorToLeft, .rightNewer), (.mirrorToLeft, .leftNewer), (.mirrorToLeft, .different): return copy(.right)
            case (.mirrorToLeft, .leftOnly): return trash(.left)
            case (.twoWay, .leftOnly), (.twoWay, .leftNewer): return copy(.left)
            case (.twoWay, .rightOnly), (.twoWay, .rightNewer): return copy(.right)
            default: return nil // e.g. "different" without a clear newer side is left for the user in update modes
            }
        }
    }

    /// Runs a plan. Replaced and removed items go to the Trash; everything is recorded for undo.
    static func execute(_ actions: [Action], left: URL, right: URL, progress: OperationProgress) throws {
        let fm = FileManager.default
        progress.setTotals(bytes: actions.reduce(0) { $0 + $1.bytes }, items: actions.count)
        for action in actions {
            try progress.waitWhilePaused()
            progress.begin(action.path)
            let baseline = progress.completedBytes
            switch action.kind {
            case .copy(let from):
                let source = (from == .left ? left : right).appendingPathComponent(action.path)
                let destination = (from == .left ? right : left).appendingPathComponent(action.path)
                if fm.fileExists(atPath: destination.path) {
                    var trashed: NSURL?
                    try fm.trashItem(at: destination, resultingItemURL: &trashed)
                    if let trashed { progress.record(.trashed([TrashedItem(original: destination, trashed: trashed as URL)])) }
                }
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try CopyEngine.copy(source, to: destination, progress: progress)
                progress.record(.created([destination]))
            case .trash(let side):
                let target = (side == .left ? left : right).appendingPathComponent(action.path)
                guard fm.fileExists(atPath: target.path) else { continue }
                var trashed: NSURL?
                try fm.trashItem(at: target, resultingItemURL: &trashed)
                if let trashed { progress.record(.trashed([TrashedItem(original: target, trashed: trashed as URL)])) }
            }
            progress.finishItem(baseline: baseline, size: action.bytes)
        }
    }
}
