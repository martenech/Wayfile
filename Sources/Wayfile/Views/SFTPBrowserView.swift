import AppKit
import SwiftUI

/// SFTP / SSH file browser: saved servers, folders, download to / upload from Wayfile.
struct SFTPBrowserView: View {
    @State private var serverID: SFTPServer.ID?
    @State private var connection: SFTPConnection?
    @State private var path = ""
    @State private var items: [SFTPItem] = []
    @State private var selection: Set<SFTPItem.ID> = []
    @State private var loading = false
    @State private var error: String?
    @State private var editing: SFTPServer?
    @State private var askPassword: SFTPServer?
    private var store: SFTPStore { .shared }

    private var current: SFTPServer? { store.servers.first { $0.id == serverID } }

    var body: some View {
        NavigationSplitView {
            List(selection: $serverID) {
                Section("Servers") {
                    ForEach(store.servers) { server in
                        HStack {
                            Label(server.name, systemImage: "server.rack")
                            Spacer()
                            if connection?.server.id == server.id { Circle().fill(.green).frame(width: 6, height: 6) }
                        }
                        .tag(server.id)
                        .help(server.address)
                        .contextMenu {
                            Button("Edit…") { editing = server }
                            Button("Forget Host Key") { SFTPKnownHosts.forget(host: server.host, port: server.port) }
                            Divider()
                            Button("Remove", role: .destructive) { store.remove(server) }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .toolbar {
                Button { editing = SFTPServer(name: "New Server", host: "", username: NSUserName()) } label: { Label("Add Server", systemImage: "plus") }
            }
            .overlay {
                if store.servers.isEmpty {
                    ContentUnavailableView {
                        Label("No servers", systemImage: "server.rack")
                    } description: {
                        Text("Add a server you reach over SSH to browse it with SFTP.")
                    } actions: {
                        Button("Add Server…") { editing = SFTPServer(name: "New Server", host: "", username: NSUserName()) }
                    }
                }
            }
        } detail: {
            detail
        }
        .frame(minWidth: 820, minHeight: 480)
        .navigationTitle(current.map { "\($0.name) — \(path)" } ?? String(localized: "SFTP"))
        .onChange(of: serverID) { _, _ in connect() }
        .sheet(item: $editing) { server in SFTPServerEditor(server: server) { saved in serverID = saved.id; connect() } }
        .sheet(item: $askPassword) { server in
            PasswordPrompt(title: server.auth == .key ? "Key passphrase for \(server.address)" : "Password for \(server.address)") { password, remember in
                if remember, server.auth == .password { try? store.save(server, password: password) }
                connect(password: password)
            }
        }
        .alert("SFTP", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .onDisappear { if let connection { Task { await connection.close() } } }
    }

    @ViewBuilder
    private var detail: some View {
        if connection != nil {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button { goUp() } label: { Image(systemName: "chevron.up") }.disabled(path == "/").accessibilityLabel("Enclosing folder")
                    Button { open(connection?.home ?? "/") } label: { Image(systemName: "house") }.accessibilityLabel("Home folder")
                    Text(path).lineLimit(1).truncationMode(.head).textSelection(.enabled)
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                    Button { Task { await list() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh")
                    Button("New Folder") { newFolder() }
                    Button("Upload…") { chooseUpload() }
                    Button("Download") { download(selected) }.disabled(selected.isEmpty)
                }
                .controlSize(.small)
                .padding(8)
                Divider()
                Table(items, selection: $selection) {
                    TableColumn("Name") { item in
                        Label(item.name, systemImage: item.isDirectory ? "folder.fill" : item.isSymlink ? "link" : "doc")
                            .foregroundStyle(item.isDirectory ? Color.accentColor : .primary)
                    }
                    TableColumn("Size") { item in Text(item.isDirectory ? "—" : Formatters.size(item.size)).foregroundStyle(.secondary) }
                        .width(min: 60, ideal: 90)
                    TableColumn("Modified") { item in Text(item.modified.map(Formatters.date) ?? "—").foregroundStyle(.secondary) }
                        .width(min: 100, ideal: 150)
                }
                .contextMenu(forSelectionType: SFTPItem.ID.self) { ids in
                    let chosen = items.filter { ids.contains($0.id) }
                    Button("Download") { download(chosen) }
                    if chosen.count == 1, !chosen[0].isDirectory { Button("Open Copy") { openCopy(chosen[0]) } }
                    if chosen.count == 1 { Button("Rename…") { rename(chosen[0]) } }
                    Button("Copy Path") { copy(chosen.map(\.path).joined(separator: "\n")) }
                    Divider()
                    Button("Delete…", role: .destructive) { delete(chosen) }
                } primaryAction: { ids in
                    guard let item = items.first(where: { ids.contains($0.id) }) else { return }
                    if item.isDirectory || item.isSymlink { open(item.path) } else { openCopy(item) }
                }
                .dropDestination(for: URL.self) { urls, _ in upload(urls); return true }
                .overlay { if !loading && items.isEmpty { ContentUnavailableView("Empty folder", systemImage: "folder", description: Text("Drop files here to upload.")) } }
                Divider()
                Text("Downloads go to “\(downloadFolder.lastPathComponent)” (the folder open in Wayfile). Uploads go to the folder shown here.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
        } else if loading {
            ProgressView("Connecting…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if current != nil {
            ContentUnavailableView {
                Label("Not connected", systemImage: "bolt.horizontal")
            } actions: {
                Button("Connect") { connect() }
            }
        } else {
            ContentUnavailableView("Choose a server", systemImage: "server.rack")
        }
    }

    private var selected: [SFTPItem] { items.filter { selection.contains($0.id) } }

    private var downloadFolder: URL {
        WindowState.lastActive?.activePane.location.folderURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    // MARK: Actions

    private func connect(password: String? = nil) {
        guard let server = current else { return }
        let old = connection
        connection = nil
        items = []
        Task { await old?.close() }
        let secret = password ?? (server.auth == .password ? store.password(for: server) : nil)
        if server.auth == .password && (secret ?? "").isEmpty {
            askPassword = server
            return
        }
        loading = true
        Task {
            do {
                let new = try await SFTPConnection.connect(server, password: secret)
                connection = new
                path = server.initialPath.isEmpty ? new.home : server.initialPath
                await list()
            } catch {
                loading = false
                let message = error.localizedDescription
                if server.auth == .key, message.contains("passphrase"), password == nil {
                    askPassword = server
                } else {
                    self.error = message
                }
            }
        }
    }

    private func list() async {
        guard let connection else { return }
        loading = true
        defer { loading = false }
        do {
            items = try await connection.list(path)
            selection = selection.intersection(items.map(\.id))
        } catch {
            self.error = SFTPConnection.friendly(error)
        }
    }

    private func open(_ newPath: String) {
        path = newPath
        selection = []
        Task { await list() }
    }

    private func goUp() {
        let parent = (path as NSString).deletingLastPathComponent
        open(parent.isEmpty ? "/" : parent)
    }

    private func download(_ chosen: [SFTPItem]) {
        guard let connection, !chosen.isEmpty else { return }
        let folder = downloadFolder
        Task {
            _ = try? await OperationCenter.shared.run(String(localized: "Downloading \(String(localized: "\(chosen.count) items")) from \(connection.server.name)"), undoTitle: "Download") { progress in
                var made: [URL] = []
                for item in chosen {
                    let url = try await connection.download(item, to: folder, progress: progress)
                    progress.record(.created([url]))
                    made.append(url)
                }
                return made
            }
            WindowState.lastActive?.reloadAll()
        }
    }

    private func openCopy(_ item: SFTPItem) {
        guard let connection else { return }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("wayfile-sftp-\(UUID().uuidString)", isDirectory: true)
        Task {
            do {
                try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
                let url = try await connection.download(item, to: temp, progress: OperationProgress())
                NSWorkspace.shared.open(url)
            } catch {
                self.error = SFTPConnection.friendly(error)
            }
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
        guard let connection, !urls.isEmpty else { return }
        let remote = path
        Task {
            do {
                _ = try await OperationCenter.shared.run(String(localized: "Uploading \(String(localized: "\(urls.count) items")) to \(connection.server.name)"), undoTitle: "Upload") { progress in
                    for url in urls { try await connection.upload(url, to: remote, progress: progress) }
                    return []
                }
            } catch is CancellationError {
            } catch {
                self.error = SFTPConnection.friendly(error)
            }
            await list()
        }
    }

    private func newFolder() {
        guard let name = ask("New Folder", placeholder: "Folder name"), let connection else { return }
        let target = SFTPConnection.join(path, name)
        Task {
            do { try await connection.makeFolder(target) } catch { self.error = SFTPConnection.friendly(error) }
            await list()
        }
    }

    private func rename(_ item: SFTPItem) {
        guard let name = ask("Rename “\(item.name)”", placeholder: item.name, initial: item.name), name != item.name, let connection else { return }
        Task {
            do { try await connection.rename(item, to: name) } catch { self.error = SFTPConnection.friendly(error) }
            await list()
        }
    }

    private func delete(_ chosen: [SFTPItem]) {
        guard let connection, !chosen.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = chosen.count == 1 ? String(localized: "Delete “\(chosen[0].name)” on the server?") : String(localized: "Delete \(String(localized: "\(chosen.count) items")) on the server?")
        alert.informativeText = String(localized: "Deleting on a server is permanent — there is no Trash.") + (chosen.contains(where: \.isDirectory) ? " Folders are deleted with everything in them." : "")
        alert.alertStyle = .critical
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do { for item in chosen { try await connection.delete(item) } } catch { self.error = SFTPConnection.friendly(error) }
            await list()
        }
    }

    private func ask(_ title: String, placeholder: String, initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        return value.isEmpty ? nil : value
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct PasswordPrompt: View {
    let title: String
    let onSubmit: (String, Bool) -> Void
    @State private var password = ""
    @State private var remember = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            SecureField("Password", text: $password).onSubmit(submit)
            Toggle("Remember in Keychain", isOn: $remember)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connect", action: submit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func submit() {
        dismiss()
        onSubmit(password, remember)
    }
}

private struct SFTPServerEditor: View {
    @State var server: SFTPServer
    let onSave: (SFTPServer) -> Void
    @State private var password = ""
    @State private var testResult: String?
    @State private var testing = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(SFTPStore.shared.servers.contains { $0.id == server.id } ? String(localized: "Edit Server") : String(localized: "Add SFTP Server")).font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $server.name)
                TextField("Host", text: $server.host, prompt: Text("server.example.com or 192.168.1.10"))
                TextField("Port", value: $server.port, format: .number.grouping(.never))
                TextField("User", text: $server.username)
                Picker("Sign in with", selection: $server.auth) {
                    Text("Password").tag(SFTPServer.Auth.password)
                    Text("SSH key").tag(SFTPServer.Auth.key)
                }
                if server.auth == .password {
                    SecureField("Password", text: $password, prompt: Text(SFTPStore.shared.password(for: server) == nil ? "" : String(localized: "Saved in Keychain — leave empty to keep")))
                } else {
                    HStack {
                        TextField("Key file", text: $server.keyPath)
                        Button("Choose…") { chooseKey() }
                    }
                    SecureField("Passphrase (if any)", text: $password)
                }
                TextField("Start in folder", text: $server.initialPath, prompt: Text("home folder"))
            }
            .formStyle(.columns)
            Text("The server’s identity is remembered on the first connection and checked every time after, like ssh.")
                .font(.caption).foregroundStyle(.secondary)
            if let testResult { Text(testResult).font(.callout).foregroundStyle(testResult.hasPrefix("✓") ? .green : .red) }
            HStack {
                Button("Test") { test() }.disabled(server.host.isEmpty || testing)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(server.host.isEmpty || server.username.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { server.keyPath = url.path }
    }

    private func test() {
        testing = true
        testResult = nil
        let candidate = server
        let secret = password.isEmpty ? (candidate.auth == .password ? SFTPStore.shared.password(for: candidate) : nil) : password
        Task {
            do {
                let connection = try await SFTPConnection.connect(candidate, password: secret)
                let count = (try? await connection.list(connection.home).count) ?? 0
                testResult = "✓ Connected — home folder \(connection.home) (\(count) items)"
                await connection.close()
            } catch {
                testResult = error.localizedDescription
            }
            testing = false
        }
    }

    private func save() {
        do {
            try SFTPStore.shared.save(server, password: server.auth == .password ? password : nil)
            onSave(server)
            dismiss()
        } catch {
            testResult = error.localizedDescription
        }
    }
}
