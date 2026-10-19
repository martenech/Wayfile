import SwiftUI

struct SidebarView: View {
    let state: WindowState

    private var pinned: PinnedStore { .shared }
    private var volumes: VolumeStore { .shared }

    @State private var showAllTags = false

    @AppStorage("sidebarMode") private var mode = "places"

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $mode) {
                Label("Places", systemImage: "star").tag("places")
                Label("Folders", systemImage: "list.bullet.indent").tag("tree")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            if mode == "tree" {
                FolderTreeView(state: state)
            } else {
                places
            }
        }
        .background(ThemeStore.shared.preset.sidebar ?? .clear)
    }

    private var places: some View {
        VStack(spacing: 0) {
            List(selection: selectionBinding) {
                ForEach(SidebarConfig.shared.visibleSections) { section($0) }
            }
            .listStyle(.sidebar)
            .themedSidebar()
            if config.hiddenCount > 0 || config.revealHidden {
                Divider()
                Button {
                    withAnimation { config.revealHidden.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: config.revealHidden ? "eye.fill" : "eye.slash")
                        Text(config.revealHidden ? String(localized: "Done — hide them again") : String(localized: "Show Hidden (\(config.hiddenCount))"))
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(config.revealHidden ? Color.themeAccent : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(config.revealHidden ? String(localized: "Hidden items are shown dimmed — right-click one and choose Show") : String(localized: "Show hidden sidebar items so you can bring them back"))
            }
        }
    }

    private var config: SidebarConfig { .shared }

    /// Header with a right-click "Hide section" (or "Show" while revealing hidden ones).
    private func header(_ title: String, _ section: SidebarSection) -> some View {
        let hidden = config.hidden.contains(section)
        return HStack(spacing: 4) {
            Text(key: title)
            if hidden { Image(systemName: "eye.slash").font(.caption2) }
        }
        .opacity(hidden ? 0.45 : 1)
        .contextMenu {
            if hidden {
                Button("Show “\(title)”") { config.setVisible(section, true) }
            } else {
                Button("Hide “\(title)”") { config.setVisible(section, false) }
            }
            revealButton
        }
    }

    @ViewBuilder
    private var revealButton: some View {
        if config.revealHidden {
            Button("Hide Hidden Items Again") { config.revealHidden = false }
        } else if config.hiddenCount > 0 {
            Button("Show Hidden Items (\(config.hiddenCount))") { config.revealHidden = true }
        }
    }

    /// The "Hide" / "Show" entry every sidebar row's menu ends with.
    @ViewBuilder
    private func hideItem(_ id: String) -> some View {
        Divider()
        if config.isHidden(id) {
            Button("Show in Sidebar", systemImage: "eye") { config.setItemHidden(id, false) }
        } else {
            Button("Hide from Sidebar", systemImage: "eye.slash") { config.setItemHidden(id, true) }
        }
        revealButton
    }

    /// Every row a section can show, by its hide id — a section whose rows are all hidden disappears too.
    private func itemIDs(_ section: SidebarSection) -> [String] {
        switch section {
        case .home: return ["home", "timeline"]
        case .favorites: return pinned.folders.map { "fav:" + $0.path }
        case .cloud: return CloudStore.shared.locations.map { "cloud:" + $0.url.path }
        case .locations:
            return volumes.volumes.map { "vol:" + $0.url.path } + ["trash", "connect"] + (Features.shared.isOn(.remote) ? ["sftp", "s3"] : [])
        case .vaults: return Features.shared.isOn(.security) ? VaultStore.shared.vaults.map { "vault:" + $0.id.uuidString } : []
        case .servers: return ServerStore.shared.servers.prefix(8).map { "server:" + $0.id.uuidString }
        case .workspaces: return WorkspaceStore.shared.workspaces.map { "ws:" + $0.id.uuidString }
        case .smartCollections: return SmartCollection.allCases.map { "smart:" + $0.rawValue }
        case .savedSearches: return SavedSearchStore.shared.searches.map { "saved:" + $0.id.uuidString }
        case .tags: return TagStore.shared.sidebarTags.map { "tag:" + $0.name } + ["alltags"]
        }
    }

    @ViewBuilder
    private func section(_ section: SidebarSection) -> some View {
        if config.listsAny(itemIDs(section)) {
            sectionContent(section)
        }
    }

    @ViewBuilder
    private func sectionContent(_ section: SidebarSection) -> some View {
        switch section {
        case .home:
        Section {
            if config.lists("home") {
                Label("Home", systemImage: "house").tag(SidebarID.home)
                    .sidebarItem("home").contextMenu { Button("Open in New Tab") { state.newTab(.home) }; hideItem("home") }
            }
            if config.lists("timeline") {
                Label("Timeline", systemImage: "clock").tag(SidebarID.timeline)
                    .sidebarItem("timeline").contextMenu { Button("Open in New Tab") { state.newTab(.timeline) }; hideItem("timeline") }
            }
        } header: {
            if config.hidden.contains(.home) { header("Home & Timeline", .home) }
        }
        case .favorites:
        Section {
            ForEach(pinned.folders.filter { config.lists("fav:" + $0.path) }, id: \.self) { url in
                Label(url.displayName, systemImage: PinnedStore.symbol(for: url))
                    .tag(SidebarID.folder(url.normalizedDirectory))
                    .sidebarItem("fav:" + url.path)
                    .dropDestination(for: URL.self) { urls, _ in state.drop(urls, into: url) }
                    .contextMenu {
                        Button("Open in New Tab") { state.newTab(.folderAt(url)) }
                        Button("Open in Other Pane") { state.openInOtherPane(url) }
                        Button("Open in Terminal") { state.openInTerminal(url) }
                        Divider()
                        Button("Remove from Favorites") { pinned.unpin(url) }
                        hideItem("fav:" + url.path)
                    }
            }
            .onMove { pinned.move(from: $0, to: $1) }
        } header: { header("Favorites", .favorites) }
        case .cloud:
        if !CloudStore.shared.locations.isEmpty {
            Section {
                ForEach(CloudStore.shared.locations.filter { config.lists("cloud:" + $0.url.path) }) { cloud in
                    Label {
                        Text(cloud.name).lineLimit(1)
                    } icon: {
                        // Provider folders carry the provider's own icon (Dropbox, Google Drive…).
                        if cloud.symbol == "icloud" {
                            Image(systemName: "icloud")
                        } else {
                            Image(nsImage: IconCache.icon(for: cloud.url)).resizable().frame(width: 16, height: 16)
                        }
                    }
                    .tag(SidebarID.folder(cloud.url))
                    .sidebarItem("cloud:" + cloud.url.path)
                    .dropDestination(for: URL.self) { urls, _ in state.drop(urls, into: cloud.url) }
                    .contextMenu {
                        Button("Open in New Tab") { state.newTab(.folderAt(cloud.url)) }
                        Button("Open in Other Pane") { state.openInOtherPane(cloud.url) }
                        Button("Properties…") { state.showProperties([cloud.url]) }
                        hideItem("cloud:" + cloud.url.path)
                    }
                }
            } header: { header("Cloud", .cloud) }
        }
        case .locations:
        Section {
            ForEach(volumes.volumes.filter { config.lists("vol:" + $0.url.path) }) { volume in
                HStack {
                    Label(volume.name, systemImage: volume.symbol)
                    Spacer()
                    if volume.isEjectable {
                        Button {
                            do { try volumes.eject(volume) } catch { state.errorMessage = error.localizedDescription }
                        } label: {
                            Image(systemName: "eject.fill").font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Eject")
                        .accessibilityLabel("Eject \(volume.name)")
                    }
                }
                .tag(SidebarID.folder(volume.url))
                .sidebarItem("vol:" + volume.url.path)
                .contextMenu {
                    Button("Open in New Tab") { state.newTab(.folderAt(volume.url)) }
                    if volume.isEjectable {
                        Button("Eject") { try? volumes.eject(volume) }
                    }
                    hideItem("vol:" + volume.url.path)
                }
            }
            if config.lists("trash") {
                Label("Trash", systemImage: "trash")
                    .tag(SidebarID.folder(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").normalizedDirectory))
                    .sidebarItem("trash")
                    .contextMenu { hideItem("trash") }
            }
            if config.lists("connect") {
                Button {
                    state.beginNew(.connectToServer)
                } label: {
                    Label("Connect to Server…", systemImage: "network")
                }
                .buttonStyle(.plain)
                .sidebarItem("connect")
                .contextMenu { hideItem("connect") }
            }
            if Features.shared.isOn(.remote) {
                if config.lists("sftp") {
                    Button {
                        NotificationCenter.default.post(name: .openToolWindow, object: "sftp")
                    } label: {
                        Label("SFTP / SSH…", systemImage: "server.rack")
                    }
                    .buttonStyle(.plain)
                    .sidebarItem("sftp")
                    .contextMenu { hideItem("sftp") }
                }
                if config.lists("s3") {
                    Button {
                        NotificationCenter.default.post(name: .openToolWindow, object: "s3")
                    } label: {
                        Label("S3 Storage…", systemImage: "externaldrive.connected.to.line.below")
                    }
                    .buttonStyle(.plain)
                    .sidebarItem("s3")
                    .contextMenu { hideItem("s3") }
                }
            }
        } header: { header("Locations", .locations) }
        case .vaults:
        if !VaultStore.shared.vaults.isEmpty && Features.shared.isOn(.security) {
            Section {
                ForEach(VaultStore.shared.vaults.filter { config.lists("vault:" + $0.id.uuidString) }) { vault in
                    let mount = VaultStore.shared.mountPoint(of: vault)
                    HStack {
                        Button {
                            if let mount { state.activePane.navigate(to: .folderAt(mount)) } else { VaultActions.unlock(vault, state: state) }
                        } label: {
                            Label(vault.name, systemImage: mount == nil ? "lock.fill" : "lock.open.fill")
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if mount != nil {
                            Button { VaultActions.lock(vault, state: state) } label: { Image(systemName: "lock").font(.caption) }
                                .buttonStyle(.borderless)
                                .help("Lock")
                                .accessibilityLabel("Lock")
                        }
                    }
                    .sidebarItem("vault:" + vault.id.uuidString)
                    .contextMenu {
                        if mount == nil {
                            Button("Unlock…") { VaultActions.unlock(vault, state: state) }
                        } else {
                            Button("Lock") { VaultActions.lock(vault, state: state) }
                        }
                        Button("Show Vault File") { NSWorkspace.shared.activateFileViewerSelecting([vault.url]) }
                        Divider()
                        Button("Remove from Sidebar") { VaultStore.shared.forget(vault) }
                        hideItem("vault:" + vault.id.uuidString)
                    }
                }
            } header: { header("Vaults", .vaults) }
        }
        case .servers:
        if !ServerStore.shared.servers.isEmpty {
            Section {
                ForEach(ServerStore.shared.servers.prefix(8).filter { config.lists("server:" + $0.id.uuidString) }) { server in
                    let mounted = Mounter.existingMount(for: server.url)
                    Button { state.connect(server) } label: {
                        HStack {
                            Label(server.name, systemImage: "server.rack")
                            Spacer()
                            if mounted != nil { Circle().fill(.green).frame(width: 6, height: 6).help("Connected") }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(server.url.absoluteString)
                    .sidebarItem("server:" + server.id.uuidString)
                    .contextMenu {
                        Button("Connect") { state.connect(server) }
                        if let mounted {
                            Button("Disconnect") {
                                do { try NSWorkspace.shared.unmountAndEjectDevice(at: mounted) } catch { state.errorMessage = error.localizedDescription }
                            }
                        }
                        Button("Copy Address") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(server.url.absoluteString, forType: .string)
                        }
                        Divider()
                        Button("Remove from Sidebar", role: .destructive) { ServerStore.shared.remove(server) }
                        hideItem("server:" + server.id.uuidString)
                    }
                }
            } header: { header("Servers", .servers) }
        }
        case .workspaces:
        if !WorkspaceStore.shared.workspaces.isEmpty {
            Section {
                ForEach(WorkspaceStore.shared.workspaces.filter { config.lists("ws:" + $0.id.uuidString) }) { workspace in
                    Button { state.open(workspace) } label: {
                        Label(workspace.name, systemImage: "rectangle.3.group")
                    }
                    .buttonStyle(.plain)
                    .sidebarItem("ws:" + workspace.id.uuidString)
                    .contextMenu {
                        Button("Update with Current Layout") {
                            WorkspaceStore.shared.save(Workspace(name: workspace.name, session: state.session,
                                                                 sidebarVisible: UserDefaults.standard.object(forKey: "sidebarVisible") as? Bool ?? true))
                        }
                        Divider()
                        Button("Delete Workspace") { WorkspaceStore.shared.remove(workspace) }
                        hideItem("ws:" + workspace.id.uuidString)
                    }
                }
            } header: { header("Workspaces", .workspaces) }
        }
        case .smartCollections:
        Section {
            ForEach(SmartCollection.allCases.filter { config.lists("smart:" + $0.rawValue) }) { collection in
                Label(collection.title, systemImage: collection.symbol)
                    .lineLimit(1)
                    .tag(SidebarID.smart(collection.rawValue))
                    .sidebarItem("smart:" + collection.rawValue)
                    .contextMenu {
                        Button("Open in New Tab") { state.newTab(.search(collection.query)) }
                        hideItem("smart:" + collection.rawValue)
                    }
            }
        } header: { header("Smart Collections", .smartCollections) }
        case .savedSearches:
        if !SavedSearchStore.shared.searches.isEmpty {
            Section {
                ForEach(SavedSearchStore.shared.searches.filter { config.lists("saved:" + $0.id.uuidString) }) { saved in
                    Label(saved.name, systemImage: "magnifyingglass")
                        .lineLimit(1)
                        .tag(SidebarID.savedSearch(saved.id))
                        .sidebarItem("saved:" + saved.id.uuidString)
                        .contextMenu {
                            Button("Open in New Tab") { state.newTab(.search(saved.query)) }
                            Divider()
                            Button("Remove Saved Search") { SavedSearchStore.shared.remove(saved) }
                            hideItem("saved:" + saved.id.uuidString)
                        }
                }
            } header: { header("Saved Searches", .savedSearches) }
        }
        case .tags:
        Section {
            let store = TagStore.shared
            ForEach(store.sidebarTags.filter { config.lists("tag:" + $0.name) }) { tag in
                HStack {
                    TagLabel(tag: tag)
                    Spacer()
                    if AppSettings.shared.sidebarShowsUsedTagsOnly, let count = store.usage[tag.name] {
                        Text("\(count)").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
                .tag(SidebarID.tag(tag.name))
                .sidebarItem("tag:" + tag.name)
                .contextMenu {
                    Button("Open in New Tab") { state.newTab(.tag(tag.name)) }
                    hideItem("tag:" + tag.name)
                }
            }
            if config.lists("alltags") {
                Button {
                    showAllTags = true
                } label: {
                    Label("All Tags…", systemImage: "ellipsis.circle")
                }
                .buttonStyle(.plain)
                .sidebarItem("alltags")
                .contextMenu { hideItem("alltags") }
                .popover(isPresented: $showAllTags, arrowEdge: .trailing) {
                    AllTagsList { tag in
                        showAllTags = false
                        state.activePane.navigate(to: .tag(tag.name))
                    }
                }
            }
        } header: { header("Tags", .tags) }
        }
    }

    /// Sidebar selection mirrors the active pane's location; picking an entry navigates there.
    private var selectionBinding: Binding<SidebarID?> {
        Binding(
            get: {
                switch state.activePane.location {
                case .home: return .home
                case .timeline: return .timeline
                case .activity: return .timeline
                case .folder(let url): return .folder(url)
                case .tag(let name): return .tag(name)
                case .search(let query):
                    if let collection = SmartCollection.matching(query) { return .smart(collection.rawValue) }
                    return SavedSearchStore.shared.search(matching: query).map { .savedSearch($0.id) }
                }
            },
            set: { id in
                guard let id else { return }
                switch id {
                case .home: state.activePane.navigate(to: .home)
                case .timeline: state.activePane.navigate(to: .timeline)
                case .folder(let url): state.activePane.navigate(to: .folderAt(url))
                case .tag(let name): state.activePane.navigate(to: .tag(name))
                case .smart(let id):
                    if let collection = SmartCollection(rawValue: id) { state.activePane.navigate(to: .search(collection.query)) }
                case .savedSearch(let id):
                    if let saved = SavedSearchStore.shared.searches.first(where: { $0.id == id }) {
                        state.activePane.navigate(to: .search(saved.query))
                    }
                }
            }
        )
    }
}

enum SidebarID: Hashable {
    case home
    case timeline
    case folder(URL)
    case tag(String)
    case savedSearch(UUID)
    case smart(String)
}

private struct TagLabel: View {
    let tag: FileTag

    var body: some View {
        Label {
            Text(tag.name).lineLimit(1)
        } icon: {
            if let color = tag.nsColor {
                Image(systemName: "circle.fill").foregroundStyle(Color(nsColor: color))
            } else {
                Image(systemName: "circle")
            }
        }
    }
}

/// Every tag in use on this Mac, loaded from Spotlight.
private struct AllTagsList: View {
    let onSelect: (FileTag) -> Void

    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("All Tags").font(.headline).padding(10)
            Divider()
            if loading {
                ProgressView().frame(maxWidth: .infinity).padding(20)
            } else if TagStore.shared.allTags.isEmpty {
                Text("No tagged files found.").foregroundStyle(.secondary).padding(16)
            } else {
                List(TagStore.shared.allTags) { tag in
                    Button { onSelect(tag) } label: { TagLabel(tag: tag).frame(maxWidth: .infinity, alignment: .leading) }
                        .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 240, height: 320)
        .task {
            await TagStore.shared.loadAllTags()
            loading = false
        }
    }
}

/// Hidden sidebar entries (visible only while revealing) are dimmed with an eye-slash.
private struct SidebarItemStyle: ViewModifier {
    let id: String

    func body(content: Content) -> some View {
        if SidebarConfig.shared.isHidden(id) {
            // Beside the row, not over it: long names truncate before the icon.
            HStack(spacing: 4) {
                content
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .opacity(0.45)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Hidden")
            }
        } else {
            content
        }
    }
}

extension View {
    fileprivate func sidebarItem(_ id: String) -> some View { modifier(SidebarItemStyle(id: id)) }
}
