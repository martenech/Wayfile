import SwiftUI

/// Duplicate finder window for one folder.
struct DuplicatesView: View {
    @State private var folder: URL
    @State private var minSize: Int64 = 1
    @State private var groups: [DuplicateFinder.Group] = []
    @State private var marked: Set<URL> = []
    @State private var scanning = false
    @State private var scanned = false
    @State private var error: String?
    @State private var scanTask: Task<Void, Never>?

    init(folder: URL) { _folder = State(initialValue: folder) }

    private static let sizes: [(String, Int64)] = [("Any size", 1), ("≥ 100 KB", 100 << 10), ("≥ 1 MB", 1 << 20), ("≥ 10 MB", 10 << 20), ("≥ 100 MB", 100 << 20)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: IconCache.icon(for: folder)).resizable().frame(width: 18, height: 18)
                Text(folder.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .lineLimit(1).truncationMode(.head)
                Button("Change…") { choose() }
                Spacer()
                Picker("Size", selection: $minSize) {
                    ForEach(Self.sizes, id: \.1) { Text($0.0).tag($0.1) }
                }
                .fixedSize()
                if scanning {
                    ProgressView().controlSize(.small)
                    Button("Stop") { scanTask?.cancel(); scanning = false }
                } else {
                    Button(scanned ? String(localized: "Scan Again") : String(localized: "Scan")) { scan() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.small)
            .padding(10)
            Divider()

            if groups.isEmpty {
                ContentUnavailableView(
                    scanning ? String(localized: "Scanning…") : scanned ? String(localized: "No duplicates") : String(localized: "Find files with identical contents"),
                    systemImage: scanned && !scanning ? "checkmark.seal" : "doc.on.doc",
                    description: Text(scanned ? "" : String(localized: "Files are compared by size, then by checksum — names don't matter."))
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.files) { file in
                                HStack(spacing: 8) {
                                    Toggle("", isOn: Binding(
                                        get: { marked.contains(file.url) },
                                        set: { if $0 { marked.insert(file.url) } else { marked.remove(file.url) } }
                                    ))
                                    .labelsHidden()
                                    .toggleStyle(.checkbox)
                                    Image(nsImage: IconCache.icon(for: file.url)).resizable().frame(width: 16, height: 16)
                                    Text(file.url.lastPathComponent).lineLimit(1)
                                    Text(relative(file.url)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                    Spacer()
                                    Text(Formatters.date(file.modified)).foregroundStyle(.secondary).font(.caption)
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Image(systemName: "magnifyingglass") }
                                        .buttonStyle(.borderless)
                                        .help("Show in Finder")
                                        .accessibilityLabel("Show in Finder")
                                }
                                .opacity(marked.contains(file.url) ? 0.55 : 1)
                            }
                        } header: {
                            Text("\(String(localized: "\(group.files.count) copies")) · \(Formatters.size(group.size)) each · \(Formatters.size(group.wasted)) wasted")
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack(spacing: 8) {
                let wasted = groups.reduce(0) { $0 + $1.wasted }
                Text(groups.isEmpty ? "" : String(localized: "\(groups.count) groups · \(Formatters.size(wasted)) can be freed"))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu("Auto-Select") {
                    ForEach(DuplicateFinder.Keep.allCases) { keep in
                        Button(keep.title) { marked = DuplicateFinder.autoMark(groups, keep: keep) }
                    }
                    Divider()
                    Button("Clear Marks") { marked = [] }
                }
                .fixedSize()
                .disabled(groups.isEmpty)
                Button("Move \(marked.count) to Trash") { trashMarked() }
                    .disabled(marked.isEmpty)
            }
            .controlSize(.small)
            .padding(10)
        }
        .frame(minWidth: 700, minHeight: 440)
        .onAppear { if !scanned && !scanning { scan() } }
        .navigationTitle("Duplicates in \(folder.lastPathComponent)")
        .alert("Couldn’t finish", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func relative(_ url: URL) -> String {
        let parent = url.deletingLastPathComponent().path
        return parent.hasPrefix(folder.path) ? "." + parent.dropFirst(folder.path.count) : parent
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { folder = url; groups = []; marked = []; scanned = false }
    }

    private func scan() {
        scanning = true
        marked = []
        let (root, min) = (folder, minSize)
        scanTask = Task {
            let progress = OperationProgress()
            let result = await Task.detached { Result { try DuplicateFinder.find(in: root, minSize: min, progress: progress) } }.value
            if case .success(let found) = result { groups = found }
            if case .failure(let failure) = result, !(failure is CancellationError) { error = failure.localizedDescription }
            scanning = false
            scanned = true
        }
    }

    private func trashMarked() {
        let urls = Array(marked)
        Task {
            do {
                try await OperationCenter.shared.run("Moving \(urls.count) duplicates to Trash", undoTitle: "Move to Trash") {
                    try FileOps.trash(urls, progress: $0)
                }
            } catch {
                self.error = error.localizedDescription
            }
            scan()
        }
    }
}
