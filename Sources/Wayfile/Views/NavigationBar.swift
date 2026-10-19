import SwiftUI

/// Back/forward, pane and layout menus, the omnibar, search, pane toggles and the "…" menu.
struct NavigationBar: View {
    @Bindable var state: WindowState
    @Binding var sidebarVisible: Bool

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let pane = state.activePane
        HStack(spacing: 4) {
            NavButton(symbol: "chevron.left", help: "Back (\(ShortcutStore.shared.display(.back)))", enabled: pane.canGoBack) { pane.goBack() }
            NavButton(symbol: "chevron.right", help: "Forward (\(ShortcutStore.shared.display(.forward)))", enabled: pane.canGoForward) { pane.goForward() }

            panesMenu
            layoutMenu(pane)

            Omnibar(state: state, pane: pane)
                .padding(.horizontal, 4)

            SearchField(state: state, pane: pane)
                .frame(width: 240)

            ToolbarToggle(symbol: "rectangle.split.2x1", help: "Dual Pane (\(ShortcutStore.shared.display(.dualPane)))", isOn: state.selectedTab.isDualPane) {
                state.selectedTab.toggleDualPane()
            }
            ToolbarToggle(symbol: "sidebar.right", help: "Inspector (\(ShortcutStore.shared.display(.previewPane)))", isOn: state.showPreviewPane) {
                state.showPreviewPane.toggle()
            }
            moreMenu(pane)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var panesMenu: some View {
        Menu {
            Toggle("Sidebar", isOn: $sidebarVisible)
            Picker("Panes", selection: Binding(
                get: { state.selectedTab.panes.count },
                set: { state.selectedTab.setPaneCount($0) }
            )) {
                Label("Single Pane", systemImage: "rectangle").tag(1)
                Label("Dual Pane", systemImage: "rectangle.split.2x1").tag(2)
                Label("Quad Pane", systemImage: "rectangle.split.2x2").tag(4)
            }
            .pickerStyle(.inline)
            Toggle("Synchronize Navigation", isOn: Binding(get: { state.selectedTab.isSynced }, set: { state.selectedTab.isSynced = $0 }))
                .disabled(!state.selectedTab.isDualPane)
            Toggle("Inspector", isOn: $state.showPreviewPane)
            Divider()
            Button("Compare Panes", systemImage: "arrow.left.arrow.right") { state.comparePanes() }
                .disabled(state.paneFolders == nil)
        } label: {
            Image(systemName: "rectangle.split.2x1")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help("Panes")
    }

    private func layoutMenu(_ pane: PaneState) -> some View {
        Menu {
            Picker("Layout", selection: Binding(get: { pane.layout }, set: { pane.layout = $0 })) {
                ForEach(LayoutMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Show Hidden Files", isOn: $state.showHidden)
            Toggle("Folders First", isOn: Binding(get: { pane.foldersFirst }, set: { pane.foldersFirst = $0 }))
            Divider()
            Button("Use as Default for All Folders") { pane.useViewSettingsAsDefault() }
            Button("Reset This Folder to Default") { pane.resetViewSettings() }
                .disabled(!pane.hasCustomViewSettings)
            Toggle("Same View for All Folders", isOn: Binding(
                get: { ViewSettingsStore.shared.syncAcrossFolders },
                set: { ViewSettingsStore.shared.syncAcrossFolders = $0; pane.applyViewSettings() }
            ))
        } label: {
            Image(systemName: pane.layout.symbol)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help("View")
    }

    private func moreMenu(_ pane: PaneState) -> some View {
        Menu {
            Button("Refresh", systemImage: "arrow.clockwise") { pane.reload() }
            Button("Enclosing Folder", systemImage: "arrow.up") { pane.goUp() }
                .disabled(!pane.canGoUp)
            Divider()
            Button("New Tab", systemImage: "plus.square.on.square") { state.newTab() }
            Menu {
                ForEach(WorkspaceStore.shared.workspaces) { workspace in
                    Button(workspace.name) { state.open(workspace) }
                }
                if !WorkspaceStore.shared.workspaces.isEmpty { Divider() }
                Button("Save Current Layout as Workspace…") { state.beginNew(.saveWorkspace) }
            } label: {
                Label("Workspaces", systemImage: "rectangle.3.group")
            }
            Button("Command Palette…", systemImage: "command") { state.showCommandPalette = true }
            Button("Status Center", systemImage: "arrow.up.arrow.down.circle") { state.showStatusCenter = true }
            Toggle(isOn: Binding(get: { DropStackStore.shared.isVisible }, set: { DropStackStore.shared.isVisible = $0 })) {
                Label("Drop Stack", systemImage: "tray.full")
            }
            Button("Connect to Server…", systemImage: "network") { state.beginNew(.connectToServer) }
            Divider()
            Button("Settings…", systemImage: "gearshape") { openSettings() }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }
}

/// Toolbar button that shows an on/off state.
struct ToolbarToggle: View {
    let symbol: String
    let help: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(isOn ? Color.themeAccent : Color.primary)
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(isOn ? Color.themeAccent.opacity(0.15) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

struct NavButton: View {
    let symbol: String
    let help: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
    }
}

private struct SearchField: View {
    @Bindable var state: WindowState
    @Bindable var pane: PaneState

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter, \(ShortcutStore.shared.display(.find)) to search", text: $pane.filterText)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit {
                    let query = pane.filterText
                    if !query.isEmpty { state.search(query) }
                }
            if !pane.filterText.isEmpty {
                Button { pane.filterText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
        .onChange(of: state.focusSearchField) { _, requested in
            guard requested else { return }
            focused = true
            state.focusSearchField = false
        }
    }
}

/// Breadcrumb path that turns into an editable path field with folder autocomplete.
struct Omnibar: View {
    @Bindable var state: WindowState
    let pane: PaneState

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            if state.isEditingPath {
                TextField("Path or search", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit {
                        state.isEditingPath = false
                        state.submitPath(text)
                    }
                    .onExitCommand { state.isEditingPath = false }
                    .onKeyPress(.tab) {
                        if let first = suggestions.first { text = first.path + "/" }
                        return .handled
                    }
                    .padding(.horizontal, 8)
            } else {
                breadcrumbs
            }
        }
        .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(state.isEditingPath ? Color.themeAccent : Color.primary.opacity(0.1))
        )
        .overlay(alignment: .topLeading) {
            if state.isEditingPath && !suggestions.isEmpty {
                suggestionList.offset(y: 30)
            }
        }
        .onChange(of: state.isEditingPath) { _, editing in
            if editing {
                text = pane.location.folderURL?.path ?? ""
                DispatchQueue.main.async { focused = true }
            }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { state.isEditingPath = false }
        }
    }

    /// Path segments; when they don't fit, middle folders collapse into a "…" menu (deepest stay visible).
    /// The crumbs live in an overlay so a long path can never widen the window.
    private var breadcrumbs: some View {
        let segments = Self.segments(for: pane.location)
        return Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            // Clicking the empty part of the bar switches to edit mode.
            .onTapGesture { state.isEditingPath = true }
            .overlay(alignment: .leading) {
                ViewThatFits(in: .horizontal) {
                    // Hide 0, 1, 2… middle segments until the row fits; the last variant always fits.
                    ForEach(0..<max(segments.count - 1, 1), id: \.self) { hidden in
                        crumbRow(segments, hidingMiddle: hidden, truncateLast: false)
                    }
                    crumbRow(segments, hidingMiddle: max(segments.count - 1, 0), truncateLast: true)
                }
                .padding(.leading, 4)
                .padding(.trailing, 40)
            }
            .clipped()
    }

    /// First segment, then (if any are hidden) a "…" menu, then the remaining deepest segments.
    @ViewBuilder
    private func crumbRow(_ segments: [Segment], hidingMiddle hidden: Int, truncateLast: Bool) -> some View {
        let hiddenRange = hidden > 0 ? 1..<min(1 + hidden, segments.count) : 1..<1
        let shown = segments.indices.filter { !hiddenRange.contains($0) }
        HStack(spacing: 2) {
            ForEach(Array(shown.enumerated()), id: \.element) { position, index in
                if position > 0 {
                    Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                }
                if position == 1, !hiddenRange.isEmpty {
                    Menu {
                        ForEach(Array(hiddenRange), id: \.self) { hiddenIndex in
                            Button(segments[hiddenIndex].title) {
                                if let location = segments[hiddenIndex].location { pane.navigate(to: location) }
                            }
                        }
                    } label: {
                        Text("…")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(segments[hiddenRange].map(\.title).joined(separator: " › "))
                    Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                }
                let isLast = index == segments.count - 1
                if index == 0, segments[index].location?.folderURL != nil {
                    Image(systemName: "internaldrive").foregroundStyle(.secondary).padding(.leading, 2)
                } else if isLast, let url = segments[index].location?.folderURL {
                    Image(nsImage: IconCache.icon(for: url)).resizable().frame(width: 16, height: 16)
                }
                Button(segments[index].title) {
                    if let location = segments[index].location { pane.navigate(to: location) }
                }
                .buttonStyle(BreadcrumbButtonStyle())
                .truncationMode(.middle)
                .fixedSize(horizontal: !(truncateLast && isLast), vertical: false)
                .help(segments[index].title)
            }
        }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions, id: \.self) { url in
                Button {
                    state.isEditingPath = false
                    pane.navigate(to: .folderAt(url))
                } label: {
                    Label(url.path, systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: 520, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .shadow(radius: 8, y: 3)
    }

    /// Subfolders of the typed parent directory whose names start with the typed prefix.
    private var suggestions: [URL] {
        let expanded = (text as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return [] }
        let parent = expanded.hasSuffix("/") ? expanded : (expanded as NSString).deletingLastPathComponent
        let prefix = expanded.hasSuffix("/") ? "" : (expanded as NSString).lastPathComponent.lowercased()
        let parentURL = URL(fileURLWithPath: parent, isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: parentURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { prefix.isEmpty || $0.lastPathComponent.lowercased().hasPrefix(prefix) }
            .filter { $0.standardizedFileURL.path != expanded }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(8)
            .map { $0 }
    }

    struct Segment {
        let title: String
        let location: Location?
    }

    static func segments(for location: Location) -> [Segment] {
        switch location {
        case .home:
            return [Segment(title: String(localized: "Home"), location: .home)]
        case .timeline:
            return [Segment(title: String(localized: "Timeline"), location: .timeline)]
        case .activity:
            return [Segment(title: String(localized: "Timeline"), location: .timeline)]
        case .search(let query):
            let base = query.scope.root.map { segments(for: .folderAt($0)) } ?? [Segment(title: String(localized: "Entire Mac"), location: nil)]
            return base + [Segment(title: query.title, location: nil)]
        case .tag(let name):
            return [Segment(title: String(localized: "Tags"), location: nil), Segment(title: name, location: nil)]
        case .folder(let url):
            var result: [Segment] = []
            var current = url.standardizedFileURL
            while true {
                result.insert(Segment(title: current.displayName, location: .folderAt(current)), at: 0)
                if current.path == "/" { break }
                current = current.deletingLastPathComponent().standardizedFileURL
            }
            return result
        }
    }
}

struct BreadcrumbButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverHighlight(isPressed: configuration.isPressed) { configuration.label.lineLimit(1) }
    }
}

/// Subtle rounded highlight on hover/press, used for flat toolbar-like buttons.
struct HoverHighlight<Content: View>: View {
    var isPressed = false
    @ViewBuilder let content: Content

    @State private var isHovering = false

    var body: some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(isPressed ? 0.15 : (isHovering ? 0.07 : 0)))
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}
