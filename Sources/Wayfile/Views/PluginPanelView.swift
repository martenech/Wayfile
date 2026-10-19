import AppKit
import SwiftUI

/// Runs one plugin: loads it into a session, renders it for the current selection, sends button presses
/// and control changes to its `action(id, values, ctx)`, then renders again.
@MainActor
@Observable
final class PluginPanelModel {
    let script: Script
    private(set) var node: PluginNode?
    private(set) var error: String?
    private(set) var busy = false
    private(set) var log: [ScriptOutputLine] = []
    var form = PluginFormState()
    private var session: ScriptSession?
    private var context = ScriptContext(selection: [])
    private var loaded = false
    /// `refreshEvery` on the root element re-renders on a timer while the panel is shown.
    private var refreshTask: Task<Void, Never>?

    init(script: Script) {
        self.script = script
    }

    /// Shows the panel for this context (loading the plugin the first time).
    func show(_ context: ScriptContext) async {
        self.context = context
        if !loaded {
            loaded = true
            let session = ScriptSession(script: script)
            self.session = session
            do {
                if case .failure(let message, let line) = try await session.start(context: context, output: appender) {
                    fail(message, line)
                    return
                }
            } catch {
                self.error = error.localizedDescription
                return
            }
        }
        await call("render", [ctxValue], recordAs: nil)
    }

    /// A button, a list row, or a control with an `action`.
    func action(_ id: String) {
        Task {
            await call("action", [id, form.values, ctxValue], recordAs: "Plugin: \(script.name)")
            await call("render", [ctxValue], recordAs: nil)
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        session?.close()
        session = nil
        loaded = false
    }

    private var ctxValue: [String: Any] {
        var values = JSScriptHost.engineContext(for: context)["values"] as? [String: Any] ?? [:]
        values["values"] = form.values
        return values
    }

    private func call(_ function: String, _ args: [Any], recordAs title: String?) async {
        guard let session else { return }
        busy = true
        defer { busy = false }
        let progress = OperationProgress()
        do {
            let outcome = try await session.invoke(function, args: args, context: context, progress: progress, output: appender)
            if let title { OperationCenter.shared.recordChanges(title, undoTitle: "Plugin", progress: progress) }
            switch outcome {
            case .failure(let message, let line):
                // A plugin without action() just has nothing to do on clicks.
                if function == "action" && message.contains("doesn't define action()") { return }
                fail(message, line)
            case .success(let value):
                guard function == "render" else { return }
                error = nil
                if let node = PluginNode(value) {
                    form.adopt(node)
                    self.node = node
                    scheduleRefresh(node.double("refreshEvery"))
                } else if value != nil {
                    error = "render() must return ui.* elements (got \(type(of: value!)))."
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func scheduleRefresh(_ seconds: Double?) {
        refreshTask?.cancel()
        guard let seconds, seconds > 0 else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(seconds, 2)))
            guard !Task.isCancelled, let self, !self.busy else { return }
            await self.call("render", [self.ctxValue], recordAs: nil)
        }
    }

    private func fail(_ message: String, _ line: Int?) {
        error = line.map { "Line \($0): \(message)" } ?? message
    }

    nonisolated private var appender: ScriptRunner.Output {
        { [weak self] line in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.log.append(line)
                    if self.log.count > 100 { self.log.removeFirst(self.log.count - 100) }
                }
            }
        }
    }
}

/// A plugin's interface, or what keeps it from showing (not allowed yet, an error).
struct PluginPanelView: View {
    @State private var model: PluginPanelModel
    let context: ScriptContext
    @State private var showLog = false
    private var center: AutomationCenter { .shared }

    init(script: Script, context: ScriptContext) {
        _model = State(initialValue: PluginPanelModel(script: script))
        self.context = context
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !center.isApproved(model.script) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("“\(model.script.name)” is a plugin. It runs its code when shown.").font(.callout)
                    Button("Allow and Show…") {
                        if center.requestApproval(model.script) { Task { await model.show(context) } }
                    }
                    .controlSize(.small)
                }
            } else {
                if let node = model.node {
                    PluginNodeView(node: node, model: model)
                        .disabled(model.busy)
                } else if model.error == nil {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if !model.log.isEmpty {
                    DisclosureGroup("Output (\(model.log.count))", isExpanded: $showLog) {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(model.log.suffix(30).enumerated()), id: \.offset) { _, line in
                                Text(line.text).font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(line.stream == .stderr ? Color.red : line.stream == .info ? .blue : .primary)
                            }
                        }
                        .textSelection(.enabled)
                    }
                    .font(.caption)
                }
            }
        }
        .task(id: TaskKey(selection: context.selection, folder: context.folder, approved: center.isApproved(model.script))) {
            guard center.isApproved(model.script) else { return }
            await model.show(context)
        }
        .onDisappear { model.stop() }
    }

    private struct TaskKey: Equatable {
        let selection: [URL]
        let folder: URL?
        let approved: Bool
    }
}

/// Draws a plugin node tree with native controls.
struct PluginNodeView: View {
    let node: PluginNode
    let model: PluginPanelModel

    var body: some View {
        switch node.kind {
        case .vstack:
            VStack(alignment: node.string("align") == "center" ? .center : .leading, spacing: node.double("spacing").map { CGFloat($0) } ?? 8) {
                children
            }
            .frame(maxWidth: .infinity, alignment: node.string("align") == "center" ? .center : .leading)
        case .hstack:
            HStack(spacing: node.double("spacing").map { CGFloat($0) } ?? 8) { children }
        case .section:
            VStack(alignment: .leading, spacing: 6) {
                if let title = node.string("title") { Text(title).font(.subheadline.weight(.semibold)) }
                children
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        case .text:
            text
        case .button:
            button
        case .textField:
            if let id = node.controlID {
                TextField(node.string("placeholder") ?? "", text: Binding(get: { model.form.text(id) }, set: { model.form.set(id, $0) }))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if let action = node.string("action") ?? node.string("submit") { model.action(action) } }
                    .accessibilityLabel(node.string("label") ?? node.string("placeholder") ?? id)
            }
        case .toggle:
            if let id = node.controlID {
                Toggle(node.string("title") ?? "", isOn: Binding(get: { model.form.flag(id) }, set: {
                    model.form.set(id, $0)
                    if let action = node.string("action") { model.action(action) }
                }))
            }
        case .picker:
            if let id = node.controlID {
                let picker = Picker(node.string("title") ?? "", selection: Binding(get: { model.form.text(id) }, set: {
                    model.form.set(id, $0)
                    if let action = node.string("action") { model.action(action) }
                })) {
                    ForEach(node.props["options"] as? [String] ?? [], id: \.self) { Text($0).tag($0) }
                }
                if node.string("style") == "segmented" { picker.pickerStyle(.segmented) } else { picker.pickerStyle(.menu) }
            }
        case .progress:
            VStack(alignment: .leading, spacing: 2) {
                if let label = node.string("label") {
                    HStack {
                        Text(label).font(.caption)
                        Spacer()
                        if let detail = node.string("detail") { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                ProgressView(value: min(max(node.double("value") ?? 0, 0), 1))
                    .tint(PluginColor.named(node.string("color")))
            }
        case .row:
            HStack(alignment: .firstTextBaseline) {
                Text(node.string("label") ?? "").foregroundStyle(.secondary)
                Spacer()
                Text(node.string("value") ?? "").textSelection(.enabled).multilineTextAlignment(.trailing)
            }
            .font(.callout)
        case .list:
            VStack(spacing: 0) {
                ForEach(node.listItems) { item in
                    listRow(item)
                    if item.index < node.listItems.count - 1 { Divider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        case .image:
            if let path = node.string("path") {
                FileThumb(url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath), size: CGFloat(node.double("size") ?? 64))
            } else if let symbol = node.string("symbol") {
                Image(systemName: symbol).font(.system(size: CGFloat(node.double("size") ?? 20)))
                    .foregroundStyle(PluginColor.named(node.string("color")))
            }
        case .badge:
            let color = PluginColor.named(node.string("color"))
            Text(node.string("text") ?? "").font(.caption.weight(.medium))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .foregroundStyle(color)
                .background(Capsule().fill(color.opacity(0.15)))
        case .divider:
            Divider()
        case .spacer:
            Spacer(minLength: 0)
        case nil:
            Text("Unknown element “\(node.type)”").font(.caption).foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var children: some View {
        ForEach(node.children) { PluginNodeView(node: $0, model: model) }
    }

    @ViewBuilder
    private var text: some View {
        let value = Text(node.string("text") ?? "")
        switch node.string("style") {
        case "title": value.font(.title3.weight(.semibold))
        case "headline": value.font(.headline)
        case "caption": value.font(.caption).foregroundStyle(.secondary)
        case "secondary": value.foregroundStyle(.secondary)
        case "mono": value.font(.system(.callout, design: .monospaced)).textSelection(.enabled)
        default: value.foregroundStyle(node.string("color").map { PluginColor.named($0) } ?? .primary)
        }
    }

    @ViewBuilder
    private var button: some View {
        let title = node.string("title") ?? ""
        let label = Group {
            if let symbol = node.string("symbol") { Label(title, systemImage: symbol) } else { Text(title) }
        }
        let action = { if let id = node.controlID { model.action(id) } }
        switch node.string("style") {
        case "prominent": Button(action: action) { label }.buttonStyle(.borderedProminent).disabled(node.bool("disabled"))
        case "destructive": Button(role: .destructive, action: action) { label }.disabled(node.bool("disabled"))
        case "link": Button(action: action) { label }.buttonStyle(.link).disabled(node.bool("disabled"))
        default: Button(action: action) { label }.disabled(node.bool("disabled"))
        }
    }

    private func listRow(_ item: PluginListItem) -> some View {
        let content = HStack(spacing: 8) {
            if let path = item.path {
                Image(nsImage: IconCache.icon(for: URL(fileURLWithPath: path))).resizable().frame(width: 18, height: 18)
            } else if let symbol = item.symbol {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1).truncationMode(.middle)
                if let subtitle = item.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            if let detail = item.detail { Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .contentShape(Rectangle())
        return Group {
            if let action = item.action {
                Button { model.action(action) } label: { content }.buttonStyle(.plain)
            } else {
                content
            }
        }
    }
}

enum PluginColor {
    static func named(_ name: String?) -> Color {
        switch name?.lowercased() {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "teal": return .teal
        case "blue": return .blue
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink": return .pink
        case "gray", "grey": return .gray
        default: return .accentColor
        }
    }
}

// MARK: - Hosts

/// Inspector sections for the plugins that apply to the selection.
struct PluginInspectorSections: View {
    let state: WindowState
    let urls: [URL]

    var body: some View {
        if Features.shared.isOn(.automation) {
            ForEach(AutomationCenter.shared.panels(.inspector, for: urls)) { script in
                InspectorSection(script.name) {
                    PluginPanelView(script: script, context: state.scriptContext(for: urls)).id(script.url)
                }
            }
        }
    }
}

/// A window plugin, working on the selection of the last used browser window.
struct PluginWindow: View {
    let path: String
    @State private var refresh = 0

    var body: some View {
        let script = AutomationCenter.shared.scripts.first { $0.url.path == path && $0.panel == .window }
        Group {
            if let script {
                let state = WindowState.lastActive
                let selection = state.map { Array($0.activePane.selection).sorted { $0.path < $1.path } } ?? []
                ScrollView {
                    PluginPanelView(script: script, context: state?.scriptContext(for: selection) ?? ScriptContext(selection: []))
                        .id(script.url)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .navigationTitle(script.name)
                .toolbar {
                    Button { refresh += 1 } label: { Label("Use Current Selection", systemImage: "arrow.clockwise") }
                        .help("Show the plugin for what's selected now")
                }
                .id(refresh)
            } else {
                ContentUnavailableView("Plugin not found", systemImage: "puzzlepiece.extension")
            }
        }
        .frame(minWidth: 380, minHeight: 300)
    }
}
