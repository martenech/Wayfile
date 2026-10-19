import AppKit
import Foundation
import Observation

/// Watches a single directory for changes (create, delete, rename, modify).
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, onChange: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend, .attrib], queue: .main
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}

@MainActor
@Observable
final class PinnedStore {
    static let shared = PinnedStore()

    private static let defaultsKey = "pinnedFolders"

    private(set) var folders: [URL] = []

    private init() {
        if let paths = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) {
            folders = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        } else {
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser
            folders = ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies"]
                .map { home.appendingPathComponent($0, isDirectory: true) }
                .filter { fm.fileExists(atPath: $0.path) }
                + [URL(fileURLWithPath: "/Applications", isDirectory: true)]
        }
    }

    func isPinned(_ url: URL) -> Bool {
        folders.contains { $0.standardizedFileURL.path == url.standardizedFileURL.path }
    }

    func pin(_ url: URL) {
        guard !isPinned(url) else { return }
        folders.append(url.normalizedDirectory)
        save()
    }

    func unpin(_ url: URL) {
        folders.removeAll { $0.standardizedFileURL.path == url.standardizedFileURL.path }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        folders.move(fromOffsets: source, toOffset: destination)
        save()
    }

    private func save() {
        UserDefaults.standard.set(folders.map(\.path), forKey: Self.defaultsKey)
    }

    static func symbol(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        switch url.standardizedFileURL.path {
        case home: return "house"
        case home + "/Desktop": return "menubar.dock.rectangle"
        case home + "/Documents": return "doc"
        case home + "/Downloads": return "arrow.down.circle"
        case home + "/Pictures": return "photo"
        case home + "/Music": return "music.note"
        case home + "/Movies": return "film"
        case "/Applications": return "square.grid.2x2"
        default: return "folder"
        }
    }
}

struct Volume: Identifiable, Hashable {
    let url: URL
    let name: String
    let total: Int64
    let available: Int64
    let isEjectable: Bool
    let isLocal: Bool
    let isInternal: Bool

    var id: URL { url }
    var used: Int64 { max(total - available, 0) }

    var symbol: String {
        if !isLocal { return "network" }
        return isInternal ? "internaldrive" : "externaldrive"
    }
}

@MainActor
@Observable
final class VolumeStore {
    static let shared = VolumeStore()

    private(set) var volumes: [Volume] = []

    private static let keys: [URLResourceKey] = [
        .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey, .volumeIsInternalKey,
    ]

    private init() {
        reload()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
    }

    func reload() {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Self.keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(Self.keys)) else { return nil }
            return Volume(
                url: url.normalizedDirectory,
                name: v.volumeLocalizedName ?? url.lastPathComponent,
                total: Int64(v.volumeTotalCapacity ?? 0),
                available: v.volumeAvailableCapacityForImportantUsage ?? 0,
                isEjectable: (v.volumeIsEjectable ?? false) || (v.volumeIsRemovable ?? false) || !(v.volumeIsLocal ?? true),
                isLocal: v.volumeIsLocal ?? true,
                isInternal: v.volumeIsInternal ?? false
            )
        }
    }

    func eject(_ volume: Volume) throws {
        try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
    }
}

struct CloudLocation: Identifiable, Hashable {
    let url: URL
    let name: String
    let symbol: String

    var id: URL { url }
}

/// iCloud Drive plus File Provider folders (Google Drive, OneDrive, Dropbox, Box…) in ~/Library/CloudStorage.
@MainActor
@Observable
final class CloudStore {
    static let shared = CloudStore()

    private(set) var locations: [CloudLocation] = []

    private init() {
        reload()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        let fm = FileManager.default
        let library = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        var result: [CloudLocation] = []

        let iCloud = library.appendingPathComponent("Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if fm.fileExists(atPath: iCloud.path) {
            result.append(CloudLocation(url: iCloud.normalizedDirectory, name: "iCloud Drive", symbol: "icloud"))
        }

        let storage = library.appendingPathComponent("CloudStorage", isDirectory: true)
        let providers = (try? fm.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for url in providers.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where FileSystem.isDirectory(url) {
            result.append(CloudLocation(url: url.normalizedDirectory, name: Self.displayName(url.lastPathComponent), symbol: "cloud"))
        }
        locations = result
    }

    /// "GoogleDrive-me@example.com" → "Google Drive (me@example.com)", "OneDrive-Personal" → "OneDrive Personal".
    static func displayName(_ folder: String) -> String {
        let parts = folder.split(separator: "-", maxSplits: 1).map(String.init)
        let providers = ["GoogleDrive": "Google Drive", "OneDrive": "OneDrive", "Dropbox": "Dropbox", "Box": "Box", "pCloudDrive": "pCloud", "ProtonDrive": "Proton Drive"]
        let provider = providers[parts[0]] ?? parts[0]
        guard parts.count > 1, !parts[1].isEmpty else { return provider }
        return parts[1].contains("@") ? "\(provider) (\(parts[1]))" : "\(provider) \(parts[1])"
    }
}

enum RowDensity: String, CaseIterable, Identifiable {
    case compact, regular, comfortable
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var iconSize: CGFloat { self == .compact ? 16 : self == .regular ? 18 : 22 }
    var verticalPadding: CGFloat { self == .compact ? 0 : self == .regular ? 1 : 4 }
}

enum StartupBehavior: String, CaseIterable, Identifiable {
    case home, restore, folder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return String(localized: "Open Home")
        case .restore: return String(localized: "Continue where you left off")
        case .folder: return String(localized: "Open a specific folder")
        }
    }
}

/// App preferences shown in the Settings window.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    var startup: StartupBehavior {
        didSet { UserDefaults.standard.set(startup.rawValue, forKey: "startup") }
    }
    var startupFolder: URL? {
        didSet { UserDefaults.standard.set(startupFolder?.path, forKey: "startupFolder") }
    }
    var showHiddenByDefault: Bool {
        didSet { UserDefaults.standard.set(showHiddenByDefault, forKey: "showHiddenByDefault") }
    }
    var vimMode: Bool {
        didSet { UserDefaults.standard.set(vimMode, forKey: "vimMode") }
    }
    var rowDensity: RowDensity {
        didSet { UserDefaults.standard.set(rowDensity.rawValue, forKey: "rowDensity") }
    }
    var compactStatusBar: Bool {
        didSet { UserDefaults.standard.set(compactStatusBar, forKey: "compactStatusBar") }
    }
    /// Compare checksums of originals and copies after copying (slower, catches bad disks/cables).
    var verifyCopies: Bool {
        didSet { UserDefaults.standard.set(verifyCopies, forKey: "verifyCopies") }
    }
    /// Last folders used with Copy To… / Move To…, most recent first.
    var recentDestinations: [URL] {
        didSet { UserDefaults.standard.set(recentDestinations.map(\.path), forKey: "recentDestinations") }
    }
    /// Sidebar shows only tags that are on at least one file (default) instead of all of Finder's tags.
    var sidebarShowsUsedTagsOnly: Bool {
        didSet { UserDefaults.standard.set(!sidebarShowsUsedTagsOnly, forKey: "sidebarShowsAllFinderTags") }
    }
    /// Finder behaviour: Return renames, ⌘↓ / double-click opens. Off (default) is Files/Windows: Return opens.
    var returnKeyRenames: Bool {
        didSet { UserDefaults.standard.set(returnKeyRenames, forKey: "returnKeyRenames") }
    }
    /// Small Quick Look / Copy Path / Trash buttons on the row under the pointer.
    var hoverActions: Bool {
        didSet { UserDefaults.standard.set(hoverActions, forKey: "hoverActions") }
    }

    private init() {
        let ud = UserDefaults.standard
        startup = ud.string(forKey: "startup").flatMap(StartupBehavior.init(rawValue:)) ?? .restore
        startupFolder = ud.string(forKey: "startupFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
        showHiddenByDefault = ud.bool(forKey: "showHiddenByDefault")
        returnKeyRenames = ud.bool(forKey: "returnKeyRenames")
        hoverActions = ud.bool(forKey: "hoverActions")
        verifyCopies = ud.bool(forKey: "verifyCopies")
        vimMode = ud.bool(forKey: "vimMode")
        rowDensity = ud.string(forKey: "rowDensity").flatMap(RowDensity.init(rawValue:)) ?? .regular
        compactStatusBar = ud.bool(forKey: "compactStatusBar")
        recentDestinations = (ud.stringArray(forKey: "recentDestinations") ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        sidebarShowsUsedTagsOnly = !ud.bool(forKey: "sidebarShowsAllFinderTags")
    }
}

/// The open tabs of a window, saved so the next launch can continue where the user left off.
struct Session: Codable, Equatable {
    struct Tab: Codable, Equatable {
        var panes: [Location]
        var activePane: Int
    }

    var tabs: [Tab]
    var selectedTab: Int
    var showPreviewPane: Bool

    private static let key = "lastSession"

    static func load() -> Session? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    /// Drops locations that no longer exist (unplugged drives, deleted folders).
    var validated: Session {
        var copy = self
        copy.tabs = tabs.map { tab in
            var tab = tab
            tab.panes = tab.panes.map { location in
                if let url = location.folderURL, !FileSystem.isDirectory(url) { return .home }
                if case .search(let query) = location, let root = query.scope.root, !FileSystem.isDirectory(root) { return .home }
                return location
            }
            return tab
        }
        return copy
    }
}

struct SavedSearch: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var query: SearchQuery
}

/// Named searches shown in the sidebar.
@MainActor
@Observable
final class SavedSearchStore {
    static let shared = SavedSearchStore()

    private static let key = "savedSearches"

    private(set) var searches: [SavedSearch]

    private init() {
        searches = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([SavedSearch].self, from: $0) } ?? []
    }

    func add(_ name: String, query: SearchQuery) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        searches.append(SavedSearch(name: trimmed.isEmpty ? query.title : trimmed, query: query))
        save()
    }

    func remove(_ search: SavedSearch) {
        searches.removeAll { $0.id == search.id }
        save()
    }

    func search(matching query: SearchQuery) -> SavedSearch? {
        searches.first { $0.query == query }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(searches), forKey: Self.key)
    }
}

/// Temporary shelf for collecting files from several places before copying or moving them together.
@MainActor
@Observable
final class DropStackStore {
    static let shared = DropStackStore()

    private static let key = "dropStack"

    private(set) var items: [URL]
    var isVisible: Bool {
        didSet { UserDefaults.standard.set(isVisible, forKey: "dropStackVisible") }
    }

    private init() {
        items = (UserDefaults.standard.stringArray(forKey: Self.key) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        isVisible = UserDefaults.standard.bool(forKey: "dropStackVisible")
    }

    func add(_ urls: [URL]) {
        let existing = Set(items.map(\.standardizedFileURL.path))
        items += urls.filter { !existing.contains($0.standardizedFileURL.path) }
        isVisible = true
        save()
    }

    func remove(_ urls: [URL]) {
        let removed = Set(urls.map(\.standardizedFileURL.path))
        items.removeAll { removed.contains($0.standardizedFileURL.path) }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    /// Drops entries whose files no longer exist (moved or deleted elsewhere).
    func prune() {
        let before = items.count
        items.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        if items.count != before { save() }
    }

    private func save() {
        UserDefaults.standard.set(items.map(\.path), forKey: Self.key)
    }
}

/// A named, saved window layout: tabs, panes and their folders, sidebar and inspector visibility.
struct Workspace: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var session: Session
    var sidebarVisible: Bool
    var created = Date()
}

@MainActor
@Observable
final class WorkspaceStore {
    static let shared = WorkspaceStore()

    private static let key = "workspaces"

    private(set) var workspaces: [Workspace]

    private init() {
        workspaces = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([Workspace].self, from: $0) } ?? []
    }

    func save(_ workspace: Workspace) {
        if let index = workspaces.firstIndex(where: { $0.name.lowercased() == workspace.name.lowercased() }) {
            workspaces[index] = Workspace(id: workspaces[index].id, name: workspace.name, session: workspace.session,
                                          sidebarVisible: workspace.sidebarVisible)
        } else {
            workspaces.append(workspace)
        }
        persist()
    }

    func remove(_ workspace: Workspace) {
        workspaces.removeAll { $0.id == workspace.id }
        persist()
    }

    func rename(_ workspace: Workspace, to name: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces[index].name = name
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(workspaces), forKey: Self.key)
    }
}
