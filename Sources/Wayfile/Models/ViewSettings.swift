import Foundation
import Observation

enum SortField: String, Codable, CaseIterable, Identifiable {
    case name, modified, created, kind, size, tags

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return String(localized: "Name")
        case .modified: return String(localized: "Date Modified")
        case .created: return String(localized: "Date Created")
        case .kind: return String(localized: "Type")
        case .size: return String(localized: "Size")
        case .tags: return String(localized: "Tags")
        }
    }

    func comparator(ascending: Bool) -> KeyPathComparator<FileItem> {
        let order: SortOrder = ascending ? .forward : .reverse
        switch self {
        case .name: return KeyPathComparator(\FileItem.name, order: order)
        case .modified: return KeyPathComparator(\FileItem.modified, order: order)
        case .created: return KeyPathComparator(\FileItem.created, order: order)
        case .kind: return KeyPathComparator(\FileItem.kind, order: order)
        case .size: return KeyPathComparator(\FileItem.sizeKey, order: order)
        case .tags: return KeyPathComparator(\FileItem.tagsKey, order: order)
        }
    }

    init(comparator: KeyPathComparator<FileItem>?) {
        switch comparator?.keyPath {
        case \FileItem.modified: self = .modified
        case \FileItem.created: self = .created
        case \FileItem.kind: self = .kind
        case \FileItem.sizeKey: self = .size
        case \FileItem.tagsKey: self = .tags
        default: self = .name
        }
    }
}

enum GroupBy: String, Codable, CaseIterable, Identifiable {
    case none, name, kind, modified, created, size, tag

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return String(localized: "None")
        case .name: return String(localized: "Name")
        case .kind: return String(localized: "Type")
        case .modified: return String(localized: "Date Modified")
        case .created: return String(localized: "Date Created")
        case .size: return String(localized: "Size")
        case .tag: return String(localized: "Tag")
        }
    }
}

struct ItemGroup: Identifiable {
    let id: String
    let title: String
    let items: [FileItem]
}

/// Per-folder (or global) presentation settings, persisted between launches.
struct ViewSettings: Codable, Equatable {
    var layout: LayoutMode = .details
    var sortField: SortField = .name
    var ascending = true
    var foldersFirst = true
    var groupBy: GroupBy = .none
    var groupDescending = false
    var iconSize: Double = 64
}

@MainActor
@Observable
final class ViewSettingsStore {
    static let shared = ViewSettingsStore()

    private static let defaultsKey = "viewSettings.defaults"
    private static let foldersKey = "viewSettings.folders"
    private static let syncKey = "viewSettings.sync"

    /// When on, every folder shares one set of settings (Files' "sync layout across directories").
    var syncAcrossFolders: Bool {
        didSet { UserDefaults.standard.set(syncAcrossFolders, forKey: Self.syncKey) }
    }

    private(set) var defaults: ViewSettings
    private var perFolder: [String: ViewSettings]

    private init() {
        let ud = UserDefaults.standard
        syncAcrossFolders = ud.bool(forKey: Self.syncKey)
        defaults = ud.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(ViewSettings.self, from: $0) } ?? ViewSettings()
        perFolder = ud.data(forKey: Self.foldersKey).flatMap { try? JSONDecoder().decode([String: ViewSettings].self, from: $0) } ?? [:]
    }

    func settings(for folder: URL?) -> ViewSettings {
        guard !syncAcrossFolders, let folder else { return defaults }
        return perFolder[folder.standardizedFileURL.path] ?? defaults
    }

    func hasCustomSettings(for folder: URL?) -> Bool {
        guard !syncAcrossFolders, let folder else { return false }
        return perFolder[folder.standardizedFileURL.path] != nil
    }

    func save(_ settings: ViewSettings, for folder: URL?) {
        if syncAcrossFolders {
            defaults = settings
        } else if let folder {
            let key = folder.standardizedFileURL.path
            perFolder[key] = settings == defaults ? nil : settings
        } else {
            return
        }
        persist()
    }

    func makeDefault(_ settings: ViewSettings) {
        defaults = settings
        persist()
    }

    func resetAllFolders() {
        perFolder.removeAll()
        persist()
    }

    var customFolderCount: Int { perFolder.count }

    func reset(_ folder: URL) {
        perFolder[folder.standardizedFileURL.path] = nil
        persist()
    }

    private func persist() {
        let ud = UserDefaults.standard
        ud.set(try? JSONEncoder().encode(defaults), forKey: Self.defaultsKey)
        ud.set(try? JSONEncoder().encode(perFolder), forKey: Self.foldersKey)
    }
}

enum Grouping {
    /// Splits already-sorted items into groups, keeping the item order inside each group.
    static func groups(_ items: [FileItem], by groupBy: GroupBy, descending: Bool, now: Date = Date()) -> [ItemGroup] {
        guard groupBy != .none else { return [ItemGroup(id: "all", title: "", items: items)] }

        var buckets: [String: (rank: Double, title: String, items: [FileItem])] = [:]
        for item in items {
            let (rank, title) = key(for: item, groupBy: groupBy, now: now)
            buckets[title, default: (rank, title, [])].items.append(item)
        }
        let ordered = buckets.values.sorted {
            $0.rank == $1.rank
                ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                : $0.rank < $1.rank
        }
        return (descending ? ordered.reversed() : ordered).map { ItemGroup(id: $0.title, title: $0.title, items: $0.items) }
    }

    private static func key(for item: FileItem, groupBy: GroupBy, now: Date) -> (Double, String) {
        switch groupBy {
        case .none:
            return (0, "")
        case .name:
            guard let first = item.name.first, first.isLetter else { return (0, "#") }
            return (1, String(first).uppercased())
        case .kind:
            return (item.isFolderLike ? 0 : 1, item.isFolderLike ? "Folders" : (item.kind.isEmpty ? "Other" : item.kind))
        case .modified:
            return dateBucket(item.modified, now: now)
        case .created:
            return dateBucket(item.created, now: now)
        case .size:
            return sizeBucket(item)
        case .tag:
            guard let tag = item.tags.first else { return (1, "No tags") }
            return (0, tag)
        }
    }

    /// Recency buckets; rank is "how long ago" so ascending order shows newest first.
    private static func dateBucket(_ date: Date, now: Date) -> (Double, String) {
        let calendar = Calendar.current
        if date == .distantPast { return (100, "Unknown") }
        if calendar.isDateInToday(date) { return (0, "Today") }
        if calendar.isDateInYesterday(date) { return (1, "Yesterday") }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return (2, "Earlier this week") }
        if let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: now),
           calendar.isDate(date, equalTo: lastWeek, toGranularity: .weekOfYear) { return (3, "Last week") }
        if calendar.isDate(date, equalTo: now, toGranularity: .month) { return (4, "Earlier this month") }
        if let lastMonth = calendar.date(byAdding: .month, value: -1, to: now),
           calendar.isDate(date, equalTo: lastMonth, toGranularity: .month) { return (5, "Last month") }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return (6, "Earlier this year") }
        let year = calendar.component(.year, from: date)
        return (Double(10 + calendar.component(.year, from: now) - year), String(year))
    }

    private static func sizeBucket(_ item: FileItem) -> (Double, String) {
        guard item.hasSize else { return (0, item.isFolderLike ? "Folders" : "Packages") }
        switch item.size {
        case 0: return (1, "Empty")
        case ..<16_384: return (2, "Tiny (< 16 KB)")
        case ..<1_048_576: return (3, "Small (< 1 MB)")
        case ..<134_217_728: return (4, "Medium (< 128 MB)")
        case ..<1_073_741_824: return (5, "Large (< 1 GB)")
        default: return (6, "Huge (≥ 1 GB)")
        }
    }
}

enum FileSorting {

    /// Sorting with direct comparisons: `sort(using:)` with KeyPathComparator is ~4× slower on big folders.
    static func sort(_ items: inout [FileItem], by order: [KeyPathComparator<FileItem>]) {
        guard let first = order.first else { return }
        let ascending = first.order == .forward
        func ordered(_ result: ComparisonResult) -> Bool { ascending ? result == .orderedAscending : result == .orderedDescending }
        func byName(_ a: FileItem, _ b: FileItem) -> ComparisonResult { a.name.localizedStandardCompare(b.name) }
        let compare: (FileItem, FileItem) -> ComparisonResult
        switch first.keyPath {
        case \FileItem.name: compare = byName
        case \FileItem.modified: compare = { $0.modified == $1.modified ? byName($0, $1) : ($0.modified < $1.modified ? .orderedAscending : .orderedDescending) }
        case \FileItem.created: compare = { $0.created == $1.created ? byName($0, $1) : ($0.created < $1.created ? .orderedAscending : .orderedDescending) }
        case \FileItem.sizeKey: compare = { $0.sizeKey == $1.sizeKey ? byName($0, $1) : ($0.sizeKey < $1.sizeKey ? .orderedAscending : .orderedDescending) }
        case \FileItem.kind:
            compare = { let r = $0.kind.localizedStandardCompare($1.kind); return r == .orderedSame ? byName($0, $1) : r }
        default:
            items.sort(using: order)
            return
        }
        items.sort { ordered(compare($0, $1)) }
    }
}
