import AppKit
import SwiftUI

/// Docker explorer: containers grouped by compose project, images, volumes.
struct DockerView: View {
    enum Tab: String, CaseIterable {
        case containers = "Containers", images = "Images", volumes = "Volumes"

        var title: String {
            switch self {
            case .containers: return String(localized: "Containers")
            case .images: return String(localized: "Images")
            case .volumes: return String(localized: "Volumes")
            }
        }
    }

    @State private var tab: Tab = .containers
    @State private var containers: [Docker.Container] = []
    @State private var images: [Docker.Image] = []
    @State private var volumes: [Docker.Volume] = []
    @State private var error: String?
    @State private var loaded = false
    @State private var busy: Set<String> = []
    @State private var logs: LogSheet?

    struct LogSheet: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if !busy.isEmpty { ProgressView().controlSize(.small) }
                Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                    .accessibilityLabel("Refresh")
            }
            .padding(8)
            Divider()
            if Docker.executable == nil {
                ContentUnavailableView("Docker isn’t installed", systemImage: "shippingbox",
                                       description: Text("Install Docker Desktop, OrbStack or Colima to manage containers here."))
            } else if let error, containers.isEmpty && images.isEmpty {
                ContentUnavailableView("Docker isn’t running", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                switch tab {
                case .containers: containerList
                case .images: imageList
                case .volumes: volumeList
                }
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .navigationTitle("Docker")
        .task {
            // Refresh while the window is open.
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .sheet(item: $logs) { sheet in
            VStack(alignment: .leading, spacing: 8) {
                Text(sheet.title).font(.headline)
                ScrollView {
                    Text(sheet.text.isEmpty ? String(localized: "No output") : sheet.text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
                HStack {
                    Spacer()
                    Button("Done") { logs = nil }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 760, height: 480)
        }
    }

    // MARK: Containers

    private var containerList: some View {
        let groups = Dictionary(grouping: containers) { $0.composeProject ?? "" }
        let keys = groups.keys.sorted { ($0.isEmpty ? "~" : $0) < ($1.isEmpty ? "~" : $1) }
        return List {
            ForEach(keys, id: \.self) { key in
                Section {
                    ForEach(groups[key] ?? []) { containerRow($0) }
                } header: {
                    projectHeader(key, containers: groups[key] ?? [])
                }
            }
        }
        .overlay { if loaded && containers.isEmpty { ContentUnavailableView("No containers", systemImage: "shippingbox") } }
    }

    private func projectHeader(_ project: String, containers: [Docker.Container]) -> some View {
        HStack {
            Text(project.isEmpty ? String(localized: "Standalone") : project)
            Spacer()
            if let folder = containers.first?.projectFolder {
                Button("Show Folder") { show(folder) }.buttonStyle(.borderless).font(.caption)
                if containers.contains(where: \.isRunning) {
                    Button("Stop All") { compose(["stop"], in: folder, project: project) }.buttonStyle(.borderless).font(.caption)
                } else {
                    Button("Start All") { compose(["start"], in: folder, project: project) }.buttonStyle(.borderless).font(.caption)
                }
            }
        }
    }

    private func containerRow(_ c: Docker.Container) -> some View {
        HStack(spacing: 8) {
            Circle().fill(c.isRunning ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.composeService ?? c.name).fontWeight(.medium)
                Text("\(c.image) · \(c.status)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            ForEach(c.localURLs.prefix(2), id: \.self) { url in
                Button { NSWorkspace.shared.open(url) } label: { Text(verbatim: ":\(url.port ?? 0)") }
                    .buttonStyle(.borderless)
                    .font(.caption.monospaced())
                    .help("Open \(url.absoluteString)")
            }
            if busy.contains(c.id) {
                ProgressView().controlSize(.small)
            } else if c.isRunning {
                Button { act(c, "stop") } label: { Image(systemName: "stop.fill") }.buttonStyle(.borderless).help("Stop")
                .accessibilityLabel("Stop")
            } else {
                Button { act(c, "start") } label: { Image(systemName: "play.fill") }.buttonStyle(.borderless).help("Start")
                .accessibilityLabel("Start")
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if c.isRunning {
                Button("Stop") { act(c, "stop") }
                Button("Restart") { act(c, "restart") }
                Button("Open Shell in Terminal") { openShell(c) }
            } else {
                Button("Start") { act(c, "start") }
            }
            Button("Show Logs") { Task { logs = LogSheet(title: "Logs — \(c.name)", text: await Docker.logs(c)) } }
            Divider()
            if let folder = c.projectFolder { Button("Show Project Folder") { show(folder) } }
            ForEach(c.bindSources, id: \.self) { source in
                Button("Show \(source.lastPathComponent) (mounted)") { show(source) }
            }
            ForEach(c.localURLs, id: \.self) { url in Button("Open \(url.absoluteString)") { NSWorkspace.shared.open(url) } }
            Button("Copy ID") { copy(c.id) }
            Divider()
            Button("Remove…", role: .destructive) {
                if confirm("Remove container “\(c.name)”?", detail: c.isRunning ? "It is running and will be stopped first." : "") {
                    act(c, "rm", extra: ["-f"])
                }
            }
        }
    }

    // MARK: Images & volumes

    private var imageList: some View {
        Table(images) {
            TableColumn("Repository") { Text($0.repository).lineLimit(1) }
            TableColumn("Tag") { Text($0.tag) }.width(min: 60, ideal: 90)
            TableColumn("Size") { Text($0.size) }.width(min: 60, ideal: 80)
            TableColumn("Created") { Text($0.created).foregroundStyle(.secondary) }.width(min: 80, ideal: 110)
            TableColumn("Used by") { image in Text(image.containers.map { "\($0)" } ?? "–").foregroundStyle(.secondary) }.width(60)
        }
        .contextMenu(forSelectionType: Docker.Image.ID.self) { ids in
            if let image = images.first(where: { ids.contains($0.id) }) {
                Button("Copy Reference") { copy(image.reference) }
                Button("Remove Image…", role: .destructive) {
                    if confirm("Remove image “\(image.reference)”?", detail: "Images used by containers can’t be removed.") {
                        perform(image.id) { try await Docker.run(["rmi", image.reference]) }
                    }
                }
            }
        }
    }

    private var volumeList: some View {
        Table(volumes) {
            TableColumn("Name") { Text($0.name).lineLimit(1) }
            TableColumn("Project") { Text($0.composeProject ?? "–").foregroundStyle(.secondary) }.width(min: 80, ideal: 120)
            TableColumn("Driver") { Text($0.driver) }.width(60)
        }
        .contextMenu(forSelectionType: Docker.Volume.ID.self) { ids in
            if let volume = volumes.first(where: { ids.contains($0.id) }) {
                Button("Copy Name") { copy(volume.name) }
                Button("Copy Mountpoint") { copy(volume.mountpoint) }
                Button("Remove Volume…", role: .destructive) {
                    if confirm("Remove volume “\(volume.name)”?", detail: "Its data is deleted permanently.") {
                        perform(volume.name) { try await Docker.run(["volume", "rm", volume.name]) }
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func refresh() async {
        do {
            async let c = Docker.containers()
            async let i = Docker.images()
            async let v = Docker.volumes()
            (containers, images, volumes) = try await (c, i, v)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func act(_ c: Docker.Container, _ command: String, extra: [String] = []) {
        perform(c.id) { try await Docker.run([command] + extra + [c.id]) }
    }

    private func compose(_ args: [String], in folder: URL, project: String) {
        perform(project) { try await Docker.run(["compose", "--project-directory", folder.path, "-p", project] + args) }
    }

    private func perform(_ key: String, _ work: @escaping () async throws -> Void) {
        busy.insert(key)
        Task {
            do { try await work() } catch { presentError(error.localizedDescription) }
            busy.remove(key)
            await refresh()
        }
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Docker")
        alert.informativeText = message
        alert.runModal()
    }

    private func confirm(_ title: String, detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Remove"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func openShell(_ c: Docker.Container) {
        guard let docker = Docker.executable else { return }
        let command = "\(docker) exec -it \(c.id) sh -c 'command -v bash >/dev/null && exec bash || exec sh'"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        NSAppleScript(source: "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell")?.executeAndReturnError(nil)
    }

    private func show(_ folder: URL) {
        if let state = WindowState.lastActive {
            state.activePane.navigate(to: .folderAt(folder))
            NSApp.windows.first { $0.identifier?.rawValue.contains("Wayfile") == true }?.makeKeyAndOrderFront(nil)
        } else {
            NSWorkspace.shared.open(folder)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
