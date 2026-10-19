import CryptoKit
import Foundation

/// Finds files with identical contents: same size → same first 64 KB → same SHA-256.
enum DuplicateFinder {
    struct File: Identifiable, Hashable {
        let url: URL
        let modified: Date
        var id: URL { url }
    }

    struct Group: Identifiable {
        let hash: String
        let size: Int64
        let files: [File]

        var id: String { hash }
        /// Space freed by keeping one copy.
        var wasted: Int64 { size * Int64(files.count - 1) }
    }

    static func find(in root: URL, minSize: Int64 = 1, includeHidden: Bool = false, progress: OperationProgress? = nil) throws -> [Group] {
        // 1. Group by size (cheap metadata only).
        var bySize: [Int64: [File]] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !includeHidden { options.insert(.skipsHiddenFiles) }
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: options, errorHandler: { _, _ in true })
        while let url = enumerator?.nextObject() as? URL {
            try progress?.checkCancelled()
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, v.isSymbolicLink != true else { continue }
            let size = Int64(v.fileSize ?? 0)
            guard size >= max(minSize, 1) else { continue }
            bySize[size, default: []].append(File(url: url, modified: v.contentModificationDate ?? .distantPast))
        }
        let candidates = bySize.filter { $0.value.count > 1 }
        progress?.setTotals(bytes: 0, items: candidates.values.reduce(0) { $0 + $1.count })

        // 2. Same size → compare the first 64 KB, then 3. the full SHA-256 for the survivors.
        var groups: [Group] = []
        for (size, files) in candidates {
            var byHead: [Data: [File]] = [:]
            for file in files {
                try progress?.checkCancelled()
                progress?.begin(file.url.lastPathComponent)
                if let head = try? headDigest(file.url) { byHead[head, default: []].append(file) }
                progress?.finishItem(baseline: 0, size: 0)
            }
            for sameHead in byHead.values where sameHead.count > 1 {
                var byHash: [String: [File]] = [:]
                for file in sameHead {
                    try progress?.checkCancelled()
                    // Small files: the head already covers the whole content.
                    let hash = size <= 65_536 ? (try? headDigest(file.url))?.base64EncodedString() : try? Hashing.sha256(of: file.url)
                    if let hash { byHash[hash, default: []].append(file) }
                }
                for (hash, same) in byHash where same.count > 1 {
                    groups.append(Group(hash: hash, size: size, files: same.sorted { $0.url.path < $1.url.path }))
                }
            }
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }

    private static func headDigest(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 65_536) ?? Data()
        return Data(SHA256.hash(data: head))
    }

    enum Keep: String, CaseIterable, Identifiable {
        case newest, oldest, shortestPath
        var id: String { rawValue }
        var title: String {
            switch self {
            case .newest: return String(localized: "Keep Newest")
            case .oldest: return String(localized: "Keep Oldest")
            case .shortestPath: return String(localized: "Keep Shortest Path")
            }
        }
    }

    /// Marks every file except the one to keep in each group.
    static func autoMark(_ groups: [Group], keep: Keep) -> Set<URL> {
        var marked: Set<URL> = []
        for group in groups {
            let kept: File? = {
                switch keep {
                case .newest: return group.files.max { $0.modified < $1.modified }
                case .oldest: return group.files.min { $0.modified < $1.modified }
                case .shortestPath: return group.files.min { ($0.url.path.count, $0.url.path) < ($1.url.path.count, $1.url.path) }
                }
            }()
            for file in group.files where file.url != kept?.url { marked.insert(file.url) }
        }
        return marked
    }
}
