import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// S3 and compatible storage: accounts, buckets, folders; download to / upload from Wayfile.
struct S3BrowserView: View {
    @State private var account: S3Account.ID?
    @State private var bucket: String?
    @State private var prefix = ""
    @State private var buckets: [String] = []
    @State private var objects: [S3Object] = []
    @State private var selection: Set<S3Object.ID> = []
    @State private var loading = false
    @State private var error: String?
    @State private var editing: S3Account?
    private var store: S3Store { .shared }

    private var current: S3Account? { store.accounts.first { $0.id == account } }

    var body: some View {
        NavigationSplitView {
            List(selection: $account) {
                Section("Accounts") {
                    ForEach(store.accounts) { account in
                        Label(account.name, systemImage: "externaldrive.connected.to.line.below").tag(account.id)
                            .contextMenu {
                                Button("Edit…") { editing = account }
                                Button("Remove", role: .destructive) { store.remove(account) }
                            }
                    }
                }
                if current != nil {
                    Section("Buckets") {
                        ForEach(buckets, id: \.self) { name in
                            Button { open(bucket: name) } label: {
                                Label(name, systemImage: "shippingbox").fontWeight(bucket == name ? .semibold : .regular)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .toolbar {
                Button { editing = S3Account(name: "New Account", endpoint: S3Account.aws(region: "eu-central-1"), region: "eu-central-1", accessKey: "", pathStyle: false) } label: {
                    Label("Add Account", systemImage: "plus")
                }
            }
            .overlay {
                if store.accounts.isEmpty {
                    ContentUnavailableView {
                        Label("No accounts", systemImage: "externaldrive.connected.to.line.below")
                    } description: {
                        Text("Add AWS S3, Cloudflare R2, MinIO, Backblaze B2 or any S3-compatible storage.")
                    } actions: {
                        Button("Add Account…") { editing = S3Account(name: "New Account", endpoint: S3Account.aws(region: "eu-central-1"), region: "eu-central-1", accessKey: "", pathStyle: false) }
                    }
                }
            }
        } detail: {
            detail
        }
        .frame(minWidth: 820, minHeight: 480)
        .navigationTitle(bucket.map { "\($0)/\(prefix)" } ?? String(localized: "S3"))
        .onChange(of: account) { _, _ in loadBuckets() }
        .sheet(item: $editing) { account in S3AccountEditor(account: account) { saved in self.account = saved.id; loadBuckets() } }
        .alert("S3", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    @ViewBuilder
    private var detail: some View {
        if let bucket {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button { goUp() } label: { Image(systemName: "chevron.up") }.disabled(prefix.isEmpty).help("Enclosing folder")
                    .accessibilityLabel("Enclosing folder")
                    breadcrumbs(bucket)
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                    Button { Task { await list() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
                    .accessibilityLabel("Refresh")
                    Button("New Folder") { newFolder() }
                    Button("Upload…") { chooseUpload() }
                    Button("Download") { download(selected) }.disabled(selected.isEmpty)
                }
                .controlSize(.small)
                .padding(8)
                Divider()
                Table(objects, selection: $selection) {
                    TableColumn("Name") { object in
                        Label(object.name, systemImage: object.isPrefix ? "folder.fill" : "doc")
                            .foregroundStyle(object.isPrefix ? Color.accentColor : .primary)
                    }
                    TableColumn("Size") { object in Text(object.isPrefix ? "—" : Formatters.size(object.size)).foregroundStyle(.secondary) }
                        .width(min: 60, ideal: 90)
                    TableColumn("Modified") { object in Text(object.modified.map(Formatters.date) ?? "—").foregroundStyle(.secondary) }
                        .width(min: 100, ideal: 150)
                }
                .contextMenu(forSelectionType: S3Object.ID.self) { ids in
                    let chosen = objects.filter { ids.contains($0.id) }
                    Button("Download") { download(chosen) }
                    Button("Copy Key") { copy(chosen.map(\.key).joined(separator: "\n")) }
                    Button("Copy S3 URI") { copy(chosen.map { "s3://\(bucket)/\($0.key)" }.joined(separator: "\n")) }
                    Divider()
                    Button("Delete…", role: .destructive) { delete(chosen) }
                } primaryAction: { ids in
                    if let folder = objects.first(where: { ids.contains($0.id) && $0.isPrefix }) {
                        prefix = folder.key
                        Task { await list() }
                    } else {
                        download(objects.filter { ids.contains($0.id) })
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    upload(urls)
                    return true
                }
                .overlay { if !loading && objects.isEmpty { ContentUnavailableView("Empty", systemImage: "tray", description: Text("Drop files here to upload.")) } }
                Divider()
                Text(downloadHint).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
        } else if current != nil {
            ContentUnavailableView("Choose a bucket", systemImage: "shippingbox")
        } else {
            ContentUnavailableView("Choose an account", systemImage: "externaldrive.connected.to.line.below")
        }
    }

    private var selected: [S3Object] { objects.filter { selection.contains($0.id) } }

    private var downloadFolder: URL {
        WindowState.lastActive?.activePane.location.folderURL
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    private var downloadHint: String {
        "Downloads go to “\(downloadFolder.lastPathComponent)” (the folder open in Wayfile). Uploads go to the folder shown here."
    }

    private func breadcrumbs(_ bucket: String) -> some View {
        let parts = prefix.split(separator: "/").map(String.init)
        return HStack(spacing: 2) {
            Button(bucket) { prefix = ""; Task { await list() } }.buttonStyle(.borderless)
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                Button(part) {
                    prefix = parts.prefix(index + 1).joined(separator: "/") + "/"
                    Task { await list() }
                }
                .buttonStyle(.borderless)
            }
        }
        .lineLimit(1)
    }

    // MARK: Actions

    private func client() -> S3Client? {
        guard let current else { return nil }
        do { return try store.client(for: current) } catch { self.error = error.localizedDescription; return nil }
    }

    private func loadBuckets() {
        bucket = nil
        objects = []
        buckets = []
        guard let client = client() else { return }
        Task {
            do { buckets = try await client.buckets() } catch { self.error = error.localizedDescription }
        }
    }

    private func open(bucket name: String) {
        bucket = name
        prefix = ""
        Task { await list() }
    }

    private func goUp() {
        var parts = prefix.split(separator: "/")
        _ = parts.popLast()
        prefix = parts.isEmpty ? "" : parts.joined(separator: "/") + "/"
        Task { await list() }
    }

    private func list() async {
        guard let client = client(), let bucket else { return }
        loading = true
        defer { loading = false }
        do {
            objects = try await client.list(bucket: bucket, prefix: prefix)
            selection = selection.intersection(objects.map(\.id))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func download(_ chosen: [S3Object]) {
        guard let client = client(), let bucket, !chosen.isEmpty else { return }
        let folder = downloadFolder
        let base = prefix
        Task {
            _ = try? await OperationCenter.shared.run(String(localized: "Downloading \(String(localized: "\(chosen.count) items")) from \(bucket)"), undoTitle: "Download") { progress in
                var files: [(key: String, local: URL)] = []
                // Folders download recursively, keeping their structure.
                for object in chosen {
                    if object.isPrefix {
                        var stack = [object.key]
                        while let current = stack.popLast() {
                            for child in try await client.list(bucket: bucket, prefix: current) {
                                if child.isPrefix { stack.append(child.key) } else {
                                    files.append((child.key, folder.appendingPathComponent(String(child.key.dropFirst(base.count)))))
                                }
                            }
                        }
                    } else {
                        files.append((object.key, folder.appendingPathComponent(object.name)))
                    }
                }
                progress.setTotals(bytes: 0, items: files.count)
                var created: [URL] = []
                for file in files {
                    try progress.checkCancelled()
                    progress.begin(file.local.lastPathComponent)
                    try FileManager.default.createDirectory(at: file.local.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let target = FileManager.default.fileExists(atPath: file.local.path) ? FileOps.uniqueURL(file.local) : file.local
                    try await client.download(bucket: bucket, key: file.key, to: target)
                    progress.record(.created([target]))
                    created.append(target)
                    progress.finishItem(baseline: 0, size: 0)
                }
                return created
            }
            WindowState.lastActive?.reloadAll()
        }
    }

    private func chooseUpload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.directoryURL = downloadFolder
        if panel.runModal() == .OK { upload(panel.urls) }
    }

    private func upload(_ urls: [URL]) {
        guard let client = client(), let bucket, !urls.isEmpty else { return }
        let base = prefix
        Task {
            do {
                _ = try await OperationCenter.shared.run(String(localized: "Uploading \(String(localized: "\(urls.count) items")) to \(bucket)"), undoTitle: "Upload") { progress in
                    var files: [(URL, String)] = []
                    for url in urls {
                        if FileSystem.isDirectory(url) {
                            let parent = url.deletingLastPathComponent().path
                            let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                            while let child = enumerator?.nextObject() as? URL {
                                guard !FileSystem.isDirectory(child) else { continue }
                                files.append((child, base + String(child.path.dropFirst(parent.count + 1))))
                            }
                        } else {
                            files.append((url, base + url.lastPathComponent))
                        }
                    }
                    progress.setTotals(bytes: 0, items: files.count)
                    for (file, key) in files {
                        try progress.checkCancelled()
                        progress.begin(file.lastPathComponent)
                        try await client.upload(file, bucket: bucket, key: key)
                        progress.finishItem(baseline: 0, size: 0)
                    }
                    return []
                }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            await list()
        }
    }

    private func newFolder() {
        let alert = NSAlert()
        alert.messageText = String(localized: "New Folder")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Folder name"
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Create"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        guard !name.isEmpty, let client = client(), let bucket else { return }
        let key = prefix + name
        Task {
            do { try await client.createFolder(bucket: bucket, key: key) } catch { self.error = error.localizedDescription }
            await list()
        }
    }

    private func delete(_ chosen: [S3Object]) {
        guard let client = client(), let bucket, !chosen.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = chosen.count == 1 ? String(localized: "Delete “\(chosen[0].name)”?") : String(localized: "Delete \(String(localized: "\(chosen.count) items"))?")
        alert.informativeText = String(localized: "Objects are deleted from the bucket permanently (unless the bucket keeps versions).")
            + (chosen.contains(where: \.isPrefix) ? " Folders are deleted with everything in them." : "")
        alert.alertStyle = .critical
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                for object in chosen {
                    if object.isPrefix { try await client.deletePrefix(bucket: bucket, prefix: object.key) } else { try await client.delete(bucket: bucket, key: object.key) }
                }
            } catch {
                self.error = error.localizedDescription
            }
            await list()
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Add / edit an S3 account; presets fill in the endpoint for common providers.
private struct S3AccountEditor: View {
    @State var account: S3Account
    let onSave: (S3Account) -> Void
    @State private var secret = ""
    @State private var endpointText = ""
    @State private var testing = false
    @State private var result: String?
    @Environment(\.dismiss) private var dismiss

    init(account: S3Account, onSave: @escaping (S3Account) -> Void) {
        _account = State(initialValue: account)
        self.onSave = onSave
        _endpointText = State(initialValue: account.endpoint.absoluteString)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(S3Store.shared.accounts.contains { $0.id == account.id } ? String(localized: "Edit Account") : String(localized: "Add S3 Account")).font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $account.name)
                Picker("Provider", selection: Binding(get: { "" }, set: preset)) {
                    Text("Choose a preset…").tag("")
                    Text("Amazon S3").tag("aws")
                    Text("Cloudflare R2").tag("r2")
                    Text("Backblaze B2").tag("b2")
                    Text("Wasabi").tag("wasabi")
                    Text("MinIO (local)").tag("minio")
                }
                TextField("Endpoint", text: $endpointText, prompt: Text("https://s3.eu-central-1.amazonaws.com"))
                TextField("Region", text: $account.region)
                Toggle("Path-style addressing (MinIO, self-hosted)", isOn: $account.pathStyle)
                TextField("Access key", text: $account.accessKey)
                SecureField("Secret key", text: $secret, prompt: Text(account.secret == nil ? "" : String(localized: "Saved in Keychain — leave empty to keep")))
            }
            .formStyle(.columns)
            if let result { Text(result).font(.callout).foregroundStyle(result.hasPrefix("✓") ? .green : .red) }
            HStack {
                Button("Test") { test() }.disabled(testing || !valid)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var valid: Bool {
        URL(string: endpointText)?.host != nil && !account.accessKey.isEmpty && !account.region.isEmpty && (!secret.isEmpty || account.secret != nil)
    }

    private func preset(_ id: String) {
        switch id {
        case "aws": account.pathStyle = false; endpointText = S3Account.aws(region: account.region).absoluteString
        case "r2": account.region = "auto"; account.pathStyle = true; endpointText = "https://<account-id>.r2.cloudflarestorage.com"
        case "b2": account.region = "eu-central-003"; account.pathStyle = false; endpointText = "https://s3.eu-central-003.backblazeb2.com"
        case "wasabi": account.region = "eu-central-1"; account.pathStyle = false; endpointText = "https://s3.eu-central-1.wasabisys.com"
        case "minio": account.region = "us-east-1"; account.pathStyle = true; endpointText = "http://localhost:9000"
        default: break
        }
    }

    private func current() -> (S3Account, String)? {
        guard let url = URL(string: endpointText) else { return nil }
        var updated = account
        updated.endpoint = url
        guard let key = secret.isEmpty ? account.secret : secret else { return nil }
        return (updated, key)
    }

    private func test() {
        guard let (candidate, key) = current() else { return }
        testing = true
        result = nil
        Task {
            do {
                let buckets = try await S3Client(account: candidate, secret: key).buckets()
                result = String(localized: "✓ Connected — \(String(localized: "\(buckets.count) buckets"))")
            } catch {
                result = error.localizedDescription
            }
            testing = false
        }
    }

    private func save() {
        guard let (candidate, _) = current() else { return }
        do {
            try S3Store.shared.save(candidate, secret: secret.isEmpty ? nil : secret)
            onSave(candidate)
            dismiss()
        } catch {
            result = error.localizedDescription
        }
    }
}
