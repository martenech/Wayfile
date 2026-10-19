import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Customizable Home dashboard: greeting, then cards the user picks, orders (drag) and arranges by preset.
struct HomeView: View {
    let state: WindowState
    let pane: PaneState

    @State private var showCustomize = false
    @State private var showGallery = false
    @State private var width: CGFloat = 900
    private var config: HomeConfig { .shared }

    private var columnCount: Int { width >= 1150 ? 3 : width >= 720 ? 2 : 1 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                let hidden = HomeWidget.allCases.filter { !config.isShown($0) }
                let columns = HomeConfig.columns(for: config.widgets, count: columnCount)
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                        VStack(spacing: 14) {
                            ForEach(column) { widget in
                                WidgetCard(widget: widget) { widgetContent(widget) } accessory: { accessory(widget) }
                            }
                            // The "Add Widget" tile sits at the bottom of the last column.
                            if index == columns.count - 1 && !hidden.isEmpty { addWidgetTile }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                if config.widgets.isEmpty {
                    ContentUnavailableView {
                        Label("Your Home is empty", systemImage: "square.dashed")
                    } description: {
                        Text("Add widgets or pick a layout.")
                    } actions: {
                        Button("Add Widget…") { showGallery = true }
                    }
                }
                footer
            }
            .padding(20)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
        .themedContentBackground()
        .popover(isPresented: $showGallery, arrowEdge: .top) { WidgetGallery() }
    }

    // MARK: Header

    private var header: some View {
        ZStack(alignment: .topTrailing) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    if config.showGreeting {
                        Text("\(HomeConfig.greeting()), \(firstName)").font(.system(size: 30, weight: .bold))
                    }
                    Text("Everything in one place. Customize your workspace.").foregroundStyle(.secondary)
                }
                Spacer(minLength: 20)
                if config.showQuote {
                    Text("“\(HomeConfig.quote())”")
                        .font(.callout.italic())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 260, alignment: .trailing)
                        .padding(.trailing, 150)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            Button { showCustomize.toggle() } label: {
                Label("Customize", systemImage: "slider.horizontal.3")
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    // Solid glass so it stays readable on any picture.
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(14)
            .popover(isPresented: $showCustomize, arrowEdge: .bottom) { CustomizeHome() }
        }
        .background(headerBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var headerBackground: some View {
        if let url = config.backgroundImage, let image = NSImage(contentsOf: url) {
            // Sized to the header and clipped, so a big picture never pushes or covers anything.
            Color.clear
                .overlay(Image(nsImage: image).resizable().scaledToFill())
                .clipped()
                .overlay(LinearGradient(colors: [Color(nsColor: .windowBackgroundColor).opacity(0.95), Color(nsColor: .windowBackgroundColor).opacity(0.55),
                                                 Color(nsColor: .windowBackgroundColor).opacity(0.25)],
                                        startPoint: .leading, endPoint: .trailing))
        } else {
            LinearGradient(colors: [Color.themeAccent.opacity(0.10), Color.themeAccent.opacity(0.22)], startPoint: .leading, endPoint: .trailing)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "mountain.2.fill")
                        .font(.system(size: 110))
                        .foregroundStyle(Color.themeAccent.opacity(0.18))
                        .offset(x: -24, y: 30)
                }
        }
    }

    private var firstName: String {
        let custom = config.displayName.trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? (NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()) : custom
    }

    private var footer: some View {
        HStack {
            Text("“Same files. A better way.”").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(HomePreset.allCases.filter { $0 != .custom }) { preset in
                    Button { config.apply(preset) } label: {
                        Label(preset.title + (preset == config.preset ? " ✓" : ""), systemImage: preset.symbol)
                    }
                }
            } label: {
                Label(config.preset.title, systemImage: config.preset.symbol)
            }
            .fixedSize()
            .help("Layouts: Everyday, Developer, Minimal")
        }
        .padding(.top, 6)
    }

    private var addWidgetTile: some View {
        Button { showGallery = true } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus").font(.title)
                Text("Add Widget").fontWeight(.medium)
                Text("Choose from gallery").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])).foregroundStyle(.tertiary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Widgets

    @ViewBuilder
    private func widgetContent(_ widget: HomeWidget) -> some View {
        switch widget {
        case .quickAccess: QuickAccessWidget(state: state, pane: pane)
        case .recentFiles: RecentFilesWidget(state: state, pane: pane)
        case .drives: DrivesWidget(state: state, pane: pane)
        case .cloudStorage: CloudWidget(pane: pane)
        case .pinnedProjects: ProjectsWidget(state: state, pane: pane)
        case .gitRepositories: GitReposWidget(state: state, pane: pane)
        case .tags: TagsWidget(pane: pane)
        case .transferQueue: TransfersWidget()
        case .notes: NotesWidget()
        case .scripts: ScriptsWidget(state: state)
        case .smartCollections: SmartCollectionsWidget(pane: pane)
        case .timeline: ActivityWidget(pane: pane)
        }
    }

    @ViewBuilder
    private func accessory(_ widget: HomeWidget) -> some View {
        switch widget {
        case .recentFiles:
            Button("See All") { pane.navigate(to: .search(SmartCollection.recentDocuments.query)) }.buttonStyle(.link).font(.caption)
        case .pinnedProjects:
            Button { chooseFolder { HomeConfig.shared.pinProject($0) } } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless).help("Pin a project folder").accessibilityLabel("Pin a project folder")
        case .timeline:
            Button("Open") { pane.navigate(to: .timeline) }.buttonStyle(.link).font(.caption)
        default:
            EmptyView()
        }
    }
}

@MainActor
func chooseFolder(_ done: (URL) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    if panel.runModal() == .OK { panel.urls.forEach(done) }
}

/// Card chrome: title, accessory, "…" menu (move / hide); drag the title to reorder.
private struct WidgetCard<Content: View, Accessory: View>: View {
    let widget: HomeWidget
    @ViewBuilder let content: Content
    @ViewBuilder let accessory: Accessory
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: widget.symbol).foregroundStyle(Color.themeAccent)
                Text(widget.title).font(.headline)
                Spacer()
                accessory
                Menu {
                    Button("Move Earlier") { HomeConfig.shared.move(widget, by: -1) }
                    Button("Move Later") { HomeConfig.shared.move(widget, by: 1) }
                    Divider()
                    Button("Hide Widget") { HomeConfig.shared.setShown(widget, false) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("\(widget.title) options")
            }
            .contentShape(Rectangle())
            .draggable(widget.rawValue)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.themeSurface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(targeted ? Color.themeAccent : Color.primary.opacity(0.08), lineWidth: targeted ? 2 : 1))
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let dragged = HomeWidget(rawValue: raw) else { return false }
            withAnimation { HomeConfig.shared.move(dragged, before: widget) }
            return true
        } isTargeted: { targeted = $0 }
    }
}

private struct CustomizeHome: View {
    @Bindable private var config = HomeConfig.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Customize Home").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(HomeWidget.allCases) { widget in
                Toggle(isOn: Binding(get: { config.isShown(widget) }, set: { config.setShown(widget, $0) })) {
                    Label(widget.title, systemImage: widget.symbol)
                }
            }
            Divider()
            Toggle("Greeting", isOn: $config.showGreeting)
            if config.showGreeting {
                TextField("Your name", text: $config.displayName, prompt: Text(NSFullUserName().split(separator: " ").first.map(String.init) ?? String(localized: "Name")))
                    .textFieldStyle(.roundedBorder).controlSize(.small)
            }
            Toggle("Quote of the day", isOn: $config.showQuote)
            HStack {
                Button("Background Image…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.image]
                    if panel.runModal() == .OK { config.backgroundImage = panel.url }
                }
                if config.backgroundImage != nil { Button("Remove") { config.backgroundImage = nil } }
            }
            .controlSize(.small)
            Text("Drag a card's title to reorder.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("Reset to Default") { config.reset() }.buttonStyle(.link)
        }
        .toggleStyle(.checkbox)
        .padding(14)
        .frame(width: 250)
    }
}

private struct WidgetGallery: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let hidden = HomeWidget.allCases.filter { !HomeConfig.shared.isShown($0) }
        VStack(alignment: .leading, spacing: 8) {
            Text("Add Widget").font(.headline)
            if hidden.isEmpty { Text("Every widget is already on Home.").foregroundStyle(.secondary) }
            ForEach(hidden) { widget in
                Button {
                    HomeConfig.shared.setShown(widget, true)
                    if HomeWidget.allCases.allSatisfy(HomeConfig.shared.isShown) { dismiss() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: widget.symbol).font(.title3).foregroundStyle(Color.themeAccent).frame(width: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(widget.title).fontWeight(.medium)
                            Text(widget.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "plus.circle")
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

// MARK: - Widget views

private struct QuickAccessWidget: View {
    let state: WindowState
    let pane: PaneState
    @State private var editing = false

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
            ForEach(PinnedStore.shared.folders, id: \.self) { url in
                Button { pane.navigate(to: .folderAt(url)) } label: {
                    VStack(spacing: 4) {
                        Image(nsImage: IconCache.icon(for: url)).resizable().frame(width: 44, height: 44)
                        Text(url.displayName).lineLimit(1)
                        Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
                    .overlay(alignment: .topTrailing) {
                        if editing {
                            Button { PinnedStore.shared.unpin(url) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                                .buttonStyle(.plain).padding(4).accessibilityLabel("Remove \(url.lastPathComponent)")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Open in New Tab") { state.newTab(.folderAt(url)) }
                    Button("Remove from Quick Access") { PinnedStore.shared.unpin(url) }
                }
            }
            Button { chooseFolder { PinnedStore.shared.pin($0) } } label: {
                VStack(spacing: 4) {
                    Image(systemName: "plus").font(.title2).frame(height: 44)
                    Text("Add Folder").font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 3])).foregroundStyle(.tertiary))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .overlay(alignment: .topTrailing) {
            Button(editing ? String(localized: "Done") : String(localized: "Edit")) { editing.toggle() }.buttonStyle(.link).font(.caption).offset(x: -26, y: -30)
        }
    }
}

private struct RecentFilesWidget: View {
    let state: WindowState
    let pane: PaneState
    @State private var recent: [URL] = []

    var body: some View {
        VStack(spacing: 0) {
            if recent.isEmpty { Text("No recent files.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            ForEach(recent.prefix(6), id: \.self) { url in
                Button { NSWorkspace.shared.open(url) } label: {
                    HStack(spacing: 10) {
                        if let item = FileItem(url: url) {
                            Thumbnail(item: item, size: 30)
                        } else {
                            Image(nsImage: IconCache.icon(for: url)).resizable().frame(width: 30, height: 30)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent).lineLimit(1)
                            Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        Text(relative(url)).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Open File Location") { pane.navigate(to: .folderAt(url.deletingLastPathComponent())) }
                    Button("Show in Finder") { state.revealInFinder([url]) }
                }
            }
        }
        .task { recent = await Spotlight.recentFiles() }
    }

    private func relative(_ url: URL) -> String {
        guard let date = (try? url.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate else { return "" }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

private struct DrivesWidget: View {
    let state: WindowState
    let pane: PaneState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(VolumeStore.shared.volumes) { volume in
                Button { pane.navigate(to: .folderAt(volume.url)) } label: {
                    HStack(spacing: 10) {
                        Image(nsImage: IconCache.icon(for: volume.url)).resizable().frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(volume.name).fontWeight(.medium)
                            if volume.total > 0 {
                                ProgressView(value: Double(volume.used), total: Double(volume.total))
                                    .tint(Double(volume.used) / Double(volume.total) > 0.9 ? .red : Color.themeAccent)
                                Text("\(Formatters.size(volume.available)) free of \(Formatters.size(volume.total))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                Image(systemName: "network").font(.title2).foregroundStyle(.secondary).frame(width: 34)
                Text("Network")
                Spacer()
                Button("Connect…") { state.showConnect = true }.controlSize(.small)
            }
        }
    }
}

private struct CloudWidget: View {
    let pane: PaneState

    private static let providers: [(name: String, match: String, symbol: String, url: String)] = [
        ("Google Drive", "google", "g.circle", "https://www.google.com/drive/download/"),
        ("Dropbox", "dropbox", "shippingbox", "https://www.dropbox.com/desktop"),
        ("OneDrive", "onedrive", "cloud", "https://www.microsoft.com/microsoft-365/onedrive/download"),
    ]

    var body: some View {
        let locations = CloudStore.shared.locations
        VStack(alignment: .leading, spacing: 10) {
            ForEach(locations) { cloud in
                Button { pane.navigate(to: .folderAt(cloud.url)) } label: {
                    HStack {
                        Image(systemName: cloud.symbol).foregroundStyle(Color.themeAccent).frame(width: 26)
                        Text(cloud.name)
                        Spacer()
                        Label("Available", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.green)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ForEach(Self.providers.filter { provider in !locations.contains { $0.name.lowercased().contains(provider.match) || $0.url.path.lowercased().contains(provider.match) } }, id: \.name) { provider in
                HStack {
                    Image(systemName: provider.symbol).foregroundStyle(.secondary).frame(width: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(provider.name)
                        Text("Not connected").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Connect") { if let url = URL(string: provider.url) { NSWorkspace.shared.open(url) } }
                        .controlSize(.small)
                        .help("Install the \(provider.name) app; its folder then appears here and in the sidebar")
                }
            }
        }
    }
}

private struct ProjectsWidget: View {
    let state: WindowState
    let pane: PaneState
    @State private var kinds: [URL: ProjectInfo.Kind] = [:]

    var body: some View {
        let projects = HomeConfig.shared.projects
        VStack(alignment: .leading, spacing: 8) {
            if projects.isEmpty {
                Text("Pin folders you work in — right-click a folder → Pin to Home Projects, or use +.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(projects, id: \.self) { url in
                Button { pane.navigate(to: .folderAt(url)) } label: {
                    HStack(spacing: 10) {
                        Image(nsImage: IconCache.icon(for: url)).resizable().frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent).fontWeight(.medium)
                            Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        if let kind = kinds[url] {
                            Label(kind.title, systemImage: kind.symbol).font(.caption2).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                        }
                        Button { HomeConfig.shared.unpinProject(url) } label: { Image(systemName: "pin.fill").foregroundStyle(Color.themeAccent) }
                            .buttonStyle(.borderless).help("Unpin").accessibilityLabel("Unpin \(url.lastPathComponent)")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Open in New Tab") { state.newTab(.folderAt(url)) }
                    Button("Open in Integrated Terminal") { state.terminal.open(url) }
                    Button("Unpin") { HomeConfig.shared.unpinProject(url) }
                }
            }
        }
        .task(id: projects) {
            let list = projects
            kinds = await Task.detached {
                Dictionary(uniqueKeysWithValues: list.compactMap { url in ProjectDetector.detect(in: url).first.map { (url, $0.kind) } })
            }.value
        }
    }
}

private struct GitReposWidget: View {
    let state: WindowState
    let pane: PaneState
    @State private var repos: [(url: URL, info: GitInfo?)] = []
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if loading { ProgressView().controlSize(.small) }
            else if repos.isEmpty { Text("No repositories found in your projects or ~/Projects, ~/Developer, ~/work.").font(.callout).foregroundStyle(.secondary) }
            ForEach(repos, id: \.url) { repo in
                Button { pane.navigate(to: .folderAt(repo.url)) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(repo.url.lastPathComponent).fontWeight(.medium)
                            Text(repo.info?.branch ?? "—").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let info = repo.info {
                            if info.changedCount > 0 { Text("\(info.changedCount) changed").font(.caption).foregroundStyle(.orange) }
                            else { Text("clean").font(.caption).foregroundStyle(.green) }
                            if info.ahead > 0 { Text("↑\(info.ahead)").font(.caption.monospacedDigit()) }
                            if info.behind > 0 { Text("↓\(info.behind)").font(.caption.monospacedDigit()) }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Changes & Commit…") { state.gitRequest = GitTarget(root: repo.url) }
                    Button("Open in Integrated Terminal") { state.terminal.open(repo.url) }
                }
            }
        }
        .task {
            let roots = HomeConfig.shared.projects + PinnedStore.shared.folders
            let found = await Task.detached { GitRepoScanner.find(extra: roots) }.value
            var result: [(URL, GitInfo?)] = []
            for url in found.prefix(8) { result.append((url, await Git.info(for: url))) }
            repos = result.map { (url: $0.0, info: $0.1) }
            loading = false
        }
    }
}

enum GitRepoScanner {
    /// Repositories among the given folders and the usual code folders (two levels deep).
    static func find(extra: [URL]) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = extra + ["Projects", "Developer", "work", "Code", "src", "GitHub", "git"].map { home.appendingPathComponent($0) }
        var found: [URL] = []
        var seen = Set<String>()
        func isRepo(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) }
        func consider(_ url: URL) {
            let key = url.standardizedFileURL.path
            guard !seen.contains(key) else { return }
            seen.insert(key)
            if isRepo(url) { found.append(url) }
        }
        for root in roots where FileSystem.isDirectory(root) {
            consider(root)
            for child in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [] where FileSystem.isDirectory(child) {
                consider(child)
                if found.count >= 40 { break }
            }
        }
        // Most recently changed first.
        return found.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a > b
        }
    }
}

private struct TagsWidget: View {
    let pane: PaneState

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(TagStore.shared.sidebarTags) { tag in
                Button { pane.navigate(to: .tag(tag.name)) } label: {
                    HStack(spacing: 5) {
                        Circle().fill(Color(nsColor: tag.nsColor ?? .tertiaryLabelColor)).frame(width: 9, height: 9)
                        Text(tag.name)
                    }
                    .font(.callout)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color(nsColor: tag.nsColor ?? .tertiaryLabelColor).opacity(0.15)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct TransfersWidget: View {
    var body: some View {
        let active = OperationCenter.shared.operations.filter(\.isRunning)
        VStack(alignment: .leading, spacing: 10) {
            if active.isEmpty { Text("No transfers in progress.").foregroundStyle(.secondary) }
            ForEach(active.prefix(4)) { operation in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(operation.snapshot.currentName.isEmpty ? operation.title : operation.snapshot.currentName).lineLimit(1)
                        Spacer()
                        Button { operation.cancel() } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).accessibilityLabel("Cancel")
                    }
                    ProgressView(value: operation.snapshot.fraction ?? 0)
                    if operation.snapshot.totalBytes > 0 {
                        Text("\(Formatters.size(operation.snapshot.completedBytes)) of \(Formatters.size(operation.snapshot.totalBytes))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct NotesWidget: View {
    @Bindable private var config = HomeConfig.shared

    var body: some View {
        TextEditor(text: $config.notes)
            .font(.callout)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 140)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.08)))
            .overlay(alignment: .topLeading) {
                if config.notes.isEmpty { Text("Jot something down…").foregroundStyle(.tertiary).padding(11).allowsHitTesting(false) }
            }
    }
}

private struct ScriptsWidget: View {
    let state: WindowState

    var body: some View {
        let scripts = AutomationCenter.shared.scripts.filter { $0.count.contains(0) && AutomationCenter.shared.isEnabled($0) }
        VStack(alignment: .leading, spacing: 8) {
            if scripts.isEmpty {
                Text("Scripts that run on a folder appear here.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(scripts.prefix(6)) { script in
                HStack {
                    Label(script.name, systemImage: script.language.symbol)
                    Spacer()
                    Button("Run") {
                        AutomationCenter.shared.request(script, context: ScriptContext(selection: [], folder: FileManager.default.homeDirectoryForCurrentUser))
                    }
                    .controlSize(.small)
                }
            }
            Button("Open Automation…") { NotificationCenter.default.post(name: .openAutomation, object: nil) }.buttonStyle(.link).font(.caption)
        }
    }
}

private struct SmartCollectionsWidget: View {
    let pane: PaneState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(SmartCollection.allCases) { collection in
                Button { pane.navigate(to: .search(collection.query)) } label: {
                    Label(collection.title, systemImage: collection.symbol).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
            }
        }
    }
}

private struct ActivityWidget: View {
    let pane: PaneState

    var body: some View {
        let entries = TimelineStore.shared.entries.prefix(5)
        VStack(alignment: .leading, spacing: 6) {
            if entries.isEmpty { Text("Nothing yet — copies, moves and renames show up here.").font(.callout).foregroundStyle(.secondary) }
            ForEach(Array(entries)) { entry in
                HStack {
                    Text(entry.title).lineLimit(1)
                    Spacer()
                    Text(entry.date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct StatusBar: View {
    let state: WindowState
    let pane: PaneState

    var body: some View {
        HStack(spacing: 12) {
            if AppSettings.shared.vimMode {
                Text(state.vimPending.isEmpty ? String(localized: "VIM") : String(localized: "VIM \(state.vimPending)"))
                    .font(.caption2.monospaced().weight(.bold))
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.themeAccent.opacity(0.2)))
                    .help("Vim keys: j/k move, h up, l open, gg/G first/last, / filter, dd trash, yy copy, x cut, p paste, r rename, u undo, H/L back/forward")
            }
            Text("\(pane.displayedItems.count) items")
            let selected = pane.selectedItems
            if !selected.isEmpty {
                let bytes = selected.filter(\.hasSize).reduce(0) { $0 + $1.size }
                Text("\(selected.count) selected") + Text(verbatim: bytes > 0 ? " (\(Formatters.size(bytes)))" : "")
            }
            if pane.isLoading {
                ProgressView().controlSize(.mini)
            }
            Spacer()
            StatusBarProgress()
            if pane.layout.supportsIconSize, pane.location != .home {
                @Bindable var pane = pane
                Slider(value: Binding(get: { pane.iconSize }, set: { pane.iconSize = $0.rounded() }), in: PaneState.iconSizeRange)
                    .controlSize(.mini)
                    .frame(width: 80)
                    .help("Item size")
            }
            if let git = pane.git {
                GitStatusControls(state: state, git: git)
            }
            if let free = pane.freeSpace {
                Text("\(Formatters.size(free)) available")
            }
        }
        .font(AppSettings.shared.compactStatusBar ? .caption2 : .caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: AppSettings.shared.compactStatusBar ? 18 : 24)
    }
}
