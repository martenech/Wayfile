import AppKit
import SwiftUI

// MARK: - Inspector sections

/// Extended attributes with the quarantine flag explained; user attributes can be removed.
struct ExtendedAttributesSection: View {
    let url: URL
    @State private var attributes: [ExtendedAttribute] = []
    @State private var error: String?

    var body: some View {
        Group {
            if !attributes.isEmpty {
                InspectorSection("Extended Attributes") {
                    if let quarantine = Quarantine.read(url) {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Downloaded — macOS checks it before opening", systemImage: "exclamationmark.shield").font(.callout)
                            Text([quarantine.agent.isEmpty ? nil : "From \(quarantine.agent)", quarantine.date.map { $0.formatted(date: .abbreviated, time: .shortened) },
                                  quarantine.isApproved ? "opening approved" : nil].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Remove Quarantine") { act { try Quarantine.remove(from: [url]) } }
                                .controlSize(.small)
                        }
                        .padding(.bottom, 4)
                    }
                    ForEach(attributes.filter { $0.name != Quarantine.attribute }) { attribute in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(attribute.name).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                Text(attribute.displayValue).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                            }
                            Spacer()
                            Button { act { try XAttr.remove(attribute.name, from: url) } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help(attribute.isSystem ? String(localized: "Remove (system attribute — Finder info, tags, metadata…)") : String(localized: "Remove"))
                        }
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: url) { load() }
    }

    private func load() { attributes = XAttr.list(url); error = nil }

    private func act(_ work: () throws -> Void) {
        do { try work(); load() } catch { self.error = error.localizedDescription }
    }
}

/// Access control list entries; add or remove rules.
struct ACLSection: View {
    let url: URL
    @State private var entries: [ACLEntry] = []
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        InspectorSection("Access Control", expandedByDefault: false) {
            if entries.isEmpty {
                Text("No access control entries — only the POSIX permissions apply.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: entry.allow ? "checkmark.circle" : "nosign").foregroundStyle(entry.allow ? .green : .red)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.principal + (entry.inherited ? " (inherited)" : "")).font(.callout)
                        Text(entry.permissions.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { remove(entry) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        .accessibilityLabel("Remove rule for \(entry.principal)")
                }
            }
            Button("Add Rule…") { adding = true }.controlSize(.small)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .task(id: url) { entries = await ACL.entries(of: url) }
        .sheet(isPresented: $adding) {
            ACLEditor(url: url) { Task { entries = await ACL.entries(of: url) } }
        }
    }

    private func remove(_ entry: ACLEntry) {
        Task {
            do { try await ACL.remove(index: entry.index, from: url) } catch { self.error = error.localizedDescription }
            entries = await ACL.entries(of: url)
        }
    }
}

private struct ACLEditor: View {
    let url: URL
    let onDone: () -> Void
    @State private var kind = "user"
    @State private var name = NSUserName()
    @State private var allow = true
    @State private var chosen: Set<String> = ["read"]
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private var relevant: [String] {
        FileSystem.isDirectory(url)
            ? ["list", "search", "add_file", "add_subdirectory", "delete_child", "delete", "readattr", "writeattr", "readsecurity", "writesecurity", "file_inherit", "directory_inherit"]
            : ["read", "write", "execute", "append", "delete", "readattr", "writeattr", "readextattr", "writeextattr", "readsecurity", "writesecurity"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Access Rule").font(.title3.weight(.semibold))
            HStack {
                Picker("", selection: $kind) { Text("User").tag("user"); Text("Group").tag("group") }.labelsHidden().fixedSize()
                TextField("Name", text: $name)
                Picker("", selection: $allow) { Text("Allow").tag(true); Text("Deny").tag(false) }.labelsHidden().fixedSize()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading) {
                ForEach(relevant, id: \.self) { permission in
                    Toggle(permission, isOn: Binding(get: { chosen.contains(permission) },
                                                     set: { if $0 { chosen.insert(permission) } else { chosen.remove(permission) } }))
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { add() }.keyboardShortcut(.defaultAction).disabled(name.isEmpty || chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func add() {
        Task {
            do {
                try await ACL.add(principal: "\(kind):\(name)", allow: allow, permissions: relevant.filter(chosen.contains), to: url)
                onDone()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Recursive permissions

struct PermissionsSheet: View {
    let state: WindowState
    let urls: [URL]
    @State private var filesText = "644"
    @State private var foldersText = "755"
    @State private var changeFiles = true
    @State private var changeFolders = true
    @State private var recursive = true
    @State private var preview: [PermissionChange]?
    @State private var owner = ""
    @State private var group = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private var plan: PermissionPlan? {
        let files = changeFiles ? PermissionPlan.parse(filesText) : nil
        let folders = changeFolders ? PermissionPlan.parse(foldersText) : nil
        if changeFiles && files == nil || changeFolders && folders == nil { return nil }
        return PermissionPlan(files: files, folders: folders, recursive: recursive)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            (urls.count == 1 ? Text("Permissions of “\(urls[0].lastPathComponent)”") : Text("Permissions of \(urls.count) Items")).font(.title3.weight(.semibold))
            Form {
                HStack {
                    Toggle("Files", isOn: $changeFiles).frame(width: 90, alignment: .leading)
                    TextField("", text: $filesText, prompt: Text("644 or u+x, go-w")).labelsHidden().disabled(!changeFiles)
                }
                HStack {
                    Toggle("Folders", isOn: $changeFolders).frame(width: 90, alignment: .leading)
                    TextField("", text: $foldersText, prompt: Text("755 or a+rx")).labelsHidden().disabled(!changeFolders)
                }
                Toggle("Include everything inside folders", isOn: $recursive)
            }
            .formStyle(.columns)
            .onChange(of: filesText) { preview = nil }
            .onChange(of: foldersText) { preview = nil }
            .onChange(of: changeFiles) { preview = nil }
            .onChange(of: changeFolders) { preview = nil }
            .onChange(of: recursive) { preview = nil }
            if plan == nil { Text("Use an octal mode (755) or symbolic changes (u+x, go-w, a+r).").font(.caption).foregroundStyle(.orange) }
            GroupBox {
                if let preview {
                    VStack(alignment: .leading, spacing: 4) {
                        (preview.isEmpty ? Text("Nothing would change.") : Text("\(preview.count) items would change:"))
                            .font(.callout.weight(.medium))
                        List(preview.prefix(300), id: \.url) { change in
                            HStack {
                                Text(change.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text("\(Permissions.symbolic(change.old)) → \(Permissions.symbolic(change.new))").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        .frame(height: 160)
                    }
                } else {
                    Button("Preview Changes") { computePreview() }.disabled(plan == nil)
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
            }
            DisclosureGroup("Owner & group (administrator)") {
                HStack {
                    TextField("Owner", text: $owner)
                    TextField("Group (optional)", text: $group)
                    Button("Change…") { changeOwner() }.disabled(owner.isEmpty)
                }
                Text("Asks for an administrator password. Owner changes aren’t recorded in the Timeline.").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }.keyboardShortcut(.defaultAction).disabled(plan == nil || preview?.isEmpty == true)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func computePreview() {
        guard let plan else { return }
        let urls = urls
        Task { preview = await Task.detached { plan.preview(urls) }.value }
    }

    private func apply() {
        guard let plan else { return }
        let urls = urls
        let known = preview
        dismiss()
        state.applyPermissions(known ?? plan.preview(urls), title: "Changing permissions of \(WindowState.describe(urls))")
    }

    private func changeOwner() {
        let urls = urls
        Task {
            do {
                try await Admin.chown(urls, owner: owner, group: group.isEmpty ? nil : group, recursive: recursive)
                state.reloadAll()
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Vaults

struct NewVaultSheet: View {
    let state: WindowState
    @State private var name = "Private"
    @State private var folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
    @State private var sizeGB = 10
    @State private var password = ""
    @State private var confirm = ""
    @State private var creating = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Encrypted Vault").font(.title3.weight(.semibold))
            Text("An AES-256 encrypted disk image. Unlocked, it works like a drive; locked, its contents are unreadable without the password.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $name)
                LabeledContent("Location") {
                    HStack {
                        Text(folder.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")).lineLimit(1).truncationMode(.head)
                        Button("Choose…") { if let chosen = chooseFolder(start: folder) { folder = chosen } }
                    }
                }
                Stepper("Maximum size: \(sizeGB) GB", value: $sizeGB, in: 1...2000)
                SecureField("Password", text: $password)
                SecureField("Confirm", text: $confirm)
            }
            .formStyle(.columns)
            Text("The image grows as you add files. There is no way to recover a forgotten password.").font(.caption).foregroundStyle(.orange)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                if creating { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }.keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || password.count < 4 || password != confirm || creating)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func create() {
        creating = true
        Task {
            do {
                let vault = try await Vaults.create(name: name, in: folder, sizeGB: sizeGB, password: password)
                VaultStore.shared.add(vault)
                let mount = try await Vaults.unlock(vault, password: password)
                VaultStore.shared.refresh()
                state.activePane.navigate(to: .folderAt(mount))
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            creating = false
        }
    }
}

@MainActor
enum VaultActions {
    static func unlock(_ vault: Vault, state: WindowState) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Unlock “\(vault.name)”")
        alert.informativeText = String(localized: "Enter the vault’s password.")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: String(localized: "Unlock"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let password = field.stringValue
        Task {
            do {
                let mount = try await Vaults.unlock(vault, password: password)
                VaultStore.shared.refresh()
                state.activePane.navigate(to: .folderAt(mount))
            } catch {
                state.errorMessage = "Couldn’t unlock “\(vault.name)”: \(error.localizedDescription)"
            }
        }
    }

    static func lock(_ vault: Vault, state: WindowState) {
        guard let mount = VaultStore.shared.mountPoint(of: vault) else { return }
        // Panes showing the vault move away first, so nothing holds it open.
        for pane in state.tabs.flatMap(\.panes) where pane.location.folderURL?.path.hasPrefix(mount.path) == true {
            pane.navigate(to: .home)
        }
        Task {
            do {
                try await Vaults.lock(mount)
                VaultStore.shared.refresh()
            } catch {
                state.errorMessage = "Couldn’t lock “\(vault.name)”: \(error.localizedDescription) Close files that are open from it and try again."
            }
        }
    }

    static func addExisting(state: WindowState) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "sparsebundle")!, .init(filenameExtension: "dmg")!, .init(filenameExtension: "sparseimage")!]
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        VaultStore.shared.add(Vault(name: url.deletingPathExtension().lastPathComponent, url: url))
    }
}
