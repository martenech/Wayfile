import CryptoKit
import Foundation

/// Two-way sync that also carries deletions over: it remembers both folders' state after each sync,
/// so next time it can tell "deleted here" from "new there". Conflicts never lose data:
/// deleted on one side but changed on the other → the changed copy is kept and copied back;
/// changed on both sides → the newer one wins and the older goes to the Trash.
enum TwoWaySync {
    struct Conflict: Equatable, Identifiable {
        enum Kind: Equatable { case bothChanged, deletedButChanged(deletedOn: DirectoryDiff.Side) }
        let path: String
        let kind: Kind
        let resolution: String
        var id: String { path }
    }

    struct Plan: Equatable {
        var actions: [DirectoryDiff.Action]
        var conflicts: [Conflict]
        /// No remembered state yet: nothing is deleted on the first sync.
        var isFirstSync: Bool
    }

    struct Snapshot: Codable, Equatable {
        struct Item: Codable, Equatable {
            let size: Int64
            let modified: TimeInterval
            let isDirectory: Bool
        }
        var items: [String: Item]
    }

    // MARK: Planning

    static func plan(left: [String: DirectoryDiff.Meta], right: [String: DirectoryDiff.Meta], base: Snapshot?) -> Plan {
        var actions: [DirectoryDiff.Action] = []
        var conflicts: [Conflict] = []
        var handled: [String] = []
        func under(_ path: String) -> Bool { handled.contains { path.hasPrefix($0 + "/") } }
        func copy(_ path: String, from side: DirectoryDiff.Side, _ meta: DirectoryDiff.Meta) {
            actions.append(.init(path: path, kind: .copy(from: side), bytes: meta.isDirectory ? subtreeBytes(path, side == .left ? left : right) : meta.size))
        }
        func trash(_ path: String, on side: DirectoryDiff.Side) {
            actions.append(.init(path: path, kind: .trash(side: side), bytes: 0))
        }
        func unchanged(_ meta: DirectoryDiff.Meta, _ item: Snapshot.Item?) -> Bool {
            guard let item, meta.isDirectory == item.isDirectory else { return false }
            return meta.isDirectory || (meta.size == item.size && abs(meta.modified.timeIntervalSince1970 - item.modified) <= DirectoryDiff.dateTolerance)
        }
        func same(_ a: DirectoryDiff.Meta, _ b: DirectoryDiff.Meta) -> Bool {
            a.isDirectory == b.isDirectory && (a.isDirectory || (a.size == b.size && abs(a.modified.timeIntervalSince(b.modified)) <= DirectoryDiff.dateTolerance))
        }
        /// Nothing under a folder on `tree` is new or modified since the snapshot.
        func subtreeUnchanged(_ path: String, _ tree: [String: DirectoryDiff.Meta]) -> Bool {
            tree.allSatisfy { key, meta in
                key != path && !key.hasPrefix(path + "/") || unchanged(meta, base?.items[key])
            }
        }

        for path in Set(left.keys).union(right.keys).sorted() {
            if under(path) { continue }
            let l = left[path], r = right[path], b = base?.items[path]
            switch (l, r) {
            case (let l?, let r?):
                if l.isDirectory && r.isDirectory { continue }
                if same(l, r) { continue }
                let leftChanged = !unchanged(l, b), rightChanged = !unchanged(r, b)
                if leftChanged && !rightChanged {
                    copy(path, from: .left, l)
                } else if rightChanged && !leftChanged {
                    copy(path, from: .right, r)
                } else {
                    let winner: DirectoryDiff.Side = l.modified >= r.modified ? .left : .right
                    copy(path, from: winner, winner == .left ? l : r)
                    if base != nil {
                        conflicts.append(Conflict(path: path, kind: .bothChanged,
                                                  resolution: "Changed on both sides — the newer (\(winner == .left ? "left" : "right")) wins, the other goes to the Trash"))
                    }
                }
                if l.isDirectory || r.isDirectory { handled.append(path) }
            case (let l?, nil):
                if l.isDirectory { handled.append(path) }
                guard let b else { copy(path, from: .left, l); continue }   // new on the left
                // Was synced before, now gone on the right: deleted there.
                let keep = l.isDirectory ? !subtreeUnchanged(path, left) : !unchanged(l, b)
                if keep {
                    copy(path, from: .left, l)
                    conflicts.append(Conflict(path: path, kind: .deletedButChanged(deletedOn: .right),
                                              resolution: "Deleted on the right but changed on the left — the changed version is kept"))
                } else {
                    trash(path, on: .left)
                }
            case (nil, let r?):
                if r.isDirectory { handled.append(path) }
                guard let b else { copy(path, from: .right, r); continue }
                let keep = r.isDirectory ? !subtreeUnchanged(path, right) : !unchanged(r, b)
                if keep {
                    copy(path, from: .right, r)
                    conflicts.append(Conflict(path: path, kind: .deletedButChanged(deletedOn: .left),
                                              resolution: "Deleted on the left but changed on the right — the changed version is kept"))
                } else {
                    trash(path, on: .right)
                }
            case (nil, nil):
                continue
            }
        }
        return Plan(actions: actions, conflicts: conflicts, isFirstSync: base == nil)
    }

    private static func subtreeBytes(_ path: String, _ tree: [String: DirectoryDiff.Meta]) -> Int64 {
        tree.reduce(0) { sum, entry in entry.key.hasPrefix(path + "/") && !entry.value.isDirectory ? sum + entry.value.size : sum }
    }

    static func snapshot(of tree: [String: DirectoryDiff.Meta]) -> Snapshot {
        Snapshot(items: tree.mapValues { Snapshot.Item(size: $0.size, modified: $0.modified.timeIntervalSince1970, isDirectory: $0.isDirectory) })
    }

    // MARK: Remembered state

    static var stateFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Wayfile/SyncState", isDirectory: true)
    }

    /// One state file per folder pair (order-independent).
    static func stateURL(left: URL, right: URL, folder: URL = stateFolder) -> URL {
        let paths = [left, right].map { $0.resolvingSymlinksInPath().standardizedFileURL.path }.sorted()
        let digest = SHA256.hash(data: Data(paths.joined(separator: "\n").utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent("\(digest).json")
    }

    /// Stored from the left folder's point of view; paths are the same on both sides after a sync.
    static func loadBase(left: URL, right: URL, folder: URL = stateFolder) -> Snapshot? {
        guard let data = try? Data(contentsOf: stateURL(left: left, right: right, folder: folder)) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func saveBase(left: URL, right: URL, includeHidden: Bool = false, folder: URL = stateFolder) throws {
        // After a sync both sides match; the left tree is the shared state.
        let tree = try DirectoryDiff.tree(left, includeHidden: includeHidden, progress: nil)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot(of: tree)).write(to: stateURL(left: left, right: right, folder: folder), options: .atomic)
    }

    static func forget(left: URL, right: URL, folder: URL = stateFolder) {
        try? FileManager.default.removeItem(at: stateURL(left: left, right: right, folder: folder))
    }

    /// Plans a sync of two folders using their remembered state.
    static func plan(left: URL, right: URL, includeHidden: Bool = false, folder: URL = stateFolder) throws -> Plan {
        let l = try DirectoryDiff.tree(left, includeHidden: includeHidden, progress: nil)
        let r = try DirectoryDiff.tree(right, includeHidden: includeHidden, progress: nil)
        return plan(left: l, right: r, base: loadBase(left: left, right: right, folder: folder))
    }
}
