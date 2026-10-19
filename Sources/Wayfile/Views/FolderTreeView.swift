import SwiftUI

/// Remembers which folders are expanded in the tree (shared by windows, kept across launches).
@MainActor
@Observable
final class FolderTreeStore {
    static let shared = FolderTreeStore()

    private(set) var expanded: Set<String>
    /// Loaded subfolders by folder path; missing means not loaded yet.
    private(set) var children: [String: [URL]] = [:]

    private init() {
        var saved = Set(UserDefaults.standard.stringArray(forKey: "folderTree.expanded") ?? [])
        // Earlier versions revealed from the disk root, which opened a second copy of the home folder
        // under Macintosh HD › Users. Close those automatic expansions once.
        if !UserDefaults.standard.bool(forKey: "folderTree.cleanedHomeAncestors") {
            UserDefaults.standard.set(true, forKey: "folderTree.cleanedHomeAncestors")
            var ancestor = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
            while true {
                saved.remove(ancestor.path)
                if ancestor.path == "/" { break }
                ancestor = ancestor.deletingLastPathComponent()
            }
            UserDefaults.standard.set(Array(saved), forKey: "folderTree.expanded")
        }
        expanded = saved
    }

    func isExpanded(_ url: URL) -> Bool { expanded.contains(url.standardizedFileURL.path) }

    func setExpanded(_ url: URL, _ value: Bool) {
        let path = url.standardizedFileURL.path
        if value { expanded.insert(path) } else { expanded.remove(path) }
        UserDefaults.standard.set(Array(expanded), forKey: "folderTree.expanded")
    }

    /// Expands every ancestor of `url` and loads their children top-down, so the current folder
    /// becomes a visible row no matter what the list has rendered so far.
    /// Only folders below the closest root are opened (a folder in Home opens under Home, not again
    /// under Macintosh HD › Users).
    func reveal(_ url: URL, roots: [URL], showHidden: Bool) async {
        let target = url.standardizedFileURL.path
        let root = roots.map { $0.standardizedFileURL.path }
            .filter { target == $0 || target.hasPrefix($0 == "/" ? "/" : $0 + "/") }
            .max { $0.count < $1.count }
        guard let root else { return }
        var ancestors: [URL] = []
        var current = url.standardizedFileURL.deletingLastPathComponent()
        while current.path.count >= root.count && (current.path == root || current.path.hasPrefix(root == "/" ? "/" : root + "/")) {
            ancestors.insert(current, at: 0)
            if current.path == root || current.path == "/" { break }
            current = current.deletingLastPathComponent()
        }
        var changed = false
        for ancestor in ancestors where expanded.insert(ancestor.path).inserted { changed = true }
        if changed { UserDefaults.standard.set(Array(expanded), forKey: "folderTree.expanded") }
        for ancestor in ancestors { await load(ancestor, showHidden: showHidden) }
    }

    func load(_ url: URL, showHidden: Bool, force: Bool = false) async {
        let path = url.standardizedFileURL.path
        guard force || children[path] == nil else { return }
        let found = await Task.detached { FolderTreeStore.subfolders(of: url, showHidden: showHidden) }.value
        children[path] = found
    }

    func invalidate() { children.removeAll() }

    /// Depth-first list of rows currently visible (roots plus expanded descendants).
    func visibleRows(roots: [URL]) -> [(url: URL, depth: Int)] {
        var rows: [(URL, Int)] = []
        func visit(_ url: URL, _ depth: Int) {
            rows.append((url, depth))
            guard isExpanded(url), let kids = children[url.standardizedFileURL.path] else { return }
            for kid in kids { visit(kid, depth + 1) }
        }
        roots.forEach { visit($0, 0) }
        return rows
    }

    /// Subfolders shown in the tree: visible folders only, no packages (.app etc.), sorted like Finder.
    nonisolated static func subfolders(of url: URL, showHidden: Bool) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                  options: showHidden ? [] : [.skipsHiddenFiles])) ?? []
        return urls.filter { child in
            guard let v = try? child.resourceValues(forKeys: Set(keys)) else { return false }
            return v.isDirectory == true && v.isPackage != true
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

/// Expandable folder outline: Home and every mounted volume. A flat, lazily rendered list of
/// visible rows; subfolders load when a folder is expanded.
struct FolderTreeView: View {
    let state: WindowState

    private var store: FolderTreeStore { .shared }

    private var roots: [URL] {
        [FileManager.default.homeDirectoryForCurrentUser.normalizedDirectory] + VolumeStore.shared.volumes.map(\.url)
    }

    var body: some View {
        let rows = store.visibleRows(roots: roots)
        ScrollViewReader { proxy in
            List {
                ForEach(rows, id: \.url) { row in
                    FolderTreeRow(state: state, url: row.url, depth: row.depth)
                        .id(row.url.standardizedFileURL.path)
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                }
            }
            .listStyle(.sidebar)
            .themedSidebar()
            .task(id: Set(rows.map(\.url.path))) {
                // Load children of every expanded visible folder (cheap, cached).
                for row in rows where store.isExpanded(row.url) {
                    await store.load(row.url, showHidden: state.showHidden)
                }
            }
            .onChange(of: state.showHidden) { store.invalidate() }
            .onChange(of: state.activePane.location.folderURL) { _, folder in
                guard let folder else { return }
                Task {
                    await store.reveal(folder, roots: roots, showHidden: state.showHidden)
                    withAnimation { proxy.scrollTo(folder.standardizedFileURL.path, anchor: .center) }
                }
            }
            .task {
                guard let folder = state.activePane.location.folderURL else { return }
                await store.reveal(folder, roots: roots, showHidden: state.showHidden)
                proxy.scrollTo(folder.standardizedFileURL.path, anchor: .center)
            }
        }
    }
}

private struct FolderTreeRow: View {
    let state: WindowState
    let url: URL
    let depth: Int

    private var store: FolderTreeStore { .shared }
    private var isCurrent: Bool { state.activePane.location.folderURL?.standardizedFileURL.path == url.standardizedFileURL.path }

    var body: some View {
        let expanded = store.isExpanded(url)
        let known = store.children[url.standardizedFileURL.path]
        HStack(spacing: 4) {
            Button {
                store.setExpanded(url, !expanded)
                if !expanded { Task { await store.load(url, showHidden: state.showHidden) } }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 14, height: 18)
                    .contentShape(Rectangle())
                    .opacity(known?.isEmpty == true ? 0 : 1)
            }
            .buttonStyle(.plain)
            Image(nsImage: IconCache.icon(for: url)).resizable().frame(width: 16, height: 16)
            Text(depth == 0 ? url.displayName : url.lastPathComponent)
                .lineLimit(1)
                .fontWeight(isCurrent ? .semibold : .regular)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 12)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 5).fill(isCurrent ? Color.themeAccent.opacity(0.18) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { state.activePane.navigate(to: .folderAt(url)) }
        .dropDestination(for: URL.self) { urls, _ in state.drop(urls, into: url) }
        .contextMenu {
            Button("Open in New Tab") { state.newTab(.folderAt(url)) }
            Button("Open in Other Pane") { state.openInOtherPane(url) }
            Button("Open in Terminal") { state.openInTerminal(url) }
            Divider()
            Button(PinnedStore.shared.isPinned(url) ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites")) {
                if PinnedStore.shared.isPinned(url) { PinnedStore.shared.unpin(url) } else { PinnedStore.shared.pin(url) }
            }
            Button("Refresh") { Task { await store.load(url, showHidden: state.showHidden, force: true) } }
        }
    }
}
