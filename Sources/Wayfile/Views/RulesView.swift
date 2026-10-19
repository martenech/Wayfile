import AppKit
import SwiftUI

/// Editor for one rule with a live preview (the simulator) of what it would do right now.
struct RuleEditor: View {
    @State var rule: Rule
    @State private var preview: [RuleStep] = []
    private var store: RulesStore { .shared }

    var body: some View {
        VSplitView {
            Form {
                Section {
                    TextField("Name", text: $rule.name)
                    Toggle("Enabled", isOn: $rule.enabled)
                }
                Section("When a file is in") {
                    FolderPicker(url: $rule.folder)
                }
                Section("And matches") {
                    HStack {
                        TextField("Name pattern (empty = any)", text: $rule.pattern)
                        Picker("", selection: $rule.patternMode) {
                            ForEach(SearchQuery.TextMatch.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    LabeledContent("Kinds") {
                        HStack(spacing: 4) {
                            ForEach(SearchQuery.Kind.allCases.filter { $0 != .folder }) { kind in
                                Toggle(isOn: Binding(get: { rule.kinds.contains(kind) },
                                                     set: { if $0 { rule.kinds.insert(kind) } else { rule.kinds.remove(kind) } })) {
                                    Image(systemName: kind.symbol)
                                }
                                .toggleStyle(.button)
                                .help(kind.title)
                            }
                        }
                    }
                    OptionalNumber(title: "Older than (days)", value: $rule.olderThanDays)
                    OptionalNumber(title: "Larger than (MB)", value: Binding(
                        get: { rule.minSize.map { Int($0 / 1_000_000) } },
                        set: { rule.minSize = $0.map { Int64($0) * 1_000_000 } }))
                }
                Section("Then") {
                    ActionPicker(action: $rule.action)
                    Toggle("Ask before acting (matches wait under Pending)", isOn: $rule.requiresApproval)
                    if rule.isAgeBased {
                        Text("Age rules are checked on launch and every hour.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 320)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Preview — what would happen now").font(.headline)
                    Spacer()
                    Button("Run Now") { store.run(preview) }
                        .disabled(preview.isEmpty)
                        .help("Apply the rule to these files (undoable from the Timeline)")
                    Button("Delete Rule", role: .destructive) { store.remove(rule) }
                }
                .controlSize(.small)
                if preview.isEmpty {
                    Text("No files match right now.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(preview) { step in
                        Label(step.description, systemImage: "arrow.right").lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .padding(12)
            .frame(minHeight: 140)
        }
        .onChange(of: rule) { _, new in
            store.update(new)
            refresh()
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        let current = rule
        Task.detached {
            let steps = RuleEngine.plan(current, files: RuleEngine.matches(current))
            await MainActor.run { preview = steps }
        }
    }
}

private struct FolderPicker: View {
    @Binding var url: URL

    var body: some View {
        HStack {
            Image(nsImage: IconCache.icon(for: url)).resizable().frame(width: 16, height: 16)
            Text(url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                .lineLimit(1).truncationMode(.head)
            Spacer()
            Button("Choose…") {
                if let chosen = chooseFolder(start: url) { url = chosen }
            }
        }
    }
}

@MainActor
func chooseFolder(start: URL?) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.directoryURL = start
    return panel.runModal() == .OK ? panel.url : nil
}

private struct OptionalNumber: View {
    let title: String
    @Binding var value: Int?

    var body: some View {
        HStack {
            Toggle(title, isOn: Binding(get: { value != nil }, set: { value = $0 ? (value ?? 30) : nil }))
            if value != nil {
                TextField("", value: Binding(get: { value ?? 0 }, set: { value = max(0, $0) }), format: .number)
                    .frame(width: 70)
                    .labelsHidden()
            }
        }
    }
}

private struct ActionPicker: View {
    @Binding var action: Rule.Action

    private enum Kind: String, CaseIterable, Identifiable {
        case move, copy, trash, tag, sortByKind, sortByDate, runScript
        var id: String { rawValue }
        var title: String {
            switch self {
            case .move: return String(localized: "Move to folder")
            case .copy: return String(localized: "Copy to folder")
            case .trash: return String(localized: "Move to Trash")
            case .tag: return String(localized: "Add tag")
            case .sortByKind: return String(localized: "Sort into kind folders")
            case .sortByDate: return String(localized: "Sort into year/month folders")
            case .runScript: return String(localized: "Run script")
            }
        }
    }

    private var kind: Kind {
        switch action {
        case .move: return .move
        case .copy: return .copy
        case .trash: return .trash
        case .tag: return .tag
        case .sortByKind: return .sortByKind
        case .sortByDate: return .sortByDate
        case .runScript: return .runScript
        }
    }

    var body: some View {
        Picker("Action", selection: Binding(get: { kind }, set: { set($0) })) {
            ForEach(Kind.allCases) { Text($0.title).tag($0) }
        }
        switch action {
        case .move(let url), .copy(let url):
            FolderPicker(url: Binding(get: { url }, set: { new in
                if case .copy = action { action = .copy(new) } else { action = .move(new) }
            }))
        case .tag(let name):
            Picker("Tag", selection: Binding(get: { name }, set: { action = .tag($0) })) {
                ForEach(TagStore.shared.menuTags) { Text($0.name).tag($0.name) }
                if !TagStore.shared.menuTags.contains(where: { $0.name == name }) { Text(name).tag(name) }
            }
        case .runScript(let name):
            Picker("Script", selection: Binding(get: { name }, set: { action = .runScript($0) })) {
                Text("Choose…").tag("")
                ForEach(AutomationCenter.shared.scripts) { Text($0.name).tag($0.url.lastPathComponent) }
            }
        default:
            EmptyView()
        }
    }

    private func set(_ kind: Kind) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch kind {
        case .move: action = .move(home.appendingPathComponent("Documents"))
        case .copy: action = .copy(home.appendingPathComponent("Documents"))
        case .trash: action = .trash
        case .tag: action = .tag(TagStore.shared.menuTags.first?.name ?? "Red")
        case .sortByKind: action = .sortByKind
        case .sortByDate: action = .sortByDate
        case .runScript: action = .runScript(AutomationCenter.shared.scripts.first?.url.lastPathComponent ?? "")
        }
    }
}

/// Matches of rules that ask first.
struct PendingRulesView: View {
    private var store: RulesStore { .shared }
    @State private var selection: Set<String> = []

    var body: some View {
        let pending = store.pending
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pending — waiting for your approval").font(.headline)
                Spacer()
                Button("Dismiss") { store.dismiss(chosen(pending)) }.disabled(pending.isEmpty)
                Button(selection.isEmpty ? String(localized: "Approve All") : String(localized: "Approve \(selection.count)")) { store.approve(chosen(pending)); selection = [] }
                    .buttonStyle(.borderedProminent)
                    .disabled(pending.isEmpty)
            }
            .controlSize(.small)
            if pending.isEmpty {
                ContentUnavailableView("Nothing waiting", systemImage: "checkmark.circle",
                                       description: Text("Rules that ask first collect their matches here."))
            } else {
                List(pending, selection: $selection) { step in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.description).lineLimit(1).truncationMode(.middle)
                        Text(step.rule.name).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
    }

    private func chosen(_ pending: [RuleStep]) -> [RuleStep] {
        selection.isEmpty ? pending : pending.filter { selection.contains($0.id) }
    }
}

/// Proposed clean-up of one folder; each suggestion is applied as an undoable operation.
struct OrganizeView: View {
    let folder: URL
    @State private var suggestions: [OrganizeSuggestions.Suggestion] = []
    @State private var chosen: Set<String> = []
    @State private var loaded = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Organize “\(folder.lastPathComponent)”").font(.title3.weight(.semibold))
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else if suggestions.isEmpty {
                ContentUnavailableView("Looks tidy", systemImage: "sparkles", description: Text("No suggestions for this folder."))
                    .frame(minHeight: 160)
            } else {
                List(suggestions) { suggestion in
                    Toggle(isOn: Binding(get: { chosen.contains(suggestion.id) },
                                         set: { if $0 { chosen.insert(suggestion.id) } else { chosen.remove(suggestion.id) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(suggestion.title, systemImage: suggestion.kind == .trash ? "trash" : "folder.badge.plus")
                            Text(suggestion.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .frame(minHeight: 200)
                Text("Everything can be undone from the Timeline.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply \(chosen.count)") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            let folder = folder
            suggestions = await Task.detached { OrganizeSuggestions.suggest(for: folder) }.value
            chosen = Set(suggestions.filter { $0.kind != .trash }.map(\.id))
            loaded = true
        }
    }

    private func apply() {
        let picked = suggestions.filter { chosen.contains($0.id) }
        let folder = folder
        dismiss()
        Task {
            _ = try? await OperationCenter.shared.run("Organize \(folder.lastPathComponent)", undoTitle: "Organize") { progress in
                var results: [URL] = []
                for suggestion in picked { results += try OrganizeSuggestions.apply(suggestion, in: folder, progress: progress) }
                return results
            }
            WindowState.lastActive?.reloadAll()
        }
    }
}
