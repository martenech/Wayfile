import AppKit
import SwiftUI

@main
struct WayfileApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Wayfile") {
            MainView()
                .frame(minWidth: 820, minHeight: 480)
        }
        .defaultSize(width: 1280, height: 780)
        // Tabs live in the title bar area (drawn by MainView), like Files and Safari.
        .windowStyle(.hiddenTitleBar)
        .commands { WayfileCommands() }

        WindowGroup("Properties", id: "properties", for: PropertiesTarget.self) { $target in
            if let target {
                PropertiesView(target: target)
            }
        }
        .windowResizability(.contentSize)

        WindowGroup("Compare Folders", id: "compare", for: CompareTarget.self) { $target in
            if let target { CompareView(target: target) }
        }
        .defaultSize(width: 980, height: 620)

        WindowGroup("Log Viewer", id: "log", for: URL.self) { $url in
            if let url { LogViewerView(url: url) }
        }
        .defaultSize(width: 900, height: 600)

        WindowGroup("Duplicates", id: "duplicates", for: URL.self) { $folder in
            if let folder { DuplicatesView(folder: folder) }
        }
        .defaultSize(width: 860, height: 600)

        WindowGroup("Ask AI", id: "askai", for: AskAITarget.self) { $target in
            if let target { AskAIView(target: target) }
        }
        .defaultSize(width: 720, height: 640)

        WindowGroup("Compare Files", id: "textdiff", for: DiffTarget.self) { $target in
            if let target { TextCompareView(target: target) }
        }
        .defaultSize(width: 1100, height: 700)

        WindowGroup("Git", id: "git", for: GitTarget.self) { $target in
            if let target { GitWindow(target: target) }
        }
        .defaultSize(width: 1100, height: 720)

        WindowGroup("Disk Usage", id: "diskusage", for: URL.self) { $url in
            if let url { DiskUsageView(root: url) }
        }
        .defaultSize(width: 1000, height: 680)

        WindowGroup("Archive", id: "archive", for: URL.self) { $url in
            if let url { ArchiveBrowserView(archive: url) }
        }
        .defaultSize(width: 720, height: 520)

        Window("SFTP", id: "sftp") {
            SFTPBrowserView()
        }
        .defaultSize(width: 980, height: 620)

        Window("S3 Storage", id: "s3") {
            S3BrowserView()
        }
        .defaultSize(width: 980, height: 620)

        Window("Docker", id: "docker") {
            DockerView()
        }
        .defaultSize(width: 900, height: 600)

        WindowGroup("Plugin", id: "plugin", for: String.self) { $path in
            if let path { PluginWindow(path: path) }
        }
        .defaultSize(width: 460, height: 560)

        Window("Automation", id: "automation") {
            AutomationView()
        }
        .defaultSize(width: 1000, height: 680)

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // SwiftUI autosaves the sidebar split per window under a fragile key and that would override
        // our remembered width (RememberedWidth.sidebar); drop it so the remembered width always applies.
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("NSSplitView Subview Frames") && key.contains("SidebarNavigationSplitView") {
            defaults.removeObject(forKey: key)
        }
    }

    /// Transfers still in the journal were cut short last time; offer to finish them.
    @MainActor
    private func offerTransferRecovery() {
        let jobs = TransferJournal.shared.jobs
        guard !jobs.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let alert = NSAlert()
            alert.messageText = String(localized: "\(jobs.count) transfers didn’t finish last time")
            alert.informativeText = jobs.prefix(5).map { "• \($0.title)" }.joined(separator: "\n")
                + "\n\nResuming skips items that were copied completely and redoes the rest (partial copies go to the Trash)."
            alert.addButton(withTitle: String(localized: "Resume"))
            alert.addButton(withTitle: String(localized: "Discard"))
            if alert.runModal() == .alertFirstButtonReturn, let state = WindowState.lastActive {
                jobs.forEach(state.resume)
            } else {
                TransferJournal.shared.clear()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            TimelineStore.shared.saveNow()
            ActivityRecorder.shared.saveNow()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) rather than an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated {
            ThemeStore.shared.applyAppearance()
            AutomationCenter.shared.start()
            RulesStore.shared.start()
            ClipboardHistory.shared.start()
            ActivityRecorder.shared.start()
            offerTransferRecovery()
        }
        #if DEBUG
        // `swift run` has no bundle, so show the app icon in the Dock from the source tree.
        if Bundle.main.bundleIdentifier == nil {
            let icon = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../Resources/AppIcon.png").standardizedFileURL
            NSApp.applicationIconImage = NSImage(contentsOf: icon)
        }
        #endif
        #if DEBUG
        scheduleSnapshotIfRequested()
        #endif
    }

    #if DEBUG
    /// Dev aid: `WAYFILE_SNAPSHOT=/path/out.png` renders each visible window to a PNG after launch
    /// (out.png for the first, out-1.png, out-2.png… for the rest).
    private func scheduleSnapshotIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["WAYFILE_SNAPSHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["WAYFILE_SNAPSHOT_DELAY"] ?? "") ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0.frame.width > 200 }
            for (index, window) in windows.enumerated() {
                guard let view = window.contentView?.superview,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = URL(fileURLWithPath: path)
                let out = index == 0 ? url : url.deletingPathExtension().appendingPathExtension("").deletingPathExtension()
                    .deletingLastPathComponent().appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(index).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: out)
            }
        }
    }
    #endif
}

struct WayfileCommands: Commands {
    @FocusedValue(\.windowState) private var state
    @Environment(\.openWindow) private var openWindow

    private var hasSelection: Bool { !(state?.activePane.selection.isEmpty ?? true) }
    private var inFolder: Bool { state?.activePane.location.folderURL != nil }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") { state?.newTab() }
                .shortcut(.newTab)
            Button("New Folder…") { state?.beginNew(.newFolder) }
                .shortcut(.newFolder)
                .disabled(!inFolder)
            Button("New Text Document…") { state?.beginNew(.newFile(.text)) }
                .shortcut(.newFile)
                .disabled(!inFolder)
            Divider()
            Button("Open") { state?.openSelection() }
                .shortcut(.open)
                .disabled(!hasSelection)
            Button("Get Info") { state?.showProperties() }
                .shortcut(.properties)
            Button("Quick Look") { state?.toggleQuickLook() }
                .shortcut(.quickLook)
                .disabled(!hasSelection)
            Button((state?.activePane.selection.count ?? 0) > 1 ? String(localized: "Rename \(state?.activePane.selection.count ?? 0) Items…") : String(localized: "Rename…")) { state?.beginRename() }
                .shortcut(.rename)
                .disabled(!hasSelection)
            Button(state?.otherPaneFolder.map { "Copy to “\($0.displayName)”" } ?? String(localized: "Copy to Other Pane")) {
                state?.transferToOtherPane(move: false)
            }
            .shortcut(.copyToOtherPane)
            .disabled(!(state?.canTransferToOtherPane ?? false))
            Button(state?.otherPaneFolder.map { "Move to “\($0.displayName)”" } ?? String(localized: "Move to Other Pane")) {
                state?.transferToOtherPane(move: true)
            }
            .shortcut(.moveToOtherPane)
            .disabled(!(state?.canTransferToOtherPane ?? false))
            Button("Copy Path") {
                guard let state else { return }
                let selected = state.activePane.selectedItems.map(\.url)
                state.copyPaths(selected.isEmpty ? [state.activePane.location.folderURL].compactMap { $0 } : selected)
            }
            .shortcut(.copyPath)
            if let state {
                CopyMoveToMenu(state: state, urls: nil, move: false).disabled(!hasSelection)
                CopyMoveToMenu(state: state, urls: nil, move: true).disabled(!hasSelection)
            }
            Button("Duplicate") { state?.duplicateSelection() }
                .shortcut(.duplicate)
                .disabled(!hasSelection)
            Button("Compress") { state?.compressSelection() }
                .disabled(!hasSelection)
            Button("Extract Here") { state?.extractSelection() }
                .disabled(!(state?.activePane.selectedItems.contains(where: \.isArchive) ?? false))
            Divider()
            Button("Open in Terminal") {
                if let state, let url = state.activePane.location.folderURL { state.openInTerminal(url) }
            }
            .shortcut(.openTerminal)
            .disabled(!inFolder)
            Button("Connect to Server…") { state?.beginNew(.connectToServer) }
                .shortcut(.connectToServer)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { state?.closeSelectedTab() }
                .shortcut(.closeTab)
        }

        CommandGroup(replacing: .undoRedo) {
            Button(OperationCenter.shared.undoTitle.map { "Undo \($0)" } ?? String(localized: "Undo")) {
                if !forwardToText(Selector(("undo:"))) { state?.undo() }
            }
            .shortcut(.undo)
            Button(OperationCenter.shared.redoTitle.map { "Redo \($0)" } ?? String(localized: "Redo")) {
                if !forwardToText(Selector(("redo:"))) { state?.redo() }
            }
            .shortcut(.redo)
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { if !forwardToText(#selector(NSText.cut(_:))) { state?.copySelection(cut: true) } }
                .shortcut(.cut)
            Button("Copy") { if !forwardToText(#selector(NSText.copy(_:))) { state?.copySelection(cut: false) } }
                .shortcut(.copy)
            Button("Paste") { if !forwardToText(#selector(NSText.paste(_:))) { state?.paste() } }
                .shortcut(.paste)
            Button("Select All") { if !forwardToText(#selector(NSText.selectAll(_:))) { state?.selectAll() } }
                .shortcut(.selectAll)
            Button("Select Matching…") { state?.showSelectMatching = true }
                .shortcut(.selectMatching)
            Button("Invert Selection") { state?.invertSelection() }
                .shortcut(.invertSelection)
            Button("Select Same Kind") { state?.selectSameKind() }
                .disabled(!hasSelection)
            Divider()
            Button("Move to Trash") {
                if !forwardToText(#selector(NSResponder.deleteToBeginningOfLine(_:))) { state?.trashSelection() }
            }
            .shortcut(.trash)
            Button("Delete Permanently…") { state?.beginPermanentDelete() }
                .shortcut(.deletePermanently)
                .disabled(!hasSelection)
            Divider()
            ClipboardHistoryMenu()
        }

        CommandGroup(after: .sidebar) {
            Button("Command Palette…") { state?.showCommandPalette.toggle() }
                .shortcut(.commandPalette)
            Button(state?.terminal.isVisible == true ? String(localized: "Hide Terminal") : String(localized: "Show Terminal")) {
                state?.terminal.toggle(folder: state?.activePane.location.folderURL)
            }
            .shortcut(.toggleTerminal)
            Divider()
            Picker("Layout", selection: Binding(
                get: { state?.activePane.layout ?? .details },
                set: { state?.activePane.layout = $0 }
            )) {
                ForEach(LayoutMode.allCases) { mode in
                    Text("as \(mode.title)").tag(mode)
                        .shortcut(.forLayout(mode))
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button(state?.showPreviewPane ?? true ? String(localized: "Hide Inspector") : String(localized: "Show Inspector")) {
                state?.showPreviewPane.toggle()
            }
            .shortcut(.previewPane)
            Button(state?.selectedTab.isDualPane ?? false ? String(localized: "Single Pane") : String(localized: "Dual Pane")) {
                state?.selectedTab.toggleDualPane()
            }
            .shortcut(.dualPane)
            Button(state?.showHidden ?? false ? String(localized: "Hide Hidden Files") : String(localized: "Show Hidden Files")) {
                state?.showHidden.toggle()
            }
            .shortcut(.hiddenFiles)
            Divider()
            Button("Refresh") { state?.activePane.reload() }
                .shortcut(.refresh)
            Divider()
            Button("Next Tab") { state?.selectAdjacentTab(1) }
                .shortcut(.nextTab)
            Button("Previous Tab") { state?.selectAdjacentTab(-1) }
                .shortcut(.previousTab)
        }

        CommandMenu("Go") {
            Button("Back") { state?.activePane.goBack() }
                .shortcut(.back)
            Button("Forward") { state?.activePane.goForward() }
                .shortcut(.forward)
            Button("Enclosing Folder") { state?.activePane.goUp() }
                .shortcut(.enclosingFolder)
            Divider()
            Button("Home") { state?.activePane.navigate(to: .home) }
                .shortcut(.home)
            Button("Desktop") { go(to: "Desktop") }
                .shortcut(.desktop)
            Button("Documents") { go(to: "Documents") }
                .shortcut(.documents)
            Button("Downloads") { go(to: "Downloads") }
                .shortcut(.downloads)
            Button("Applications") { state?.activePane.navigate(to: .folderAt(URL(fileURLWithPath: "/Applications"))) }
                .shortcut(.applications)
            Divider()
            Button("Timeline") { state?.activePane.navigate(to: .timeline) }
                .shortcut(.timeline)
            Button("Find…") { state?.focusSearchField = true }
                .shortcut(.find)
            Button("Go to Path…") { state?.isEditingPath = true }
                .shortcut(.goToPath)
        }

        CommandMenu("Tools") {
            let features = Features.shared
            if features.isOn(.automation) {
                Button("Automation…") { openWindow(id: "automation") }
                    .shortcut(.automation)
                ScriptsMenu(state: state, urls: nil)
                Divider()
            }
            if features.isOn(.developer) { Button("Docker…") { openWindow(id: "docker") } }
            if features.isOn(.remote) {
                Button("SFTP / SSH…") { openWindow(id: "sftp") }
                Button("S3 Storage…") { openWindow(id: "s3") }
            }
            if features.isOn(.security) {
                Divider()
                Button("New Encrypted Vault…") { state?.showNewVault = true }
                Button("Add Existing Vault…") { if let state { VaultActions.addExisting(state: state) } }
            }
            Divider()
            Picker("Mode", selection: Binding(get: { features.mode }, set: { features.mode = $0 })) {
                Text("Standard").tag(Features.Mode.standard)
                Text("Power").tag(Features.Mode.power)
                if features.mode == .custom { Text("Custom").tag(Features.Mode.custom) }
            }
        }
    }

    private func go(to homeSubfolder: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(homeSubfolder)
        state?.activePane.navigate(to: .folderAt(url))
    }

    /// When a text field is being edited, editing shortcuts must act on the text, not on files.
    private func forwardToText(_ action: Selector) -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder as? NSText else { return false }
        return NSApp.sendAction(action, to: responder, from: nil)
    }
}
