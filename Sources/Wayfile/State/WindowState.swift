import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class TabState: Identifiable {
    let id = UUID()
    private(set) var panes: [PaneState]
    var activePaneID: UUID

    init(location: Location, showHidden: Bool) {
        let pane = PaneState(location: location, showHidden: showHidden)
        panes = [pane]
        activePaneID = pane.id
        hookPanes()
    }

    init(session tab: Session.Tab, showHidden: Bool) {
        let restored = (tab.panes.isEmpty ? [.home] : Array(tab.panes.prefix(4))).map { PaneState(location: $0, showHidden: showHidden) }
        panes = restored
        activePaneID = restored[min(max(tab.activePane, 0), restored.count - 1)].id
        hookPanes()
    }

    var session: Session.Tab {
        Session.Tab(panes: panes.map(\.location), activePane: panes.firstIndex { $0.id == activePaneID } ?? 0)
    }

    var activePane: PaneState {
        panes.first { $0.id == activePaneID } ?? panes[0]
    }

    /// More than one pane (dual or quad).
    var isDualPane: Bool { panes.count > 1 }
    var isQuad: Bool { panes.count == 4 }

    var title: String { activePane.location.title }

    /// In dual mode the other pane; in quad mode the pane beside the active one (same row).
    private func partner(of pane: PaneState) -> PaneState? {
        guard let index = panes.firstIndex(where: { $0.id == pane.id }), panes.count > 1 else { return nil }
        let other = panes.count == 4 ? index ^ 1 : 1 - index
        return panes.indices.contains(other) ? panes[other] : nil
    }

    /// The pane that isn't active, creating a second pane if needed.
    func otherPane() -> PaneState {
        if !isDualPane { setPaneCount(2) }
        return partner(of: activePane) ?? panes[0]
    }

    /// The partner pane when there are several, without creating one.
    var inactivePane: PaneState? { partner(of: activePane) }

    func toggleDualPane() {
        setPaneCount(isDualPane ? 1 : 2)
    }

    /// 1, 2 or 4 panes; new panes start at the active pane's location.
    func setPaneCount(_ count: Int) {
        let count = [1, 2, 4].contains(count) ? count : 1
        if panes.count > count {
            let keepActive = panes.firstIndex { $0.id == activePaneID }.map { $0 < count } ?? false
            panes = Array(panes.prefix(count))
            if !keepActive { activePaneID = panes[0].id }
        } else {
            let current = activePane
            while panes.count < count {
                panes.append(PaneState(location: current.location, showHidden: current.showHidden))
            }
        }
        if panes.count == 1 { isSynced = false }
        hookPanes()
    }

    // MARK: Synchronized navigation

    /// When on, stepping into a subfolder or up in one pane does the same in the others (if possible).
    var isSynced = false
    @ObservationIgnored private var isSyncing = false

    private func hookPanes() {
        for pane in panes {
            pane.onNavigate = { [weak self] pane, old, new in self?.paneDidNavigate(pane, from: old, to: new) }
        }
    }

    private func paneDidNavigate(_ pane: PaneState, from old: Location, to new: Location) {
        guard isSynced, !isSyncing, let from = old.folderURL?.standardizedFileURL, let to = new.folderURL?.standardizedFileURL else { return }
        isSyncing = true
        defer { isSyncing = false }
        let descended = to.deletingLastPathComponent().path == from.path
        let ascended = from.deletingLastPathComponent().path == to.path
        guard descended || ascended else { return }
        for other in panes where other.id != pane.id {
            guard let folder = other.location.folderURL?.standardizedFileURL else { continue }
            let target = descended ? folder.appendingPathComponent(to.lastPathComponent) : folder.deletingLastPathComponent()
            if FileSystem.isDirectory(target) { other.navigate(to: .folderAt(target)) }
        }
    }
}

enum NamePrompt: Identifiable, Equatable {
    case rename(URL)
    case newFolder
    case newFile(FileTemplate)
    case connectToServer
    case createBranch(URL)
    case cloneRepository
    case saveSearch(SearchQuery)
    case saveWorkspace

    var id: String {
        switch self {
        case .rename(let url): return "rename:\(url.path)"
        case .newFolder: return "newFolder"
        case .newFile(let template): return "newFile:\(template.id)"
        case .connectToServer: return "connect"
        case .createBranch(let root): return "branch:\(root.path)"
        case .cloneRepository: return "clone"
        case .saveSearch: return "saveSearch"
        case .saveWorkspace: return "saveWorkspace"
        }
    }

    var title: String {
        switch self {
        case .rename: return String(localized: "Rename")
        case .newFolder: return String(localized: "New Folder")
        case .newFile(let template): return String(localized: "New \(template.title)")
        case .connectToServer: return String(localized: "Connect to Server")
        case .createBranch: return String(localized: "New Branch")
        case .cloneRepository: return String(localized: "Clone Repository")
        case .saveSearch: return String(localized: "Save Search")
        case .saveWorkspace: return String(localized: "Save Workspace")
        }
    }

    var confirmTitle: String {
        switch self {
        case .rename: return "Rename"
        case .newFolder, .newFile: return "Create"
        case .connectToServer: return "Connect"
        case .createBranch: return "Create"
        case .cloneRepository: return "Clone"
        case .saveSearch, .saveWorkspace: return "Save"
        }
    }
}

/// Everything belonging to one window: tabs, layout toggles, prompts and the file commands.
@MainActor
@Observable
final class WindowState {
    /// The main window used last; tool windows (Automation) act on its selection.
    @ObservationIgnored weak static var lastActive: WindowState?
    /// Integrated terminal (bottom panel).
    let terminal = TerminalPanelState()

    struct OrganizeTarget: Identifiable { let folder: URL; var id: URL { folder } }
    /// Shows the "Suggest Organization" sheet for a folder.
    var organizeRequest: OrganizeTarget?

    private(set) var tabs: [TabState]
    var selectedTabID: UUID

    var showPreviewPane = true
    var isEditingPath = false
    /// Set to move keyboard focus into the search field (⌘F).
    var focusSearchField = false
    /// Keys typed so far in a Vim sequence ("g", "d"…), shown in the status bar.
    var vimPending = ""
    var showCommandPalette = false
    var showStatusCenter = false
    /// Set to ask the window to open a Properties window (views own `openWindow`).
    var propertiesRequest: PropertiesTarget?
    var batchRenameRequest: BatchRenameRequest?
    var compareRequest: CompareTarget?
    var duplicatesRequest: URL?
    /// Opens a Compare Files window.
    var textDiffRequest: DiffTarget?
    /// Opens a Git window (changes, or a file's history).
    var gitRequest: GitTarget?
    /// Shows the Connect to Server sheet.
    var showConnect = false
    struct URLsTarget: Identifiable { let urls: [URL]; let id = UUID() }
    /// Compress-with-options sheet.
    var compressRequest: URLsTarget?
    /// Broken-links sheet for a folder.
    var brokenLinksRequest: OrganizeTarget?
    /// Opens the Disk Usage window for a folder.
    var diskUsageRequest: URL?
    /// Opens an archive in the archive browser.
    var archiveRequest: URL?
    /// Recursive permissions sheet.
    var permissionsRequest: URLsTarget?
    /// New encrypted vault sheet.
    var showNewVault = false

    func runCompress(_ urls: [URL], options: CompressOptions) {
        Task {
            await run("Compressing \(Self.describe(urls))", undoTitle: "Compress", select: true) { progress in
                let archive = try await options.compress(urls)
                progress.record(.created([archive]))
                return [archive]
            }
        }
    }

    func makeLink(_ urls: [URL], hard: Bool) {
        Task {
            await run(hard ? "Creating hard links" : "Creating symbolic links", undoTitle: "Make Link", select: true) { progress in
                var made: [URL] = []
                for url in urls {
                    let link = hard ? try Links.makeHardLink(to: url) : try Links.makeSymlink(to: url)
                    progress.record(.created([link]))
                    made.append(link)
                }
                return made
            }
        }
    }

    /// Connects to a saved server and opens it in the active pane.
    func connect(_ server: SavedServer) {
        Task {
            do {
                activePane.navigate(to: .folderAt(try await ServerStore.shared.connect(server.url, username: server.username)))
            } catch {
                errorMessage = "Couldn’t connect to “\(server.name)”: \(error.localizedDescription)"
            }
        }
    }
    var logViewerRequest: URL?
    var showSelectMatching = false
    var integrityReport: IntegrityResult?
    var showHidden = false {
        didSet { tabs.flatMap(\.panes).forEach { $0.showHidden = showHidden } }
    }

    var prompt: NamePrompt?
    var promptText = ""
    var errorMessage: String?
    var quickLookURL: URL?

    init(location: Location = .home) {
        let showHidden = AppSettings.shared.showHiddenByDefault
        let tab = TabState(location: location, showHidden: showHidden)
        tabs = [tab]
        selectedTabID = tab.id
        self.showHidden = showHidden
    }

    // MARK: Session

    var session: Session {
        Session(
            tabs: tabs.map(\.session),
            selectedTab: tabs.firstIndex { $0.id == selectedTabID } ?? 0,
            showPreviewPane: showPreviewPane
        )
    }

    func open(_ workspace: Workspace) {
        restore(workspace.session)
        UserDefaults.standard.set(workspace.sidebarVisible, forKey: "sidebarVisible")
    }

    func restore(_ session: Session) {
        guard !session.tabs.isEmpty else { return }
        let restored = session.validated.tabs.map { TabState(session: $0, showHidden: showHidden) }
        tabs = restored
        selectedTabID = restored[min(max(session.selectedTab, 0), restored.count - 1)].id
        showPreviewPane = session.showPreviewPane
    }

    var selectedTab: TabState {
        tabs.first { $0.id == selectedTabID } ?? tabs[0]
    }

    var activePane: PaneState { selectedTab.activePane }

    // MARK: Tabs

    func newTab(_ location: Location = .home, select: Bool = true) {
        let tab = TabState(location: location, showHidden: showHidden)
        if let index = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        if select { selectedTabID = tab.id }
    }

    func duplicateTab(_ tab: TabState) {
        selectedTabID = tab.id
        newTab(tab.activePane.location)
    }

    func closeTab(_ tab: TabState) {
        guard tabs.count > 1 else {
            NSApp.keyWindow?.performClose(nil)
            return
        }
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if selectedTabID == tab.id {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    func closeOtherTabs(_ tab: TabState) {
        tabs = [tab]
        selectedTabID = tab.id
    }

    func closeSelectedTab() { closeTab(selectedTab) }

    func selectAdjacentTab(_ offset: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        selectedTabID = tabs[(index + offset + tabs.count) % tabs.count].id
    }

    func moveTab(_ id: UUID, before target: UUID) {
        guard id != target,
              let from = tabs.firstIndex(where: { $0.id == id }),
              let to = tabs.firstIndex(where: { $0.id == target }) else { return }
        tabs.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
    }

    // MARK: Opening

    func open(_ item: FileItem, in pane: PaneState? = nil) {
        if item.isFolderLike {
            (pane ?? activePane).navigate(to: .folderAt(item.url))
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func openSelection(in pane: PaneState? = nil) {
        let pane = pane ?? activePane
        let items = pane.selectedItems
        if items.count == 1 {
            open(items[0], in: pane)
        } else {
            // Opening several: folders become tabs, files open in their apps.
            for item in items {
                if item.isFolderLike { newTab(.folderAt(item.url), select: false) } else { NSWorkspace.shared.open(item.url) }
            }
        }
    }

    /// Return key in a file list: open (default) or rename, depending on Settings.
    func handleReturnKey(in pane: PaneState) {
        if AppSettings.shared.returnKeyRenames {
            guard pane.selection.count == 1 else { NSSound.beep(); return }
            if pane !== activePane { selectedTab.activePaneID = pane.id }
            beginRename()
        } else {
            openSelection(in: pane)
        }
    }

    func openInOtherPane(_ url: URL) {
        selectedTab.otherPane().navigate(to: .folderAt(url))
    }

    /// Folder shown in the other pane — the target of F5/F6 — when it differs from the active one.
    var otherPaneFolder: URL? {
        guard let folder = selectedTab.inactivePane?.location.folderURL,
              folder != activePane.location.folderURL else { return nil }
        return folder
    }

    var canTransferToOtherPane: Bool {
        otherPaneFolder != nil && !activePane.selection.isEmpty
    }

    /// Total Commander-style F5/F6: copy or move the selection into the other pane's folder.
    func transferToOtherPane(move: Bool) {
        guard let destination = otherPaneFolder else {
            // Single pane (or both panes on the same folder): open the second pane to pick a target.
            if !selectedTab.isDualPane { selectedTab.toggleDualPane() }
            NSSound.beep()
            return
        }
        let sources = activePane.selectedItems.map(\.url)
        guard !sources.isEmpty else { return }
        let target = selectedTab.inactivePane
        transfer(sources, to: destination, mode: move ? .move : .copy) {
            target?.reload()
        }
    }

    func openInTerminal(_ url: URL) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    func revealInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Compares a file with one picked in an open panel.
    func compareFile(_ url: URL) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = otherPaneFolder ?? url.deletingLastPathComponent()
        panel.message = String(localized: "Choose a file to compare with “\(url.lastPathComponent)”")
        guard panel.runModal() == .OK, let other = panel.url else { return }
        textDiffRequest = DiffTarget(left: .file(url), right: .file(other))
    }

    /// The same-named file in the other pane's folder, if there is one.
    func counterpart(of url: URL) -> URL? {
        guard let folder = otherPaneFolder else { return nil }
        let candidate = folder.appendingPathComponent(url.lastPathComponent)
        return candidate != url && FileManager.default.fileExists(atPath: candidate.path) && !FileSystem.isDirectory(candidate) ? candidate : nil
    }

    /// Working copy vs. index for a changed file in the active pane's repository.
    func showGitChanges(_ url: URL) {
        guard let root = activePane.git?.root else { return }
        let path = Git.relativePath(of: url, in: root)
        textDiffRequest = DiffTarget(left: .git(root: root, path: path, revision: "HEAD"), right: .file(url))
    }

    func showGitHistory(_ url: URL) {
        guard let root = activePane.git?.root else { return }
        gitRequest = GitTarget(root: root, path: Git.relativePath(of: url, in: root))
    }

    /// Copies editor links or web (GitHub / GitLab / Bitbucket) links.
    func copyDevLinks(_ urls: [URL], web: Bool) {
        guard web else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.map { DevLinks.editorURI($0) }.joined(separator: "\n"), forType: .string)
            return
        }
        guard let git = activePane.git else { return }
        Task {
            guard let remote = await Git.remoteURL(in: git.root) else {
                errorMessage = "This repository has no “origin” remote."
                return
            }
            let links = urls.compactMap {
                DevLinks.webURL(remote: remote, branch: git.branch, relativePath: Git.relativePath(of: $0, in: git.root), isDirectory: FileSystem.isDirectory($0))
            }
            guard !links.isEmpty else {
                errorMessage = "The remote “\(remote)” isn’t a web host Wayfile knows."
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
        }
    }

    /// Context for running a script on `urls` from this window.
    func scriptContext(for urls: [URL], dryRun: Bool = false) -> ScriptContext {
        ScriptContext(selection: urls, folder: activePane.location.folderURL, otherFolder: otherPaneFolder, dryRun: dryRun, ui: scriptUI)
    }

    /// What a script started from this window may do with it (panel, workspaces); held weakly.
    private var scriptUI: ScriptUI {
        ScriptUI(
            open: { [weak self] url in self?.activePane.navigate(to: .folderAt(url)) },
            refresh: { [weak self] in self?.reloadAll() },
            select: { [weak self] urls in
                guard let pane = self?.activePane else { return }
                // The folder may still be loading after panel.open.
                // Matched by resolved path: scripts may say /var/… where the listing has /private/var/….
                let wanted = Set(urls.map { $0.resolvingSymlinksInPath().path })
                @MainActor func matches() -> Set<URL> { Set(pane.items.map(\.url).filter { wanted.contains($0.resolvingSymlinksInPath().path) }) }
                Task { @MainActor in
                    for _ in 0..<20 where matches().count < wanted.count {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    pane.selection = matches()
                }
            },
            workspaces: { WorkspaceStore.shared.workspaces.map(\.name) },
            openWorkspace: { [weak self] name in
                guard let workspace = WorkspaceStore.shared.workspaces.first(where: { $0.name == name }) else { return false }
                self?.open(workspace)
                return true
            }
        )
    }

    /// Copies paths in the chosen format; relative paths are relative to the repo root or current folder.
    func copyPaths(_ urls: [URL], format: PathFormat) {
        let base = activePane.git?.root ?? activePane.location.folderURL
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(format.string(for: urls, relativeTo: base), forType: .string)
    }

    func copySHA256(_ url: URL) {
        Task {
            do {
                let hashes = try await Hashing.hashes(of: url) { _ in }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hashes.sha256, forType: .string)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func rotateImages(_ urls: [URL], degrees: Int) {
        Task {
            await run("Rotating \(Self.describe(urls))", undoTitle: "Rotate") { try await TypeActions.rotate(urls, degrees: degrees, progress: $0) }
        }
    }

    func convertImages(_ urls: [URL], to format: TypeActions.ImageFormat) {
        Task {
            await run("Converting \(Self.describe(urls)) to \(format.title)", undoTitle: "Convert", select: true) {
                try await TypeActions.convert(urls, to: format, progress: $0)
            }
        }
    }

    func copyPaths(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    func showProperties(_ urls: [URL]? = nil) {
        let targets = urls ?? {
            let selected = activePane.selectedItems.map(\.url)
            return selected.isEmpty ? [activePane.location.folderURL].compactMap { $0 } : selected
        }()
        guard !targets.isEmpty else { return }
        propertiesRequest = PropertiesTarget(urls: targets)
    }

    func toggleQuickLook() {
        if quickLookURL != nil {
            quickLookURL = nil
        } else {
            quickLookURL = activePane.selectedItems.first?.url
        }
    }

    /// Handles a path typed into the omnibar: folders navigate, files open, anything else searches.
    func submitPath(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let path = (trimmed as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        if path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) {
            if FileSystem.isDirectory(url), !(FileItem(url: url)?.isPackage ?? false) {
                activePane.navigate(to: .folderAt(url))
            } else {
                NSWorkspace.shared.open(url)
            }
        } else {
            search(trimmed)
        }
    }

    /// What the model understood in the last "Ask AI" search (shown under the search bar).
    var aiSummary: [String]?
    var aiBusy = false
    /// "Search with AI" sheet; `aiSearchFolder` limits it to a folder.
    var showAskAI = false
    var aiSearchFolder: URL?
    /// Opens an "Ask AI" conversation about files or a folder.
    var askAIRequest: AskAITarget?

    /// Plain-language search through the model chosen in Settings → AI.
    func askAI(_ request: String, in folder: URL? = nil) {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !aiBusy else { return }
        let places = NaturalSearch.Places(current: folder ?? activePane.location.folderURL ?? {
            if case .search(let q) = activePane.location { return q.scope.root } else { return nil }
        }())
        let forceFolder = folder
        let tagNames = TagStore.shared.allTags.map(\.name) + TagStore.shared.favorites.map(\.name)
        let configuration = AISettings.shared.configuration
        let pane = activePane
        aiBusy = true
        Task {
            defer { aiBusy = false }
            do {
                var result = try await NaturalSearch.interpret(trimmed, places: places, tagNames: Array(Set(tagNames)), configuration: configuration)
                // "Search with AI" on a folder stays in that folder unless the request names another place.
                if let forceFolder, result.query.scope == .everywhere {
                    result.query.scope = .subfolders(forceFolder)
                    result.summary.append("in \(forceFolder.lastPathComponent)")
                }
                aiSummary = result.summary
                if case .search = pane.location { pane.updateSearch(result.query) } else { pane.navigate(to: .search(result.query)) }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func search(_ query: String) {
        let pane = activePane
        if case .search(var current) = pane.location {
            // Already searching: refine the text, keep the filters.
            current.text = query
            pane.updateSearch(current)
            return
        }
        var search = SearchQuery()
        search.text = query
        search.scope = pane.location.folderURL.map { .subfolders($0) } ?? .everywhere
        pane.navigate(to: .search(search))
    }

    // MARK: Clipboard

    func copySelection(cut: Bool) {
        let urls = activePane.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        FileClipboard.shared.set(urls, cut: cut)
    }

    func paste(into dir: URL? = nil) {
        guard let dest = dir ?? activePane.location.folderURL else { return }
        let (urls, isCut) = FileClipboard.shared.contents()
        guard !urls.isEmpty else { return }
        transfer(urls, to: dest, mode: isCut ? .move : .copy) {
            if isCut { FileClipboard.shared.clearCut() }
        }
    }

    /// Drop handling: same volume moves, other volumes copy; holding ⌥ always copies.
    func drop(_ urls: [URL], into dir: URL) -> Bool {
        let sources = urls.filter { $0.standardizedFileURL.path != dir.standardizedFileURL.path }
        guard !sources.isEmpty else { return false }
        transfer(sources, to: dir, mode: NSEvent.modifierFlags.contains(.option) ? .copy : .automatic)
        return true
    }

    /// Copy/move with a conflict prompt up front, then progress in the Status Center.
    func transfer(_ sources: [URL], to dir: URL, mode: FileOps.TransferMode, onSuccess: (() -> Void)? = nil) {
        Task {
            var overrides: [String: FileOps.ConflictPolicy] = [:]
            let conflicts = FileOps.conflicts(sources, in: dir)
            if !conflicts.isEmpty {
                guard let chosen = await askConflictPolicies(conflicts, destination: dir) else { return }
                overrides = chosen
            }
            let choices = overrides
            let verify = AppSettings.shared.verifyCopies
            let verb = mode == .copy ? "Copying" : (mode == .move ? "Moving" : "Transferring")
            let title = "\(verb) \(Self.describe(sources)) to “\(dir.displayName)”"
            let lane = (try? dir.resourceValues(forKeys: [.volumeURLKey]).volume)?.path ?? dir.path
            await run(title, undoTitle: mode == .copy ? "Copy" : "Move", select: true, lane: lane,
                      retry: { [weak self] in
                          // Retrying asks about conflicts again, so already-copied items can be skipped.
                          let remaining = sources.filter { FileManager.default.fileExists(atPath: $0.path) }
                          self?.transfer(remaining, to: dir, mode: mode)
                      }) {
                // Journaled so a crash mid-transfer can be finished on the next launch.
                let isMove = mode == .move || (mode == .automatic && sources.first.map { FileSystem.sameVolume($0, dir) } == true)
                let job = TransferJob(sources: sources, destination: dir, mode: isMove ? .move : .copy, started: Date())
                TransferJournal.shared.begin(job)
                defer { TransferJournal.shared.finish(job.id) }
                return try FileOps.transfer(sources, to: dir, mode: mode, policy: .keepBoth, overrides: choices, verify: verify, progress: $0)
            }
            onSuccess?()
        }
    }

    /// Finishes a transfer that was interrupted (crash / force quit): done items are skipped, partial ones redone.
    func resume(_ job: TransferJob) {
        let plan = TransferJournal.resumePlan(for: job)
        TransferJournal.shared.finish(job.id)
        guard !plan.sources.isEmpty, FileManager.default.fileExists(atPath: job.destination.path) else { return }
        let verify = AppSettings.shared.verifyCopies
        Task {
            await run("Resuming: \(job.title)", undoTitle: job.mode == .copy ? "Copy" : "Move", select: true) { progress in
                let resumed = TransferJob(sources: plan.sources, destination: job.destination, mode: job.mode, started: Date())
                TransferJournal.shared.begin(resumed)
                defer { TransferJournal.shared.finish(resumed.id) }
                return try FileOps.transfer(plan.sources, to: job.destination, mode: job.mode == .copy ? .copy : .move,
                                            policy: .keepBoth, overrides: plan.overrides, verify: verify, progress: progress)
            }
        }
    }

    // MARK: Conflicts

    struct ConflictItem: Identifiable {
        let source: URL
        let existing: URL
        let sourceSize: Int64?
        let existingSize: Int64?
        let sourceDate: Date?
        let existingDate: Date?

        var id: String { source.standardizedFileURL.path }
        var name: String { source.lastPathComponent }
        var sourceIsNewer: Bool { (sourceDate ?? .distantPast) > (existingDate ?? .distantPast) }

        init(source: URL, existing: URL) {
            self.source = source
            self.existing = existing
            func info(_ url: URL) -> (Int64?, Date?) {
                let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey])
                return (v?.isDirectory == true ? nil : v?.fileSize.map(Int64.init), v?.contentModificationDate)
            }
            (sourceSize, sourceDate) = info(source)
            (existingSize, existingDate) = info(existing)
        }
    }

    struct ConflictPrompt: Identifiable {
        let id = UUID()
        let items: [ConflictItem]
        let destination: String
        fileprivate let continuation: CheckedContinuation<[String: FileOps.ConflictPolicy]?, Never>
    }

    var conflictPrompt: ConflictPrompt?

    private func askConflictPolicies(_ conflicts: [URL], destination: URL) async -> [String: FileOps.ConflictPolicy]? {
        let items = conflicts.map { ConflictItem(source: $0, existing: destination.appendingPathComponent($0.lastPathComponent)) }
        return await withCheckedContinuation { continuation in
            conflictPrompt = ConflictPrompt(items: items, destination: destination.displayName, continuation: continuation)
        }
    }

    /// Per-item choices keyed by source path; nil cancels the whole operation.
    func resolveConflicts(_ choices: [String: FileOps.ConflictPolicy]?) {
        guard let prompt = conflictPrompt else { return }
        conflictPrompt = nil
        prompt.continuation.resume(returning: choices)
    }

    // MARK: File commands

    func selectAll() {
        activePane.selection = Set(activePane.displayedItems.map(\.url))
    }

    /// Items in the active pane matching a rule (name pattern, kind, size, date, tags).
    func items(matching rule: SearchQuery) -> [FileItem] {
        activePane.displayedItems.filter { item in
            guard rule.nameMatches(item.name),
                  let values = try? item.url.resourceValues(forKeys: SearchEngine.scanKeys) else { return false }
            return SearchEngine.matchesFilters(values, query: rule)
        }
    }

    func select(matching rule: SearchQuery, adding: Bool) {
        let matches = Set(items(matching: rule).map(\.url))
        activePane.selection = adding ? activePane.selection.union(matches) : matches
    }

    func invertSelection() {
        let pane = activePane
        pane.selection = Set(pane.displayedItems.map(\.url)).subtracting(pane.selection)
    }

    func selectSameKind() {
        let pane = activePane
        let kinds = Set(pane.selectedItems.map(\.kind))
        guard !kinds.isEmpty else { return }
        pane.selection = Set(pane.displayedItems.filter { kinds.contains($0.kind) }.map(\.url))
    }

    /// Both panes' folders, when they differ (for "Compare Panes").
    var paneFolders: (URL, URL)? {
        guard selectedTab.isDualPane, let left = selectedTab.panes[0].location.folderURL,
              let right = selectedTab.panes[1].location.folderURL, left != right else { return nil }
        return (left, right)
    }

    struct IntegrityResult: Identifiable {
        let id = UUID()
        let folder: URL
        let report: Integrity.Report
    }

    /// Records SHA-256 of every file in the folder as its integrity baseline.
    func createIntegrityBaseline(_ folder: URL) {
        Task {
            await run("Fingerprinting “\(folder.lastPathComponent)”", undoTitle: "Integrity") { progress in
                let files = try Integrity.hashes(of: folder, progress: progress)
                try Integrity.save(Integrity.Baseline(folder: folder.standardizedFileURL.path, created: Date(), files: files))
                return []
            }
        }
    }

    /// Re-hashes the folder and reports what changed since its baseline.
    func checkIntegrity(_ folder: URL) {
        guard let baseline = Integrity.baseline(for: folder) else {
            errorMessage = "“\(folder.lastPathComponent)” has no integrity baseline yet. Create one first."
            return
        }
        Task {
            await run("Checking “\(folder.lastPathComponent)”", undoTitle: "Integrity") { progress in
                let current = try Integrity.hashes(of: folder, progress: progress)
                let report = Integrity.compare(baseline, with: current)
                await MainActor.run { self.integrityReport = IntegrityResult(folder: folder, report: report) }
                return []
            }
        }
    }

    func comparePanes() {
        guard let (left, right) = paneFolders else { NSSound.beep(); return }
        compareRequest = CompareTarget(left: left, right: right)
    }

    /// Compare a folder with the other pane's folder, or with one the user picks.
    func compare(_ folder: URL) {
        if let other = otherPaneFolder, other != folder {
            compareRequest = CompareTarget(left: folder, right: other)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Compare “\(folder.lastPathComponent)” with:")
        panel.prompt = String(localized: "Compare")
        if panel.runModal() == .OK, let other = panel.url {
            compareRequest = CompareTarget(left: folder, right: other)
        }
    }

    /// Copy To… / Move To…: a chosen folder (or a recent one) instead of the clipboard or the other pane.
    func copyOrMove(_ urls: [URL]? = nil, move: Bool, to destination: URL? = nil) {
        let sources = urls ?? activePane.selectedItems.map(\.url)
        guard !sources.isEmpty else { return }
        var target = destination
        if target == nil {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = move ? "Move Here" : "Copy Here"
            panel.message = String(localized: "\(move ? "Move" : "Copy") \(Self.describe(sources)) to:")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            target = url
        }
        guard let target else { return }
        let settings = AppSettings.shared
        settings.recentDestinations = Array(([target.normalizedDirectory] + settings.recentDestinations.filter {
            $0.standardizedFileURL.path != target.standardizedFileURL.path
        }).prefix(8))
        transfer(sources, to: target, mode: move ? .move : .copy)
    }

    /// Copies the selection next to itself ("name 2"), like Finder's Duplicate.
    func duplicateSelection(_ urls: [URL]? = nil) {
        let sources = urls ?? activePane.selectedItems.map(\.url)
        guard let first = sources.first else { return }
        let folders = Set(sources.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        guard folders.count == 1 else { NSSound.beep(); return }
        transfer(sources, to: first.deletingLastPathComponent(), mode: .copy)
    }

    func trashSelection() {
        let urls = activePane.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        Task {
            do {
                _ = try await OperationCenter.shared.run("Moving \(Self.describe(urls)) to Trash", undoTitle: "Move to Trash") {
                    try FileOps.trash(urls, progress: $0)
                }
            } catch is CancellationError {
            } catch where Self.isPermissionError(error) {
                offerAdminTrash(urls.filter { FileManager.default.fileExists(atPath: $0.path) })
            } catch {
                errorMessage = error.localizedDescription
            }
            reloadAll()
        }
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain,
           [Int(EACCES), Int(EPERM)].contains(underlying.code) { return true }
        return ns.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(ns.code)
    }

    /// Protected items: offer to move them with administrator rights.
    func offerAdminTrash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "You don’t have permission to move \(Self.describe(urls)) to the Trash.")
        alert.informativeText = String(localized: "Move with administrator rights? This asks for an administrator password and can’t be undone from the Timeline.")
        alert.addButton(withTitle: String(localized: "Use Administrator"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do { try await Admin.trash(urls) } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
            reloadAll()
        }
    }

    /// Recursive permission change (undoable).
    func applyPermissions(_ changes: [PermissionChange], title: String) {
        guard !changes.isEmpty else { return }
        Task {
            await run(title, undoTitle: "Permissions") { progress in
                try PermissionPlan.apply(changes, progress: progress)
                return []
            }
        }
    }

    func removeQuarantine(_ urls: [URL]) {
        do {
            let count = try Quarantine.remove(from: urls)
            if count == 0 { errorMessage = "No quarantine flag to remove." }
        } catch {
            errorMessage = error.localizedDescription
        }
        reloadAll()
    }

    /// Items waiting for confirmation before being deleted permanently.
    var pendingPermanentDelete: [URL]?

    func beginPermanentDelete() {
        let urls = activePane.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        pendingPermanentDelete = urls
    }

    func confirmPermanentDelete() {
        guard let urls = pendingPermanentDelete else { return }
        pendingPermanentDelete = nil
        Task {
            await run("Deleting \(Self.describe(urls))", undoTitle: "Delete") {
                try FileOps.delete(urls, progress: $0)
            }
        }
    }

    /// One item: inline name prompt. Several: the batch rename sheet.
    func beginRename() {
        let items = activePane.selectedItems
        if items.count > 1 {
            batchRenameRequest = BatchRenameRequest(items: items)
        } else if let item = items.first {
            promptText = item.name
            prompt = .rename(item.url)
        }
    }

    func applyBatchRename(_ rows: [BatchRenameRow]) {
        let count = rows.filter { $0.status == .ok }.count
        Task {
            await run("Renaming \(count) items", undoTitle: "Rename", select: true) {
                try BatchRename.apply(rows, progress: $0)
            }
        }
    }

    func beginNew(_ kind: NamePrompt) {
        if kind == .connectToServer { showConnect = true; return }
        switch kind {
        case .newFolder: promptText = String(localized: "New Folder")
        case .newFile(let template): promptText = template.fileName
        case .connectToServer: promptText = "smb://"
        case .createBranch: promptText = ""
        case .cloneRepository: promptText = "https://github.com/"
        case .saveSearch(let query): promptText = query.title
        case .saveWorkspace: promptText = selectedTab.title
        case .rename: return
        }
        if case .saveSearch = kind { prompt = kind; return }
        if case .saveWorkspace = kind { prompt = kind; return }
        guard kind == .connectToServer || activePane.location.folderURL != nil else { return }
        prompt = kind
    }

    func commitPrompt() {
        guard let prompt else { return }
        let text = promptText
        self.prompt = nil
        let dir = activePane.location.folderURL
        Task {
            switch prompt {
            case .rename(let url):
                await run("Renaming “\(url.lastPathComponent)”", undoTitle: "Rename", select: true) { progress in
                    let renamed = try FileOps.rename(url, to: text)
                    if renamed != url { progress.record(.moved([MovedItem(from: url, to: renamed)])) }
                    return [renamed]
                }
            case .newFolder:
                guard let dir else { return }
                await run("Creating folder “\(text)”", undoTitle: "New Folder", select: true) { progress in
                    let created = try FileOps.createFolder(named: text, in: dir)
                    progress.record(.created([created]))
                    return [created]
                }
            case .newFile(let template):
                guard let dir else { return }
                await run("Creating “\(text)”", undoTitle: "New File", select: true) { progress in
                    let created = try FileOps.createFile(named: text, in: dir, contents: try template.contents())
                    if template.isExecutable {
                        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: created.path)
                    }
                    progress.record(.created([created]))
                    return [created]
                }
            case .createBranch(let root):
                await runGit("Creating branch “\(text)”", ["switch", "-c", text.trimmingCharacters(in: .whitespaces)], in: root)
            case .cloneRepository:
                guard let dir else { return }
                cloneRepository(text.trimmingCharacters(in: .whitespaces), into: dir)
            case .saveSearch(let query):
                SavedSearchStore.shared.add(text, query: query)
            case .saveWorkspace:
                let name = text.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                WorkspaceStore.shared.save(Workspace(name: name, session: session,
                                                     sidebarVisible: UserDefaults.standard.object(forKey: "sidebarVisible") as? Bool ?? true))
            case .connectToServer:
                if let url = URL(string: text), url.scheme != nil {
                    NSWorkspace.shared.open(url)
                } else {
                    errorMessage = "“\(text)” is not a valid server address."
                }
            }
        }
    }

    func openTemplatesFolder() {
        do {
            NSWorkspace.shared.open(try FileTemplate.ensureUserFolder())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelPrompt() {
        prompt = nil
    }

    func compressSelection() {
        let urls = activePane.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        Task {
            await run("Compressing \(Self.describe(urls))", undoTitle: "Compress", select: true) { progress in
                progress.setTotals(bytes: 0, items: 1)
                let created = try await FileOps.compress(urls)
                progress.record(.created(created))
                return created
            }
        }
    }

    func extractSelection() {
        let archives = activePane.selectedItems.filter(\.isArchive).map(\.url)
        guard !archives.isEmpty else { return }
        Task {
            await run("Extracting \(Self.describe(archives))", undoTitle: "Extract", select: true) { progress in
                progress.setTotals(bytes: 0, items: archives.count)
                var created: [URL] = []
                for archive in archives {
                    try progress.checkCancelled()
                    progress.begin(archive.lastPathComponent)
                    let result = try await FileOps.extract(archive)
                    progress.record(.created(result))
                    progress.finishItem(baseline: 0, size: 0)
                    created += result
                }
                return created
            }
        }
    }

    func toggleTag(_ tag: FileTag, on items: [FileItem]) {
        let shouldAdd = !items.allSatisfy { $0.tags.contains(tag.name) }
        let changes = items.map { item in
            var tags = item.fileTags.filter { $0.name != tag.name }
            if shouldAdd { tags.append(tag) }
            return TagChange(url: item.url, old: item.fileTags, new: tags)
        }
        Task {
            await run("Tagging \(Self.describe(items.map(\.url)))", undoTitle: "Tag") { progress in
                for change in changes { try FileOps.setTags(change.new, on: change.url) }
                progress.record(.tagged(changes))
                return []
            }
            TagStore.shared.refreshUsageSoon()
        }
    }

    // MARK: Git

    func gitSwitch(to branch: GitBranch, in root: URL) {
        Task {
            if branch.isRemote {
                // "origin/feature" → local "feature" tracking it (or just switch if it already exists).
                let local = String(branch.name.split(separator: "/", maxSplits: 1).last ?? Substring(branch.name))
                let exists = await Git.branches(in: root).contains { !$0.isRemote && $0.name == local }
                await runGit("Switching to \(local)", exists ? ["switch", local] : ["switch", "-c", local, "--track", branch.name], in: root)
            } else {
                await runGit("Switching to \(branch.name)", ["switch", branch.name], in: root)
            }
        }
    }

    func gitFetch(_ root: URL) {
        Task { await runGit("Fetching \(root.lastPathComponent)", ["fetch", "--prune"], in: root) }
    }

    func gitPull(_ root: URL) {
        Task { await runGit("Pulling \(root.lastPathComponent)", ["pull", "--ff-only"], in: root) }
    }

    func gitPush(_ info: GitInfo) {
        let args = info.upstream == nil ? ["push", "-u", "origin", "HEAD"] : ["push"]
        Task { await runGit("Pushing \(info.branch)", args, in: info.root) }
    }

    func cloneRepository(_ remote: String, into dir: URL) {
        let name = (remote.split(separator: "/").last.map(String.init) ?? "repository")
            .replacingOccurrences(of: ".git", with: "")
        Task {
            await run("Cloning \(name)", undoTitle: "Clone", select: true) { progress in
                let dest = FileOps.uniqueURL(dir.appendingPathComponent(name))
                try await Shell.check("/usr/bin/git", ["clone", remote, dest.path], environment: Git.environment)
                progress.record(.created([dest]))
                return [dest]
            }
        }
    }

    private func runGit(_ title: String, _ args: [String], in root: URL) async {
        await run(title, undoTitle: "Git") { progress in
            progress.note(root)
            try await Git.check(args, in: root)
            return []
        }
    }

    // MARK: Undo

    func undo() {
        Task {
            do { try await OperationCenter.shared.undo() } catch { errorMessage = error.localizedDescription }
            TagStore.shared.refreshUsageSoon()
            reloadAll()
        }
    }

    func redo() {
        Task {
            do { try await OperationCenter.shared.redo() } catch { errorMessage = error.localizedDescription }
            reloadAll()
        }
    }

    // MARK: Helpers

    private func select(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pane = activePane
        pane.reload()
        // The listing reloads asynchronously; apply the selection once the new items are in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let available = Set(pane.items.map(\.url))
            let wanted = Set(urls.map { url in available.first { $0.standardizedFileURL.path == url.standardizedFileURL.path } ?? url })
            pane.selection = wanted.intersection(available)
        }
    }

    func reloadAll() {
        tabs.flatMap(\.panes).forEach { $0.reload() }
    }

    /// Runs a file operation through the Operation Center, reporting errors and refreshing panes.
    private func run(
        _ title: String,
        undoTitle: String,
        select shouldSelect: Bool = false,
        lane: String? = nil,
        retry: (() -> Void)? = nil,
        work: @escaping @Sendable (OperationProgress) async throws -> [URL]
    ) async {
        do {
            let urls = try await OperationCenter.shared.run(title, undoTitle: undoTitle, lane: lane, retry: retry, work: work)
            reloadAll()
            if shouldSelect { select(urls) }
        } catch is CancellationError {
            reloadAll()
        } catch {
            errorMessage = error.localizedDescription
            reloadAll()
        }
    }

    static func describe(_ urls: [URL]) -> String {
        urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : String(localized: "\(urls.count) items")
    }
}

struct WindowStateKey: FocusedValueKey {
    typealias Value = WindowState
}

extension FocusedValues {
    var windowState: WindowState? {
        get { self[WindowStateKey.self] }
        set { self[WindowStateKey.self] = newValue }
    }
}
