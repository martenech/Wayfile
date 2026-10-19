import AppKit
import SwiftUI

/// Which two folders a Compare window shows.
struct CompareTarget: Codable, Hashable {
    var left: URL
    var right: URL
}

/// Side-by-side folder comparison with per-item copy/trash and previewed sync.
struct CompareView: View {
    @State private var left: URL
    @State private var right: URL
    @State private var byContent = false
    @State private var includeHidden = false
    @State private var entries: [DirectoryDiff.Entry] = []
    @State private var loading = false
    @State private var error: String?
    @State private var shown: Set<DirectoryDiff.Status> = Set(DirectoryDiff.Status.allCases).subtracting([.same])
    @State private var selection: Set<String> = []
    @State private var syncPlan: SyncPreview?
    @State private var compareTask: Task<Void, Never>?

    struct SyncPreview: Identifiable {
        let id = UUID()
        let mode: DirectoryDiff.SyncMode?
        let title: String
        let actions: [DirectoryDiff.Action]
        /// Two-way sync with deletions: conflicts shown before running; the state is remembered afterwards.
        var conflicts: [TwoWaySync.Conflict] = []
        var isFirstSync = false
        var remembersState = false
    }

    init(target: CompareTarget) {
        _left = State(initialValue: target.left)
        _right = State(initialValue: target.right)
    }

    private var visible: [DirectoryDiff.Entry] { entries.filter { shown.contains($0.status) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filters
            Divider()
            table
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 480)
        .navigationTitle("Compare \(left.lastPathComponent) ⇄ \(right.lastPathComponent)")
        .task(id: CompareKey(left: left, right: right, byContent: byContent, hidden: includeHidden)) {
            await compare()
            #if DEBUG
            if ProcessInfo.processInfo.environment["WAYFILE_TWOWAY_PREVIEW"] != nil { planTwoWay() }
            #endif
        }
        .sheet(item: $syncPlan) { plan in
            SyncPreviewSheet(plan: plan, left: left, right: right) { run(plan) }
        }
        .alert("Comparison failed", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private struct CompareKey: Equatable {
        let left: URL, right: URL, byContent: Bool, hidden: Bool
    }

    // MARK: Header & filters

    private var header: some View {
        HStack(spacing: 10) {
            folderButton(left) { left = $0 }
            Button { swap(&left, &right); selection = [] } label: { Image(systemName: "arrow.left.arrow.right") }
                .help("Swap sides")
                .accessibilityLabel("Swap sides")
            folderButton(right) { right = $0 }
            Spacer()
            Toggle("Compare contents", isOn: $byContent)
                .help("Also compare checksums of files with the same size (slower)")
            Toggle("Hidden files", isOn: $includeHidden)
            Button { Task { await compare() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Compare again")
                .accessibilityLabel("Compare again")
        }
        .controlSize(.small)
        .padding(10)
    }

    private func folderButton(_ url: URL, set: @escaping (URL) -> Void) -> some View {
        Button {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.directoryURL = url
            if panel.runModal() == .OK, let chosen = panel.url { set(chosen); selection = [] }
        } label: {
            HStack(spacing: 6) {
                Image(nsImage: IconCache.icon(for: url)).resizable().frame(width: 16, height: 16)
                Text(url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .lineLimit(1).truncationMode(.head)
            }
            .frame(maxWidth: 280, alignment: .leading)
        }
        .help(url.path)
    }

    private var filters: some View {
        HStack(spacing: 6) {
            ForEach(DirectoryDiff.Status.allCases, id: \.self) { status in
                let count = entries.filter { $0.status == status }.count
                Toggle(isOn: Binding(
                    get: { shown.contains(status) },
                    set: { if $0 { shown.insert(status) } else { shown.remove(status) } }
                )) {
                    Label("\(status.title) \(count)", systemImage: status.symbol)
                }
                .toggleStyle(.button)
                .disabled(count == 0 && status != .same)
            }
            Spacer()
            if loading { ProgressView().controlSize(.small) }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: Table

    private var table: some View {
        Table(visible, selection: $selection) {
            TableColumn("") { entry in
                Image(systemName: entry.status.symbol).foregroundStyle(color(entry.status))
            }
            .width(24)
            TableColumn("Path") { entry in
                HStack(spacing: 6) {
                    Image(systemName: entry.isDirectory ? "folder" : "doc").foregroundStyle(.secondary)
                    Text(entry.path).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 200, ideal: 340)
            TableColumn("Left") { entry in metaText(entry.left, highlight: entry.status == .leftNewer) }
                .width(min: 130, ideal: 170)
            TableColumn("Right") { entry in metaText(entry.right, highlight: entry.status == .rightNewer) }
                .width(min: 130, ideal: 170)
            TableColumn("Status") { entry in Text(entry.status.title).foregroundStyle(color(entry.status)) }
                .width(min: 80, ideal: 100)
        }
        .contextMenu(forSelectionType: String.self) { paths in
            let actions = actions(for: paths)
            Button("Copy → Right") { preview("Copy to right", actions.toRight) }.disabled(actions.toRight.isEmpty)
            Button("Copy ← Left") { preview("Copy to left", actions.toLeft) }.disabled(actions.toLeft.isEmpty)
            Divider()
            Button("Show Left in Finder") { reveal(paths, in: left) }
            Button("Show Right in Finder") { reveal(paths, in: right) }
        }
        .overlay {
            if !loading && visible.isEmpty {
                ContentUnavailableView(entries.isEmpty ? String(localized: "The folders are identical") : String(localized: "Nothing in the selected filters"),
                                       systemImage: entries.isEmpty ? "checkmark.seal" : "line.3.horizontal.decrease.circle")
            }
        }
    }

    private func metaText(_ meta: DirectoryDiff.Meta?, highlight: Bool) -> some View {
        Group {
            if let meta {
                Text(meta.isDirectory ? Formatters.date(meta.modified) : String(localized: "\(Formatters.size(meta.size)) · \(Formatters.date(meta.modified))"))
                    .fontWeight(highlight ? .semibold : .regular)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .lineLimit(1)
    }

    private func color(_ status: DirectoryDiff.Status) -> Color {
        switch status {
        case .leftOnly, .leftNewer: return .blue
        case .rightOnly, .rightNewer: return .orange
        case .different: return .red
        case .same: return .secondary
        }
    }

    // MARK: Footer & actions

    private var footer: some View {
        let actions = actions(for: selection)
        return HStack(spacing: 8) {
            Text(selection.isEmpty ? String(localized: "\(visible.count) differences") : String(localized: "\(selection.count) selected"))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Copy → Right") { preview("Copy to right", actions.toRight) }
                .disabled(actions.toRight.isEmpty)
            Button("Copy ← Left") { preview("Copy to left", actions.toLeft) }
                .disabled(actions.toLeft.isEmpty)
            Menu("Sync") {
                Button("Two-way, including deletions (remembers the last sync)") { planTwoWay() }
                Divider()
                ForEach(DirectoryDiff.SyncMode.allCases) { mode in
                    Button(mode.title) {
                        syncPlan = SyncPreview(mode: mode, title: mode.title, actions: DirectoryDiff.plan(entries, mode: mode))
                    }
                }
                if TwoWaySync.loadBase(left: left, right: right) != nil {
                    Divider()
                    Button("Forget Remembered Sync State") { TwoWaySync.forget(left: left, right: right) }
                }
            }
            .fixedSize()
        }
        .controlSize(.small)
        .padding(10)
    }

    private func actions(for paths: Set<String>) -> (toRight: [DirectoryDiff.Action], toLeft: [DirectoryDiff.Action]) {
        let chosen = entries.filter { paths.contains($0.path) }
        let toRight = chosen.filter { $0.left != nil }.map { DirectoryDiff.Action(path: $0.path, kind: .copy(from: .left), bytes: $0.left?.size ?? 0) }
        let toLeft = chosen.filter { $0.right != nil }.map { DirectoryDiff.Action(path: $0.path, kind: .copy(from: .right), bytes: $0.right?.size ?? 0) }
        return (toRight, toLeft)
    }

    private func planTwoWay() {
        let (l, r, hidden) = (left, right, includeHidden)
        Task {
            do {
                let plan = try await Task.detached { try TwoWaySync.plan(left: l, right: r, includeHidden: hidden) }.value
                syncPlan = SyncPreview(mode: nil, title: "Two-way sync, including deletions", actions: plan.actions,
                                       conflicts: plan.conflicts, isFirstSync: plan.isFirstSync, remembersState: true)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func preview(_ title: String, _ actions: [DirectoryDiff.Action]) {
        syncPlan = SyncPreview(mode: nil, title: title, actions: actions)
    }

    private func reveal(_ paths: Set<String>, in root: URL) {
        let urls = paths.map { root.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    private func compare() async {
        compareTask?.cancel()
        loading = true
        let (l, r, content, hidden) = (left, right, byContent, includeHidden)
        let result = await Task.detached { Result { try DirectoryDiff.compare(left: l, right: r, byContent: content, includeHidden: hidden) } }.value
        loading = false
        switch result {
        case .success(let found):
            entries = found
            selection = selection.intersection(found.map(\.path))
        case .failure(let failure):
            error = failure.localizedDescription
        }
    }

    private func run(_ plan: SyncPreview) {
        let (l, r, actions) = (left, right, plan.actions)
        let (remembers, hidden) = (plan.remembersState, includeHidden)
        syncPlan = nil
        Task {
            do {
                let lane = (try? r.resourceValues(forKeys: [.volumeURLKey]).volume)?.path
                try await OperationCenter.shared.run("\(plan.title): \(l.lastPathComponent) ⇄ \(r.lastPathComponent)", undoTitle: "Sync", lane: lane) { progress in
                    try DirectoryDiff.execute(actions, left: l, right: r, progress: progress)
                    if remembers { try TwoWaySync.saveBase(left: l, right: r, includeHidden: hidden) }
                    return []
                }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            await compare()
        }
    }
}

/// Dry run: every step a sync will take, before anything changes.
private struct SyncPreviewSheet: View {
    let plan: CompareView.SyncPreview
    let left: URL
    let right: URL
    let onRun: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let copiesRight = plan.actions.filter { $0.kind == .copy(from: .left) }
        let copiesLeft = plan.actions.filter { $0.kind == .copy(from: .right) }
        let trashes = plan.actions.filter { if case .trash = $0.kind { return true }; return false }
        VStack(alignment: .leading, spacing: 12) {
            Text(plan.title).font(.title3.weight(.semibold))
            Text(summary(copiesRight.count, copiesLeft.count, trashes.count))
                .foregroundStyle(.secondary)
            if plan.remembersState {
                Label(plan.isFirstSync
                      ? String(localized: "First sync of these folders: nothing is deleted this time. From now on, files you delete on one side are deleted on the other too.")
                      : String(localized: "Uses the state remembered from the last sync to carry deletions over."),
                      systemImage: plan.isFirstSync ? "info.circle" : "clock.arrow.circlepath")
                    .font(.callout).foregroundStyle(.secondary)
            }
            List {
                if !plan.conflicts.isEmpty {
                    Section("Conflicts (\(plan.conflicts.count))") {
                        ForEach(plan.conflicts) { conflict in
                            VStack(alignment: .leading, spacing: 1) {
                                Label(conflict.path, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(1).truncationMode(.middle)
                                Text(conflict.resolution).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                section("Copy to \(right.lastPathComponent)", copiesRight, symbol: "arrow.right")
                section("Copy to \(left.lastPathComponent)", copiesLeft, symbol: "arrow.left")
                section("Move to Trash", trashes, symbol: "trash")
            }
            .frame(minHeight: 200, maxHeight: 360)
            Text("Items that get replaced or removed go to the Trash. The whole sync can be undone from the Timeline.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(plan.actions.isEmpty ? (plan.remembersState ? "Remember Current State" : "Nothing to Do") : String(localized: "Sync \(plan.actions.count) Items")) { onRun() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.actions.isEmpty && !plan.remembersState)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func summary(_ right: Int, _ left: Int, _ trash: Int) -> String {
        let bytes = plan.actions.reduce(0) { $0 + $1.bytes }
        let parts = [right > 0 ? "\(right) to copy →" : nil, left > 0 ? "\(left) to copy ←" : nil, trash > 0 ? "\(trash) to remove" : nil]
        let text = parts.compactMap { $0 }.joined(separator: " · ")
        return text.isEmpty ? "Already in sync." : text + (bytes > 0 ? " · \(Formatters.size(bytes))" : "")
    }

    @ViewBuilder
    private func section(_ title: String, _ actions: [DirectoryDiff.Action], symbol: String) -> some View {
        if !actions.isEmpty {
            Section {
                ForEach(actions) { action in
                    Label(action.path, systemImage: symbol).lineLimit(1).truncationMode(.middle)
                }
            } header: {
                Text(key: title) + Text(verbatim: " (\(actions.count))")
            }
        }
    }
}
