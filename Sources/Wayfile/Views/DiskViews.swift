import AppKit
import QuickLookUI
import SwiftUI

// MARK: - Disk usage

/// Treemap of what takes space under a folder; click to drill down, right-click to reveal or trash.
struct DiskUsageView: View {
    let root: URL
    @State private var tree: SizeNode?
    @State private var current: SizeNode?
    @State private var hovered: SizeNode?
    @State private var progress = DiskUsage.Progress()
    @State private var scanned = (files: 0, bytes: Int64(0))
    @State private var version = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let current {
                HSplitView {
                    GeometryReader { geo in
                        Treemap(node: current, size: geo.size, hovered: $hovered, version: version) { node in
                            if node.isDirectory && !node.children.isEmpty { self.current = node }
                        } menu: { node in
                            AnyView(menu(for: node))
                        }
                    }
                    .frame(minWidth: 420)
                    list(current)
                        .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Scanning… \(String(localized: "\(scanned.files) files")) · \(Formatters.size(scanned.bytes))").foregroundStyle(.secondary)
                    Button("Stop") { progress.cancel() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 480)
        .navigationTitle("Disk Usage — \(root.lastPathComponent)")
        .task { await scan() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button { if let parent = current?.parent { current = parent } } label: { Image(systemName: "chevron.up") }
                .accessibilityLabel("Enclosing folder")
                .disabled(current?.parent == nil)
            ForEach(path, id: \.id) { node in
                if node !== path.first { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                Button(node.name) { current = node }.buttonStyle(.borderless)
            }
            Spacer()
            Button { Task { await scan() } } label: { Image(systemName: "arrow.clockwise") }.help("Scan again")
            .accessibilityLabel("Scan again")
        }
        .lineLimit(1)
        .controlSize(.small)
        .padding(8)
    }

    private var path: [SizeNode] {
        var nodes: [SizeNode] = []
        var node = current
        while let n = node { nodes.insert(n, at: 0); node = n.parent }
        return nodes
    }

    private var footer: some View {
        HStack {
            if let node = hovered ?? current {
                Text(node.isAggregate ? node.name : node.url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                (Text(verbatim: Formatters.size(node.size) + " · ") + Text("\(node.fileCount) files")).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func list(_ node: SizeNode) -> some View {
        List(node.children) { child in
            HStack(spacing: 6) {
                Image(nsImage: child.isAggregate ? NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)! : IconCache.icon(for: child.url))
                    .resizable().frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(child.name).lineLimit(1).truncationMode(.middle)
                    GeometryReader { geo in
                        Capsule().fill(Treemap.color(for: child).opacity(0.8))
                            .frame(width: max(2, geo.size.width * CGFloat(Double(child.size) / Double(max(node.size, 1)))))
                    }
                    .frame(height: 4)
                }
                Spacer()
                Text(Formatters.size(child.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if child.isDirectory && !child.children.isEmpty { current = child } }
            .onHover { hovered = $0 ? child : nil }
            .contextMenu { menu(for: child) }
        }
    }

    @ViewBuilder
    private func menu(for node: SizeNode) -> some View {
        if !node.isAggregate {
            if node.isDirectory && !node.children.isEmpty { Button("Zoom In") { current = node } }
            Button("Show in Wayfile") { reveal(node.url) }
            Button("Quick Look") { NSWorkspace.shared.open(node.url) }
            Divider()
            Button("Move to Trash", role: .destructive) { trash(node) }
        }
    }

    private func reveal(_ url: URL) {
        guard let state = WindowState.lastActive else { NSWorkspace.shared.activateFileViewerSelecting([url]); return }
        state.activePane.navigate(to: .folderAt(url.deletingLastPathComponent()))
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            state.activePane.selection = [url]
        }
    }

    private func trash(_ node: SizeNode) {
        let url = node.url
        Task {
            do {
                _ = try await OperationCenter.shared.run("Trashing “\(url.lastPathComponent)”", undoTitle: "Trash") { progress in
                    try FileOps.trash([url], progress: progress)
                }
                node.parent?.remove(node)
                version += 1
                WindowState.lastActive?.reloadAll()
            } catch {}
        }
    }

    private func scan() async {
        progress.cancel()
        let fresh = DiskUsage.Progress()
        progress = fresh
        tree = nil
        current = nil
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                scanned = (fresh.files, fresh.bytes)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        let root = root
        let result = await Task.detached(priority: .userInitiated) { DiskUsage.scan(root, progress: fresh) }.value
        poll.cancel()
        tree = result
        current = result
    }
}

/// Nested treemap: each folder's children inside its rectangle (two levels deep).
private struct Treemap: View {
    let node: SizeNode
    let size: CGSize
    @Binding var hovered: SizeNode?
    let version: Int
    let open: (SizeNode) -> Void
    let menu: (SizeNode) -> AnyView

    var body: some View {
        let children = node.children.filter { $0.size > 0 }
        let rects = DiskUsage.treemap(children.map { Double($0.size) }, in: CGRect(origin: .zero, size: size))
        ZStack(alignment: .topLeading) {
            ForEach(Array(zip(children, rects)), id: \.0.id) { child, rect in
                cell(child, rect: rect)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .id(version)
    }

    @ViewBuilder
    private func cell(_ child: SizeNode, rect: CGRect) -> some View {
        let color = Self.color(for: child)
        let inner = rect.insetBy(dx: 1, dy: 1)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3).fill(color.opacity(hovered === child ? 0.55 : 0.32))
            RoundedRectangle(cornerRadius: 3).stroke(color.opacity(0.8), lineWidth: 0.5)
            // Second level: show what's inside big folders.
            if child.isDirectory, inner.width > 60, inner.height > 40 {
                let grand = child.children.filter { $0.size > 0 }
                let header: CGFloat = 16
                let area = CGRect(x: 2, y: header, width: inner.width - 4, height: inner.height - header - 2)
                let sub = DiskUsage.treemap(grand.map { Double($0.size) }, in: area)
                ForEach(Array(zip(grand, sub)), id: \.0.id) { g, r in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Self.color(for: g).opacity(0.28))
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                        .overlay(alignment: .topLeading) {
                            if r.width > 50 && r.height > 16 {
                                Text(g.name + (r.width > 130 ? "  " + Formatters.size(g.size) : ""))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .padding(3)
                            }
                        }
                        .frame(width: max(0, r.width - 1), height: max(0, r.height - 1))
                        .offset(x: r.minX, y: r.minY)
                }
            }
            if inner.width > 46 && inner.height > 14 {
                Text(child.name + (inner.width > 120 ? "  " + Formatters.size(child.size) : ""))
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
                    .frame(width: inner.width, alignment: .leading)
            }
        }
        .frame(width: max(0, inner.width), height: max(0, inner.height))
        .offset(x: inner.minX, y: inner.minY)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? child : (hovered === child ? nil : hovered) }
        .onTapGesture(count: 2) { open(child) }
        .contextMenu { menu(child) }
        .help("\(child.name) — \(Formatters.size(child.size))")
    }

    static func color(for node: SizeNode) -> Color {
        if node.isAggregate { return .gray }
        if node.isDirectory { return .blue }
        switch RuleEngine.kindFolder(for: node.url) {
        case "Images": return .green
        case "Videos": return .purple
        case "Audio": return .pink
        case "Documents": return .orange
        case "Archives": return .brown
        case "Applications": return .teal
        case "Text & Code": return .mint
        default: return .secondary
        }
    }
}

// MARK: - Archive browser

/// Browse an archive's folders read-only; extract a selection or open one file.
struct ArchiveBrowserView: View {
    let archive: URL
    @State private var entries: [ArchiveEntry] = []
    @State private var folder = ""
    @State private var selection: Set<ArchiveEntry.ID> = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        let children = ArchiveIndex.children(of: folder, in: entries)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { goUp() } label: { Image(systemName: "chevron.up") }.disabled(folder.isEmpty).accessibilityLabel("Enclosing folder")
                Image(nsImage: IconCache.icon(for: archive)).resizable().frame(width: 16, height: 16)
                Text(([archive.lastPathComponent] + folder.split(separator: "/").map(String.init)).joined(separator: " › ")).lineLimit(1).truncationMode(.head)
                Spacer()
                Button("Extract Selected") { extract(children.filter { selection.contains($0.id) }) }.disabled(selection.isEmpty)
                Button("Extract All") { extract(ArchiveIndex.children(of: "", in: entries), base: "") }.disabled(entries.isEmpty)
            }
            .controlSize(.small)
            .padding(8)
            Divider()
            Table(children, selection: $selection) {
                TableColumn("Name") { entry in
                    HStack(spacing: 6) {
                        Image(systemName: entry.isDirectory ? "folder.fill" : "doc").foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                        Text(entry.name).lineLimit(1)
                    }
                }
                TableColumn("Size") { entry in
                    Text(Formatters.size(entry.isDirectory ? ArchiveIndex.size(of: entry.path, in: entries) : entry.size)).foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 90)
            }
            .contextMenu(forSelectionType: ArchiveEntry.ID.self) { ids in
                let chosen = children.filter { ids.contains($0.id) }
                Button("Extract to Current Folder") { extract(chosen) }
                if chosen.count == 1, !chosen[0].isDirectory { Button("Open") { open(chosen[0]) } }
            } primaryAction: { ids in
                guard let entry = children.first(where: { ids.contains($0.id) }) else { return }
                if entry.isDirectory { folder = entry.path; selection = [] } else { open(entry) }
            }
            .overlay {
                if !loaded { ProgressView() } else if entries.isEmpty { ContentUnavailableView("Can’t read this archive", systemImage: "archivebox") }
            }
            Divider()
            Text("Read-only. Extracted items go to “\(destination.lastPathComponent)”; everything can be undone from the Timeline.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
        .frame(minWidth: 620, minHeight: 420)
        .navigationTitle(archive.lastPathComponent)
        .task {
            do { entries = try await ArchiveIndex.entries(of: archive) } catch { self.error = error.localizedDescription }
            // Chains of single folders (a zip of "/Users/me/project") are opened right away.
            var top = ArchiveIndex.children(of: "", in: entries)
            while top.count == 1, top[0].isDirectory {
                folder = top[0].path
                top = ArchiveIndex.children(of: folder, in: entries)
            }
            loaded = true
        }
        .alert("Archive", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var destination: URL {
        WindowState.lastActive?.activePane.location.folderURL ?? archive.deletingLastPathComponent()
    }

    private func goUp() {
        var parts = folder.split(separator: "/")
        _ = parts.popLast()
        folder = parts.isEmpty ? "" : parts.joined(separator: "/") + "/"
        selection = []
    }

    private func extract(_ chosen: [ArchiveEntry], base: String? = nil) {
        guard !chosen.isEmpty else { return }
        let archive = archive, dest = destination, root = base ?? folder
        Task {
            do {
                _ = try await OperationCenter.shared.run(String(localized: "Extracting \(String(localized: "\(chosen.count) items")) from \(archive.lastPathComponent)"), undoTitle: "Extract") { progress in
                    let made = try await ArchiveIndex.extract(archive, entries: chosen, base: root, to: dest)
                    progress.record(.created(made))
                    return made
                }
                WindowState.lastActive?.reloadAll()
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func open(_ entry: ArchiveEntry) {
        let archive = archive
        let folder = folder
        Task {
            do {
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent("wayfile-archive-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
                let made = try await ArchiveIndex.extract(archive, entries: [entry], base: folder, to: temp)
                if let file = made.first { NSWorkspace.shared.open(file) }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Compress options

struct CompressSheet: View {
    let state: WindowState
    let urls: [URL]
    @State private var options = CompressOptions()
    @Environment(\.dismiss) private var dismiss

    init(state: WindowState, urls: [URL]) {
        self.state = state
        self.urls = urls
        var initial = CompressOptions()
        initial.name = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
        if let raw = UserDefaults.standard.string(forKey: "compress.format"), let format = CompressOptions.Format(rawValue: raw) { initial.format = format }
        initial.level = UserDefaults.standard.object(forKey: "compress.level") as? Int ?? 6
        _options = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            (urls.count == 1 ? Text("Compress “\(urls[0].lastPathComponent)”") : Text("Compress \(urls.count) Items")).font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $options.name)
                Picker("Format", selection: $options.format) {
                    ForEach(CompressOptions.Format.allCases) { Text($0.title).tag($0) }
                }
                if options.format.supportsLevel {
                    LabeledContent("Compression") {
                        HStack {
                            Text("Faster").font(.caption).foregroundStyle(.secondary)
                            Slider(value: Binding(get: { Double(options.level) }, set: { options.level = Int($0) }), in: 0...9, step: 1)
                            Text("Smaller").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if options.format == .zip {
                    SecureField("Password (optional)", text: $options.password)
                    if !options.password.isEmpty {
                        Text("ZIP passwords use the old ZipCrypto scheme that opens everywhere but is weak. For real protection use an Encrypted Vault.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Toggle("Leave out .DS_Store and Mac metadata", isOn: $options.excludeMacMetadata)
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Compress") { compress() }.keyboardShortcut(.defaultAction).disabled(options.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func compress() {
        UserDefaults.standard.set(options.format.rawValue, forKey: "compress.format")
        UserDefaults.standard.set(options.level, forKey: "compress.level")
        let options = options, urls = urls
        dismiss()
        state.runCompress(urls, options: options)
    }
}

// MARK: - Broken links

struct BrokenLinksView: View {
    let folder: URL
    @State private var links: [URL]?
    @State private var chosen: Set<URL> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Broken Links in “\(folder.lastPathComponent)”").font(.title3.weight(.semibold))
            if let links {
                if links.isEmpty {
                    ContentUnavailableView("No broken links", systemImage: "link", description: Text("Every symbolic link here points to something."))
                        .frame(height: 160)
                } else {
                    List(links, id: \.self, selection: $chosen) { link in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(String(link.path.dropFirst(folder.path.count + 1))).lineLimit(1).truncationMode(.middle)
                            Text("→ " + (Links.info(link).symlinkTarget ?? "?")).font(.caption).foregroundStyle(.red).lineLimit(1)
                        }
                    }
                    .frame(height: 240)
                }
            } else {
                ProgressView("Looking…").frame(maxWidth: .infinity, minHeight: 160)
            }
            HStack {
                Spacer()
                Button("Close", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(chosen.isEmpty ? String(localized: "Trash All") : String(localized: "Trash \(chosen.count)")) { trash() }.disabled(links?.isEmpty ?? true)
            }
        }
        .padding(20)
        .frame(width: 540)
        .task {
            let folder = folder
            links = await Task.detached { Links.broken(in: folder) }.value
        }
    }

    private func trash() {
        let targets = chosen.isEmpty ? (links ?? []) : Array(chosen)
        dismiss()
        Task {
            _ = try? await OperationCenter.shared.run(String(localized: "Trashing \(targets.count) broken links"), undoTitle: "Trash") { progress in
                try FileOps.trash(targets, progress: progress)
            }
            WindowState.lastActive?.reloadAll()
        }
    }
}
