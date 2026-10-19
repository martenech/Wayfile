import AppKit
import SwiftUI

/// Right-click menu for selected items, or for the folder background when `urls` is empty.
struct FileContextMenu: View {
    let state: WindowState
    let pane: PaneState
    let urls: Set<URL>

    private var items: [FileItem] {
        pane.displayedItems.filter { urls.contains($0.url) }
    }

    var body: some View {
        if urls.isEmpty {
            backgroundMenu
        } else {
            itemMenu
        }
    }

    @ViewBuilder
    private var backgroundMenu: some View {
        if let dir = pane.location.folderURL {
            Menu { NewItemMenu(state: state) } label: { Label("New", systemImage: "plus.circle") }
            Button("Paste", systemImage: "doc.on.clipboard") { state.paste(into: dir) }
                .shortcut(.paste)
                .disabled(!FileClipboard.shared.hasContents)
            Divider()
            Button("Refresh", systemImage: "arrow.clockwise") { pane.reload() }
                .shortcut(.refresh)
            CopyPathMenu(state: state, urls: [dir])
            Button("Open in Terminal", systemImage: "terminal") { state.openInTerminal(dir) }
            Button("Open in Integrated Terminal", systemImage: "apple.terminal") { state.terminal.open(dir) }
            let features = Features.shared
            Button("Ask AI About This Folder…", systemImage: "sparkles") { state.askAIRequest = AskAITarget(urls: [dir]) }
            Button("Search with AI…", systemImage: "sparkle.magnifyingglass") {
                state.aiSearchFolder = dir
                state.showAskAI = true
            }
            if features.isOn(.automation) { ScriptsMenu(state: state, urls: []) }
            if features.isOn(.developer), let git = pane.git {
                Button("Git Changes & Commit…", systemImage: "arrow.triangle.branch") { state.gitRequest = GitTarget(root: git.root) }
            }
            if features.isOn(.compare) {
                Button("Compare With…", systemImage: "arrow.left.arrow.right") { state.compare(dir) }
                Button("Find Duplicates…", systemImage: "doc.on.doc") { state.duplicatesRequest = dir }
            }
            if features.isOn(.automation) {
                Button("Suggest Organization…", systemImage: "sparkles") { state.organizeRequest = .init(folder: dir) }
            }
            if features.isOn(.diskTools) {
                Button("Disk Usage…", systemImage: "chart.pie") { state.diskUsageRequest = dir }
                Button("Find Broken Links…", systemImage: "link.badge.plus") { state.brokenLinksRequest = .init(folder: dir) }
            }
            Button("Show in Finder", systemImage: "macwindow") { state.revealInFinder([dir]) }
            Divider()
            if PinnedStore.shared.isPinned(dir) {
                Button("Remove from Favorites", systemImage: "star.slash") { PinnedStore.shared.unpin(dir) }
            } else {
                Button("Add to Favorites", systemImage: "star") { PinnedStore.shared.pin(dir) }
            }
            Button("Get Info", systemImage: "info.circle") { state.showProperties([dir]) }
                .shortcut(.properties)
        }
    }

    /// Item menu laid out like the design: open, type-specific, edit, path/tools, transfer, organize, info.
    /// Section order and hidden entries come from Settings → Context Menu; shortcuts shown are the user's.
    @ViewBuilder
    private var itemMenu: some View {
        let items = self.items
        ForEach(ContextMenuConfig.shared.order) { section in
            sectionView(section, items: items)
            if section != ContextMenuConfig.shared.order.last { Divider() }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: ContextMenuSection, items: [FileItem]) -> some View {
        switch section {
        case .open: openSection(items)
        case .typeSpecific: typeSection(items)
        case .edit: editSection
        case .path: pathSection(items)
        case .transfer: transferSection
        case .organize: organizeSection(items)
        case .info:
            Button("Get Info", systemImage: "info.circle") { state.showProperties(Array(urls)) }
                .shortcut(.properties)
        }
    }

    private func shows(_ item: ContextMenuItem) -> Bool { ContextMenuConfig.shared.shows(item) }

    private func single(_ items: [FileItem]) -> FileItem? { items.count == 1 ? items.first : nil }

    @ViewBuilder
    private func openSection(_ items: [FileItem]) -> some View {
        let single = single(items)
        Button("Open", systemImage: "arrow.up.forward.app") {
            pane.selection = urls
            state.openSelection(in: pane)
        }
        .keyboardShortcut(AppSettings.shared.returnKeyRenames ? ShortcutStore.shared.keyboardShortcut(.open) : KeyboardShortcut(.return, modifiers: []))
        if let single, !single.isFolderLike, shows(.openWith) {
            openWithMenu(for: single.url)
        }
        if let single, single.isFolderLike, shows(.openInTabs) {
            Button("Open in New Tab", systemImage: "plus.square.on.square") { state.newTab(.folderAt(single.url)) }
            Button("Open in Other Pane", systemImage: "rectangle.split.2x1") { state.openInOtherPane(single.url) }
        }
        if shows(.quickLook) {
            Button("Quick Look", systemImage: "eye") {
                pane.selection = urls
                state.quickLookURL = single?.url ?? items.first?.url
            }
            .keyboardShortcut(.space, modifiers: [])
        }
    }

    /// Entries that only appear for some kinds of files.
    @ViewBuilder
    private func typeSection(_ items: [FileItem]) -> some View {
        let single = single(items)
        let all = items.map(\.url)
        if shows(.imageActions), !all.isEmpty, all.allSatisfy(TypeActions.isImage) {
            if let single {
                Button("Set Desktop Picture", systemImage: "menubar.dock.rectangle") {
                    do { try TypeActions.setDesktopPicture(single.url) } catch { state.errorMessage = error.localizedDescription }
                }
            }
            Button("Rotate Left", systemImage: "rotate.left") { state.rotateImages(all, degrees: -90) }
            Button("Rotate Right", systemImage: "rotate.right") { state.rotateImages(all, degrees: 90) }
            Menu {
                ForEach(TypeActions.ImageFormat.allCases) { format in
                    Button(format.title) { state.convertImages(all, to: format) }
                }
            } label: {
                Label("Convert To", systemImage: "photo.on.rectangle.angled")
            }
        }
        if shows(.packageContents), let single, single.isPackage {
            Button("Show Package Contents", systemImage: "shippingbox") { pane.navigate(to: .folderAt(single.url)) }
        }
        if shows(.askAI) {
            Button(single?.isFolderLike == true ? String(localized: "Ask AI About This Folder…") : String(localized: "Ask AI…"), systemImage: "sparkles") {
                state.askAIRequest = AskAITarget(urls: Array(urls).sorted { $0.path < $1.path })
            }
            if let single, single.isFolderLike {
                Button("Search with AI…", systemImage: "sparkle.magnifyingglass") {
                    state.aiSearchFolder = single.url
                    state.showAskAI = true
                }
            }
        }
        if shows(.scripts) {
            ScriptsMenu(state: state, urls: Array(urls).sorted { $0.path < $1.path })
        }
        if shows(.openInEditor), let single, single.isFolderLike || TypeActions.isEditableText(single.url) {
            let editors = Editors.installed
            if let first = editors.first {
                Button("Open in \(first.name)", systemImage: "chevron.left.forwardslash.chevron.right") {
                    Editors.open(single.url, with: first.url)
                }
            }
        }
    }

    @ViewBuilder
    private var editSection: some View {
        Button(urls.count > 1 ? String(localized: "Rename \(urls.count) Items…") : String(localized: "Rename"), systemImage: "character.cursor.ibeam") {
            pane.selection = urls
            state.beginRename()
        }
        .shortcut(.rename)
        if shows(.duplicate) {
            Button("Duplicate", systemImage: "plus.square.on.square") { state.duplicateSelection(Array(urls)) }
                .shortcut(.duplicate)
        }
        Button("Move to Trash", systemImage: "trash") {
            pane.selection = urls
            state.trashSelection()
        }
        .shortcut(.trash)
    }

    @ViewBuilder
    private func pathSection(_ items: [FileItem]) -> some View {
        let single = single(items)
        if shows(.copyPath) {
            CopyPathMenu(state: state, urls: Array(urls))
        }
        if shows(.developer) {
            developerItems(items)
        }
        if shows(.checksum), let single, !single.isFolderLike {
            Button("Copy SHA-256", systemImage: "number") { state.copySHA256(single.url) }
        }
        if let single, single.isFolderLike {
            if shows(.terminal) {
                Button("Open in Terminal", systemImage: "terminal") { state.openInTerminal(single.url) }
                Button("Open in Integrated Terminal", systemImage: "apple.terminal") { state.terminal.open(single.url) }
            }
            if shows(.compare) {
                Button("Compare With…", systemImage: "arrow.left.arrow.right") { state.compare(single.url) }
            }
            if shows(.findDuplicates) {
                Button("Find Duplicates…", systemImage: "doc.on.doc") { state.duplicatesRequest = single.url }
                if Features.shared.isOn(.diskTools) {
                    Button("Disk Usage…", systemImage: "chart.pie") { state.diskUsageRequest = single.url }
                }
            }
        }
        if shows(.showInFinder) {
            Button("Show in Finder", systemImage: "macwindow") { state.revealInFinder(Array(urls)) }
        }
    }

    @ViewBuilder
    private func developerItems(_ items: [FileItem]) -> some View {
        let files = items.filter { !$0.isDirectory }
        if files.count == 2 {
            Button("Compare Files", systemImage: "doc.on.doc") {
                state.textDiffRequest = DiffTarget(left: .file(files[0].url), right: .file(files[1].url))
            }
        } else if let file = single(items), !file.isDirectory {
            if let other = state.counterpart(of: file.url) {
                Button("Compare with Other Pane", systemImage: "rectangle.split.2x1") {
                    state.textDiffRequest = DiffTarget(left: .file(file.url), right: .file(other))
                }
            }
            Button("Compare With…", systemImage: "arrow.left.arrow.right") { state.compareFile(file.url) }
        }
        if pane.git != nil, let item = single(items) {
            if !item.isDirectory, let status = item.gitStatus, status != .untracked {
                Button("Show Git Changes", systemImage: "plusminus") { state.showGitChanges(item.url) }
            }
            if item.lastCommit != nil {
                Button("Git History", systemImage: "clock.arrow.circlepath") { state.showGitHistory(item.url) }
            }
        }
    }

    @ViewBuilder
    private var transferSection: some View {
        let single = single(items)
        Button("Cut", systemImage: "scissors") { pane.selection = urls; state.copySelection(cut: true) }
            .shortcut(.cut)
        Button("Copy", systemImage: "doc.on.doc") { pane.selection = urls; state.copySelection(cut: false) }
            .shortcut(.copy)
        if let single, single.isFolderLike {
            Button("Paste into Folder", systemImage: "doc.on.clipboard") { state.paste(into: single.url) }
                .disabled(!FileClipboard.shared.hasContents)
        }
        if shows(.dropStack) {
            Button("Add to Drop Stack", systemImage: "tray.and.arrow.down") { DropStackStore.shared.add(Array(urls)) }
        }
        if shows(.copyMoveTo) {
            CopyMoveToMenu(state: state, urls: Array(urls), move: false)
            CopyMoveToMenu(state: state, urls: Array(urls), move: true)
        }
        if shows(.otherPane), let target = state.otherPaneFolder {
            Button("Copy to “\(target.displayName)”", systemImage: "arrowshape.right") { pane.selection = urls; state.transferToOtherPane(move: false) }
                .shortcut(.copyToOtherPane)
            Button("Move to “\(target.displayName)”", systemImage: "arrowshape.right.fill") { pane.selection = urls; state.transferToOtherPane(move: true) }
                .shortcut(.moveToOtherPane)
        }
    }

    @ViewBuilder
    private func organizeSection(_ items: [FileItem]) -> some View {
        let single = single(items)
        if shows(.compress) {
            Button("Compress", systemImage: "archivebox") { pane.selection = urls; state.compressSelection() }
            if Features.shared.isOn(.diskTools) {
                Button("Compress…", systemImage: "archivebox.circle") { state.compressRequest = .init(urls: Array(urls).sorted { $0.path < $1.path }) }
            }
            if items.contains(where: \.isArchive) {
                Button("Extract Here", systemImage: "arrow.up.bin") { pane.selection = urls; state.extractSelection() }
                if let single, single.isArchive, Features.shared.isOn(.diskTools) {
                    Button("Browse Archive", systemImage: "archivebox.fill") { state.archiveRequest = single.url }
                }
            }
        }
        if shows(.tags) {
            Menu {
                ForEach(TagStore.shared.menuTags) { tag in
                    Toggle(isOn: Binding(
                        get: { !items.isEmpty && items.allSatisfy { $0.tags.contains(tag.name) } },
                        set: { _ in state.toggleTag(tag, on: items) }
                    )) {
                        Label {
                            Text(tag.name)
                        } icon: {
                            Image(nsImage: Self.dot(tag.nsColor))
                        }
                    }
                }
            } label: {
                Label("Tags", systemImage: "tag")
            }
        }
        if shows(.links) {
            Menu {
                Button("Symbolic Link") { state.makeLink(Array(urls), hard: false) }
                Button("Hard Link") { state.makeLink(Array(urls), hard: true) }
                    .disabled(items.contains(where: \.isDirectory))
            } label: {
                Label("Make Link", systemImage: "link.badge.plus")
            }
        }
        if shows(.security) {
            Menu {
                Button("Change Permissions…") { state.permissionsRequest = .init(urls: Array(urls).sorted { $0.path < $1.path }) }
                if urls.count <= 50, urls.contains(where: { Quarantine.read($0) != nil }) {
                    Button("Remove Quarantine") { state.removeQuarantine(Array(urls)) }
                }
                Divider()
                Button("Move to Trash as Administrator…") { state.offerAdminTrash(Array(urls)) }
            } label: {
                Label("Security", systemImage: "lock.shield")
            }
        }
        if shows(.favorites), let single, single.isFolderLike {
            if HomeConfig.shared.isProject(single.url) {
                Button("Unpin from Home Projects", systemImage: "pin.slash") { HomeConfig.shared.unpinProject(single.url) }
            } else {
                Button("Pin to Home Projects", systemImage: "pin") { HomeConfig.shared.pinProject(single.url) }
            }
        }
        if shows(.favorites), let single, single.isFolderLike {
            if PinnedStore.shared.isPinned(single.url) {
                Button("Remove from Favorites", systemImage: "star.slash") { PinnedStore.shared.unpin(single.url) }
            } else {
                Button("Add to Favorites", systemImage: "star") { PinnedStore.shared.pin(single.url) }
            }
        }
    }

    /// Menus render SF Symbol colours unreliably, so tag colours are drawn as small images.
    private static func dot(_ color: NSColor?) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            if let color {
                color.setFill()
                circle.fill()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                circle.stroke()
            }
            return true
        }
    }

    private func openWithMenu(for url: URL) -> some View {
        Menu {
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
            let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
            ForEach(apps.prefix(20), id: \.self) { app in
                Button {
                    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                } label: {
                    Label {
                        Text(app.deletingPathExtension().lastPathComponent + (app == defaultApp ? " (default)" : ""))
                    } icon: {
                        Image(nsImage: Self.appIcon(app))
                    }
                }
            }
        } label: {
            Label("Open With", systemImage: "square.grid.2x2")
        }
    }

    private static func appIcon(_ app: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}

/// Scripts that fit the items (or the folder, when `urls` is nil/empty), Apple Shortcuts, and the manager.
struct ScriptsMenu: View {
    let state: WindowState?
    let urls: [URL]?

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let center = AutomationCenter.shared
        let selection = urls ?? state.map { Array($0.activePane.selection).sorted { $0.path < $1.path } } ?? []
        let all = center.scripts(for: selection)
        let scripts = all.filter { !$0.pinned }
        // `@menu pin` scripts sit right in the menu.
        ForEach(all.filter(\.pinned)) { script in
            Button(script.name, systemImage: script.language.symbol) {
                guard let state else { return }
                center.request(script, context: state.scriptContext(for: selection))
            }
        }
        Menu {
            ForEach(scripts) { script in
                Button(script.name, systemImage: script.language.symbol) {
                    guard let state else { return }
                    center.request(script, context: state.scriptContext(for: selection))
                }
            }
            if scripts.isEmpty {
                Text(center.scripts.isEmpty ? String(localized: "No scripts yet") : String(localized: "No scripts for this selection"))
            }
            let plugins = center.panels(.window)
            if !plugins.isEmpty {
                Divider()
                ForEach(plugins) { plugin in
                    Button(plugin.name, systemImage: "puzzlepiece.extension") { openWindow(id: "plugin", value: plugin.url.path) }
                }
            }
            if !center.shortcuts.isEmpty {
                Divider()
                Menu {
                    ForEach(center.shortcuts, id: \.self) { name in
                        Button(name) { center.runShortcut(name, input: selection) }
                    }
                } label: {
                    Label("Run Shortcut", systemImage: "square.2.layers.3d")
                }
            }
            Divider()
            Button("Automation…", systemImage: "gearshape.2") { openWindow(id: "automation") }
        } label: {
            Label("Scripts", systemImage: "applescript")
        }
    }
}

/// "Copy Path" (with its shortcut) plus a "Copy Path As" submenu with the other formats.
struct CopyPathMenu: View {
    let state: WindowState
    let urls: [URL]

    var body: some View {
        Button(urls.count > 1 ? String(localized: "Copy Paths") : String(localized: "Copy Path"), systemImage: "link") { state.copyPaths(urls, format: .path) }
            .shortcut(.copyPath)
        Menu {
            ForEach(PathFormat.allCases.filter { $0 != .path }) { format in
                Button(format.title) { state.copyPaths(urls, format: format) }
            }
            Divider()
            Button("VS Code Link") { state.copyDevLinks(urls, web: false) }
            if state.activePane.git != nil {
                Button("Web Link (GitHub, GitLab…)") { state.copyDevLinks(urls, web: true) }
            }
        } label: {
            Label(urls.count > 1 ? String(localized: "Copy Paths As") : String(localized: "Copy Path As"), systemImage: "link.badge.plus")
        }
    }
}

/// Entries of every "New" menu: folder, built-in file types, the user's templates.
struct NewItemMenu: View {
    let state: WindowState

    var body: some View {
        Button("Folder", systemImage: "folder.badge.plus") { state.beginNew(.newFolder) }
        Divider()
        ForEach(FileTemplate.builtIn) { template in
            Button(template.title, systemImage: template.symbol) { state.beginNew(.newFile(template)) }
        }
        let userTemplates = FileTemplate.userTemplates()
        if !userTemplates.isEmpty {
            Divider()
            ForEach(userTemplates) { template in
                Button(template.title, systemImage: template.symbol) { state.beginNew(.newFile(template)) }
            }
        }
        Divider()
        Button("Open Templates Folder…", systemImage: "folder") { state.openTemplatesFolder() }
    }
}

/// "Copy To" / "Move To" submenu: recent destinations plus "Choose Folder…".
struct CopyMoveToMenu: View {
    let state: WindowState
    let urls: [URL]?
    let move: Bool

    var body: some View {
        Menu {
            let recents = AppSettings.shared.recentDestinations.filter(FileSystem.isDirectory)
            ForEach(recents, id: \.self) { folder in
                Button(folder.displayName) { state.copyOrMove(urls, move: move, to: folder) }
            }
            if !recents.isEmpty { Divider() }
            Button("Choose Folder…") { state.copyOrMove(urls, move: move) }
        } label: {
            Label(move ? String(localized: "Move To") : String(localized: "Copy To"), systemImage: move ? "folder.badge.gearshape" : "folder.badge.plus")
        }
    }
}
