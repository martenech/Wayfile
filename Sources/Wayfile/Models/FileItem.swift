import AppKit
import Foundation
import QuickLookThumbnailing

struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    let isSymlink: Bool
    let size: Int64
    let modified: Date
    let created: Date
    private(set) var kind: String
    /// Tags with their Finder colours.
    private(set) var fileTags: [FileTag]
    /// False after a quick first pass (big folders): type name and tags still to be read.
    private(set) var detailsLoaded = true

    var tags: [String] { fileTags.map(\.name) }

    /// Filled in by the pane when the folder is inside a git repository.
    var gitStatus: GitStatus?
    var lastCommit: GitCommit?

    var id: URL { url }

    var gitStatusKey: Int { gitStatus?.rank ?? .max }
    var commitSubjectKey: String { lastCommit?.subject ?? "" }
    var commitAuthorKey: String { lastCommit?.author ?? "" }
    var commitDateKey: Date { lastCommit?.date ?? .distantPast }
    var commitHashKey: String { lastCommit?.hash ?? "" }

    /// Directories that should be navigated into rather than opened (packages like .app are opened).
    var isFolderLike: Bool { isDirectory && !isPackage }

    var isArchive: Bool { FileItem.archiveExtensions.contains(url.pathExtension.lowercased()) }

    /// Sort key for the tags column.
    var tagsKey: String { tags.joined(separator: ",") }

    /// Folders and packages (.app etc.) report no meaningful size without a recursive scan.
    var hasSize: Bool { !isDirectory }

    /// Sort key for the size column; folders always sort as smallest.
    var sizeKey: Int64 { hasSize ? size : -1 }

    static let archiveExtensions: Set<String> = [
        "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "lz4", "zst",
    ]

    static let resourceKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey,
        .fileSizeKey, .contentModificationDateKey, .creationDateKey,
        .localizedTypeDescriptionKey, .tagNamesKey,
    ]

    /// Everything except the expensive keys (type description, tags) — ~10× faster for big folders.
    static let basicKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey,
        .fileSizeKey, .contentModificationDateKey, .creationDateKey,
    ]

    /// Quick variant: type names come from a per-extension cache when known; `loadDetails()` fills in the rest.
    init?(basicURL url: URL) {
        guard let v = try? url.resourceValues(forKeys: Set(Self.basicKeys)) else { return nil }
        self.url = url
        self.name = v.name ?? url.lastPathComponent
        self.isDirectory = v.isDirectory ?? false
        self.isPackage = v.isPackage ?? false
        self.isHidden = v.isHidden ?? false
        self.isSymlink = v.isSymbolicLink ?? false
        self.size = Int64(v.fileSize ?? 0)
        self.modified = v.contentModificationDate ?? .distantPast
        self.created = v.creationDate ?? .distantPast
        self.kind = KindCache.shared.kind(for: url, isDirectory: isDirectory, isPackage: isPackage) ?? ""
        self.fileTags = []
        self.detailsLoaded = false
    }

    /// Second pass with values prefetched for the whole folder (much faster than asking item by item).
    mutating func applyDetails(kind detailKind: String?, hasTags: Bool) {
        guard !detailsLoaded else { return }
        if kind.isEmpty, let detailKind {
            kind = detailKind
            KindCache.shared.store(detailKind, for: url, isDirectory: isDirectory, isPackage: isPackage)
        }
        fileTags = hasTags ? TagIO.read(url) : []
        detailsLoaded = true
    }

    /// Second pass of a quick load: real type name (when not cached) and tags.
    mutating func loadDetails() {
        guard !detailsLoaded else { return }
        if kind.isEmpty {
            kind = (try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]))?.localizedTypeDescription ?? ""
            KindCache.shared.store(kind, for: url, isDirectory: isDirectory, isPackage: isPackage)
        }
        fileTags = TagIO.read(url)
        detailsLoaded = true
    }

    init?(url: URL) {
        guard let v = try? url.resourceValues(forKeys: Set(Self.resourceKeys)) else { return nil }
        self.url = url
        self.name = v.name ?? url.lastPathComponent
        self.isDirectory = v.isDirectory ?? false
        self.isPackage = v.isPackage ?? false
        self.isHidden = v.isHidden ?? false
        self.isSymlink = v.isSymbolicLink ?? false
        self.size = Int64(v.fileSize ?? 0)
        self.modified = v.contentModificationDate ?? .distantPast
        self.created = v.creationDate ?? .distantPast
        self.kind = v.localizedTypeDescription ?? ""
        KindCache.shared.store(kind, for: url, isDirectory: isDirectory, isPackage: isPackage)
        // Colours live in the xattr; only read it for files that have tags.
        self.fileTags = (v.tagNames ?? []).isEmpty ? [] : TagIO.read(url)
    }
}

/// Type descriptions by extension ("pdf" → "PDF document"); learned from real lookups, so they match Finder.
final class KindCache: @unchecked Sendable {
    static let shared = KindCache()
    private let lock = NSLock()
    private var kinds: [String: String] = [:]

    /// Files without an extension and symlinks vary item by item and aren't cached.
    private func key(_ url: URL, isDirectory: Bool, isPackage: Bool) -> String? {
        if isDirectory && !isPackage { return "/folder" }
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? nil : (isPackage ? "/pkg." : ".") + ext
    }

    func kind(for url: URL, isDirectory: Bool, isPackage: Bool) -> String? {
        guard let key = key(url, isDirectory: isDirectory, isPackage: isPackage) else { return nil }
        return lock.withLock { kinds[key] }
    }

    func store(_ kind: String, for url: URL, isDirectory: Bool, isPackage: Bool) {
        guard !kind.isEmpty, let key = key(url, isDirectory: isDirectory, isPackage: isPackage) else { return }
        lock.withLock { kinds[key] = kind }
    }
}

extension URL {
    /// Canonical directory URL so locations compare equal regardless of trailing slashes.
    var normalizedDirectory: URL {
        URL(fileURLWithPath: standardizedFileURL.path, isDirectory: true)
    }

    var displayName: String {
        let name = FileManager.default.displayName(atPath: path)
        // macOS doesn't always localize the standard home folders (e.g. when synced with iCloud).
        if name == lastPathComponent, let localized = URL.standardFolderNames[standardizedFileURL.path] { return localized }
        return name
    }

    /// The home folder's standard folders by path, in the app's language.
    static var standardFolderNames: [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            home + "/Desktop": String(localized: "Desktop"), home + "/Documents": String(localized: "Documents"),
            home + "/Downloads": String(localized: "Downloads"), home + "/Pictures": String(localized: "Pictures"),
            home + "/Music": String(localized: "Music"), home + "/Movies": String(localized: "Movies"),
            home + "/Public": String(localized: "Public"), home + "/Library": String(localized: "Library"),
            "/Applications": String(localized: "Applications"),
        ]
    }
}

@MainActor
enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(image, forKey: key)
        return image
    }
}

@MainActor
enum ThumbnailCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 2000
        return cache
    }()

    /// Sizes are bucketed so dragging the size slider doesn't regenerate on every step.
    private static func bucket(_ size: Double) -> Int { (Int(size) / 48 + 1) * 48 }

    static func key(_ url: URL, _ size: Double) -> String { "\(url.path)#\(bucket(size))" }

    /// A real content thumbnail, or nil when the file only has a generic icon (or is a folder).
    static func thumbnail(for item: FileItem, size: Double) async -> NSImage? {
        guard !item.isDirectory else { return nil }
        let key = key(item.url, size) as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let side = CGFloat(bucket(size))
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: side, height: side),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        cache.setObject(representation.nsImage, forKey: key)
        return representation.nsImage
    }
}

enum Formatters {
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func date(_ date: Date) -> String {
        date == .distantPast ? "" : date.formatted(date: .abbreviated, time: .shortened)
    }
}
