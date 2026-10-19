import AppKit
import PDFKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Right-hand inspector: Preview / Details / Actions for the selection (or the current folder).
struct InspectorView: View {
    let state: WindowState
    let pane: PaneState

    @AppStorage("inspectorTab") private var tab: Tab = .preview

    enum Tab: String, CaseIterable, Identifiable {
        case preview = "Preview", details = "Details", actions = "Actions"

        var title: String {
            switch self {
            case .preview: return String(localized: "Preview")
            case .details: return String(localized: "Details")
            case .actions: return String(localized: "Actions")
            }
        }
        var id: String { rawValue }
    }

    /// What the inspector describes: the selection, or the folder being viewed when nothing is selected.
    private var items: [FileItem] {
        let selected = pane.selectedItems
        if !selected.isEmpty { return selected }
        return pane.location.folderURL.flatMap(FileItem.init(url:)).map { [$0] } ?? []
    }

    var body: some View {
        let items = self.items
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Inspector", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                moreMenu(items)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if items.isEmpty {
                ContentUnavailableView("Nothing selected", systemImage: "sidebar.right",
                                       description: Text("Select a file to see its preview and details."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch tab {
                        case .preview: PreviewTab(state: state, items: items)
                        case .details: DetailsTab(state: state, items: items)
                        case .actions: ActionsTab(state: state, pane: pane, items: items)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedContentBackground()
    }

    private func moreMenu(_ items: [FileItem]) -> some View {
        Menu {
            Button("Open", systemImage: "arrow.up.forward.app") { items.forEach { state.open($0, in: pane) } }
            Button("Show in Finder", systemImage: "macwindow") { state.revealInFinder(items.map(\.url)) }
            Button("Copy Path", systemImage: "link") { state.copyPaths(items.map(\.url)) }
            Divider()
            Button("Properties Window…", systemImage: "info.circle") { state.showProperties(items.map(\.url)) }
        } label: {
            Image(systemName: "ellipsis").frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(items.isEmpty)
    }
}

// MARK: - Preview tab

private struct PreviewTab: View {
    let state: WindowState
    let items: [FileItem]

    var body: some View {
        if items.count == 1, let item = items.first {
            PreviewBox(item: item, state: state)
                .padding(.bottom, 8)
            PluginInspectorSections(state: state, urls: items.map(\.url))
            FileInformationSection(item: item)
            if item.isFolderLike && Features.shared.isOn(.developer) { ProjectSection(folder: item.url) }
            TagsSection(state: state, items: items)
            QuickActionsSection(state: state, items: items)
            PermissionsSection(state: state, item: item)
            MoreMetadataSection(item: item)
        } else {
            SelectionSummary(items: items)
                .padding(.bottom, 8)
            PluginInspectorSections(state: state, urls: items.map(\.url))
            SelectionInformationSection(items: items)
            TagsSection(state: state, items: items)
            QuickActionsSection(state: state, items: items)
        }
    }
}

/// Preview with working zoom per type: images (AppKit magnification), PDFs (PDFKit scale),
/// web pages (WebKit page zoom). Other types use Quick Look, which can't be zoomed programmatically,
/// so the zoom controls are hidden for them.
private struct PreviewBox: View {
    let item: FileItem

    @State private var zoom: Double = 1

    let state: WindowState

    @State private var markdownHTML: String?

    var body: some View {
        let kind = ViewerKind.of(item)
        VStack(spacing: 8) {
            Group {
                switch kind {
                case .web:
                    // Real browser rendering at desktop width, scaled to fit; zoom changes the page zoom.
                    GeometryReader { geo in
                        WebPreview(url: item.url, pageZoom: geo.size.width / 1100 * zoom)
                    }
                case .image:
                    ZoomableImage(url: item.url, zoom: $zoom)
                case .pdf:
                    PDFPreview(url: item.url, zoom: $zoom)
                case .markdown:
                    if let markdownHTML {
                        HTMLStringPreview(html: markdownHTML, baseURL: item.url.deletingLastPathComponent(), pageZoom: zoom * 0.85)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .json:
                    JSONTreePreview(url: item.url)
                case .yaml:
                    YAMLPreview(url: item.url)
                case .code(let language):
                    CodePreview(url: item.url, language: language)
                case .archive:
                    ArchivePreview(url: item.url)
                case .log:
                    LogSnippet(url: item.url) { state.logViewerRequest = item.url }
                case .binary:
                    HexPreview(url: item.url)
                case .other:
                    QuickLookView(url: item.url)
                }
            }
            .task(id: item.url) {
                guard kind == .markdown else { return }
                let url = item.url
                markdownHTML = await Task.detached { MarkdownHTML.render((try? String(contentsOf: url, encoding: .utf8)) ?? "") }.value
            }
            .frame(maxWidth: .infinity)
            .frame(height: 230)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
            .id(item.url)

            HStack(spacing: 6) {
                if kind.zoomable {
                    HStack(spacing: 4) {
                        Button { zoom = max(zoom / 1.25, Self.zoomRange.lowerBound) } label: { Image(systemName: "minus.circle") }
                            .help("Zoom Out")
                            .accessibilityLabel("Zoom Out")
                        Slider(value: $zoom, in: Self.zoomRange).controlSize(.mini).frame(maxWidth: 90)
                        Button { zoom = min(zoom * 1.25, Self.zoomRange.upperBound) } label: { Image(systemName: "plus.circle") }
                            .help("Zoom In")
                            .accessibilityLabel("Zoom In")
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))

                    Button { zoom = 1 } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.borderless)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
                    .help("Fit")
                }

                Spacer(minLength: 0)

                if let opener = Self.opener(for: item) {
                    Button {
                        NSWorkspace.shared.open([item.url], withApplicationAt: opener.app, configuration: NSWorkspace.OpenConfiguration())
                    } label: {
                        Label(opener.title, systemImage: opener.symbol).lineLimit(1)
                    }
                    .controlSize(.small)
                }
            }
        }
        .onChange(of: item.url) { zoom = 1 }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .init("WayfileDebugZoom"))) { note in
            if let value = note.object as? Double { zoom = value }
        }
        #endif
    }

    static let zoomRange: ClosedRange<Double> = 0.5...4

    static func isWebPage(_ item: FileItem) -> Bool {
        ["html", "htm", "xhtml"].contains(item.url.pathExtension.lowercased())
    }

    /// Web pages open in the default browser; everything else in its default app.
    static func opener(for item: FileItem) -> (title: String, symbol: String, app: URL)? {
        if item.isFolderLike { return nil }
        let ext = item.url.pathExtension.lowercased()
        if ["html", "htm", "xhtml"].contains(ext), let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) {
            return ("Open in Browser", "safari", browser)
        }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: item.url) else { return nil }
        return ("Open in \(app.deletingPathExtension().lastPathComponent)", "arrow.up.forward.app", app)
    }
}

private struct SelectionSummary: View {
    let items: [FileItem]

    var body: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                ForEach(items.prefix(12)) { item in
                    VStack(spacing: 2) {
                        Thumbnail(item: item, size: 56)
                        Text(item.name).font(.caption2).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            if items.count > 12 { Text("+\(items.count - 12) more").font(.caption).foregroundStyle(.secondary) }
            Text("\(items.count) items selected").font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

// MARK: - Sections

/// Collapsible section whose open/closed state is remembered.
struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    @AppStorage private var isExpanded: Bool

    init(_ title: String, expandedByDefault: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
        _isExpanded = AppStorage(wrappedValue: expandedByDefault, "inspector.section.\(title)")
    }

    var body: some View {
        if InspectorConfig.shared.isShown(title) { section }
    }

    private var section: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text(key: title).font(.headline)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content
                    .padding(.leading, 2)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var copyable = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key: label)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if copyable {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy")
                .accessibilityLabel("Copy")
            }
        }
        .font(.callout)
    }
}



private func sizeText(_ bytes: Int64, complete: Bool = true) -> String {
    let exact = bytes >= 1000 ? " (" + String(localized: "\(bytes.formatted()) bytes") + ")" : ""
    return Formatters.size(bytes) + exact + (complete ? "" : "…")
}

private struct FileInformationSection: View {
    let item: FileItem

    @State private var summary: SizeSummary?

    var body: some View {
        InspectorSection("File Information") {
            InfoRow(label: "Name", value: item.name)
            InfoRow(label: "Type", value: item.kind)
            if item.hasSize {
                InfoRow(label: "Size", value: sizeText(item.size))
            } else if let summary {
                InfoRow(label: "Size", value: sizeText(summary.bytes, complete: summary.isComplete))
                InfoRow(label: "Contains", value: String(localized: "\(summary.files) files") + ", " + String(localized: "\(max(summary.folders - 1, 0)) folders"))
            }
            InfoRow(label: "Created", value: Formatters.date(item.created))
            InfoRow(label: "Modified", value: Formatters.date(item.modified))
            InfoRow(label: "Where", value: item.url.deletingLastPathComponent().path, copyable: true)
        }
        .task(id: item.url) {
            summary = nil
            guard !item.hasSize else { return }
            for await update in SizeCalculator.summarize([item.url]) { summary = update }
        }
    }
}

private struct SelectionInformationSection: View {
    let items: [FileItem]

    @State private var summary: SizeSummary?

    var body: some View {
        InspectorSection("Selection") {
            InfoRow(label: "Items", value: "\(items.count)")
            if let summary {
                InfoRow(label: "Total size", value: sizeText(summary.bytes, complete: summary.isComplete))
            }
            let kinds = Dictionary(grouping: items, by: \.kind).map { "\($0.value.count) × \($0.key)" }.sorted()
            InfoRow(label: "Kinds", value: kinds.prefix(4).joined(separator: "\n") + (kinds.count > 4 ? "\n…" : ""))
            let folders = Set(items.map { $0.url.deletingLastPathComponent().path })
            InfoRow(label: "Where", value: folders.count == 1 ? folders.first! : "\(folders.count) folders", copyable: folders.count == 1)
        }
        .task(id: items.map(\.url)) {
            summary = nil
            for await update in SizeCalculator.summarize(items.map(\.url)) { summary = update }
        }
    }
}

private struct TagsSection: View {
    let state: WindowState
    let items: [FileItem]

    @State private var newTag = ""

    /// Tags every selected item has.
    private var common: [FileTag] {
        guard let first = items.first else { return [] }
        return first.fileTags.filter { tag in items.allSatisfy { $0.tags.contains(tag.name) } }
    }

    var body: some View {
        InspectorSection("Tags") {
            FlowLayout(spacing: 6) {
                ForEach(common) { tag in
                    TagPill(tag: tag, onRemove: { state.toggleTag(tag, on: items) })
                }
                TextField("Add Tag…", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                    .onSubmit(addTag)
            }
            let suggestions = TagStore.shared.favorites.filter { tag in !common.contains { $0.name == tag.name } }
            if !suggestions.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(suggestions) { tag in
                        Button { state.toggleTag(tag, on: items) } label: {
                            Circle()
                                .fill(Color(nsColor: tag.nsColor ?? .tertiaryLabelColor))
                                .frame(width: 12, height: 12)
                        }
                        .buttonStyle(.plain)
                        .help("Add “\(tag.name)”")
                    }
                }
            }
        }
    }

    private func addTag() {
        let name = newTag.trimmingCharacters(in: .whitespaces)
        newTag = ""
        guard !name.isEmpty, !common.contains(where: { $0.name == name }) else { return }
        let tag = FileTag(name: name, color: TagStore.shared.color(for: name))
        // Add to items that don't have it yet (toggle would remove it from the others).
        state.toggleTag(tag, on: items.filter { !$0.tags.contains(name) })
    }
}

private struct QuickActionsSection: View {
    let state: WindowState
    let items: [FileItem]

    @State private var hash: String?
    @State private var hashing = false

    var body: some View {
        InspectorSection("Quick Actions") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ActionTile(items.count == 1 ? "Copy Path" : "Copy Paths", symbol: "doc.on.doc") {
                    state.copyPaths(items.map(\.url))
                }
                ActionTile("Show in Finder", symbol: "macwindow") { state.revealInFinder(items.map(\.url)) }
                if items.count == 1, let item = items.first {
                    if item.isFolderLike {
                        ActionTile("Open in Terminal", symbol: "terminal") { state.openInTerminal(item.url) }
                    } else {
                        ActionTile(hashing ? "Hashing…" : (hash == nil ? "SHA-256" : "SHA-256 Copied"), symbol: "number") {
                            copySHA256(item.url)
                        }
                        .disabled(hashing)
                    }
                }
                ActionTile("Compress", symbol: "archivebox") {
                    state.activePane.selection = Set(items.map(\.url))
                    state.compressSelection()
                }
            }
            if let hash {
                Text(hash)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
        }
        .onChange(of: items.map(\.url)) { hash = nil }
    }

    private func copySHA256(_ url: URL) {
        hashing = true
        Task {
            if let hashes = try? await Hashing.hashes(of: url, progress: { _ in }) {
                hash = hashes.sha256
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hashes.sha256, forType: .string)
            }
            hashing = false
        }
    }
}

private struct ActionTile: View {
    let title: String
    let symbol: String
    let action: () -> Void

    init(_ title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 16)
                Text(key: title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PermissionsSection: View {
    let state: WindowState
    let item: FileItem

    var body: some View {
        InspectorSection("Permissions", expandedByDefault: false) {
            if let permissions = Permissions.read(item.url) {
                InfoRow(label: "Owner", value: permissions.owner)
                InfoRow(label: "Group", value: permissions.group)
                InfoRow(label: "Mode", value: "\(permissions.symbolic)  (\(permissions.octal))")
                if permissions.isLocked { InfoRow(label: "Locked", value: "Yes") }
                Button("Edit Permissions…") { state.showProperties([item.url]) }
                    .controlSize(.small)
            } else {
                Text("Unavailable").foregroundStyle(.secondary)
            }
        }
    }
}

private struct MoreMetadataSection: View {
    let item: FileItem

    @State private var sections: [MetadataSection]?

    var body: some View {
        InspectorSection("More Metadata", expandedByDefault: false) {
            if let commit = item.lastCommit {
                InfoRow(label: "Git", value: item.gitStatus?.title ?? String(localized: "Unchanged"))
                InfoRow(label: "Last commit", value: "\(commit.subject)\n\(commit.author) · \(commit.date.formatted(.relative(presentation: .named))) · \(commit.hash)")
            }
            if let sections {
                ForEach(sections) { section in
                    ForEach(section.rows) { row in InfoRow(label: row.label, value: row.value) }
                }
                if sections.isEmpty && item.lastCommit == nil {
                    Text("No additional metadata.").foregroundStyle(.secondary).font(.callout)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: item.url) {
            sections = item.isFolderLike ? [] : await Metadata.sections(for: item.url)
        }
    }
}

// MARK: - Details tab

private struct DetailsTab: View {
    let state: WindowState
    let items: [FileItem]

    var body: some View {
        if items.count == 1, let item = items.first {
            FileInformationSection(item: item)
            let features = Features.shared
            if item.isFolderLike && features.isOn(.developer) { ProjectSection(folder: item.url) }
            if features.isOn(.diskTools) {
                LinksSection(state: state, item: item)
                CustomMetadataSection(item: item)
            }
            if features.isOn(.security) {
                ExtendedAttributesSection(url: item.url)
                ACLSection(url: item.url)
            }
            GitSection(state: state, item: item)
            if !item.isDirectory { HashesSection(item: item) }
            if !item.isDirectory { VersionsSection(url: item.url, state: state) }
            PermissionsSection(state: state, item: item)
            MoreMetadataSection(item: item)
        } else {
            SelectionInformationSection(items: items)
        }
    }
}

private struct GitSection: View {
    let state: WindowState
    let item: FileItem

    var body: some View {
        if item.gitStatus != nil || item.lastCommit != nil {
            InspectorSection("Git") {
                InfoRow(label: "Status", value: item.gitStatus?.title ?? String(localized: "Unchanged"))
                if let commit = item.lastCommit {
                    InfoRow(label: "Commit", value: commit.subject)
                    InfoRow(label: "Author", value: commit.author)
                    InfoRow(label: "Date", value: Formatters.date(commit.date))
                    InfoRow(label: "Hash", value: commit.hash, copyable: true)
                }
                HStack {
                    if !item.isDirectory, let status = item.gitStatus, status != .untracked {
                        Button("Show Changes") { state.showGitChanges(item.url) }
                    }
                    if item.lastCommit != nil {
                        Button("History") { state.showGitHistory(item.url) }
                    }
                    if let root = state.activePane.git?.root {
                        Button("Commit…") { state.gitRequest = GitTarget(root: root) }
                    }
                }
                .controlSize(.small)
            }
        }
    }
}

/// Symbolic link target (with a way to it) and hard-link count.
private struct LinksSection: View {
    let state: WindowState
    let item: FileItem

    var body: some View {
        let info = Links.info(item.url)
        if info.isSymlink || info.hardLinkCount > 1 {
            InspectorSection("Links") {
                if let target = info.symlinkTarget {
                    InfoRow(label: "Points to", value: target, copyable: true)
                    if let resolved = info.resolved {
                        Button("Show Original") {
                            state.activePane.navigate(to: .folderAt(resolved.deletingLastPathComponent()))
                            Task {
                                try? await Task.sleep(for: .milliseconds(400))
                                state.activePane.selection = [resolved]
                            }
                        }
                        .controlSize(.small)
                    } else {
                        Label("Broken — the original is missing", systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    }
                }
                if info.hardLinkCount > 1 {
                    InfoRow(label: "Hard links", value: "\(info.hardLinkCount) names share this file’s data")
                }
            }
        }
    }
}

/// Key/value pairs kept with the file (extended attribute); searchable with the Metadata filter.
private struct CustomMetadataSection: View {
    let item: FileItem
    @State private var rows: [Row] = []
    @State private var error: String?

    struct Row: Identifiable, Equatable { let id = UUID(); var key: String; var value: String }

    var body: some View {
        InspectorSection("Custom Metadata", expandedByDefault: false) {
            ForEach($rows) { $row in
                HStack(spacing: 4) {
                    TextField("Key", text: $row.key).frame(width: 90)
                    TextField("Value", text: $row.value)
                    Button { rows.removeAll { $0.id == row.id }; save() } label: { Image(systemName: "minus.circle") }
                        .accessibilityLabel("Remove field \(row.key)")
                        .buttonStyle(.borderless)
                }
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit(save)
            }
            HStack {
                Button("Add Field") { rows.append(Row(key: "", value: "")) }
                Spacer()
                if rows != loaded { Button("Save", action: save).keyboardShortcut(.return, modifiers: .command) }
            }
            .controlSize(.small)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onAppear(perform: load)
        .onChange(of: item.url) { load() }
    }

    @State private var loaded: [Row] = []

    private func load() {
        rows = CustomMetadata.read(item.url).sorted { $0.key < $1.key }.map { Row(key: $0.key, value: $0.value) }
        loaded = rows
        error = nil
    }

    private func save() {
        var values: [String: String] = [:]
        for row in rows where !row.key.trimmingCharacters(in: .whitespaces).isEmpty { values[row.key.trimmingCharacters(in: .whitespaces)] = row.value }
        do {
            try CustomMetadata.write(values, to: item.url)
            loaded = rows
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Detected project types in a folder with their common commands (run in the Automation console).
private struct ProjectSection: View {
    let folder: URL
    @State private var projects: [ProjectInfo] = []

    var body: some View {
        Group {
            if !projects.isEmpty {
                InspectorSection("Project") {
                    ForEach(projects) { project in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: project.kind.symbol).foregroundStyle(.secondary)
                                Text(project.kind.title).fontWeight(.medium)
                                if let name = project.name { Text(name).foregroundStyle(.secondary).lineLimit(1) }
                                if let version = project.version { Text(version).font(.caption).foregroundStyle(.tertiary) }
                                if project.kind == .docker {
                                    Spacer()
                                    Button("Containers") { NotificationCenter.default.post(name: .openToolWindow, object: "docker") }
                                        .controlSize(.small)
                                }
                            }
                            if !project.commands.isEmpty {
                                FlowLayout(spacing: 4) {
                                    ForEach(project.commands) { command in
                                        Button(command.title) {
                                            AutomationCenter.shared.runCommand(command.command, title: command.command, in: folder)
                                            NotificationCenter.default.post(name: .openAutomation, object: nil)
                                        }
                                        .controlSize(.small)
                                        .help(command.command)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    HStack {
                        ForEach(Editors.installed.prefix(2), id: \.url) { editor in
                            Button("Open in \(editor.name)") { Editors.open(folder, with: editor.url) }
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
        .task(id: folder) {
            let folder = folder
            projects = await Task.detached { ProjectDetector.detect(in: folder) }.value
        }
    }
}

private struct HashesSection: View {
    let item: FileItem

    @State private var hashes: FileHashes?
    @State private var progress: Double?

    var body: some View {
        InspectorSection("Hashes", expandedByDefault: false) {
            if let hashes {
                ForEach(hashes.all, id: \.name) { InfoRow(label: $0.name, value: $0.value, copyable: true) }
            } else if let progress {
                ProgressView(value: progress)
            } else {
                Button("Calculate MD5, SHA-1, SHA-256, SHA-512") { calculate() }
                    .controlSize(.small)
            }
        }
        .onChange(of: item.url) { hashes = nil; progress = nil }
    }

    private func calculate() {
        progress = 0
        let url = item.url
        Task {
            hashes = try? await Hashing.hashes(of: url) { value in Task { @MainActor in progress = value } }
            progress = nil
        }
    }
}

// MARK: - Actions tab

private struct ActionsTab: View {
    let state: WindowState
    let pane: PaneState
    let items: [FileItem]

    var body: some View {
        let urls = items.map(\.url)
        let single = items.count == 1 ? items.first : nil
        VStack(alignment: .leading, spacing: 8) {
            group("Open") {
                ActionTile("Open", symbol: "arrow.up.forward.app") { items.forEach { state.open($0, in: pane) } }
                ActionTile("Quick Look", symbol: "eye") { state.quickLookURL = urls.first }
                if let single, single.isFolderLike {
                    ActionTile("Open in New Tab", symbol: "plus.square.on.square") { state.newTab(.folderAt(single.url)) }
                    ActionTile("Open in Terminal", symbol: "terminal") { state.openInTerminal(single.url) }
                    ActionTile("Compare…", symbol: "arrow.left.arrow.right") { state.compare(single.url) }
                }
                if let single, single.isFolderLike {
                    ActionTile("Find Duplicates", symbol: "doc.on.doc") { state.duplicatesRequest = single.url }
                    ActionTile("Fingerprint (Baseline)", symbol: "checkmark.shield") { state.createIntegrityBaseline(single.url) }
                    if Integrity.baseline(for: single.url) != nil {
                        ActionTile("Check Integrity", symbol: "shield.lefthalf.filled") { state.checkIntegrity(single.url) }
                    }
                }
                ActionTile("Show in Finder", symbol: "macwindow") { state.revealInFinder(urls) }
            }
            group("Organize") {
                ActionTile(items.count > 1 ? "Rename \(items.count) Items…" : "Rename…", symbol: "character.cursor.ibeam") {
                    select(urls); state.beginRename()
                }
                ActionTile("Duplicate", symbol: "plus.square.on.square") { state.duplicateSelection(urls) }
                ActionTile("Compress", symbol: "archivebox") { select(urls); state.compressSelection() }
                if items.contains(where: \.isArchive) {
                    ActionTile("Extract", symbol: "arrow.up.bin") { select(urls); state.extractSelection() }
                }
                if let single, single.isFolderLike {
                    let pinned = PinnedStore.shared.isPinned(single.url)
                    ActionTile(pinned ? "Remove from Favorites" : "Add to Favorites", symbol: pinned ? "star.slash" : "star") {
                        if pinned { PinnedStore.shared.unpin(single.url) } else { PinnedStore.shared.pin(single.url) }
                    }
                }
            }
            let scripts = Features.shared.isOn(.automation) ? AutomationCenter.shared.scripts(for: urls) : []
            if !scripts.isEmpty {
                group("Scripts") {
                    ForEach(scripts.prefix(8)) { script in
                        ActionTile(script.name, symbol: script.language.symbol) {
                            AutomationCenter.shared.request(script, context: state.scriptContext(for: urls))
                        }
                    }
                    ActionTile("Automation…", symbol: "gearshape.2") { NotificationCenter.default.post(name: .openAutomation, object: nil) }
                }
            }
            group("AI") {
                ActionTile(items.count == 1 && items[0].isFolderLike ? "Ask AI About Folder" : "Ask AI", symbol: "sparkles") {
                    state.askAIRequest = AskAITarget(urls: urls)
                }
                if let single, single.isFolderLike {
                    ActionTile("Search with AI", symbol: "sparkle.magnifyingglass") {
                        state.aiSearchFolder = single.url
                        state.showAskAI = true
                    }
                }
            }
            group("Share & Info") {
                ActionTile("Copy Path", symbol: "link") { state.copyPaths(urls) }
                ActionTile("Properties Window", symbol: "info.circle") { state.showProperties(urls) }
                ActionTile("Move to Trash", symbol: "trash") { select(urls); state.trashSelection() }
            }
        }
        .padding(.top, 4)
    }

    private func select(_ urls: [URL]) {
        // When the inspector shows the current folder (nothing selected), act on that folder.
        if pane.selection.isEmpty, let folder = urls.first, urls.count == 1, folder == pane.location.folderURL {
            return
        }
        pane.selection = Set(urls)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(key: title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                content()
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Shared pieces

/// A row of compact tag capsules for tables and cards (clipped when there's no room).
struct TagPills: View {
    let tags: [FileTag]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags) { TagPill(tag: $0, compact: true) }
        }
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .help(tags.map(\.name).joined(separator: ", "))
    }
}

/// Coloured tag capsule; shows a remove button on hover when `onRemove` is given.
struct TagPill: View {
    let tag: FileTag
    var compact = false
    var onRemove: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        let color = Color(nsColor: tag.nsColor ?? .secondaryLabelColor)
        HStack(spacing: 4) {
            Text(tag.name).lineLimit(1)
            if let onRemove, hovering {
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain)
            }
        }
        .font(compact ? .caption : .callout)
        .padding(.horizontal, compact ? 7 : 10)
        .padding(.vertical, compact ? 1.5 : 3)
        .foregroundStyle(tag.nsColor == nil ? Color.primary : color)
        .background(Capsule().fill(color.opacity(tag.nsColor == nil ? 0.12 : 0.16)))
        .onHover { hovering = $0 }
    }
}

/// Wraps children onto new lines when they don't fit (for tag pills).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// An image that fits the box at zoom 1 and magnifies natively (slider, buttons or trackpad pinch).
struct ZoomableImage: NSViewRepresentable {
    let url: URL
    @Binding var zoom: Double

    func makeCoordinator() -> Coordinator { Coordinator(zoom: $zoom) }

    func makeNSView(context: Context) -> FitImageScrollView {
        let scroll = FitImageScrollView()
        scroll.image = NSImage(contentsOf: url)
        scroll.minMagnification = PreviewBox.zoomRange.lowerBound
        scroll.maxMagnification = PreviewBox.zoomRange.upperBound
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.magnified(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification, object: scroll
        )
        return scroll
    }

    func updateNSView(_ scroll: FitImageScrollView, context: Context) {
        context.coordinator.zoom = $zoom
        if abs(scroll.magnification - zoom) > 0.001 {
            let center = NSPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY)
            scroll.setMagnification(zoom, centeredAt: center)
        }
    }

    final class Coordinator: NSObject {
        var zoom: Binding<Double>
        init(zoom: Binding<Double>) { self.zoom = zoom }

        /// Pinch gestures update the slider.
        @objc func magnified(_ note: Notification) {
            guard let scroll = note.object as? NSScrollView else { return }
            zoom.wrappedValue = scroll.magnification
        }
    }
}

final class FitImageScrollView: NSScrollView {
    private let imageView = NSImageView()

    var image: NSImage? {
        didSet { imageView.image = image; needsLayout = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        contentView = CenteringClipView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        documentView = imageView
        allowsMagnification = true
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        // At magnification 1 the image fills the visible area (aspect fit); magnification scales from there.
        guard let size = image?.size, size.width > 0, size.height > 0 else { return }
        let available = frame.size
        let scale = min(available.width / size.width, available.height / size.height)
        let fitted = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        if imageView.frame.size != fitted { imageView.frame = NSRect(origin: .zero, size: fitted) }
    }
}

/// Keeps a smaller-than-viewport document centred instead of pinned to the bottom-left.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

/// PDF pages fitted to the box at zoom 1; zoom scales from the fitted size (pinch updates the slider).
struct PDFPreview: NSViewRepresentable {
    let url: URL
    @Binding var zoom: Double

    func makeCoordinator() -> Coordinator { Coordinator(zoom: $zoom) }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = PDFDocument(url: url)
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        view.autoScales = true
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.scaleChanged(_:)),
            name: .PDFViewScaleChanged, object: view
        )
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.zoom = $zoom
        let fit = view.scaleFactorForSizeToFit
        guard fit > 0 else { return }
        let target = fit * zoom
        if abs(view.scaleFactor - target) > 0.001 {
            context.coordinator.isUpdating = true
            view.autoScales = false
            view.scaleFactor = target
            context.coordinator.isUpdating = false
        }
    }

    final class Coordinator: NSObject {
        var zoom: Binding<Double>
        var isUpdating = false
        init(zoom: Binding<Double>) { self.zoom = zoom }

        @objc func scaleChanged(_ note: Notification) {
            guard !isUpdating, let view = note.object as? PDFView, view.scaleFactorForSizeToFit > 0 else { return }
            zoom.wrappedValue = view.scaleFactor / view.scaleFactorForSizeToFit
        }
    }
}

/// Renders a local web page with WebKit (relative CSS/images in its folder load too).
struct WebPreview: NSViewRepresentable {
    let url: URL
    let pageZoom: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url?.standardizedFileURL != url.standardizedFileURL {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        let zoom = max(pageZoom, 0.1)
        if abs(view.pageZoom - zoom) > 0.001 { view.pageZoom = zoom }
    }
}

/// Embeds the system Quick Look renderer (images, PDFs, video, text, web pages, Office docs…).
struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact)!
        view.autostarts = true
        view.shouldCloseWithWindow = false
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

// MARK: - Versions

/// Older versions macOS kept for a document (apps that use document versioning: TextEdit, Pages…).
struct VersionsSection: View {
    let url: URL
    let state: WindowState

    @State private var versions: [NSFileVersion] = []

    var body: some View {
        Group {
            if !versions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Versions").font(.headline)
                    ForEach(versions, id: \.url) { version in
                        HStack {
                            Text(version.modificationDate.map(Formatters.date) ?? String(localized: "Unknown date"))
                            if let computer = version.localizedNameOfSavingComputer {
                                Text(computer).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Open") { NSWorkspace.shared.open(version.url) }.controlSize(.small)
                            Button("Restore…") { restore(version) }.controlSize(.small)
                                .help("Replace the current file with this version (the current one goes to the Trash)")
                        }
                        .font(.callout)
                    }
                }
                .padding(.vertical, 10)
                .overlay(alignment: .top) { Divider() }
            }
        }
        .task(id: url) { versions = (NSFileVersion.otherVersionsOfItem(at: url) ?? []).sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) } }
    }

    private func restore(_ version: NSFileVersion) {
        let (target, source) = (url, version.url)
        Task {
            do {
                try await OperationCenter.shared.run("Restoring a version of “\(target.lastPathComponent)”", undoTitle: "Restore Version") { progress in
                    var trashed: NSURL?
                    try FileManager.default.trashItem(at: target, resultingItemURL: &trashed)
                    if let trashed { progress.record(.trashed([TrashedItem(original: target, trashed: trashed as URL)])) }
                    try FileManager.default.copyItem(at: source, to: target)
                    progress.record(.created([target]))
                    return [target]
                }
                state.reloadAll()
            } catch {
                state.errorMessage = error.localizedDescription
            }
        }
    }
}
