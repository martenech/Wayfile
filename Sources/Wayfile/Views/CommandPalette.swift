import AppKit
import SwiftUI

struct PaletteAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var shortcut = ""
    var category = "Commands"
    var isEnabled = true
    let perform: () -> Void
}

@MainActor
enum PaletteActions {
    /// Everything the palette can run, built against the current window state.
    static func all(for state: WindowState) -> [PaletteAction] {
        let pane = state.activePane
        let hasSelection = !pane.selection.isEmpty
        let folder = pane.location.folderURL
        let home = FileManager.default.homeDirectoryForCurrentUser

        var actions: [PaletteAction] = [
            // Files
            .init(id: "new.folder", title: String(localized: "New Folder"), symbol: "folder.badge.plus", shortcut: "⇧⌘N", category: "File", isEnabled: folder != nil) { state.beginNew(.newFolder) },
            .init(id: "new.file", title: String(localized: "New Text Document"), symbol: "doc.badge.plus", shortcut: "⌥⌘N", category: "File", isEnabled: folder != nil) { state.beginNew(.newFile(.text)) },
            .init(id: "templates.open", title: String(localized: "Open Templates Folder"), symbol: "folder", category: "File") { state.openTemplatesFolder() },
            .init(id: "open", title: String(localized: "Open Selection"), symbol: "arrow.up.forward.app", shortcut: "⌘↓", category: "File", isEnabled: hasSelection) { state.openSelection() },
            .init(id: "quicklook", title: String(localized: "Quick Look"), symbol: "eye", shortcut: "Space", category: "File", isEnabled: hasSelection) { state.toggleQuickLook() },
            .init(id: "properties", title: String(localized: "Properties"), symbol: "info.circle", shortcut: "⌘I", category: "File", isEnabled: hasSelection || folder != nil) { state.showProperties() },
            .init(id: "rename", title: pane.selection.count > 1 ? "Rename \(pane.selection.count) Items (Batch Rename)" : "Rename", symbol: "character.cursor.ibeam", shortcut: "F2", category: "File", isEnabled: hasSelection) { state.beginRename() },
            .init(id: "cut", title: String(localized: "Cut"), symbol: "scissors", shortcut: "⌘X", category: "File", isEnabled: hasSelection) { state.copySelection(cut: true) },
            .init(id: "copy", title: String(localized: "Copy"), symbol: "doc.on.doc", shortcut: "⌘C", category: "File", isEnabled: hasSelection) { state.copySelection(cut: false) },
            .init(id: "paste", title: String(localized: "Paste"), symbol: "doc.on.clipboard", shortcut: "⌘V", category: "File", isEnabled: folder != nil) { state.paste() },
            .init(id: "copy.path", title: String(localized: "Copy Path"), symbol: "link", category: "File", isEnabled: hasSelection || folder != nil) {
                state.copyPaths(hasSelection ? pane.selectedItems.map(\.url) : [folder].compactMap { $0 })
            },
            .init(id: "undo", title: OperationCenter.shared.undoTitle.map { "Undo \($0)" } ?? "Undo", symbol: "arrow.uturn.backward", shortcut: "⌘Z", category: "Edit", isEnabled: OperationCenter.shared.undoTitle != nil) { state.undo() },
            .init(id: "redo", title: OperationCenter.shared.redoTitle.map { "Redo \($0)" } ?? "Redo", symbol: "arrow.uturn.forward", shortcut: "⇧⌘Z", category: "Edit", isEnabled: OperationCenter.shared.redoTitle != nil) { state.redo() },
            .init(id: "delete.permanent", title: String(localized: "Delete Permanently"), symbol: "trash.slash", shortcut: "⌥⌘⌫", category: "File", isEnabled: hasSelection) { state.beginPermanentDelete() },
            .init(id: "status.center", title: String(localized: "Show Status Center"), symbol: "arrow.up.arrow.down.circle", category: "Window") { state.showStatusCenter = true },
            .init(id: "compare.panes", title: String(localized: "Compare Panes"), symbol: "arrow.left.arrow.right", category: "File", isEnabled: state.paneFolders != nil) { state.comparePanes() },
            .init(id: "compare.with", title: String(localized: "Compare Folder With…"), symbol: "arrow.left.arrow.right", category: "File", isEnabled: folder != nil) {
                if let target = pane.selectedItems.first(where: \.isFolderLike)?.url ?? folder { state.compare(target) }
            },
            .init(id: "dropstack.add", title: String(localized: "Add to Drop Stack"), symbol: "tray.and.arrow.down", category: "File", isEnabled: hasSelection) {
                DropStackStore.shared.add(pane.selectedItems.map(\.url))
            },
            .init(id: "dropstack.toggle", title: DropStackStore.shared.isVisible ? String(localized: "Hide Drop Stack") : String(localized: "Show Drop Stack"), symbol: "tray.full", category: "Window") {
                DropStackStore.shared.isVisible.toggle()
            },
            .init(id: "duplicates", title: String(localized: "Find Duplicates in This Folder"), symbol: "doc.on.doc", category: "File", isEnabled: folder != nil) {
                state.duplicatesRequest = folder
            },
            .init(id: "large.files", title: String(localized: "Find Large Files Here"), symbol: "externaldrive.badge.exclamationmark", category: "File", isEnabled: folder != nil) {
                guard let folder else { return }
                var query = SearchQuery(); query.scope = .subfolders(folder); query.minSize = 100 << 20
                pane.navigate(to: .search(query))
                pane.sortOrder = [SortField.size.comparator(ascending: false)]
            },
            .init(id: "integrity.baseline", title: String(localized: "Create Integrity Baseline for This Folder"), symbol: "checkmark.shield", category: "File", isEnabled: folder != nil) {
                if let folder { state.createIntegrityBaseline(folder) }
            },
            .init(id: "integrity.check", title: String(localized: "Check Folder Integrity"), symbol: "shield.lefthalf.filled", category: "File", isEnabled: folder.flatMap { Integrity.baseline(for: $0) } != nil) {
                if let folder { state.checkIntegrity(folder) }
            },
            .init(id: "copy.to", title: String(localized: "Copy To…"), symbol: "folder.badge.plus", category: "File", isEnabled: hasSelection) { state.copyOrMove(move: false) },
            .init(id: "move.to", title: String(localized: "Move To…"), symbol: "folder.badge.gearshape", category: "File", isEnabled: hasSelection) { state.copyOrMove(move: true) },
            .init(id: "pane.copy", title: state.otherPaneFolder.map { "Copy to Other Pane (\($0.displayName))" } ?? "Copy to Other Pane", symbol: "doc.on.doc", category: "File", isEnabled: state.canTransferToOtherPane) { state.transferToOtherPane(move: false) },
            .init(id: "pane.move", title: state.otherPaneFolder.map { "Move to Other Pane (\($0.displayName))" } ?? "Move to Other Pane", symbol: "arrow.right.doc.on.clipboard", category: "File", isEnabled: state.canTransferToOtherPane) { state.transferToOtherPane(move: true) },
            .init(id: "trash", title: String(localized: "Move to Trash"), symbol: "trash", shortcut: "⌘⌫", category: "File", isEnabled: hasSelection) { state.trashSelection() },
            .init(id: "compress", title: String(localized: "Compress to ZIP"), symbol: "archivebox", category: "File", isEnabled: hasSelection) { state.compressSelection() },
            .init(id: "extract", title: String(localized: "Extract Here"), symbol: "arrow.up.bin", category: "File", isEnabled: pane.selectedItems.contains(where: \.isArchive)) { state.extractSelection() },
            .init(id: "select.matching", title: String(localized: "Select Matching…"), symbol: "checklist.checked", category: "File") { state.showSelectMatching = true },
            .init(id: "select.invert", title: String(localized: "Invert Selection"), symbol: "arrow.left.arrow.right.square", category: "File") { state.invertSelection() },
            .init(id: "select.kind", title: String(localized: "Select Same Kind"), symbol: "square.stack", category: "File", isEnabled: hasSelection) { state.selectSameKind() },
            .init(id: "select.all", title: String(localized: "Select All"), symbol: "checklist", shortcut: "⌘A", category: "File") { state.selectAll() },
            .init(id: "reveal", title: String(localized: "Show in Finder"), symbol: "macwindow", category: "File", isEnabled: hasSelection || folder != nil) {
                state.revealInFinder(hasSelection ? pane.selectedItems.map(\.url) : [folder].compactMap { $0 })
            },
            .init(id: "terminal", title: String(localized: "Open in Terminal"), symbol: "terminal", shortcut: "⌥⌘T", category: "File", isEnabled: folder != nil) {
                if let folder { state.openInTerminal(folder) }
            },
            .init(id: "pin", title: folder.map { PinnedStore.shared.isPinned($0) ? "Unpin Current Folder" : "Pin Current Folder to Sidebar" } ?? "Pin to Sidebar", symbol: "pin", category: "File", isEnabled: folder != nil) {
                guard let folder else { return }
                if PinnedStore.shared.isPinned(folder) { PinnedStore.shared.unpin(folder) } else { PinnedStore.shared.pin(folder) }
            },

            // Navigation
            .init(id: "back", title: String(localized: "Go Back"), symbol: "chevron.left", shortcut: "⌘[", category: "Go", isEnabled: pane.canGoBack) { pane.goBack() },
            .init(id: "forward", title: String(localized: "Go Forward"), symbol: "chevron.right", shortcut: "⌘]", category: "Go", isEnabled: pane.canGoForward) { pane.goForward() },
            .init(id: "up", title: String(localized: "Go to Enclosing Folder"), symbol: "arrow.up", shortcut: "⌘↑", category: "Go", isEnabled: pane.canGoUp) { pane.goUp() },
            .init(id: "timeline", title: String(localized: "Show Timeline (Files, Apps, Actions)"), symbol: "clock", category: "Go") { pane.navigate(to: .timeline) },
            .init(id: "find", title: String(localized: "Find…"), symbol: "magnifyingglass", category: "Go") { state.focusSearchField = true },
            .init(id: "path", title: String(localized: "Go to Path…"), symbol: "text.cursor", shortcut: "⌘L", category: "Go") { state.isEditingPath = true },
            .init(id: "refresh", title: String(localized: "Refresh"), symbol: "arrow.clockwise", shortcut: "⌘R", category: "Go") { pane.reload() },
            .init(id: "home", title: String(localized: "Go Home"), symbol: "house", shortcut: "⇧⌘H", category: "Go") { pane.navigate(to: .home) },
            .init(id: "connect", title: String(localized: "Connect to Server…"), symbol: "network", shortcut: "⌘K", category: "Go") { state.beginNew(.connectToServer) },

            // Tabs & panes
            .init(id: "tab.new", title: String(localized: "New Tab"), symbol: "plus.square.on.square", shortcut: "⌘T", category: "Window") { state.newTab() },
            .init(id: "tab.duplicate", title: String(localized: "Duplicate Tab"), symbol: "plus.square.on.square", category: "Window") { state.duplicateTab(state.selectedTab) },
            .init(id: "tab.close", title: String(localized: "Close Tab"), symbol: "xmark.square", shortcut: "⌘W", category: "Window") { state.closeSelectedTab() },
            .init(id: "tab.closeOthers", title: String(localized: "Close Other Tabs"), symbol: "xmark.square", category: "Window", isEnabled: state.tabs.count > 1) { state.closeOtherTabs(state.selectedTab) },
            .init(id: "tab.next", title: String(localized: "Next Tab"), symbol: "arrow.right.square", shortcut: "⌃⇥", category: "Window") { state.selectAdjacentTab(1) },
            .init(id: "tab.previous", title: String(localized: "Previous Tab"), symbol: "arrow.left.square", shortcut: "⌃⇧⇥", category: "Window") { state.selectAdjacentTab(-1) },
            .init(id: "pane.dual", title: state.selectedTab.isDualPane ? "Close Dual Pane" : "Open Dual Pane", symbol: "rectangle.split.2x1", shortcut: "⌥⌘D", category: "Window") { state.selectedTab.toggleDualPane() },
            .init(id: "pane.quad", title: state.selectedTab.isQuad ? "Back to Dual Pane" : "Quad Pane (2×2)", symbol: "rectangle.split.2x2", category: "Window") {
                state.selectedTab.setPaneCount(state.selectedTab.isQuad ? 2 : 4)
            },
            .init(id: "pane.sync", title: state.selectedTab.isSynced ? "Stop Synchronized Navigation" : "Synchronize Pane Navigation", symbol: "link", category: "Window", isEnabled: state.selectedTab.isDualPane) {
                state.selectedTab.isSynced.toggle()
            },
            .init(id: "pane.preview", title: state.showPreviewPane ? "Hide Inspector" : "Show Inspector", symbol: "sidebar.right", shortcut: "⌥⌘P", category: "Window") { state.showPreviewPane.toggle() },

            // View
            .init(id: "hidden", title: state.showHidden ? "Hide Hidden Files" : "Show Hidden Files", symbol: "eye.slash", shortcut: "⇧⌘.", category: "View") { state.showHidden.toggle() },
            .init(id: "folders.first", title: pane.foldersFirst ? "Mix Folders with Files" : "Show Folders First", symbol: "folder", category: "View") { pane.foldersFirst.toggle() },
        ]

        for (index, mode) in LayoutMode.allCases.enumerated() {
            actions.append(.init(id: "layout.\(mode.rawValue)", title: String(localized: "Layout: \(mode.title)"), symbol: mode.symbol, shortcut: "⌘\(index + 1)", category: "View") {
                pane.layout = mode
            })
        }

        for field in SortField.allCases {
            actions.append(.init(id: "sort.\(field.rawValue)", title: String(localized: "Sort by \(field.title)"), symbol: "arrow.up.arrow.down", category: "View") {
                // Dates and sizes read most naturally largest/newest first.
                pane.sortOrder = [field.comparator(ascending: ![.modified, .created, .size].contains(field))]
            })
        }

        for template in FileTemplate.builtIn.dropFirst() + FileTemplate.userTemplates() {
            actions.append(.init(id: "new.\(template.id)", title: String(localized: "New \(template.title) File"), symbol: template.symbol, category: "File", isEnabled: folder != nil) {
                state.beginNew(.newFile(template))
            })
        }

        // Git
        actions.append(.init(id: "git.clone", title: String(localized: "Clone Repository…"), symbol: "square.and.arrow.down.on.square", category: "Git", isEnabled: folder != nil) {
            state.beginNew(.cloneRepository)
        })
        if let git = pane.git {
            actions += [
                .init(id: "git.branch.new", title: String(localized: "Create Branch…"), symbol: "arrow.triangle.branch", category: "Git") {
                    state.beginNew(.createBranch(git.root))
                },
                .init(id: "git.pull", title: String(localized: "Pull"), symbol: "arrow.down", category: "Git", isEnabled: git.upstream != nil) { state.gitPull(git.root) },
                .init(id: "git.push", title: git.upstream == nil ? "Publish Branch" : "Push", symbol: "arrow.up", category: "Git") { state.gitPush(git) },
                .init(id: "git.fetch", title: String(localized: "Fetch"), symbol: "arrow.clockwise", category: "Git", isEnabled: git.upstream != nil) { state.gitFetch(git.root) },
                .init(id: "git.root", title: String(localized: "Go to Repository Root"), symbol: "folder", category: "Git") { pane.navigate(to: .folderAt(git.root)) },
            ]
            for editor in Editors.installed {
                actions.append(.init(id: "git.open.\(editor.name)", title: String(localized: "Open Repository in \(editor.name)"), symbol: "chevron.left.forwardslash.chevron.right", category: "Git") {
                    Editors.open(git.root, with: editor.url)
                })
            }
        }

        for group in GroupBy.allCases {
            actions.append(.init(id: "group.\(group.rawValue)", title: group == .none ? "Don’t Group" : "Group by \(group.title)", symbol: "square.stack.3d.up", category: "View") {
                pane.groupBy = group
            })
        }
        actions.append(.init(id: "view.default", title: String(localized: "Use View Settings as Default"), symbol: "slider.horizontal.3", category: "View") {
            pane.useViewSettingsAsDefault()
        })
        actions.append(.init(id: "view.reset", title: String(localized: "Reset Folder View Settings"), symbol: "arrow.counterclockwise", category: "View", isEnabled: pane.hasCustomViewSettings) {
            pane.resetViewSettings()
        })

        for tag in TagStore.shared.menuTags {
            actions.append(.init(id: "tag.toggle.\(tag.name)", title: String(localized: "Toggle Tag: \(tag.name)"), symbol: "tag", category: "Tags", isEnabled: hasSelection) {
                state.toggleTag(tag, on: pane.selectedItems)
            })
            actions.append(.init(id: "tag.show.\(tag.name)", title: String(localized: "Show Files Tagged \(tag.name)"), symbol: "tag.fill", category: "Tags") {
                pane.navigate(to: .tag(tag.name))
            })
        }

        // Places: pinned folders, drives and the standard home folders.
        var places: [URL] = PinnedStore.shared.folders + CloudStore.shared.locations.map(\.url) + VolumeStore.shared.volumes.map(\.url)
        places += ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies", "Library", "Library/CloudStorage"]
            .map { home.appendingPathComponent($0) }
        places.append(home)
        var seen = Set<String>()
        for url in places where seen.insert(url.standardizedFileURL.path).inserted && FileSystem.isDirectory(url) {
            let path = url.path.replacingOccurrences(of: home.path, with: "~")
            actions.append(.init(id: "go.\(url.path)", title: String(localized: "Go to \(url.displayName) — \(path)"), symbol: "folder", category: "Places") {
                pane.navigate(to: .folderAt(url))
            })
        }

        actions.append(.init(id: "workspace.save", title: String(localized: "Save Current Layout as Workspace…"), symbol: "rectangle.3.group", category: "Window") {
            state.beginNew(.saveWorkspace)
        })
        actions.append(.init(id: "automation", title: String(localized: "Automation (Scripts & Shortcuts)"), symbol: "gearshape.2", shortcut: ShortcutStore.shared.display(.automation), category: "Tools") {
            NotificationCenter.default.post(name: .openAutomation, object: nil)
        })
        actions.append(.init(id: "s3.sftp", title: String(localized: "SFTP / SSH Servers"), symbol: "server.rack", category: "Tools") {
            NotificationCenter.default.post(name: .openToolWindow, object: "sftp")
        })
        actions.append(.init(id: "s3", title: String(localized: "S3 Storage (AWS, R2, MinIO…)"), symbol: "externaldrive.connected.to.line.below", category: "Tools") {
            NotificationCenter.default.post(name: .openToolWindow, object: "s3")
        })
        actions.append(.init(id: "vault.new", title: String(localized: "New Encrypted Vault…"), symbol: "lock.rectangle.stack", category: "Tools") { state.showNewVault = true })
        for vault in VaultStore.shared.vaults {
            let open = VaultStore.shared.mountPoint(of: vault) != nil
            actions.append(.init(id: "vault.\(vault.id)", title: open ? String(localized: "Lock Vault: \(vault.name)") : String(localized: "Unlock Vault: \(vault.name)"), symbol: open ? "lock" : "lock.open", category: "Vaults") {
                if open { VaultActions.lock(vault, state: state) } else { VaultActions.unlock(vault, state: state) }
            })
        }
        if hasSelection {
            actions.append(.init(id: "permissions", title: String(localized: "Change Permissions…"), symbol: "lock.shield", category: "File") {
                state.permissionsRequest = .init(urls: Array(pane.selection).sorted { $0.path < $1.path })
            })
        }
        actions.append(.init(id: "terminal.toggle", title: state.terminal.isVisible ? "Hide Terminal" : "Show Terminal", symbol: "apple.terminal",
                             shortcut: ShortcutStore.shared.display(.toggleTerminal), category: "Tools") { state.terminal.toggle(folder: folder) })
        actions.append(.init(id: "terminal.new", title: String(localized: "New Terminal Tab"), symbol: "plus.rectangle", category: "Tools") { state.terminal.newSession(in: folder) })
        actions.append(.init(id: "ai.ask", title: String(localized: "Search with AI…"), symbol: "sparkle.magnifyingglass", category: "AI") { state.showAskAI = true })
        let aiTargets = hasSelection ? Array(pane.selection).sorted { $0.path < $1.path } : folder.map { [$0] } ?? []
        if !aiTargets.isEmpty {
            actions.append(.init(id: "ai.chat", title: hasSelection ? "Ask AI About Selection…" : "Ask AI About This Folder…", symbol: "sparkles", category: "AI") {
                state.askAIRequest = AskAITarget(urls: aiTargets)
            })
        }
        actions.append(.init(id: "connect", title: String(localized: "Connect to Server…"), symbol: "network", category: "Places") { state.showConnect = true })
        for entry in ClipboardHistory.shared.entries.prefix(10) {
            actions.append(.init(id: "clip.\(entry.id)", title: String(localized: "Clipboard: \(entry.title)"), symbol: entry.symbol, category: "Clipboard History") {
                ClipboardHistory.shared.restore(entry)
            })
        }
        if Docker.executable != nil {
            actions.append(.init(id: "docker", title: String(localized: "Docker (Containers, Images, Volumes)"), symbol: "shippingbox", category: "Tools") {
                NotificationCenter.default.post(name: .openToolWindow, object: "docker")
            })
        }
        if let git = pane.git {
            actions.append(.init(id: "git.changes", title: String(localized: "Git: Changes & Commit…"), symbol: "arrow.triangle.branch", category: "Git") {
                state.gitRequest = GitTarget(root: git.root)
            })
            actions.append(.init(id: "git.log", title: String(localized: "Git: Repository History"), symbol: "clock.arrow.circlepath", category: "Git") {
                state.gitRequest = GitTarget(root: git.root, path: nil)
            })
        }
        let files = pane.selectedItems.filter { !$0.isDirectory }
        if files.count == 2 {
            actions.append(.init(id: "compare.files", title: String(localized: "Compare Files"), symbol: "doc.on.doc", category: "File") {
                state.textDiffRequest = DiffTarget(left: .file(files[0].url), right: .file(files[1].url))
            })
        }
        if let folder {
            for project in ProjectDetector.detect(in: folder) {
                for command in project.commands {
                    actions.append(.init(id: "project.\(command.command)", title: String(localized: "Run: \(command.command)"), symbol: project.kind.symbol, category: project.kind.title) {
                        AutomationCenter.shared.runCommand(command.command, title: command.command, in: folder)
                        NotificationCenter.default.post(name: .openAutomation, object: nil)
                    })
                }
            }
        }
        if let folder {
            actions.append(.init(id: "organize", title: String(localized: "Suggest Organization…"), symbol: "sparkles", category: "Tools") {
                state.organizeRequest = .init(folder: folder)
            })
        }
        let selection = Array(pane.selection).sorted { $0.path < $1.path }
        for script in AutomationCenter.shared.scripts(for: selection) {
            actions.append(.init(id: "script.\(script.url.path)", title: String(localized: "Run Script: \(script.name)"), symbol: script.language.symbol, category: "Scripts") {
                AutomationCenter.shared.request(script, context: state.scriptContext(for: selection))
            })
        }
        if Features.shared.isOn(.automation) {
            for script in AutomationCenter.shared.panels(.window) {
                actions.append(.init(id: "plugin.\(script.url.path)", title: String(localized: "Open Plugin: \(script.name)"), symbol: "puzzlepiece.extension", category: "Scripts") {
                    NotificationCenter.default.post(name: .openPlugin, object: script.url.path)
                })
            }
        }
        for name in AutomationCenter.shared.shortcuts {
            actions.append(.init(id: "shortcut.\(name)", title: String(localized: "Run Shortcut: \(name)"), symbol: "square.2.layers.3d", category: "Scripts") {
                AutomationCenter.shared.runShortcut(name, input: selection)
            })
        }
        for workspace in WorkspaceStore.shared.workspaces {
            actions.append(.init(id: "workspace.\(workspace.id)", title: String(localized: "Workspace: \(workspace.name)"), symbol: "rectangle.3.group", category: "Places") {
                state.open(workspace)
            })
        }
        for collection in SmartCollection.allCases {
            actions.append(.init(id: "smart.\(collection.rawValue)", title: String(localized: "Smart Collection: \(collection.title)"), symbol: collection.symbol, category: "Places") {
                pane.navigate(to: .search(collection.query))
            })
        }
        for saved in SavedSearchStore.shared.searches {
            actions.append(.init(id: "saved.\(saved.id)", title: String(localized: "Saved Search: \(saved.name)"), symbol: "magnifyingglass", category: "Places") {
                pane.navigate(to: .search(saved.query))
            })
        }

        for (index, tab) in state.tabs.enumerated() where tab.id != state.selectedTabID {
            actions.append(.init(id: "tab.switch.\(tab.id)", title: String(localized: "Switch to Tab \(index + 1): \(tab.title)"), symbol: tab.activePane.location.symbol, category: "Tabs") {
                state.selectedTabID = tab.id
            })
        }

        // Show the user's actual shortcuts (they may have been remapped in Settings).
        let store = ShortcutStore.shared
        for index in actions.indices {
            if let action = shortcutAction(forPaletteID: actions[index].id) {
                actions[index].shortcut = store.display(action)
            }
        }
        return actions.filter { module(for: $0.id).map(Features.shared.isOn) ?? true }
    }

    static func module(for id: String) -> FeatureModule? { FeatureModule.forPaletteAction(id) }

    private static let shortcutIDs: [String: ShortcutAction] = [
        "new.folder": .newFolder, "new.file": .newFile, "open": .open, "quicklook": .quickLook,
        "rename": .rename, "properties": .properties, "cut": .cut, "copy": .copy, "paste": .paste,
        "trash": .trash, "delete.permanent": .deletePermanently, "select.all": .selectAll,
        "terminal": .openTerminal, "undo": .undo, "redo": .redo, "back": .back, "forward": .forward,
        "up": .enclosingFolder, "path": .goToPath, "refresh": .refresh, "home": .home,
        "connect": .connectToServer, "find": .find, "timeline": .timeline, "tab.new": .newTab, "tab.close": .closeTab, "tab.next": .nextTab,
        "tab.previous": .previousTab, "select.matching": .selectMatching, "select.invert": .invertSelection, "pane.dual": .dualPane, "pane.copy": .copyToOtherPane, "pane.move": .moveToOtherPane, "pane.preview": .previewPane, "hidden": .hiddenFiles,
    ]

    private static func shortcutAction(forPaletteID id: String) -> ShortcutAction? {
        if id.hasPrefix("layout."), let mode = LayoutMode(rawValue: String(id.dropFirst(7))) {
            return .forLayout(mode)
        }
        return shortcutIDs[id]
    }

    /// Subsequence fuzzy match; higher is better, nil means no match.
    static func score(_ title: String, query: String) -> Int? {
        let title = title.lowercased()
        let query = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return 0 }
        if title.hasPrefix(query) { return 1000 - title.count }
        if let range = title.range(of: query) {
            let atWordStart = range.lowerBound == title.startIndex || title[title.index(before: range.lowerBound)] == " "
            return (atWordStart ? 800 : 600) - title.count
        }
        var score = 0
        var titleIndex = title.startIndex
        var previousMatch: String.Index?
        for char in query where char != " " {
            guard let found = title[titleIndex...].firstIndex(of: char) else { return nil }
            if let previousMatch, title.index(after: previousMatch) == found { score += 5 }
            if found == title.startIndex || title[title.index(before: found)] == " " { score += 8 }
            score += 1
            previousMatch = found
            titleIndex = title.index(after: found)
        }
        return score
    }
}

struct CommandPalette: View {
    let state: WindowState

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var focused: Bool

    private var results: [PaletteAction] {
        let actions = PaletteActions.all(for: state)
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            // Recently used first, then the usual commands.
            let recent = PaletteHistory.shared.recent.compactMap { id in actions.first { $0.id == id && $0.isEnabled } }
            let recentIDs = Set(recent.map(\.id))
            return recent.map { var a = $0; a.category = "Recent"; return a }
                + actions.filter { $0.isEnabled && $0.category != "Places" && $0.category != "Tags" && !recentIDs.contains($0.id) }
        }
        return actions
            .compactMap { action in PaletteActions.score(action.title, query: query).map { (action, $0 + (action.isEnabled ? 50 : 0)) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    var body: some View {
        let results = self.results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                TextField("Type a command or folder…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { run(results) }
                    .onExitCommand { close() }
                    .onKeyPress(.downArrow) { move(1, count: results.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, count: results.count); return .handled }
            }
            .padding(14)

            Divider()

            if results.isEmpty {
                Text("No matching commands")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, action in
                                row(action, isSelected: index == selectedIndex)
                                    .id(action.id)
                                    .onTapGesture {
                                        selectedIndex = index
                                        run(results)
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: selectedIndex) { _, index in
                        if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
                    }
                }
            }
        }
        .frame(width: 580)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onChange(of: query) { selectedIndex = 0 }
    }

    private func row(_ action: PaletteAction, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: action.symbol)
                .frame(width: 20)
                .foregroundStyle(isSelected ? Color.white : .secondary)
            Text(action.title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(key: action.category)
                .font(.caption)
                .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary.opacity(0.7))
            if !action.shortcut.isEmpty {
                Text(action.shortcut)
                    .font(.callout.monospaced())
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : .secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .foregroundStyle(isSelected ? Color.white : .primary)
        .opacity(action.isEnabled ? 1 : 0.45)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.themeAccent : .clear))
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func run(_ results: [PaletteAction]) {
        guard results.indices.contains(selectedIndex) else { return }
        let action = results[selectedIndex]
        guard action.isEnabled else { NSSound.beep(); return }
        close()
        // Let the palette dismiss first so prompts/alerts present cleanly.
        PaletteHistory.shared.record(action.id)
        DispatchQueue.main.async { action.perform() }
    }

    private func close() {
        state.showCommandPalette = false
    }
}

