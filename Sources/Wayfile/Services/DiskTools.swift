import CoreGraphics
import Foundation

// MARK: - Disk usage

/// A folder tree with allocated sizes. Small leftovers are merged into one "Smaller items" node
/// per folder so huge trees stay light.
final class SizeNode: Identifiable, @unchecked Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    /// "Smaller items" bucket: not a real file.
    let isAggregate: Bool
    private(set) var size: Int64
    private(set) var fileCount: Int
    private(set) var children: [SizeNode]
    weak var parent: SizeNode?

    var id: String { isAggregate ? url.path + "/…" : url.path }

    init(url: URL, name: String? = nil, isDirectory: Bool, isAggregate: Bool = false, size: Int64 = 0, fileCount: Int = 0, children: [SizeNode] = []) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.isDirectory = isDirectory
        self.isAggregate = isAggregate
        self.size = size
        self.fileCount = fileCount
        self.children = children
        children.forEach { $0.parent = self }
    }

    /// Detaches a child (after it was trashed) and fixes the totals up the tree.
    func remove(_ child: SizeNode) {
        guard let index = children.firstIndex(where: { $0 === child }) else { return }
        children.remove(at: index)
        var node: SizeNode? = self
        while let current = node {
            current.size -= child.size
            current.fileCount -= child.fileCount
            node = current.parent
        }
    }
}

enum DiskUsage {
    /// Children kept per folder before the rest are merged.
    static let keepPerFolder = 150

    final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var _files = 0, _bytes: Int64 = 0
        private var _cancelled = false
        var files: Int { lock.withLock { _files } }
        var bytes: Int64 { lock.withLock { _bytes } }
        var isCancelled: Bool { lock.withLock { _cancelled } }
        func cancel() { lock.withLock { _cancelled = true } }
        func add(files: Int, bytes: Int64) { lock.withLock { _files += files; _bytes += bytes } }
    }

    /// Scans `root` (stays on its volume; symlinks aren't followed).
    static func scan(_ root: URL, progress: Progress = Progress()) -> SizeNode {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .volumeIdentifierKey, .isPackageKey]
        let rootVolume = (try? root.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject

        func visit(_ dir: URL) -> SizeNode {
            let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys), options: [])) ?? []
            var children: [SizeNode] = []
            var batchFiles = 0
            var batchBytes: Int64 = 0
            for url in urls {
                if progress.isCancelled { break }
                guard let v = try? url.resourceValues(forKeys: keys) else { continue }
                if v.isDirectory == true && v.isSymbolicLink != true {
                    if let volume = v.volumeIdentifier as? NSObject, let rootVolume, !volume.isEqual(rootVolume) { continue }
                    children.append(visit(url))
                } else {
                    let size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0)
                    children.append(SizeNode(url: url, isDirectory: false, size: size, fileCount: 1))
                    batchFiles += 1
                    batchBytes += size
                }
            }
            progress.add(files: batchFiles, bytes: batchBytes)
            children.sort { $0.size > $1.size }
            if children.count > keepPerFolder {
                let rest = children[keepPerFolder...]
                let merged = SizeNode(url: dir, name: "\(rest.count) smaller items", isDirectory: false, isAggregate: true,
                                      size: rest.reduce(0) { $0 + $1.size }, fileCount: rest.reduce(0) { $0 + $1.fileCount })
                children = Array(children[..<keepPerFolder]) + [merged]
            }
            return SizeNode(url: dir, isDirectory: true, size: children.reduce(0) { $0 + $1.size },
                            fileCount: children.reduce(0) { $0 + $1.fileCount }, children: children)
        }
        return visit(root)
    }

    /// Squarified treemap (Bruls, Huizing, van Wijk): rectangles for `values` (sorted descending) inside `rect`.
    static func treemap(_ values: [Double], in rect: CGRect) -> [CGRect] {
        guard !values.isEmpty, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        let total = values.reduce(0, +)
        guard total > 0 else { return values.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var result = [CGRect](repeating: .zero, count: values.count)
        var remaining = rect
        var start = 0

        func worst(_ row: ArraySlice<Double>, side: Double) -> Double {
            let sum = row.reduce(0, +)
            guard sum > 0, let maxA = row.max(), let minA = row.min(), minA > 0 else { return .infinity }
            let s2 = side * side
            return max(s2 * maxA / (sum * sum), (sum * sum) / (s2 * minA))
        }

        while start < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            var end = start + 1
            while end < areas.count && worst(areas[start...end], side: side) <= worst(areas[start..<end], side: side) {
                end += 1
            }
            let row = areas[start..<end]
            let sum = row.reduce(0, +)
            if remaining.width >= remaining.height {
                // Column on the left.
                let width = CGFloat(sum / Double(remaining.height))
                var y = remaining.minY
                for (offset, area) in row.enumerated() {
                    let height = width > 0 ? CGFloat(area) / width : 0
                    result[start + offset] = CGRect(x: remaining.minX, y: y, width: width, height: height)
                    y += height
                }
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY, width: max(0, remaining.width - width), height: remaining.height)
            } else {
                // Row on top.
                let height = CGFloat(sum / Double(remaining.width))
                var x = remaining.minX
                for (offset, area) in row.enumerated() {
                    let width = height > 0 ? CGFloat(area) / height : 0
                    result[start + offset] = CGRect(x: x, y: remaining.minY, width: width, height: height)
                    x += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height, width: remaining.width, height: max(0, remaining.height - height))
            }
            start = end
        }
        return result
    }
}

// MARK: - Archives

/// An archive read with bsdtar (zip, tar, gz, bz2, xz, 7z, iso, rar…), browsed like folders.
struct ArchiveEntry: Identifiable, Hashable {
    let path: String
    let size: Int64
    let isDirectory: Bool
    var id: String { path }
    var name: String { (path.hasSuffix("/") ? String(path.dropLast()) : path).split(separator: "/").last.map(String.init) ?? path }
}

enum ArchiveIndex {
    static func entries(of archive: URL) async throws -> [ArchiveEntry] {
        parse(try await Shell.check("/usr/bin/tar", ["-tvf", archive.path], environment: ["LC_ALL": "C"]))
    }

    /// Parses `tar -tv` (ls-style) lines: "drwxr-xr-x  0 user group  0 Jan  2 10:00 dir/".
    static func parse(_ output: String) -> [ArchiveEntry] {
        let pattern = try! NSRegularExpression(pattern: #"^([\-dlrwxsStT]{10})\s+\d+\s+\S+\s+\S+\s+(\d+)\s+\S+\s+\S+\s+\S+\s+(.+)$"#)
        var entries: [String: ArchiveEntry] = [:]
        for line in output.split(separator: "\n") {
            let text = String(line)
            guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let modeRange = Range(match.range(at: 1), in: text), let sizeRange = Range(match.range(at: 2), in: text),
                  let nameRange = Range(match.range(at: 3), in: text) else { continue }
            var path = String(text[nameRange])
            if let arrow = path.range(of: " -> "), text[modeRange].hasPrefix("l") { path = String(path[..<arrow.lowerBound]) }
            if path.hasPrefix("./") { path.removeFirst(2) }
            if path.hasPrefix("__MACOSX/") || path.isEmpty || path == "." { continue }
            // AppleDouble companions ("._name") carry Finder metadata, not content.
            if path.split(separator: "/").last?.hasPrefix("._") == true { continue }
            let isDir = text[modeRange].hasPrefix("d") || path.hasSuffix("/")
            let clean = isDir ? (path.hasSuffix("/") ? path : path + "/") : path
            entries[clean] = ArchiveEntry(path: clean, size: Int64(text[sizeRange]) ?? 0, isDirectory: isDir)
        }
        // Folders implied by file paths (zips often omit them).
        for entry in Array(entries.values) {
            // Every ancestor of the entry (the entry itself is already there).
            let parts = entry.path.split(separator: "/").map(String.init).dropLast()
            var prefix = ""
            for part in parts {
                prefix += part + "/"
                if entries[prefix] == nil { entries[prefix] = ArchiveEntry(path: prefix, size: 0, isDirectory: true) }
            }
        }
        return entries.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Direct children of `folder` ("" = root), folders first.
    static func children(of folder: String, in entries: [ArchiveEntry]) -> [ArchiveEntry] {
        entries.filter { entry in
            guard entry.path.hasPrefix(folder), entry.path != folder else { return false }
            let rest = entry.path.dropFirst(folder.count)
            let trimmed = rest.hasSuffix("/") ? rest.dropLast() : rest
            return !trimmed.contains("/")
        }
        .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }

    /// Total size of everything under a folder entry.
    static func size(of folder: String, in entries: [ArchiveEntry]) -> Int64 {
        entries.filter { $0.path.hasPrefix(folder) && !$0.isDirectory }.reduce(0) { $0 + $1.size }
    }

    /// Extracts entries (folders include their contents) into `destination`, keeping their paths
    /// relative to `base` (the folder being browsed). Returns the top-level items created.
    static func extract(_ archive: URL, entries: [ArchiveEntry], base: String, to destination: URL) async throws -> [URL] {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("wayfile-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let patterns = entries.map { $0.isDirectory ? String($0.path.dropLast()) : $0.path }
        try await Shell.check("/usr/bin/tar", ["-xf", archive.path, "-C", temp.path, "--"] + patterns)
        var results: [URL] = []
        for entry in entries {
            let source = temp.appendingPathComponent(entry.isDirectory ? String(entry.path.dropLast()) : entry.path)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let relative = String(entry.path.dropFirst(base.count))
            let target = FileOps.uniqueURL(destination.appendingPathComponent(relative.hasSuffix("/") ? String(relative.dropLast()) : relative))
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: source, to: target)
            results.append(target)
        }
        return results
    }
}

// MARK: - Compression options

struct CompressOptions: Hashable {
    enum Format: String, CaseIterable, Identifiable {
        case zip, tarGz, tarBz2, tarXz, tar
        var id: String { rawValue }
        var title: String {
            switch self {
            case .zip: return String(localized: "ZIP")
            case .tarGz: return String(localized: "tar.gz")
            case .tarBz2: return String(localized: "tar.bz2")
            case .tarXz: return String(localized: "tar.xz")
            case .tar: return String(localized: "tar (no compression)")
            }
        }
        var fileExtension: String {
            switch self {
            case .zip: return "zip"
            case .tarGz: return "tar.gz"
            case .tarBz2: return "tar.bz2"
            case .tarXz: return "tar.xz"
            case .tar: return "tar"
            }
        }
        var supportsLevel: Bool { self != .tar }
    }

    var format: Format = .zip
    /// 0 (store) … 9 (smallest).
    var level = 6
    /// ZIP only (legacy ZipCrypto — weak; the UI says so).
    var password = ""
    var name = "Archive"
    var excludeMacMetadata = true

    /// Executable, arguments and working directory for compressing `sources` (all in one folder).
    func command(for sources: [URL], output: URL) -> (String, [String]) {
        let names = sources.map(\.lastPathComponent)
        switch format {
        case .zip:
            var args = ["-r", "-y", "-q", "-\(level)"]
            if !password.isEmpty { args += ["-P", password] }
            args.append(output.path)
            args += names
            if excludeMacMetadata { args += ["-x", "*.DS_Store", "-x", "__MACOSX/*"] }
            return ("/usr/bin/zip", args)
        case .tarGz, .tarBz2, .tarXz, .tar:
            let flag = ["tarGz": "z", "tarBz2": "j", "tarXz": "J", "tar": ""][format.rawValue]!
            var args = ["-c\(flag)f", output.path]
            if format.supportsLevel {
                let filter = ["tarGz": "gzip", "tarBz2": "bzip2", "tarXz": "xz"][format.rawValue]!
                args += ["--options", "\(filter):compression-level=\(max(1, level))"]
            }
            if excludeMacMetadata { args += ["--exclude", ".DS_Store", "--no-mac-metadata"] }
            args += ["--"] + names
            return ("/usr/bin/tar", args)
        }
    }

    func compress(_ sources: [URL]) async throws -> URL {
        guard let dir = sources.first?.deletingLastPathComponent() else { throw ShellError(message: "Nothing to compress.") }
        let output = FileOps.uniqueURL(dir.appendingPathComponent("\(name).\(format.fileExtension)"))
        let (exe, args) = command(for: sources, output: output)
        do {
            try await Shell.check(exe, args, cwd: dir)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }
}

// MARK: - Links

enum Links {
    struct Info: Equatable {
        /// Destination of a symbolic link as stored (may be relative).
        let symlinkTarget: String?
        /// Resolved destination, nil when the link is broken.
        let resolved: URL?
        /// Number of hard links to the file (1 = just this one).
        let hardLinkCount: Int
        var isSymlink: Bool { symlinkTarget != nil }
        var isBroken: Bool { isSymlink && resolved == nil }
    }

    static func info(_ url: URL) -> Info {
        let fm = FileManager.default
        let target = try? fm.destinationOfSymbolicLink(atPath: url.path)
        var resolved: URL?
        if let target {
            let full = target.hasPrefix("/") ? URL(fileURLWithPath: target) : url.deletingLastPathComponent().appendingPathComponent(target)
            resolved = fm.fileExists(atPath: full.path) ? full.standardizedFileURL : nil
        }
        var st = stat()
        let count = lstat(url.path, &st) == 0 ? Int(st.st_nlink) : 1
        return Info(symlinkTarget: target, resolved: resolved, hardLinkCount: (st.st_mode & S_IFMT) == S_IFDIR ? 1 : count)
    }

    /// Creates "<name> link" next to `target` (or in `folder`), pointing at it with a relative path when possible.
    @discardableResult
    static func makeSymlink(to target: URL, in folder: URL? = nil, relative: Bool = true) throws -> URL {
        let dir = folder ?? target.deletingLastPathComponent()
        let link = FileOps.uniqueURL(dir.appendingPathComponent(target.lastPathComponent + " link"))
        let destination = relative ? relativePath(from: dir, to: target) : target.path
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
        return link
    }

    @discardableResult
    static func makeHardLink(to file: URL, in folder: URL? = nil) throws -> URL {
        let dir = folder ?? file.deletingLastPathComponent()
        let base = file.deletingPathExtension().lastPathComponent + " hardlink"
        let name = file.pathExtension.isEmpty ? base : base + "." + file.pathExtension
        let link = FileOps.uniqueURL(dir.appendingPathComponent(name))
        try FileManager.default.linkItem(at: file, to: link)
        return link
    }

    static func relativePath(from dir: URL, to target: URL) -> String {
        let a = dir.standardizedFileURL.pathComponents, b = target.standardizedFileURL.pathComponents
        var common = 0
        while common < min(a.count, b.count) && a[common] == b[common] { common += 1 }
        guard common > 1 else { return target.path }   // only "/" in common: absolute is clearer
        return (Array(repeating: "..", count: a.count - common) + b[common...]).joined(separator: "/")
    }

    /// Broken symbolic links under `folder`.
    static func broken(in folder: URL, recursive: Bool = true, limit: Int = 5000) -> [URL] {
        var found: [URL] = []
        let keys: [URLResourceKey] = [.isSymbolicLinkKey]
        if recursive {
            let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants], errorHandler: { _, _ in true })
            while let url = enumerator?.nextObject() as? URL, found.count < limit {
                if (try? url.resourceValues(forKeys: Set(keys)))?.isSymbolicLink == true, info(url).isBroken { found.append(url) }
            }
        } else {
            for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? [] where info(url).isBroken {
                found.append(url)
            }
        }
        return found.sorted { $0.path < $1.path }
    }
}

// MARK: - Custom metadata

/// User key/value pairs stored with the file in an extended attribute (travels with copies on APFS/HFS+).
enum CustomMetadata {
    static let attribute = "dev.wayfile.metadata"

    static func read(_ url: URL) -> [String: String] {
        let size = getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [:] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, attribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read == size else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    static func write(_ values: [String: String], to url: URL) throws {
        let cleaned = values.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
        if cleaned.isEmpty {
            if removexattr(url.path, attribute, XATTR_NOFOLLOW) != 0 && errno != ENOATTR { throw posixError() }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(cleaned)
        let result = data.withUnsafeBytes { setxattr(url.path, attribute, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        if result != 0 { throw posixError() }
    }

    /// "key=value", "key=" / "key" (has key), case-insensitive; value matches as a substring.
    static func matches(_ url: URL, filter: String) -> Bool {
        let values = read(url)
        guard !values.isEmpty else { return false }
        let parts = filter.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let key = parts.first, !key.isEmpty else { return true }
        guard let value = values.first(where: { $0.key.lowercased() == key })?.value else { return false }
        return parts.count < 2 || parts[1].isEmpty || value.lowercased().contains(parts[1])
    }

    private static func posixError() -> Error {
        ShellError(message: String(cString: strerror(errno)))
    }
}
