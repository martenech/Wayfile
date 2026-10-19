import AppKit
import SwiftUI

/// One side of a text comparison: a file on disk, or a file's version in git.
enum DiffSource: Codable, Hashable {
    case file(URL)
    /// `revision` is "HEAD", a commit hash, or "" for the staged (index) version.
    case git(root: URL, path: String, revision: String)

    var title: String {
        switch self {
        case .file(let url): return url.lastPathComponent
        case .git(_, let path, let revision):
            let name = (path as NSString).lastPathComponent
            switch revision {
            case "": return String(localized: "\(name) (staged)")
            case "HEAD": return String(localized: "\(name) (HEAD)")
            default: return String(localized: "\(name) @ \(revision.prefix(7))")
            }
        }
    }

    var subtitle: String {
        switch self {
        case .file(let url): return url.deletingLastPathComponent().path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        case .git(let root, let path, _): return String(localized: "\(root.lastPathComponent)/\(path)")
        }
    }

    /// Text content; nil when the file doesn't exist there (added/deleted) or isn't text.
    func load() async -> String? {
        switch self {
        case .file(let url):
            guard let data = try? Data(contentsOf: url), data.count < 20_000_000 else { return nil }
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        case .git(let root, let path, let revision):
            return await Git.show(path, at: revision, in: root)
        }
    }
}

struct DiffTarget: Codable, Hashable {
    var left: DiffSource
    var right: DiffSource
}

/// Window: compare two files (or versions) side by side.
struct TextCompareView: View {
    @State var target: DiffTarget

    var body: some View {
        DiffView(left: target.left, right: target.right) {
            Button { target = DiffTarget(left: target.right, right: target.left) } label: { Image(systemName: "arrow.left.arrow.right") }
                .help("Swap sides")
                .accessibilityLabel("Swap sides")
        }
        .frame(minWidth: 760, minHeight: 440)
        .navigationTitle("\(target.left.title) ⇄ \(target.right.title)")
    }
}

/// Side-by-side diff with line numbers, change colours and folded unchanged runs.
struct DiffView<Accessory: View>: View {
    let left: DiffSource
    let right: DiffSource
    @ViewBuilder var accessory: () -> Accessory

    @State private var leftText: String?
    @State private var rightText: String?
    @State private var loaded = false
    @AppStorage("diff.onlyChanges") private var onlyChanges = true
    @AppStorage("diff.ignoreWhitespace") private var ignoreWhitespace = false
    @State private var expanded: Set<Int> = []

    var body: some View {
        let rows = TextDiff.rows(leftText ?? "", rightText ?? "", ignoreWhitespace: ignoreWhitespace)
        let stats = TextDiff.stats(rows)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                sideHeader(left, missing: loaded && leftText == nil)
                accessory()
                sideHeader(right, missing: loaded && rightText == nil)
            }
            .padding(10)
            Divider()
            HStack(spacing: 12) {
                if stats.isIdentical {
                    Label(loaded ? String(localized: "No differences") : String(localized: "Loading…"), systemImage: "checkmark.seal").foregroundStyle(.secondary)
                } else {
                    Text("\(stats.changed) changed").foregroundStyle(.orange)
                    Text("\(stats.removed) removed").foregroundStyle(.red)
                    Text("\(stats.added) added").foregroundStyle(.green)
                }
                Spacer()
                Toggle("Only changes", isOn: $onlyChanges)
                Toggle("Ignore whitespace", isOn: $ignoreWhitespace)
            }
            .font(.callout)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if loaded && leftText == nil && rightText == nil {
                ContentUnavailableView("Can’t compare", systemImage: "doc.questionmark", description: Text("Neither side could be read as text."))
            } else {
                diffList(rows)
            }
        }
        .task(id: [left, right]) {
            loaded = false
            async let l = left.load()
            async let r = right.load()
            (leftText, rightText) = await (l, r)
            expanded = []
            loaded = true
        }
    }

    private func sideHeader(_ source: DiffSource, missing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(source.title).fontWeight(.semibold).lineLimit(1)
            Text(missing ? String(localized: "Doesn’t exist here") : source.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func diffList(_ rows: [TextDiff.Row]) -> some View {
        let lines: [TextDiff.Line] = onlyChanges ? TextDiff.hunks(rows) : rows.map { .row($0) }
        let width = CGFloat(String(rows.count).count) * 8 + 10
        return ScrollView([.vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    switch line {
                    case .row(let row):
                        rowView(row, numberWidth: width)
                    case .fold(let id, let count):
                        if expanded.contains(id) {
                            ForEach(foldedRows(rows, endingBefore: id, count: count)) { rowView($0, numberWidth: width) }
                        } else {
                            Button { expanded.insert(id) } label: {
                                Label("\(count) unchanged lines", systemImage: "arrow.up.and.down")
                                    .font(.caption)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 3)
                                    .background(.quaternary.opacity(0.5))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// The rows a fold stands for: `count` rows before the row with id `id` (or the end).
    private func foldedRows(_ rows: [TextDiff.Row], endingBefore id: Int, count: Int) -> [TextDiff.Row] {
        let end = min(id, rows.count)
        return Array(rows[max(0, end - count)..<end])
    }

    private func rowView(_ row: TextDiff.Row, numberWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            cell(row.left, highlight: row.kind == .removed || row.kind == .changed ? Color.red : nil, numberWidth: numberWidth)
            Divider()
            cell(row.right, highlight: row.kind == .added || row.kind == .changed ? Color.green : nil, numberWidth: numberWidth)
        }
    }

    private func cell(_ line: (number: Int, text: String)?, highlight: Color?, numberWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(line.map { String($0.number) } ?? "")
                .foregroundStyle(.tertiary)
                .frame(width: numberWidth, alignment: .trailing)
            Text(line?.text.isEmpty == false ? line!.text : " ")
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity)
        .background(line == nil ? Color.secondary.opacity(0.06) : (highlight?.opacity(0.14) ?? .clear))
        .clipped()
    }
}

// MARK: - Git window

struct GitTarget: Codable, Hashable {
    var root: URL
    /// Opens on this file's history when set.
    var path: String?
}

struct GitWindow: View {
    let target: GitTarget
    @State private var tab: Tab

    enum Tab: String, CaseIterable { case changes = "Changes", history = "History" }

    init(target: GitTarget) {
        self.target = target
        _tab = State(initialValue: target.path == nil ? .changes : .history)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text(key: $0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(8)
            Divider()
            switch tab {
            case .changes: GitChangesView(root: target.root)
            case .history: GitHistoryView(root: target.root, path: target.path)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .navigationTitle(target.path.map { "History of \(($0 as NSString).lastPathComponent)" } ?? target.root.lastPathComponent)
    }
}

private struct GitChangesView: View {
    let root: URL
    @State private var changes: [GitChange] = []
    @State private var selected: Selected?
    @State private var message = ""
    @State private var amend = false
    @State private var error: String?
    @State private var busy = false

    struct Selected: Hashable { let path: String; let staged: Bool }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selected) {
                    let staged = changes.filter(\.hasStaged)
                    let unstaged = changes.filter(\.hasUnstaged)
                    Section {
                        ForEach(staged) { row($0, staged: true) }
                    } header: {
                        sectionHeader("Staged", count: staged.count, action: "Unstage All") { unstage(staged.map(\.path)) }
                    }
                    Section {
                        ForEach(unstaged) { row($0, staged: false) }
                    } header: {
                        sectionHeader("Changes", count: unstaged.count, action: "Stage All") { stage(unstaged.map(\.path)) }
                    }
                }
                .overlay {
                    if changes.isEmpty && !busy {
                        ContentUnavailableView("Working tree clean", systemImage: "checkmark.circle")
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Commit message", text: $message, axis: .vertical)
                        .lineLimit(2...5)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Toggle("Amend last commit", isOn: $amend).controlSize(.small)
                        Spacer()
                        Button("Commit") { commit() }
                            .keyboardShortcut(.return, modifiers: .command)
                            .buttonStyle(.borderedProminent)
                            .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!amend && !changes.contains(where: \.hasStaged)))
                    }
                }
                .padding(10)
            }
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)

            Group {
                if let selected {
                    if selected.staged {
                        DiffView(left: .git(root: root, path: selected.path, revision: "HEAD"), right: .git(root: root, path: selected.path, revision: "")) { EmptyView() }
                    } else {
                        DiffView(left: .git(root: root, path: selected.path, revision: ""), right: .file(root.appendingPathComponent(selected.path))) { EmptyView() }
                    }
                } else {
                    ContentUnavailableView("Select a change", systemImage: "doc.text.magnifyingglass")
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await refresh() }
        .alert("Git", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func sectionHeader(_ title: String, count: Int, action: String, perform: @escaping () -> Void) -> some View {
        HStack {
            Text(key: title) + Text(verbatim: " (\(count))")
            Spacer()
            if count > 0 { Button(LocalizedStringKey(action), action: perform).buttonStyle(.borderless).font(.caption) }
        }
    }

    private func row(_ change: GitChange, staged: Bool) -> some View {
        let code = staged ? change.staged : (change.isUntracked ? "U" : change.unstaged)
        return HStack(spacing: 6) {
            Image(nsImage: IconCache.icon(for: root.appendingPathComponent(change.path))).resizable().frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text((change.path as NSString).lastPathComponent).lineLimit(1)
                let dir = (change.path as NSString).deletingLastPathComponent
                if !dir.isEmpty { Text(dir).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
            }
            Spacer()
            Text(String(code)).font(.caption.monospaced().weight(.bold)).foregroundStyle(change.status?.color ?? .secondary)
            Button { staged ? unstage([change.path]) : stage([change.path]) } label: {
                Image(systemName: staged ? "minus.circle" : "plus.circle")
            }
            .buttonStyle(.borderless)
            .help(staged ? String(localized: "Unstage") : String(localized: "Stage"))
        }
        .tag(Selected(path: change.path, staged: staged))
        .contextMenu {
            Button(staged ? String(localized: "Unstage") : String(localized: "Stage")) { staged ? unstage([change.path]) : stage([change.path]) }
            if !staged {
                Button(change.isUntracked ? String(localized: "Move to Trash…") : String(localized: "Discard Changes…"), role: .destructive) { discard(change) }
            }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(change.path)]) }
        }
    }

    private func refresh() async {
        busy = true
        defer { busy = false }
        do {
            changes = try await Git.changes(in: root)
            if selected == nil, let first = changes.first(where: \.hasStaged) ?? changes.first {
                selected = Selected(path: first.path, staged: first.hasStaged)
            }
            if let current = selected, !changes.contains(where: { $0.path == current.path && (current.staged ? $0.hasStaged : $0.hasUnstaged) }) {
                selected = nil
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func perform(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { self.error = error.localizedDescription }
            await refresh()
            WindowState.lastActive?.reloadAll()
        }
    }

    private func stage(_ paths: [String]) { perform { try await Git.stage(paths, in: root) } }
    private func unstage(_ paths: [String]) { perform { try await Git.unstage(paths, in: root) } }

    private func discard(_ change: GitChange) {
        let alert = NSAlert()
        alert.messageText = change.isUntracked ? "Move “\(change.path)” to the Trash?" : "Discard changes to “\(change.path)”?"
        alert.informativeText = change.isUntracked ? "The file isn’t tracked by git; it can be restored from the Trash."
            : "The working copy goes back to the staged (or committed) version. This can’t be undone."
        alert.addButton(withTitle: change.isUntracked ? "Move to Trash" : "Discard")
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if change.isUntracked {
            perform { try FileManager.default.trashItem(at: root.appendingPathComponent(change.path), resultingItemURL: nil) }
        } else {
            perform { try await Git.discard([change.path], in: root) }
        }
    }

    private func commit() {
        let text = message
        let amending = amend
        perform {
            try await Git.commit(message: text, amend: amending, in: root)
            message = ""
            amend = false
        }
    }
}

private struct GitHistoryView: View {
    let root: URL
    let path: String?
    @State private var entries: [GitLogEntry] = []
    @State private var selected: String?
    @State private var files: [String] = []
    @State private var file: String?
    @State private var error: String?

    var body: some View {
        HSplitView {
            List(entries, selection: $selected) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.subject).lineLimit(2)
                    Text("\(entry.shortHash) · \(entry.author) · \(Formatters.date(entry.date))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button("Copy Hash") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.hash, forType: .string)
                    }
                }
            }
            .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
            .overlay { if entries.isEmpty { ContentUnavailableView("No history", systemImage: "clock") } }

            Group {
                if let entry = entries.first(where: { $0.hash == selected }) {
                    VStack(spacing: 0) {
                        if path == nil {
                            Picker("File", selection: $file) {
                                ForEach(files, id: \.self) { Text($0).tag(Optional($0)) }
                            }
                            .padding(8)
                            Divider()
                        }
                        if let shown = path.map({ entry.path ?? $0 }) ?? file {
                            let previous = entries.firstIndex(of: entry).flatMap { index in
                                path != nil ? entries[safe: index + 1]?.path ?? shown : shown
                            } ?? shown
                            DiffView(left: .git(root: root, path: previous, revision: entry.hash + "^"),
                                     right: .git(root: root, path: shown, revision: entry.hash)) { EmptyView() }
                        } else {
                            ContentUnavailableView("Choose a file", systemImage: "doc")
                        }
                    }
                } else {
                    ContentUnavailableView("Select a commit", systemImage: "clock.arrow.circlepath")
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            do {
                if let path {
                    entries = try await Git.history(of: path, in: root)
                } else {
                    entries = try await Git.log(in: root)
                }
                selected = entries.first?.hash
            } catch {
                self.error = error.localizedDescription
            }
        }
        .task(id: selected) {
            guard path == nil, let selected else { return }
            files = (try? await Git.filesChanged(in: selected, root: root)) ?? []
            file = files.first
        }
        .alert("Git", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
