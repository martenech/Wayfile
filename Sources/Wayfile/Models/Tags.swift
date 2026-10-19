import AppKit
import Foundation
import Observation

/// A Finder tag: a name plus Finder's colour number (0 none, 1 gray, 2 green, 3 purple, 4 blue,
/// 5 yellow, 6 red, 7 orange). Names are whatever the user sees in Finder, i.e. localized
/// ("Červená" on a Slovak Mac), so they must never be hard-coded in English.
struct FileTag: Hashable, Codable, Identifiable {
    let name: String
    let color: Int

    var id: String { name }

    var nsColor: NSColor? { FileTag.colors[color] }

    static let colors: [Int: NSColor] = [
        1: .systemGray, 2: .systemGreen, 3: .systemPurple, 4: .systemBlue,
        5: .systemYellow, 6: .systemRed, 7: .systemOrange,
    ]
}

enum TagIO {
    private static let attribute = "com.apple.metadata:_kMDItemUserTags"

    /// Tags with colours, read from the extended attribute Finder writes ("name\nN").
    static func read(_ url: URL) -> [FileTag] {
        let size = getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, attribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read == size,
              let entries = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return [] }
        return entries.map(parse)
    }

    static func parse(_ entry: String) -> FileTag {
        let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let color = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
        return FileTag(name: String(parts[0]), color: color)
    }

    /// Writes tags exactly like Finder does, keeping each tag's colour.
    static func write(_ tags: [FileTag], to url: URL) throws {
        if tags.isEmpty {
            if removexattr(url.path, attribute, XATTR_NOFOLLOW) != 0 && errno != ENOATTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return
        }
        let entries = tags.map { "\($0.name)\n\($0.color)" }
        let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
        let result = data.withUnsafeBytes { setxattr(url.path, attribute, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// A tag by name with the colour the system gives it (e.g. "Red" → red), for tags added by name.
    static func named(_ name: String) -> FileTag {
        FileTag(name: name, color: systemColors(for: [name])[name] ?? 0)
    }

    /// Colours the system assigns to tag names (it knows the localized standard colour names).
    /// Asks Foundation by tagging a scratch file, so it works in every language.
    static func systemColors(for names: [String]) -> [String: Int] {
        guard !names.isEmpty else { return [:] }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("wayfile-tags-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: scratch.path, contents: Data()) else { return [:] }
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard (try? (scratch as NSURL).setResourceValue(names, forKey: .tagNamesKey)) != nil else { return [:] }
        return Dictionary(read(scratch).map { ($0.name, $0.color) }, uniquingKeysWith: { first, _ in first })
    }
}

/// The tags shown in the sidebar and menus: Finder's favourite tags, in Finder's order and language.
@MainActor
@Observable
final class TagStore {
    static let shared = TagStore()

    private(set) var favorites: [FileTag] = []
    /// Tags on at least one file (from Spotlight), with how many files carry each.
    private(set) var allTags: [FileTag] = []
    private(set) var usage: [String: Int] = [:]
    private(set) var hasLoadedUsage = false
    private var knownColors: [String: Int] = [:]
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?

    private init() {
        reload()
        Task { await loadAllTags() }
    }

    /// Sidebar list: only tags in use (Finder's order first, then the rest A–Z), or Finder's favourites.
    var sidebarTags: [FileTag] {
        guard AppSettings.shared.sidebarShowsUsedTagsOnly else { return favorites }
        guard hasLoadedUsage else { return [] }
        let used = Set(allTags.map(\.name))
        let fromFavorites = favorites.filter { used.contains($0.name) }
        let favoriteNames = Set(fromFavorites.map(\.name))
        return fromFavorites + allTags.filter { !favoriteNames.contains($0.name) }
    }

    /// Tags offered in menus: Finder's favourites plus any other tag already in use.
    var menuTags: [FileTag] {
        let names = Set(favorites.map(\.name))
        return favorites + allTags.filter { !names.contains($0.name) }
    }

    /// Re-reads tag usage shortly after tags change (Spotlight needs a moment to index the change).
    func refreshUsageSoon() {
        pendingRefresh?.cancel()
        pendingRefresh = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await loadAllTags()
        }
    }

    func reload() {
        let finder = UserDefaults(suiteName: "com.apple.finder")
        var names = (finder?.stringArray(forKey: "FavoriteTagNames") ?? []).filter { !$0.isEmpty }
        if names.isEmpty {
            // Finder never opened: fall back to the colour labels in the system language.
            names = Array(NSWorkspace.shared.fileLabels.dropFirst())
        }
        let colors = TagIO.systemColors(for: names)
        knownColors.merge(colors) { _, new in new }
        favorites = names.map { FileTag(name: $0, color: colors[$0] ?? 0) }
    }

    func color(for name: String) -> Int { knownColors[name] ?? 0 }

    /// Every tag used on this Mac, for "All Tags…": Spotlight finds the tagged files, and the tags
    /// (with colours) are read from the files themselves — more reliable than parsing mdfind's output.
    func loadAllTags() async {
        let output = await Shell.run("/usr/bin/mdfind", ["-0", "kMDItemUserTags == '*'"])
        let paths = output.stdout.split(separator: "\0").prefix(5000).map(String.init)
        let (found, counts) = await Task.detached { () -> ([String: FileTag], [String: Int]) in
            var tags: [String: FileTag] = [:]
            var counts: [String: Int] = [:]
            for path in paths {
                for tag in TagIO.read(URL(fileURLWithPath: path)) {
                    counts[tag.name, default: 0] += 1
                    if tags[tag.name] == nil || tags[tag.name]?.color == 0 { tags[tag.name] = tag }
                }
            }
            return (tags, counts)
        }.value
        for (name, tag) in found where tag.color != 0 { knownColors[name] = tag.color }
        allTags = found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        usage = counts
        hasLoadedUsage = true
    }
}
