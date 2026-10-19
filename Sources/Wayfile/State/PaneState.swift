import AppKit
import Foundation
import Observation

/// One file browser pane: a location, its history, contents and view settings.
@MainActor
@Observable
final class PaneState: Identifiable {
    let id = UUID()

    private(set) var location: Location
    private(set) var backStack: [Location] = []
    private(set) var forwardStack: [Location] = []

    private(set) var items: [FileItem] = [] { didSet { updateDisplayed() } }
    private(set) var displayedItems: [FileItem] = []
    /// `displayedItems` split into sections according to `groupBy` (a single untitled group when off).
    private(set) var groups: [ItemGroup] = []
    var selection: Set<URL> = []

    var sortOrder: [KeyPathComparator<FileItem>] = [KeyPathComparator(\FileItem.name)] {
        didSet { updateDisplayed(reorder: true); saveViewSettings() }
    }
    var foldersFirst = true { didSet { updateDisplayed(reorder: true); saveViewSettings() } }
    var groupBy: GroupBy = .none { didSet { updateDisplayed(reorder: true); saveViewSettings() } }
    var groupDescending = false { didSet { updateDisplayed(reorder: true); saveViewSettings() } }
    /// Bumped when the whole order changes (sort, grouping): lists reload instead of animating thousands of
    /// row moves, which SwiftUI's Table does row by row (tens of seconds for a few thousand items).
    private(set) var orderGeneration = 0
    var iconSize: Double = 64 { didSet { saveViewSettings() } }
    var showHidden = false { didSet { updateDisplayed() } }
    var filterText = "" { didSet { updateDisplayed() } }
    var layout: LayoutMode = .details {
        didSet {
            saveViewSettings()
            guard layout == .columns, oldValue != .columns else { return }
            columnsAnchor = nil
            updateColumnsAnchor()
        }
    }

    static let iconSizeRange: ClosedRange<Double> = 32...160

    var viewSettings: ViewSettings {
        let first = sortOrder.first
        return ViewSettings(
            layout: layout,
            sortField: SortField(comparator: first),
            ascending: first?.order != .reverse,
            foldersFirst: foldersFirst,
            groupBy: groupBy,
            groupDescending: groupDescending,
            iconSize: iconSize
        )
    }

    var hasCustomViewSettings: Bool {
        ViewSettingsStore.shared.hasCustomSettings(for: location.folderURL)
    }

    /// Leftmost folder shown in Columns layout; columns run from here down to `location`.
    private(set) var columnsAnchor: URL?

    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var git: GitInfo?
    private(set) var freeSpace: Int64?

    @ObservationIgnored private var watcher: FolderMonitor?
    /// Location the current `items` belong to (a reload of it doesn't stream).
    @ObservationIgnored private var loadedLocation: Location?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var pendingReload: DispatchWorkItem?
    @ObservationIgnored private var isApplyingViewSettings = false
    /// Re-runs searches periodically so saved searches and Smart Collections stay live.
    @ObservationIgnored private var liveRefresh: Task<Void, Never>?

    init(location: Location = .home, showHidden: Bool = false) {
        self.location = location
        self.showHidden = showHidden
        applyViewSettings()
        load()
    }

    // MARK: View settings

    /// Loads the remembered settings for the current folder (or the defaults).
    func applyViewSettings() {
        let settings = ViewSettingsStore.shared.settings(for: location.folderURL)
        isApplyingViewSettings = true
        defer { isApplyingViewSettings = false }
        // Columns is a browsing mode: drilling down shouldn't kick you out of it.
        if layout != .columns || location.folderURL == nil { layout = settings.layout }
        sortOrder = [settings.sortField.comparator(ascending: settings.ascending)]
        foldersFirst = settings.foldersFirst
        groupBy = settings.groupBy
        groupDescending = settings.groupDescending
        iconSize = settings.iconSize
    }

    private func saveViewSettings() {
        guard !isApplyingViewSettings, let folder = location.folderURL else { return }
        ViewSettingsStore.shared.save(viewSettings, for: folder)
    }

    func useViewSettingsAsDefault() {
        ViewSettingsStore.shared.makeDefault(viewSettings)
    }

    func resetViewSettings() {
        guard let folder = location.folderURL else { return }
        ViewSettingsStore.shared.reset(folder)
        applyViewSettings()
    }

    var selectedItems: [FileItem] {
        displayedItems.filter { selection.contains($0.url) }
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool {
        guard let url = location.folderURL else { return false }
        return url.path != "/"
    }

    // MARK: Navigation

    func navigate(to newLocation: Location) {
        guard newLocation != location else { return }
        backStack.append(location)
        forwardStack.removeAll()
        setLocation(newLocation)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(location)
        setLocation(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(location)
        setLocation(next)
    }

    func goUp() {
        guard canGoUp, let url = location.folderURL else { return }
        let child = url
        navigate(to: .folderAt(url.deletingLastPathComponent()))
        // Select the folder we came from, like Explorer/Finder do.
        selection = [child]
    }

    /// Changes search filters in place, without a history entry per keystroke.
    func updateSearch(_ query: SearchQuery) {
        guard case .search(let current) = location, current != query else { return }
        location = .search(query)
        selection = []
        load()
    }

    /// Called after every location change (used for synchronized navigation between panes).
    @ObservationIgnored var onNavigate: ((PaneState, Location, Location) -> Void)?

    private func setLocation(_ newLocation: Location) {
        let old = location
        defer { onNavigate?(self, old, newLocation) }
        location = newLocation
        applyViewSettings()
        updateColumnsAnchor()
        selection = []
        filterText = ""
        items = []
        load()
    }

    /// Folders from the columns anchor down to the current folder (inclusive), one per column.
    var columnFolders: [URL] {
        guard let current = location.folderURL else { return [] }
        guard let anchor = columnsAnchor else { return [current] }
        var chain: [URL] = []
        var url = current
        while true {
            chain.insert(url, at: 0)
            if url.path == anchor.path || url.path == "/" { break }
            url = url.deletingLastPathComponent().normalizedDirectory
        }
        return chain
    }

    /// Keeps the anchor while navigating inside it; jumping elsewhere starts a fresh column set.
    private func updateColumnsAnchor() {
        guard let current = location.folderURL else {
            columnsAnchor = nil
            return
        }
        if let anchor = columnsAnchor,
           current.path == anchor.path || current.path.hasPrefix(anchor.path == "/" ? "/" : anchor.path + "/") {
            return
        }
        columnsAnchor = current
    }

    // MARK: Loading

    func reload() { load() }

    private func scheduleReload(after delay: TimeInterval = 0.15) {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.load() }
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func load() {
        loadTask?.cancel()
        watcher = nil
        errorMessage = nil
        let loc = location

        switch loc {
        case .home, .timeline, .activity:
            items = []
            isLoading = false
            git = nil
            freeSpace = nil
            return
        case .folder(let url):
            watcher = FolderMonitor(url) { [weak self] in
                MainActor.assumeIsolated { self?.scheduleReload() }
            }
        case .search(let query):
            // Searches inside a folder follow changes there; everywhere-searches refresh periodically.
            if let root = query.scope.root, query.engine == .scan || !(query.metadata ?? "").isEmpty {
                let recursive: Bool
                if case .subfolders = query.scope { recursive = true } else { recursive = false }
                watcher = FolderMonitor(root, recursive: recursive) { [weak self] in
                    MainActor.assumeIsolated { self?.scheduleReload(after: 1.5) }
                }
            }
            fallthrough
        case .tag:
            liveRefresh?.cancel()
            liveRefresh = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self, self.location == loc else { return }
                self.load()
            }
        }

        isLoading = true
        // Opening a folder streams it in (big folders appear at once); reloads swap the list when ready.
        let streams = loadedLocation != loc
        loadedLocation = loc
        loadTask = Task { [weak self] in
            if streams, case .folder(let url) = loc {
                var all: [FileItem] = []
                var index: [URL: Int] = [:]
                do {
                    for try await event in FileSystem.listProgressively(url) {
                        guard let self, !Task.isCancelled, self.location == loc else { return }
                        switch event {
                        case .items(let batch):
                            for item in batch { index[item.url] = all.count; all.append(item) }
                        case .details(let batch):
                            for item in batch { if let i = index[item.url] { all[i] = item } }
                        }
                        self.items = self.applyGit(all)
                    }
                    guard let self, !Task.isCancelled, self.location == loc else { return }
                    if all.isEmpty { self.items = [] }
                    self.isLoading = false
                    self.selection.formIntersection(all.map(\.url))
                } catch {
                    guard let self, self.location == loc else { return }
                    self.isLoading = false
                    self.items = []
                    self.errorMessage = error.localizedDescription
                }
            } else {
                let result = await PaneState.fetch(loc)
                guard let self, !Task.isCancelled, self.location == loc else { return }
                self.isLoading = false
                switch result {
                case .success(let items):
                    // Reuse the last git info so status columns don't blink while it refreshes.
                    self.items = self.applyGit(items)
                    self.selection.formIntersection(items.map(\.url))
                case .failure(let error):
                    self.items = []
                    self.errorMessage = error.localizedDescription
                }
            }
            guard let self, !Task.isCancelled, self.location == loc else { return }
            if let url = loc.folderURL {
                self.freeSpace = FileSystem.availableSpace(at: url)
                let info = await Git.info(for: url)
                guard self.location == loc, !Task.isCancelled else { return }
                if info != self.git {
                    self.git = info
                    self.items = self.applyGit(self.items)
                }
            } else {
                self.git = nil
                self.freeSpace = nil
            }
        }
    }

    private func applyGit(_ items: [FileItem]) -> [FileItem] {
        guard let git, location.folderURL != nil else {
            return items.contains { $0.gitStatus != nil || $0.lastCommit != nil }
                ? items.map { var item = $0; item.gitStatus = nil; item.lastCommit = nil; return item }
                : items
        }
        return items.map { item in
            var item = item
            item.gitStatus = git.statuses[item.name]
            item.lastCommit = git.commits[item.name]
            return item
        }
    }

    nonisolated private static func fetch(_ location: Location) async -> Result<[FileItem], Error> {
        switch location {
        case .home, .timeline, .activity:
            return .success([])
        case .folder(let url):
            return await Task.detached(priority: .userInitiated) {
                Result { try FileSystem.list(url) }
            }.value
        case .search(let query):
            let urls = await SearchEngine.run(query)
            return .success(await Task.detached { urls.compactMap(FileItem.init(url:)) }.value)
        case .tag(let name):
            let urls = await Spotlight.files(taggedWith: name)
            return .success(await Task.detached { urls.compactMap(FileItem.init(url:)) }.value)
        }
    }

    /// Lists at least this big are sorted and grouped off the main thread (locale-aware name sorting of
    /// 30k items takes ~0.5 s, which would freeze the window).
    static let backgroundArrangeThreshold = 3000
    @ObservationIgnored private var arrangeGeneration = 0

    private func updateDisplayed(reorder: Bool = false) {
        arrangeGeneration += 1
        let options = ArrangeOptions(showHidden: showHidden, filter: filterText, sortOrder: sortOrder, foldersFirst: foldersFirst,
                                     groupBy: groupBy, groupDescending: groupDescending)
        guard items.count >= Self.backgroundArrangeThreshold else {
            (groups, displayedItems) = Self.layout(items, options)
            if reorder { orderGeneration += 1 }
            return
        }
        let generation = arrangeGeneration
        let snapshot = items
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { PaneState.layout(snapshot, options) }.value
            // A newer change may have started its own pass meanwhile.
            guard let self, self.arrangeGeneration == generation else { return }
            (self.groups, self.displayedItems) = result
            if reorder { self.orderGeneration += 1 }
        }
    }

    struct ArrangeOptions: Sendable {
        var showHidden: Bool
        var filter: String
        var sortOrder: [KeyPathComparator<FileItem>]
        var foldersFirst: Bool
        var groupBy: GroupBy
        var groupDescending: Bool
    }

    nonisolated static func layout(_ items: [FileItem], _ options: ArrangeOptions) -> ([ItemGroup], [FileItem]) {
        let arranged = arrange(items, options)
        let groups = Grouping.groups(arranged, by: options.groupBy, descending: options.groupDescending)
        // Keep the flat order identical to the on-screen (grouped) order.
        return (groups, options.groupBy == .none ? arranged : groups.flatMap(\.items))
    }

    /// Applies this pane's hidden-file, filter and sort settings to a listing.
    func arrange(_ items: [FileItem], filter: String = "") -> [FileItem] {
        Self.arrange(items, ArrangeOptions(showHidden: showHidden, filter: filter, sortOrder: sortOrder, foldersFirst: foldersFirst,
                                           groupBy: .none, groupDescending: false))
    }

    nonisolated static func arrange(_ items: [FileItem], _ options: ArrangeOptions) -> [FileItem] {
        var result = items
        if !options.showHidden { result.removeAll(where: \.isHidden) }
        let filter = options.filter.trimmingCharacters(in: .whitespaces)
        if !filter.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        }
        FileSorting.sort(&result, by: options.sortOrder)
        if options.foldersFirst {
            result = result.filter(\.isFolderLike) + result.filter { !$0.isFolderLike }
        }
        return result
    }
}
