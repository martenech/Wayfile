import AppKit
import SwiftUI

/// Script manager: scripts with an editor, Apple Shortcuts, example library and the run console.
struct AutomationView: View {
    enum Item: Hashable {
        case script(URL), shortcut(String), library, console, rule(UUID), pending
    }

    @State private var selection: Item? = .console
    @State private var error: String?
    @State private var importing: ImportReview?
    private var center: AutomationCenter { .shared }

    init(initial: Item? = nil) {
        var start = initial ?? .console
        #if DEBUG
        // Dev aid: open with a script selected.
        if initial == nil, let path = ProcessInfo.processInfo.environment["WAYFILE_AUTOMATION_SELECT"] {
            let wanted = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            let folder = AutomationCenter.shared.folder
            let match = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .first { $0.resolvingSymlinksInPath().path == wanted }
            start = .script(match ?? URL(fileURLWithPath: path))
        }
        #endif
        _selection = State(initialValue: start)
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["WAYFILE_IMPORT_SCRIPT"] {
            _importing = State(initialValue: try? ImportReview(url: URL(fileURLWithPath: path)))
        }
        #endif
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("Console", systemImage: "text.alignleft").tag(Item.console)
                        .badge(center.runs.filter { $0.status == .running }.count)
                    Label("Library", systemImage: "books.vertical").tag(Item.library)
                }
                Section("Scripts") {
                    ForEach(center.scripts) { script in
                        ScriptRow(script: script).tag(Item.script(script.url))
                            // Drop files on a script to run it on them.
                            .dropDestination(for: URL.self) { urls, _ in
                                guard !urls.isEmpty else { return false }
                                let context = WindowState.lastActive.map { state -> ScriptContext in
                                    var context = state.scriptContext(for: urls)
                                    context.folder = urls[0].deletingLastPathComponent()
                                    return context
                                } ?? ScriptContext(selection: urls, folder: urls[0].deletingLastPathComponent())
                                center.request(script, context: context)
                                selection = .console
                                return true
                            }
                            .contextMenu {
                                Button(center.isEnabled(script) ? String(localized: "Disable") : String(localized: "Enable")) { center.setEnabled(script, !center.isEnabled(script)) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([script.url]) }
                            }
                    }
                    if center.scripts.isEmpty {
                        Text("No scripts yet — create one or install examples from the Library.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Rules") {
                    Label("Pending", systemImage: "hand.raised").tag(Item.pending)
                        .badge(RulesStore.shared.pending.count)
                    ForEach(RulesStore.shared.rules) { rule in
                        Label(rule.name, systemImage: rule.enabled ? "wand.and.stars" : "pause.circle")
                            .foregroundStyle(rule.enabled ? .primary : .secondary)
                            .tag(Item.rule(rule.id))
                            .help(rule.summary)
                    }
                    Button { newRule() } label: { Label("New Rule", systemImage: "plus") }
                        .buttonStyle(.borderless)
                }
                Section("Shortcuts") {
                    ForEach(center.shortcuts, id: \.self) { name in
                        Label(name, systemImage: "square.2.layers.3d").tag(Item.shortcut(name))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                ToolbarItemGroup {
                    Menu {
                        ForEach(Script.Language.allCases, id: \.self) { language in
                            Button(language.title, systemImage: language.symbol) { create(language) }
                        }
                        Divider()
                        Button("Plugin in the Inspector", systemImage: "puzzlepiece.extension") { createPlugin(.inspector) }
                        Button("Plugin Window", systemImage: "macwindow") { createPlugin(.window) }
                    } label: {
                        Label("New Script", systemImage: "plus")
                    }
                    Button { chooseImport() } label: { Label("Import Script…", systemImage: "square.and.arrow.down") }
                        .help("Import a .wayfilescript package or a script file — it is shown for review first")
                    Button { NSWorkspace.shared.open(center.folder) } label: { Label("Open Scripts Folder", systemImage: "folder") }
                        .help("Open the Scripts folder in Finder")
                }
            }
        } detail: {
            switch selection {
            case .script(let url):
                if let script = center.scripts.first(where: { $0.url == url }) {
                    ScriptDetail(script: script).id(url)
                } else {
                    ContentUnavailableView("Script not found", systemImage: "questionmark.folder")
                }
            case .shortcut(let name):
                ShortcutDetail(name: name)
            case .library:
                LibraryView()
            case .rule(let id):
                if let rule = RulesStore.shared.rules.first(where: { $0.id == id }) {
                    RuleEditor(rule: rule).id(id)
                } else {
                    ContentUnavailableView("Rule deleted", systemImage: "wand.and.stars")
                }
            case .pending:
                PendingRulesView()
            case .console, nil:
                ConsoleView(runs: center.runs)
            }
        }
        .frame(minWidth: 860, minHeight: 520)
        .navigationTitle("Automation")
        .task { if center.shortcuts.isEmpty { await center.loadShortcuts() } }
        .alert("Automation", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .sheet(item: $importing) { review in
            ScriptImportView(review: review) { url in selection = .script(url) }
                .frame(width: 640, height: 560)
        }
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.message = String(localized: "Choose a .wayfilescript package or a script (.js, .sh, .zsh, .bash, .py, .applescript)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            importing = try ImportReview(url: url)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func newRule() {
        let folder = WindowState.lastActive?.activePane.location.folderURL
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        var rule = Rule(folder: folder)
        rule.name = "New Rule"
        RulesStore.shared.add(rule)
        selection = .rule(rule.id)
    }

    private func createPlugin(_ panel: ScriptPanel) {
        do {
            let url = try ScriptLibrary.createPlugin(named: panel == .inspector ? "New Inspector Plugin" : "New Plugin Window", panel: panel, in: center.folder)
            center.reload()
            selection = .script(url)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func create(_ language: Script.Language) {
        do {
            let url = try ScriptLibrary.create(named: "New \(language.title) Script", language: language, in: center.folder)
            center.reload()
            selection = .script(url)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ScriptRow: View {
    let script: Script

    var body: some View {
        let enabled = AutomationCenter.shared.isEnabled(script)
        HStack(spacing: 6) {
            Label(script.name, systemImage: script.panel != nil ? "puzzlepiece.extension" : script.language.symbol).lineLimit(1)
                .foregroundStyle(enabled ? .primary : .secondary)
            Spacer(minLength: 0)
            if !enabled { Image(systemName: "pause.circle").help("Disabled — not in menus, never runs automatically") }
            if let shortcut = script.shortcut { Text(shortcut.display).font(.caption2).foregroundStyle(.secondary) }
            if !script.after.isEmpty { Image(systemName: "arrow.turn.down.right").help("Runs after: \(script.after.map(\.title).sorted().joined(separator: ", "))") }
            if script.triggerFolder != nil { Image(systemName: "bolt").help("Runs on new files in \(script.triggerFolder!.path)") }
            if let minutes = script.scheduleMinutes { Image(systemName: "clock").help("Runs every \(minutes) minutes") }
            if !AutomationCenter.shared.isApproved(script) {
                Image(systemName: "lock").help("Not allowed yet — asks before the first run")
            }
        }
        .foregroundStyle(.primary)
        .imageScale(.small)
    }
}

/// What a run from the Automation window acts on: the last used main window's selection.
private struct RunTarget: View {
    let script: Script?

    var body: some View {
        let state = WindowState.lastActive
        let selection = state.map { Array($0.activePane.selection) } ?? []
        let folder = state?.activePane.location.folderURL
        HStack(spacing: 4) {
            Image(systemName: "scope")
            if selection.isEmpty {
                Text(folder.map { "No selection in “\($0.lastPathComponent)”" } ?? String(localized: "No Wayfile window"))
            } else {
                Text("\(selection.count) selected in “\(folder?.lastPathComponent ?? "")”")
            }
            if let script, !script.applies(to: selection) {
                Text("· doesn’t match this script’s filters").foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

@MainActor
private func currentContext(dryRun: Bool = false) -> ScriptContext {
    guard let state = WindowState.lastActive else { return ScriptContext(selection: [], dryRun: dryRun) }
    return state.scriptContext(for: Array(state.activePane.selection).sorted { $0.path < $1.path }, dryRun: dryRun)
}

// MARK: - Script detail

private struct ScriptDetail: View {
    let script: Script

    @State private var text = ""
    @State private var saved = ""
    @State private var error: String?
    @State private var problem: ScriptLinter.Problem?
    @State private var showReference = false
    @State private var showVersions = false
    private var center: AutomationCenter { .shared }
    private var dirty: Bool { text != saved }

    private var runs: [ScriptRun] { center.runs.filter { $0.title.hasSuffix(script.name) } }

    /// The line the latest run failed on, while the source is still what ran.
    private var runtimeError: (message: String, line: Int?)? {
        guard !dirty, let last = runs.first, last.status != .running, !last.succeeded,
              let line = last.lines.first(where: { $0.stream == .stderr }) else { return nil }
        return (line.text, ScriptLinter.line(fromConsole: line.text))
    }

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 10) {
                header
                CodeEditor(text: $text, language: script.language, errorLine: problem?.line ?? runtimeError?.line)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                if let problem {
                    errorBar(problem.line.map { "Line \($0): \(problem.message)" } ?? problem.message, symbol: "exclamationmark.triangle.fill", note: "Syntax error — fix it before running")
                } else if let failure = runtimeError {
                    errorBar(failure.message, symbol: "xmark.octagon.fill", note: "Last run failed")
                }
                HStack {
                    RunTarget(script: script)
                    Spacer()
                    Button("Revert") { text = saved }.disabled(!dirty)
                    Button("Save") { save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!dirty)
                    if script.panel == .window {
                        Button("Open Plugin") {
                            if dirty { save() }
                            NotificationCenter.default.post(name: .openPlugin, object: script.url.path)
                        }
                        .buttonStyle(.borderedProminent)
                    } else if script.panel == .inspector {
                        Text("Shows in the Inspector for matching selections").font(.caption).foregroundStyle(.secondary)
                    }
                    if script.panel == nil {
                    Button("Dry Run") { run(dryRun: true) }
                        .help(script.language == .javascript
                              ? String(localized: "Shows what the script would change without changing anything")
                              : String(localized: "Runs with WAYFILE_DRY_RUN=1 — the script itself must honour it"))
                    Button("Run") { run(dryRun: false) }
                        .keyboardShortcut("r", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                    }
                }
                .controlSize(.small)
            }
            .padding(14)
            .frame(minHeight: 300)

            ConsoleView(runs: runs, compact: true)
                .frame(minHeight: 120, idealHeight: 180)
        }
        .onAppear(perform: load)
        .sheet(isPresented: $showVersions) {
            ScriptVersionsView(script: script) { restored in
                text = restored
                saved = restored
                center.reload()
            }
            .frame(width: 720, height: 480)
        }
        .task(id: text) {
            // Checked as you type, after a short pause.
            try? await Task.sleep(for: .milliseconds(script.language == .javascript ? 350 : 800))
            guard !Task.isCancelled else { return }
            problem = await ScriptLinter.check(text, language: script.language)
        }
        .alert("Script", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(script.name).font(.title3.weight(.semibold))
                Text(script.language.title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("Enabled", isOn: Binding(get: { center.isEnabled(script) }, set: { center.setEnabled(script, $0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Disabled scripts aren't offered in menus and never run automatically")
                if script.language == .javascript {
                    Button { showReference.toggle() } label: { Label("API Reference", systemImage: "book") }
                        .controlSize(.small)
                        .help("The wayfile API — type “wayfile.” in the editor for completion")
                        .popover(isPresented: $showReference, arrowEdge: .bottom) { ScriptAPIReference().frame(width: 520, height: 480) }
                }
                Menu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([script.url]) }
                    Button("Open in Default Editor") { NSWorkspace.shared.open(script.url) }
                    Button("Version History…") { showVersions = true }
                    Button("Export…") { export() }
                    if center.isApproved(script) {
                        Button("Revoke Permission") { center.revoke(script) }
                    }
                    Divider()
                    Button("Move to Trash", role: .destructive) { trash() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if !script.summary.isEmpty { Text(script.summary).foregroundStyle(.secondary) }
            FlowChips(chips: chips)
            if !center.allowsAutomaticRuns(script), script.triggerFolder != nil || script.scheduleMinutes != nil || !script.after.isEmpty {
                HStack {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                    Text("This imported script declares automatic runs. They stay off until you allow them.").font(.caption)
                    Spacer()
                    Button("Allow Automatic Runs") { center.setAllowsAutomaticRuns(script, true) }.controlSize(.small)
                }
                .padding(6)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var chips: [(String, String)] {
        var list: [(String, String)] = []
        let count = script.count
        if count.max == 0 {
            list.append(("folder", String(localized: "Runs on the current folder")))
        } else {
            list.append(("doc.on.doc", script.extensions.isEmpty ? (script.foldersOnly ? String(localized: "Folders only") : String(localized: "Any file")) : script.extensions.sorted().joined(separator: ", ")))
        }
        if count.max != 0 { list.append(("number", count == .any ? String(localized: "Any count") : count.max == nil ? String(localized: "\(count.min)+ items") : count.min == count.max ? String(localized: "\(count.min) items") : String(localized: "\(count.min)–\(count.max!) items"))) }
        for permission in script.permissions.sorted() { list.append(("checkmark.shield", permission.rawValue)) }
        if let folder = script.triggerFolder { list.append(("bolt", String(localized: "New files in \(folder.lastPathComponent)"))) }
        if let minutes = script.scheduleMinutes { list.append(("clock", String(localized: "Every \(minutes) min"))) }
        if !script.showInMenu { list.append(("eye.slash", String(localized: "Not in menus"))) }
        if script.pinned { list.append(("pin", String(localized: "Pinned to the context menu"))) }
        if let shortcut = script.shortcut { list.append(("keyboard", shortcut.display)) }
        if !script.after.isEmpty { list.append(("arrow.turn.down.right", String(localized: "After \(script.after.map(\.rawValue).sorted().joined(separator: ", "))"))) }
        if let panel = script.panel { list.append(("puzzlepiece.extension", panel == .window ? String(localized: "Plugin window") : String(localized: "Inspector plugin"))) }
        if let version = script.version { list.append(("number.circle", "v\(version)")) }
        if let modified = (try? script.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            list.append(("pencil", String(localized: "Edited \(modified.formatted(.relative(presentation: .named)))")))
        }
        list.append((center.isApproved(script) ? "lock.open" : "lock", center.isApproved(script) ? String(localized: "Allowed") : String(localized: "Asks before running")))
        if !center.allowsAutomaticRuns(script) { list.append(("hand.raised", String(localized: "Imported — runs only when you start it"))) }
        return list
    }

    private func errorBar(_ message: String, symbol: String, note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.red)
            Text(message).font(.system(.caption, design: .monospaced)).lineLimit(2).textSelection(.enabled)
            Spacer()
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }

    private func load() {
        let content = (try? String(contentsOf: script.url, encoding: .utf8)) ?? ""
        text = content
        saved = content
    }

    private func save() {
        do {
            try ScriptVersions.save(text, to: script.url)
            saved = text
            center.reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func run(dryRun: Bool) {
        // Syntax errors stop the run before anything happens.
        if let problem {
            NSSound.beep()
            error = "Fix the syntax error first:\n" + (problem.line.map { "Line \($0): " } ?? "") + problem.message
            return
        }
        if dirty { save() }
        guard let fresh = Script.load(script.url) else { return }
        center.request(fresh, context: currentContext(dryRun: dryRun))
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = script.name + "." + ScriptPackage.fileExtension
        panel.message = String(localized: "A package with the script and its manifest — share it, import it with Automation → Import Script…")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ScriptPackage.export(script).write(to: url, options: .atomic)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func trash() {
        do {
            try FileManager.default.trashItem(at: script.url, resultingItemURL: nil)
            center.reload()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct FlowChips: View {
    let chips: [(String, String)]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) { row }
    }

    private var row: some View {
        HStack(spacing: 6) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                Label(chip.1, systemImage: chip.0)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
        }
    }
}

// MARK: - Shortcut, library, console

private struct ShortcutDetail: View {
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(name, systemImage: "square.2.layers.3d").font(.title3.weight(.semibold))
            Text("Runs the Apple Shortcut with the selected files as its input.").foregroundStyle(.secondary)
            RunTarget(script: nil)
            HStack {
                Button("Open in Shortcuts") {
                    let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
                    if let url = URL(string: "shortcuts://open-shortcut?name=\(encoded)") { NSWorkspace.shared.open(url) }
                }
                Button("Run") { AutomationCenter.shared.runShortcut(name, input: currentContext().selection) }
                    .buttonStyle(.borderedProminent)
            }
            Divider()
            ConsoleView(runs: AutomationCenter.shared.runs.filter { $0.title == "Shortcut: \(name)" }, compact: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct LibraryView: View {
    @State private var refresh = 0
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Text("Example scripts to start from. Installed scripts are plain files in the Scripts folder — edit them freely.")
                    .foregroundStyle(.secondary)
            }
            ForEach(ScriptExamples.all) { example in
                if let script = example.script {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: script.language.symbol).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(script.name).fontWeight(.medium)
                            Text(script.summary).font(.caption).foregroundStyle(.secondary)
                            Text(example.fileName).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        let installed = ScriptExamples.isInstalled(example, in: AutomationCenter.shared.folder)
                        Button(installed ? String(localized: "Reinstall") : String(localized: "Install")) { install(example) }
                            .controlSize(.small)
                    }
                    .padding(.vertical, 3)
                    .id("\(example.id)-\(refresh)")
                }
            }
            Section {
                Button("Install All") { ScriptExamples.all.forEach(install) }
            }
        }
        .alert("Library", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func install(_ example: ScriptExamples.Example) {
        do {
            try ScriptExamples.install(example, in: AutomationCenter.shared.folder)
            AutomationCenter.shared.reload()
            refresh += 1
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ConsoleView: View {
    let runs: [ScriptRun]
    var compact = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(compact ? String(localized: "Output") : String(localized: "Console")).font(.headline)
                Spacer()
                if !compact {
                    Button("Clear") { AutomationCenter.shared.clearRuns() }
                        .controlSize(.small)
                        .disabled(runs.allSatisfy { $0.status == .running })
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if runs.isEmpty {
                ContentUnavailableView("No runs yet", systemImage: "text.alignleft",
                                       description: Text("Run a script from the context menu, the command palette or here."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(runs) { run in RunView(run: run, expanded: compact || run.id == runs.first?.id) }
                    }
                    .padding(12)
                }
            }
        }
    }
}

private struct RunView: View {
    let run: ScriptRun
    @State var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button { expanded.toggle() } label: {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .buttonStyle(.borderless)
                statusIcon
                Text(run.title).fontWeight(.medium)
                Text("· \(run.trigger) · \(run.started.formatted(date: .omitted, time: .standard))")
                    .foregroundStyle(.secondary)
                Spacer()
                if run.status == .running {
                    Button("Stop") { run.task?.cancel() }.controlSize(.small)
                } else {
                    Button { copyOutput() } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy output")
                        .accessibilityLabel("Copy output")
                }
            }
            .font(.callout)
            if expanded, run.dryRun, !run.plan.isEmpty {
                DryRunPlanView(steps: run.plan, finished: run.status != .running, runForReal: run.runForReal)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(run.lines.enumerated()), id: \.offset) { _, line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .foregroundStyle(color(line.stream))
                            .textSelection(.enabled)
                    }
                    if case .failed(let message) = run.status {
                        Text(message).foregroundStyle(.red)
                    } else if case .finished(let code) = run.status, code != 0 {
                        Text("Exited with status \(code)").foregroundStyle(.red)
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch run.status {
        case .running: ProgressView().controlSize(.mini)
        case .finished(0): Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .finished: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }

    private func color(_ stream: ScriptOutputLine.Stream) -> Color {
        switch stream {
        case .stdout: return .primary
        case .stderr: return .red
        case .info: return .blue
        }
    }

    private func copyOutput() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(run.lines.map(\.text).joined(separator: "\n"), forType: .string)
    }
}

/// What a dry run would change: a summary, the steps with conflicts highlighted, and a way to run it for real.
struct DryRunPlanView: View {
    let steps: [ScriptPlanStep]
    var finished = true
    var runForReal: (() -> Void)?
    @State private var showAll = false

    var body: some View {
        let conflicts = steps.filter { $0.conflict != nil }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Dry run plan", systemImage: "eye").font(.callout.weight(.semibold))
                ForEach(ScriptPlanStep.summary(steps), id: \.action) { item in
                    Label("\(item.count) \(item.action.title.lowercased())", systemImage: item.action.symbol)
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                if conflicts > 0 {
                    Label("\(conflicts) conflicts", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                if let runForReal, finished {
                    Button("Run for Real") { runForReal() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .help("Runs the script on the same items and makes these changes")
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                ForEach(Array(steps.prefix(showAll ? steps.count : 12).enumerated()), id: \.offset) { _, step in
                    GridRow {
                        Label(step.action.title, systemImage: step.action.symbol).foregroundStyle(step.action == .trash ? .red : .primary)
                        Text(step.name).lineLimit(1).truncationMode(.middle).help(step.path)
                        Text(destination(step)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(step.target ?? "")
                        if let conflict = step.conflict {
                            Label(conflict, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(1)
                        } else {
                            Text("")
                        }
                    }
                    .font(.caption)
                }
            }
            if steps.count > 12 {
                Button(showAll ? String(localized: "Show less") : String(localized: "Show all \(steps.count)")) { showAll.toggle() }.buttonStyle(.link).font(.caption)
            }
        }
        .padding(10)
        .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.blue.opacity(0.25)))
    }

    private func destination(_ step: ScriptPlanStep) -> String {
        switch step.action {
        case .rename: return "→ " + ((step.target ?? "") as NSString).lastPathComponent
        case .move, .copy, .skip: return "→ " + (((step.target ?? "") as NSString).deletingLastPathComponent).replacingOccurrences(of: NSHomeDirectory(), with: "~")
        case .tag: return step.detail ?? ""
        case .create, .write, .mkdir: return ((step.path as NSString).deletingLastPathComponent).replacingOccurrences(of: NSHomeDirectory(), with: "~")
        case .trash: return ""
        }
    }
}

/// The JavaScript API, grouped, with signatures, return values and required permissions.
struct ScriptAPIReference: View {
    @State private var search = ""

    private var groups: [(String, [ScriptAPI.Member])] {
        let members = ScriptAPI.members.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.summary.localizedCaseInsensitiveContains(search) }
        var order = ["Context & files"]
        for member in ScriptAPI.members {
            let parts = member.name.split(separator: ".")
            if parts.count > 2, !order.contains(parts.prefix(2).joined(separator: ".")) { order.append(parts.prefix(2).joined(separator: ".")) }
        }
        let grouped = Dictionary(grouping: members) { member -> String in
            let parts = member.name.split(separator: ".")
            return parts.count > 2 ? parts.prefix(2).joined(separator: ".") : "Context & files"
        }
        return order.compactMap { key in grouped[key].map { (key, $0) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("wayfile API \(ScriptAPI.version)").font(.headline)
                Spacer()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 160)
            }
            .padding(10)
            Divider()
            List {
                ForEach(groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1) { member in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(member.name + member.signature).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                    Spacer()
                                    if let permission = member.permission {
                                        Text(permission.rawValue).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(Color.orange.opacity(0.15), in: Capsule())
                                            .help("Needs @permissions \(permission.rawValue)")
                                    }
                                    if member.interactive {
                                        Image(systemName: "macwindow").font(.caption).foregroundStyle(.secondary)
                                            .help("Only when started from a window — not from triggers or schedules")
                                    }
                                }
                                Text(member.summary).font(.caption).foregroundStyle(.secondary)
                                Text("→ \(member.returns)").font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                Section("Notes") {
                    Text("Relative paths resolve against the current folder. Changes are undoable from the Timeline; in a dry run they are only planned. Errors thrown by the API are JavaScript exceptions — use try / catch. Async functions work: end the script with main().")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Earlier saves of a script: pick one to see it, restore it (the current text is kept as a version too).
struct ScriptVersionsView: View {
    let script: Script
    let onRestore: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [ScriptVersions.Version] = []
    @State private var selected: ScriptVersions.Version?
    @State private var preview = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Versions of “\(script.name)”").font(.headline)
                Spacer()
                Text("Kept on every save (last \(ScriptVersions.limit))").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            if versions.isEmpty {
                ContentUnavailableView("No earlier versions", systemImage: "clock.arrow.circlepath",
                                       description: Text("A version is kept each time you save a change here."))
            } else {
                HSplitView {
                    List(versions, selection: $selected) { version in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(version.date.formatted(date: .abbreviated, time: .standard))
                            Text(version.date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(version)
                    }
                    .frame(minWidth: 200, idealWidth: 220, maxWidth: 260)
                    CodeEditor(text: .constant(preview), language: script.language, editable: false)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Restore This Version") { restore() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected == nil)
            }
            .padding(12)
        }
        .onAppear {
            versions = ScriptVersions.list(for: script.url)
            selected = versions.first
        }
        .onChange(of: selected) {
            preview = selected.flatMap { try? String(contentsOf: $0.url, encoding: .utf8) } ?? ""
        }
        .alert("Versions", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func restore() {
        guard let selected else { return }
        do {
            try ScriptVersions.restore(selected, to: script.url)
            onRestore((try? String(contentsOf: script.url, encoding: .utf8)) ?? "")
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A package (or plain script file) waiting for review before it's installed.
struct ImportReview: Identifiable {
    let id = UUID()
    let package: ScriptPackage
    let script: Script

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        if url.pathExtension.lowercased() == ScriptPackage.fileExtension {
            (package, script) = try ScriptPackage.read(data)
        } else {
            guard let language = Script.Language(fileExtension: url.pathExtension) else { throw ScriptPackage.PackageError.unsupportedLanguage(url.pathExtension) }
            guard data.count <= ScriptPackage.sizeLimit else { throw ScriptPackage.PackageError.tooLarge }
            let text = String(decoding: data, as: UTF8.self)
            guard let parsed = Script(url: URL(fileURLWithPath: "/imported").appendingPathComponent(ScriptPackage.safeFileName(url.lastPathComponent, language: language)), text: text) else {
                throw ScriptPackage.PackageError.unreadable
            }
            script = parsed
            package = ScriptPackage(script: parsed, source: text)
        }
    }
}

/// Shows what an imported script declares and its source before anything is written; nothing runs.
struct ScriptImportView: View {
    let review: ImportReview
    let onInstalled: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        let manifest = review.package.manifest
        let script = review.script
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(script.name, systemImage: script.language.symbol).font(.title3.weight(.semibold))
                if let version = manifest.version { Text("v\(version)").foregroundStyle(.secondary) }
                Spacer()
                Text(script.language.title).font(.caption).foregroundStyle(.secondary)
            }
            if let description = manifest.description { Text(description).foregroundStyle(.secondary) }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Permissions").foregroundStyle(.secondary)
                    Text(script.permissions.isEmpty ? String(localized: "None") : script.permissions.sorted().map(\.title).joined(separator: ", "))
                }
                GridRow {
                    Text("Works on").foregroundStyle(.secondary)
                    Text(script.extensions.isEmpty ? String(localized: "Any file") : script.extensions.sorted().joined(separator: ", "))
                }
                if !manifest.triggers.isEmpty {
                    GridRow {
                        Text("Automatic runs").foregroundStyle(.secondary)
                        Text(manifest.triggers.joined(separator: " · ") + " — off until you allow them")
                    }
                }
            }
            .font(.callout)
            if script.language != .javascript {
                Label("\(script.language.title) scripts run with your full user access — the declared permissions can't be enforced. Read the source before you install it.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Label(JSScriptHost.isIsolated
                      ? String(localized: "JavaScript runs in a sandboxed helper and can only use the permissions it declares. Its file changes are undoable.")
                      : String(localized: "JavaScript scripts can only use the permissions they declare. Their file changes are undoable."), systemImage: "checkmark.shield")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Source").font(.headline)
            CodeEditor(text: .constant(review.package.source), language: review.script.language, editable: false)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            HStack {
                Text("Installing doesn't run it. The first run asks for permission.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Install") { install() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .alert("Import", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func install() {
        do {
            let url = try AutomationCenter.shared.install(review.package, language: review.script.language)
            dismiss()
            onInstalled(url)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
