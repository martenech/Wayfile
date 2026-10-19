import AppKit
import SwiftUI

/// Value used to open a Properties window (one window per selection).
struct PropertiesTarget: Codable, Hashable {
    let urls: [URL]
}

struct PropertiesView: View {
    let target: PropertiesTarget

    @State private var urls: [URL]
    @State private var page: Page = .general

    private enum Page: String, CaseIterable, Identifiable {
        case general = "General", hashes = "Hashes", permissions = "Permissions", details = "Details"

        var title: String {
            switch self {
            case .general: return String(localized: "General")
            case .hashes: return String(localized: "Hashes")
            case .permissions: return String(localized: "Permissions")
            case .details: return String(localized: "Details")
            }
        }
        var id: String { rawValue }
    }

    private var pages: [Page] {
        if single == nil { return [.general] }
        return isFile ? Page.allCases : [.general, .permissions]
    }

    init(target: PropertiesTarget) {
        self.target = target
        _urls = State(initialValue: target.urls)
    }

    private var single: URL? { urls.count == 1 ? urls[0] : nil }
    private var isFile: Bool { single.map { !FileSystem.isDirectory($0) } ?? false }

    var body: some View {
        // A segmented picker rather than TabView: in small windows TabView tucks its tabs into an overflow menu.
        VStack(spacing: 0) {
            if pages.count > 1 {
                Picker("Page", selection: $page) {
                    ForEach(pages) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.top, 12)
            }
            switch (page, single) {
            case (.hashes, let url?): HashesTab(url: url)
            case (.permissions, let url?): PermissionsTab(url: url)
            case (.details, let url?): DetailsTab(url: url)
            default: GeneralTab(urls: $urls)
            }
        }
        .frame(width: 480, height: 540)
        .navigationTitle(single.map { String(localized: "\($0.lastPathComponent) Properties") } ?? String(localized: "\(urls.count) Items Properties"))
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Binding var urls: [URL]

    @State private var name = ""
    @State private var summary = SizeSummary()
    @State private var item: FileItem?
    @State private var accessed: Date?
    @State private var isHidden = false
    @State private var error: String?

    private var single: URL? { urls.count == 1 ? urls[0] : nil }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: single.map { IconCache.icon(for: $0) } ?? NSImage(named: NSImage.multipleDocumentsName)!)
                        .resizable()
                        .frame(width: 56, height: 56)
                    if let single {
                        TextField("Name", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .font(.title3)
                            .onSubmit { rename(single) }
                    } else {
                        Text("\(urls.count) items").font(.title3.weight(.semibold))
                    }
                }
                .padding(.vertical, 4)
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            }

            Section {
                if let item { row("Type", item.kind) }
                row("Location", commonLocation) {
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                        .controlSize(.small)
                }
                row("Size", sizeText(summary.bytes))
                row("Size on disk", sizeText(summary.allocated))
                if folderCount > 0 || urls.count > 1 {
                    row("Contains", "\(summary.files.formatted()) files, \(max(summary.folders - folderCount, 0).formatted()) folders"
                        + (summary.isComplete ? "" : "…"))
                }
            }

            if let item {
                Section {
                    row("Created", Formatters.date(item.created))
                    row("Modified", Formatters.date(item.modified))
                    if let accessed { row("Accessed", Formatters.date(accessed)) }
                }
                Section {
                    Toggle("Hidden", isOn: $isHidden)
                        .onChange(of: isHidden) { _, hidden in setHidden(hidden, on: item.url) }
                    if !item.tags.isEmpty {
                        LabeledContent("Tags") { TagDots(tags: item.fileTags) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: urls) { await load() }
    }

    private var folderCount: Int { urls.filter(FileSystem.isDirectory).count }

    private var commonLocation: String {
        let parents = Set(urls.map { $0.deletingLastPathComponent().path })
        return parents.count == 1 ? parents.first! : "Multiple locations"
    }

    private func sizeText(_ bytes: Int64) -> String {
        let suffix = summary.isComplete ? "" : "…"
        let exact = bytes >= 1000 ? " (" + String(localized: "\(bytes.formatted()) bytes") + ")" : ""
        return "\(Formatters.size(bytes))\(exact)\(suffix)"
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(LocalizedStringKey(label)) {
            Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
        }
    }

    private func row<Accessory: View>(_ label: String, _ value: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        LabeledContent(LocalizedStringKey(label)) {
            HStack {
                Text(value).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                accessory()
            }
        }
    }

    private func load() async {
        if let single {
            name = single.lastPathComponent
            item = FileItem(url: single)
            accessed = try? single.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate
            isHidden = item?.isHidden ?? false
        } else {
            item = nil
        }
        summary = SizeSummary()
        for await update in SizeCalculator.summarize(urls) {
            summary = update
        }
    }

    private func rename(_ url: URL) {
        let newName = name
        guard newName != url.lastPathComponent else { return }
        Task {
            do {
                let renamed = try await OperationCenter.shared.run("Renaming “\(url.lastPathComponent)”", undoTitle: "Rename") { progress in
                    let renamed = try FileOps.rename(url, to: newName)
                    progress.record(.moved([MovedItem(from: url, to: renamed)]))
                    return [renamed]
                }
                error = nil
                if let renamed = renamed.first { urls = [renamed] }
            } catch {
                self.error = error.localizedDescription
                name = url.lastPathComponent
            }
        }
    }

    private func setHidden(_ hidden: Bool, on url: URL) {
        guard hidden != (FileItem(url: url)?.isHidden ?? false) else { return }
        var values = URLResourceValues()
        values.isHidden = hidden
        var mutable = url
        do { try mutable.setResourceValues(values) } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Hashes

private struct HashesTab: View {
    let url: URL

    @State private var hashes: FileHashes?
    @State private var progress: Double?
    @State private var task: Task<Void, Never>?
    @State private var compare = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                if let hashes {
                    ForEach(hashes.all, id: \.name) { hash in
                        LabeledContent(hash.name) {
                            HStack(alignment: .top) {
                                Text(hash.value)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .lineLimit(3)
                                    .foregroundStyle(hashes.match(compare) == hash.name ? Color.green : Color.primary)
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(hash.value, forType: .string)
                                } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless)
                                .help("Copy")
                                .accessibilityLabel("Copy")
                            }
                        }
                    }
                } else if let progress {
                    VStack(alignment: .leading) {
                        ProgressView(value: progress)
                        HStack {
                            Text("Calculating… \(Int(progress * 100)) %").foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") { task?.cancel(); task = nil; self.progress = nil }
                        }
                    }
                } else {
                    HStack {
                        Text("MD5, SHA-1, SHA-256 and SHA-512").foregroundStyle(.secondary)
                        Spacer()
                        Button("Calculate") { calculate() }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }

            Section("Compare") {
                TextField("Paste a hash to verify", text: $compare)
                    .font(.callout.monospaced())
                if !compare.isEmpty {
                    if let hashes {
                        if let match = hashes.match(compare) {
                            Label("Matches \(match)", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        } else {
                            Label("Doesn’t match any hash", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                        }
                    } else {
                        Text("Calculate the hashes to compare.").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { task?.cancel() }
        .onAppear {
            // Small files are instant; large ones wait for an explicit click.
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if hashes == nil, task == nil, size < 64 << 20 { calculate() }
        }
    }

    private func calculate() {
        error = nil
        progress = 0
        task = Task {
            do {
                let result = try await Hashing.hashes(of: url) { value in
                    Task { @MainActor in if self.hashes == nil { self.progress = value } }
                }
                hashes = result
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            progress = nil
        }
    }
}

// MARK: - Permissions

private struct PermissionsTab: View {
    let url: URL

    @State private var permissions: Permissions?
    @State private var error: String?

    var body: some View {
        Form {
            if let permissions {
                Section {
                    LabeledContent("Owner", value: permissions.owner)
                    LabeledContent("Group", value: permissions.group)
                    LabeledContent("Mode") {
                        Text("\(permissions.symbolic)  (\(permissions.octal))").font(.body.monospaced())
                    }
                }
                Section("Access") {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                        GridRow {
                            Text("")
                            ForEach(Permissions.bits, id: \.self) { Text($0).foregroundStyle(.secondary) }
                        }
                        ForEach(0..<3, id: \.self) { cls in
                            GridRow {
                                Text(Permissions.classes[cls])
                                ForEach(0..<3, id: \.self) { perm in
                                    Toggle("", isOn: binding(cls, perm))
                                        .labelsHidden()
                                        .toggleStyle(.checkbox)
                                }
                            }
                        }
                    }
                }
                Section {
                    Toggle("Locked (can’t be modified or deleted)", isOn: Binding(
                        get: { permissions.isLocked },
                        set: { update { $0.isLocked = $1 }($0) }
                    ))
                }
            } else {
                Text("Permissions unavailable").foregroundStyle(.secondary)
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .task(id: url) { permissions = Permissions.read(url) }
    }

    private func binding(_ cls: Int, _ perm: Int) -> Binding<Bool> {
        let bit = Permissions.bit(cls, perm)
        return Binding(
            get: { (permissions?.mode ?? 0) & bit != 0 },
            set: { update { p, on in p.mode = on ? p.mode | bit : p.mode & ~bit }($0) }
        )
    }

    /// Applies a change on disk, then re-reads so the UI always shows what actually happened.
    private func update(_ change: @escaping (inout Permissions, Bool) -> Void) -> (Bool) -> Void {
        { value in
            guard var updated = permissions else { return }
            change(&updated, value)
            do {
                try updated.apply(to: url)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            permissions = Permissions.read(url)
        }
    }
}

// MARK: - Details

private struct DetailsTab: View {
    let url: URL

    @State private var sections: [MetadataSection]?

    var body: some View {
        Form {
            if let sections {
                if sections.isEmpty {
                    Text("No additional details for this file.").foregroundStyle(.secondary)
                }
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.rows) { row in
                            LabeledContent(row.label) {
                                Text(row.value).textSelection(.enabled).multilineTextAlignment(.trailing)
                            }
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .formStyle(.grouped)
        .task(id: url) { sections = await Metadata.sections(for: url) }
    }
}
