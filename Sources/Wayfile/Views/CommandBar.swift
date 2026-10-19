import SwiftUI

/// Files-style command bar: new, clipboard, rename, share, delete, then sort/layout/pane toggles.
struct CommandBar: View {
    @Bindable var state: WindowState

    var body: some View {
        // Never wider than the window: drop text labels first, then scroll as a last resort.
        ViewThatFits(in: .horizontal) {
            bar(compact: false)
            bar(compact: true)
            ScrollView(.horizontal, showsIndicators: false) { bar(compact: true) }
        }
        .frame(height: 34)
    }

    private func bar(compact: Bool) -> some View {
        let config = CommandBarConfig.shared
        return HStack(spacing: 2) {
            ForEach(config.left) { item in itemView(item, compact: compact) }
            Spacer()
            ForEach(config.right) { item in itemView(item, compact: compact) }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
    }

    @ViewBuilder
    private func itemView(_ item: CommandBarItem, compact: Bool) -> some View {
        let pane = state.activePane
        let hasSelection = !pane.selection.isEmpty
        let inFolder = pane.location.folderURL != nil
        let shortcut = { (action: ShortcutAction) in ShortcutStore.shared.display(action) }
        switch item {
        case .new:
            Menu {
                NewItemMenu(state: state)
            } label: {
                if compact { Image(systemName: "plus.circle") } else { Label("New", systemImage: "plus.circle") }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!inFolder)
            .padding(.trailing, 6)
        case .divider:
            Divider().frame(height: 18).padding(.horizontal, 4)
        case .cut:
            CommandButton("Cut (\(shortcut(.cut)))", symbol: "scissors", enabled: hasSelection) { state.copySelection(cut: true) }
        case .copy:
            CommandButton("Copy (\(shortcut(.copy)))", symbol: "doc.on.doc", enabled: hasSelection) { state.copySelection(cut: false) }
        case .paste:
            CommandButton("Paste (\(shortcut(.paste)))", symbol: "doc.on.clipboard", enabled: inFolder) { state.paste() }
        case .trash:
            CommandButton("Move to Trash (\(shortcut(.trash)))", symbol: "trash", enabled: hasSelection) { state.trashSelection() }
        case .rename:
            CommandButton("Rename (\(shortcut(.rename)))", symbol: "character.cursor.ibeam", enabled: hasSelection) { state.beginRename() }
        case .duplicate:
            CommandButton("Duplicate (\(shortcut(.duplicate)))", symbol: "plus.square.on.square", enabled: hasSelection) { state.duplicateSelection() }
        case .compress:
            CommandButton("Compress", symbol: "archivebox", enabled: hasSelection) { state.compressSelection() }
        case .share:
            ShareLink(items: pane.selectedItems.map(\.url)) {
                Image(systemName: "square.and.arrow.up").frame(width: 28, height: 24)
            }
            .buttonStyle(.borderless)
            .disabled(!hasSelection)
            .help("Share")
        case .copyPath:
            CommandButton("Copy Path (\(shortcut(.copyPath)))", symbol: "link", enabled: hasSelection || inFolder) {
                let selected = pane.selectedItems.map(\.url)
                state.copyPaths(selected.isEmpty ? [pane.location.folderURL].compactMap { $0 } : selected)
            }
        case .terminal:
            CommandButton("Open in Terminal", symbol: "terminal", enabled: inFolder) {
                if let folder = pane.location.folderURL { state.openInTerminal(folder) }
            }
        case .dropStack:
            CommandButton("Drop Stack", symbol: "tray.full", enabled: true) { DropStackStore.shared.isVisible.toggle() }
        case .compare:
            CommandButton("Compare Panes", symbol: "arrow.left.arrow.right", enabled: state.paneFolders != nil) { state.comparePanes() }
        case .transferPanes:
            if state.selectedTab.isDualPane {
                Divider().frame(height: 18).padding(.horizontal, 4)
                let target = state.otherPaneFolder?.displayName ?? "other pane"
                let toRight = state.selectedTab.panes.first?.id == state.selectedTab.activePaneID
                CommandButton("Copy to \(target) (\(shortcut(.copyToOtherPane)))",
                              symbol: toRight ? "arrowshape.right" : "arrowshape.left", enabled: state.canTransferToOtherPane) {
                    state.transferToOtherPane(move: false)
                }
                CommandButton("Move to \(target) (\(shortcut(.moveToOtherPane)))",
                              symbol: toRight ? "arrowshape.right.fill" : "arrowshape.left.fill", enabled: state.canTransferToOtherPane) {
                    state.transferToOtherPane(move: true)
                }
            }
        case .sort:
            SortMenu(pane: pane, compact: compact).padding(.trailing, 4)
        case .group:
            GroupMenu(pane: pane, compact: compact).padding(.trailing, 4)
        case .layout:
            Picker("Layout", selection: Binding(get: { pane.layout }, set: { pane.layout = $0 })) {
                ForEach(LayoutMode.allCases) { mode in
                    Image(systemName: mode.symbol).help(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        case .statusCenter:
            StatusCenterButton(state: state).padding(.leading, 4)
        case .palette:
            CommandButton("Command Palette (\(shortcut(.commandPalette)))", symbol: "command", enabled: true) { state.showCommandPalette = true }
        case .ai:
            AIToolbarMenu(state: state, compact: compact).padding(.trailing, 4)
        case .terminalPanel:
            CommandButton("Terminal (\(shortcut(.toggleTerminal)))", symbol: state.terminal.isVisible ? "apple.terminal.fill" : "apple.terminal", enabled: true) {
                state.terminal.toggle(folder: pane.location.folderURL)
            }
        }
    }
}

/// Everything the command bar can show.
enum CommandBarItem: String, Codable, CaseIterable, Identifiable {
    case new, divider, cut, copy, paste, trash, rename, duplicate, compress, share, copyPath, terminal
    case dropStack, compare, transferPanes, sort, group, layout, statusCenter, palette, ai, terminalPanel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .new: return String(localized: "New")
        case .divider: return String(localized: "Separator")
        case .cut: return String(localized: "Cut")
        case .copy: return String(localized: "Copy")
        case .paste: return String(localized: "Paste")
        case .trash: return String(localized: "Move to Trash")
        case .rename: return String(localized: "Rename")
        case .duplicate: return String(localized: "Duplicate")
        case .compress: return String(localized: "Compress")
        case .share: return String(localized: "Share")
        case .copyPath: return String(localized: "Copy Path")
        case .terminal: return String(localized: "Open in Terminal")
        case .dropStack: return String(localized: "Drop Stack")
        case .compare: return String(localized: "Compare Panes")
        case .transferPanes: return String(localized: "Copy/Move to Other Pane (dual pane)")
        case .sort: return String(localized: "Sort")
        case .group: return String(localized: "Group")
        case .layout: return String(localized: "Layouts")
        case .statusCenter: return String(localized: "Status Center")
        case .palette: return String(localized: "Command Palette")
        case .ai: return String(localized: "AI (Ask, Search)")
        case .terminalPanel: return String(localized: "Integrated Terminal")
        }
    }

    var symbol: String {
        switch self {
        case .new: return "plus.circle"
        case .divider: return "line.diagonal"
        case .cut: return "scissors"
        case .copy: return "doc.on.doc"
        case .paste: return "doc.on.clipboard"
        case .trash: return "trash"
        case .rename: return "character.cursor.ibeam"
        case .duplicate: return "plus.square.on.square"
        case .compress: return "archivebox"
        case .share: return "square.and.arrow.up"
        case .copyPath: return "link"
        case .terminal: return "terminal"
        case .dropStack: return "tray.full"
        case .compare: return "arrow.left.arrow.right"
        case .transferPanes: return "arrowshape.right"
        case .sort: return "arrow.up.arrow.down"
        case .group: return "square.stack.3d.up"
        case .layout: return "list.bullet.rectangle"
        case .statusCenter: return "arrow.up.arrow.down.circle"
        case .palette: return "command"
        case .ai: return "sparkles"
        case .terminalPanel: return "apple.terminal"
        }
    }
}

/// Which items the command bar shows, on which side, in which order (Settings → Toolbar).
@MainActor
@Observable
final class CommandBarConfig {
    static let shared = CommandBarConfig()

    static let defaultLeft: [CommandBarItem] = [.new, .divider, .cut, .copy, .paste, .trash, .transferPanes]
    static let defaultRight: [CommandBarItem] = [.terminalPanel, .ai, .sort, .group, .layout, .statusCenter]
    /// Items added in later versions, inserted once into customized bars too.
    private static let introduced: [(CommandBarItem, String)] = [(.ai, "commandBar.introduced.ai"), (.terminalPanel, "commandBar.introduced.terminal")]

    var left: [CommandBarItem] { didSet { save() } }
    var right: [CommandBarItem] { didSet { save() } }

    private init() {
        let ud = UserDefaults.standard
        left = (ud.stringArray(forKey: "commandBar.left")?.compactMap(CommandBarItem.init(rawValue:))) ?? Self.defaultLeft
        right = (ud.stringArray(forKey: "commandBar.right")?.compactMap(CommandBarItem.init(rawValue:))) ?? Self.defaultRight
        for (item, key) in Self.introduced where !ud.bool(forKey: key) {
            ud.set(true, forKey: key)
            if !(left + right).contains(item) { right.insert(item, at: 0) }
        }
    }

    /// Items not on the bar (separators can be added any number of times).
    var available: [CommandBarItem] {
        CommandBarItem.allCases.filter { $0 == .divider || !(left + right).contains($0) }
    }

    func reset() {
        left = Self.defaultLeft
        right = Self.defaultRight
    }

    private func save() {
        UserDefaults.standard.set(left.map(\.rawValue), forKey: "commandBar.left")
        UserDefaults.standard.set(right.map(\.rawValue), forKey: "commandBar.right")
    }
}

private struct CommandButton: View {
    let title: String
    let symbol: String
    let enabled: Bool
    let action: () -> Void

    init(_ title: String, symbol: String, enabled: Bool, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(title)
    }
}


private struct SortMenu: View {
    let pane: PaneState
    var compact = false

    var body: some View {
        let settings = pane.viewSettings
        Menu {
            Picker("Sort By", selection: Binding(
                get: { settings.sortField },
                set: { pane.sortOrder = [$0.comparator(ascending: settings.ascending)] }
            )) {
                ForEach(SortField.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Order", selection: Binding(
                get: { settings.ascending },
                set: { pane.sortOrder = [settings.sortField.comparator(ascending: $0)] }
            )) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Folders First", isOn: Binding(get: { pane.foldersFirst }, set: { pane.foldersFirst = $0 }))
        } label: {
            if compact { Image(systemName: "arrow.up.arrow.down") } else { Label("Sort", systemImage: "arrow.up.arrow.down") }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sort")
    }
}

private struct GroupMenu: View {
    let pane: PaneState
    var compact = false

    var body: some View {
        Menu {
            Picker("Group By", selection: Binding(get: { pane.groupBy }, set: { pane.groupBy = $0 })) {
                ForEach(GroupBy.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Descending", isOn: Binding(get: { pane.groupDescending }, set: { pane.groupDescending = $0 }))
                .disabled(pane.groupBy == .none)
        } label: {
            if compact { Image(systemName: "square.stack.3d.up") } else { Label("Group", systemImage: "square.stack.3d.up") }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!pane.layout.supportsGrouping)
        .help("Group")
    }
}


/// Toolbar AI menu: ask about the selection or folder, search in your own words, choose the model.
struct AIToolbarMenu: View {
    let state: WindowState
    let compact: Bool
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let pane = state.activePane
        let selection = Array(pane.selection).sorted { $0.path < $1.path }
        let folder = pane.location.folderURL
        Menu {
            Button(selection.isEmpty ? String(localized: "Ask AI About This Folder…") : selection.count == 1 ? String(localized: "Ask AI About “\(selection[0].lastPathComponent)”…") : String(localized: "Ask AI About \(selection.count) Items…"),
                   systemImage: "sparkles") {
                if !selection.isEmpty { state.askAIRequest = AskAITarget(urls: selection) }
                else if let folder { state.askAIRequest = AskAITarget(urls: [folder]) }
            }
            .disabled(selection.isEmpty && folder == nil)
            Button(folder.map { "Search “\($0.lastPathComponent)” with AI…" } ?? String(localized: "Search with AI…"), systemImage: "sparkle.magnifyingglass") {
                state.aiSearchFolder = folder
                state.showAskAI = true
            }
            Divider()
            Button("AI Settings… (\(AISettings.shared.provider.title))", systemImage: "gearshape") {
                UserDefaults.standard.set("ai", forKey: "settings.tab")
                openSettings()
            }
        } label: {
            if state.aiBusy {
                ProgressView().controlSize(.small)
            } else if compact {
                Image(systemName: "sparkles")
            } else {
                Label("AI", systemImage: "sparkles")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Ask AI about the selection or this folder, or search in your own words")
    }
}
