import SwiftUI

struct PaneView: View {
    let state: WindowState
    let tab: TabState
    let pane: PaneState

    var body: some View {
        Group {
            switch pane.location {
            case .home:
                HomeView(state: state, pane: pane)
            case .timeline, .activity:
                FileTimelineView(state: state, pane: pane)
            default:
                content
            }
        }
        .simultaneousGesture(TapGesture().onEnded { activate() })
        .onChange(of: pane.selection) { _, selection in
            if !selection.isEmpty { activate() }
        }
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            switch pane.layout {
            case .details: DetailsView(state: state, pane: pane)
            case .list: ListLayoutView(state: state, pane: pane)
            case .grid, .cards: ItemsGridView(state: state, pane: pane, style: pane.layout == .cards ? .cards : .grid)
            case .columns: ColumnsView(state: state, pane: pane)
            }
            if let message = pane.errorMessage {
                ContentUnavailableView("Can’t open this folder", systemImage: "exclamationmark.triangle", description: Text(message))
                    .background(.background)
            } else if pane.isLoading && pane.displayedItems.isEmpty {
                ProgressView().controlSize(.small)
            } else if pane.displayedItems.isEmpty && pane.layout != .columns {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
        }
    }

    private func activate() {
        if tab.activePaneID != pane.id { tab.activePaneID = pane.id }
    }

    private var emptyMessage: String {
        if !pane.filterText.isEmpty { return "No items match “\(pane.filterText)”." }
        switch pane.location {
        case .search(let query) where query.isEmpty: return "Type to search, or choose a filter above."
        case .search(let query) where query.engine == .spotlight:
            return "No results. Spotlight skips unindexed folders — try “Scan Files”."
        case .search: return "No results."
        case .tag: return "No files with this tag."
        default: return "This folder is empty."
        }
    }
}

// MARK: - Details (table) layout

struct DetailsView: View {
    let state: WindowState
    @Bindable var pane: PaneState

    /// Column visibility/order/widths (right-click the header), shared by all panes and persisted.
    @State private var columns = DetailsView.loadColumns()

    private static let columnsKey = "detailsColumns"

    private static func loadColumns() -> TableColumnCustomization<FileItem> {
        UserDefaults.standard.data(forKey: columnsKey)
            .flatMap { try? JSONDecoder().decode(TableColumnCustomization<FileItem>.self, from: $0) } ?? .init()
    }

    var body: some View {
        Table(of: FileItem.self, selection: $pane.selection, sortOrder: $pane.sortOrder, columnCustomization: $columns) {
            TableColumn("Name", value: \.name) { item in
                let density = AppSettings.shared.rowDensity
                HStack(spacing: 6) {
                    Image(nsImage: IconCache.icon(for: item.url))
                        .resizable()
                        .frame(width: density.iconSize, height: density.iconSize)
                    Text(item.name)
                        .lineLimit(1)
                        .opacity(item.isHidden ? 0.55 : 1)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, density.verticalPadding)
                .modifier(HoverActions(state: state, pane: pane, url: item.url))
            }
            .width(min: 160, ideal: 260)
            .customizationID("name")

            TableColumn("Date Modified", value: \.modified) { item in
                Text(Formatters.date(item.modified)).foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 140)
            .customizationID("modified")

            TableColumn("Date Created", value: \.created) { item in
                Text(Formatters.date(item.created)).foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 140)
            .customizationID("created")
            .defaultVisibility(.hidden)

            TableColumn("Type", value: \.kind) { item in
                Text(item.kind).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 70, ideal: 110)
            .customizationID("kind")

            TableColumn("Size", value: \.sizeKey) { item in
                Text(item.hasSize ? Formatters.size(item.size) : "—")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 55, ideal: 70)
            .customizationID("size")

            if pane.git != nil {
                TableColumn("Git", value: \.gitStatusKey) { item in
                    if let status = item.gitStatus { GitStatusBadge(status: status) }
                }
                .width(min: 28, ideal: 34, max: 50)
                .customizationID("gitStatus")

                TableColumn("Last Commit", value: \.commitSubjectKey) { item in
                    if let commit = item.lastCommit {
                        Text(commit.subject).lineLimit(1).foregroundStyle(.secondary).help(commit.subject)
                    }
                }
                .width(min: 100, ideal: 220)
                .customizationID("commitSubject")

                TableColumn("Commit Date", value: \.commitDateKey) { item in
                    if let commit = item.lastCommit {
                        Text(commit.date, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                    }
                }
                .width(min: 80, ideal: 110)
                .customizationID("commitDate")
                .defaultVisibility(.hidden)

                TableColumn("Author", value: \.commitAuthorKey) { item in
                    Text(item.lastCommit?.author ?? "").foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 70, ideal: 110)
                .customizationID("commitAuthor")
                .defaultVisibility(.hidden)

                TableColumn("Commit", value: \.commitHashKey) { item in
                    Text(item.lastCommit?.hash ?? "").font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 70)
                .customizationID("commitHash")
                .defaultVisibility(.hidden)
            }

            TableColumn("Tags", value: \.tagsKey) { item in
                TagPills(tags: item.fileTags)
            }
            .width(min: 50, ideal: 130)
            .customizationID("tags")
        } rows: {
            if pane.groupBy == .none {
                ForEach(pane.displayedItems) { item in
                    TableRow(item).draggable(item.url)
                }
            } else {
                ForEach(pane.groups) { group in
                    Section("\(group.title) (\(group.items.count))") {
                        ForEach(group.items) { item in
                            TableRow(item).draggable(item.url)
                        }
                    }
                }
            }
        }
        // A new order reloads the table instead of animating every row move.
        .id(pane.orderGeneration)
        .contextMenu(forSelectionType: URL.self) { urls in
            FileContextMenu(state: state, pane: pane, urls: urls)
        } primaryAction: { urls in
            pane.selection = urls
            state.openSelection(in: pane)
        }
        .themedContentBackground()
        .alternatingRowBackgrounds(ThemeStore.shared.customizesContent ? .disabled : .enabled)
        .onKeyPress(.return) {
            state.handleReturnKey(in: pane)
            return .handled
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let dir = pane.location.folderURL else { return false }
            return state.drop(urls, into: dir)
        }
        .onKeyPress(.space) {
            state.toggleQuickLook()
            return .handled
        }
        .onChange(of: columns) { _, columns in
            UserDefaults.standard.set(try? JSONEncoder().encode(columns), forKey: Self.columnsKey)
        }
    }
}

struct TagDots: View {
    let tags: [FileTag]

    var body: some View {
        HStack(spacing: -3) {
            ForEach(tags) { tag in
                Circle()
                    .fill(Color(nsColor: tag.nsColor ?? .tertiaryLabelColor))
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                    .frame(width: 10, height: 10)
                    .help(tag.name)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tags.isEmpty ? "" : String(localized: "Tags: ") + tags.map(\.name).joined(separator: ", "))
    }
}

// MARK: - Shared item interaction

/// Click handling shared by the custom (non-Table) layouts: ⌘/⇧-click toggles, plain click selects.
@MainActor
func selectItem(_ item: FileItem, in pane: PaneState) {
    let flags = NSEvent.modifierFlags
    if flags.contains(.command) || flags.contains(.shift) {
        if pane.selection.contains(item.url) { pane.selection.remove(item.url) } else { pane.selection.insert(item.url) }
    } else {
        pane.selection = [item.url]
    }
}

/// Lets items in the custom layouts give keyboard focus to their container when clicked,
/// so Return / Space / arrow handling works right after a click.
private struct FocusFileAreaKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var focusFileArea: () -> Void {
        get { self[FocusFileAreaKey.self] }
        set { self[FocusFileAreaKey.self] = newValue }
    }
}

private struct ItemInteraction: ViewModifier {
    let state: WindowState
    let pane: PaneState
    let item: FileItem

    @Environment(\.focusFileArea) private var focusFileArea

    func body(content: Content) -> some View {
        content
            .onTapGesture {
                selectItem(item, in: pane)
                focusFileArea()
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                pane.selection = [item.url]
                state.open(item, in: pane)
            })
            .draggable(item.url) {
                Image(nsImage: IconCache.icon(for: item.url)).resizable().frame(width: 48, height: 48)
            }
            .dropDestination(for: URL.self) { urls, _ in
                item.isFolderLike ? state.drop(urls, into: item.url) : false
            }
            .contextMenu {
                let urls = pane.selection.contains(item.url) ? pane.selection : [item.url]
                FileContextMenu(state: state, pane: pane, urls: urls)
            }
    }
}

/// Background behaviour shared by the custom layouts: deselect, folder menu, drop, keyboard.
private struct ContainerInteraction: ViewModifier {
    let state: WindowState
    let pane: PaneState

    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .environment(\.focusFileArea) { isFocused = true }
            .contentShape(Rectangle())
            .onTapGesture {
                pane.selection = []
                isFocused = true
            }
            .contextMenu { FileContextMenu(state: state, pane: pane, urls: []) }
            .dropDestination(for: URL.self) { urls, _ in
                guard let dir = pane.location.folderURL else { return false }
                return state.drop(urls, into: dir)
            }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            // Like Finder: switching to this layout makes the file area ready for the keyboard.
            .onAppear { isFocused = true }
            .onKeyPress(.space) {
                state.toggleQuickLook()
                return .handled
            }
            .onKeyPress(.return) {
                state.handleReturnKey(in: pane)
                return .handled
            }
    }
}

private struct GroupHeader: View {
    let group: ItemGroup

    var body: some View {
        HStack(spacing: 6) {
            Text(group.title).font(.headline)
            Text("\(group.items.count)").foregroundStyle(.secondary)
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(.regularMaterial)
    }
}

// MARK: - Grid & cards layouts

struct ItemsGridView: View {
    enum Style { case grid, cards }

    let state: WindowState
    let pane: PaneState
    let style: Style

    private var columns: [GridItem] {
        switch style {
        case .grid:
            let width = max(pane.iconSize + 40, 90)
            return [GridItem(.adaptive(minimum: width, maximum: width + 30), spacing: 8)]
        case .cards:
            let width = 200 + pane.iconSize * 1.2
            return [GridItem(.adaptive(minimum: width, maximum: width + 80), spacing: 10)]
        }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: style == .cards ? 10 : 12, pinnedViews: [.sectionHeaders]) {
                ForEach(pane.groups) { group in
                    Section {
                        ForEach(group.items) { item in
                            cell(item)
                                .modifier(ItemInteraction(state: state, pane: pane, item: item))
                        }
                    } header: {
                        if pane.groupBy != .none { GroupHeader(group: group) }
                    }
                }
            }
            .padding(12)
        }
        .themedContentBackground()
        .modifier(ContainerInteraction(state: state, pane: pane))
    }

    @ViewBuilder
    private func cell(_ item: FileItem) -> some View {
        let selected = pane.selection.contains(item.url)
        switch style {
        case .grid: GridCell(item: item, isSelected: selected, iconSize: pane.iconSize)
        case .cards: CardCell(item: item, isSelected: selected, iconSize: pane.iconSize)
        }
    }
}

private struct GridCell: View {
    let item: FileItem
    let isSelected: Bool
    let iconSize: Double

    var body: some View {
        VStack(spacing: 4) {
            Thumbnail(item: item, size: iconSize)
            Text(item.name)
                .font(iconSize < 48 ? .caption : .callout)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(isSelected ? Color.themeAccent : .clear))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            TagDots(tags: item.fileTags)
        }
        .opacity(item.isHidden ? 0.55 : 1)
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: iconSize + 54, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.themeAccent.opacity(0.12) : .clear))
        .contentShape(Rectangle())
    }
}

private struct CardCell: View {
    let item: FileItem
    let isSelected: Bool
    let iconSize: Double

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(item: item, size: max(iconSize * 0.75, 32))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.kind)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text([item.hasSize ? Formatters.size(item.size) : nil, Formatters.date(item.modified)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                TagPills(tags: item.fileTags)
            }
            Spacer(minLength: 0)
            if let status = item.gitStatus { GitStatusBadge(status: status) }
        }
        .opacity(item.isHidden ? 0.55 : 1)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.themeAccent.opacity(0.18) : Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.themeAccent : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - List layout

/// Minimal one-column list (icon + name), like Files' List layout.
struct ListLayoutView: View {
    let state: WindowState
    let pane: PaneState

    private var iconSize: Double { min(max(pane.iconSize / 3, 16), 48) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(pane.groups) { group in
                    Section {
                        ForEach(group.items) { item in
                            row(item)
                                .modifier(ItemInteraction(state: state, pane: pane, item: item))
                        }
                    } header: {
                        if pane.groupBy != .none { GroupHeader(group: group) }
                    }
                }
            }
            .padding(8)
        }
        .themedContentBackground()
        .modifier(ContainerInteraction(state: state, pane: pane))
    }

    private func row(_ item: FileItem) -> some View {
        let selected = pane.selection.contains(item.url)
        return HStack(spacing: 8) {
            Image(nsImage: IconCache.icon(for: item.url))
                .resizable()
                .frame(width: iconSize, height: iconSize)
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
            TagDots(tags: item.fileTags)
            Spacer(minLength: 0)
            if let status = item.gitStatus { GitStatusBadge(status: status) }
        }
        .modifier(HoverActions(state: state, pane: pane, url: item.url))
        .opacity(item.isHidden ? 0.55 : 1)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 2 + AppSettings.shared.rowDensity.verticalPadding)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.themeAccent : .clear))
        .contentShape(Rectangle())
    }
}

/// Optional row buttons under the pointer (Settings → Context Menu): Quick Look, Copy Path, Trash.
private struct HoverActions: ViewModifier {
    let state: WindowState
    let pane: PaneState
    let url: URL

    @State private var hovering = false

    func body(content: Content) -> some View {
        if AppSettings.shared.hoverActions {
            content
                .overlay(alignment: .trailing) {
                    if hovering {
                        HStack(spacing: 2) {
                            button("eye", "Quick Look") { state.quickLookURL = url }
                            button("link", "Copy Path") { state.copyPaths([url], format: .path) }
                            button("trash", "Move to Trash") {
                                pane.selection = [url]
                                state.trashSelection()
                            }
                        }
                        .padding(2)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                .onHover { hovering = $0 }
        } else {
            content
        }
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10)).frame(width: 18, height: 16).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

// MARK: - Thumbnails

/// File icon that upgrades to a Quick Look thumbnail (images, PDFs, videos…) once generated.
struct Thumbnail: View {
    let item: FileItem
    let size: Double

    @State private var image: NSImage?

    var body: some View {
        Image(nsImage: image ?? IconCache.icon(for: item.url))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .task(id: ThumbnailCache.key(item.url, size)) {
                image = await ThumbnailCache.thumbnail(for: item, size: size)
            }
    }
}
