import SwiftUI

/// Status bar git controls: branch picker, ahead/behind with sync actions, open in editor.
struct GitStatusControls: View {
    let state: WindowState
    let git: GitInfo

    @State private var showBranches = false

    var body: some View {
        HStack(spacing: 2) {
            Button {
                showBranches.toggle()
            } label: {
                HoverHighlight {
                    Label(git.branch, systemImage: "arrow.triangle.branch")
                }
            }
            .buttonStyle(.plain)
            .help("Switch or create branch")
            .popover(isPresented: $showBranches, arrowEdge: .top) {
                BranchPicker(state: state, git: git) { showBranches = false }
            }

            Menu {
                Button("Pull", systemImage: "arrow.down") { state.gitPull(git.root) }
                    .disabled(git.upstream == nil)
                Button(git.upstream == nil ? String(localized: "Publish Branch") : String(localized: "Push"), systemImage: "arrow.up") { state.gitPush(git) }
                Button("Fetch", systemImage: "arrow.clockwise") { state.gitFetch(git.root) }
                    .disabled(git.upstream == nil)
                if let upstream = git.upstream {
                    Divider()
                    Text("Tracking \(upstream)")
                }
            } label: {
                HoverHighlight {
                    if git.upstream == nil {
                        Image(systemName: "icloud.and.arrow.up")
                    } else {
                        HStack(spacing: 4) {
                            Text("↑\(git.ahead)")
                            Text("↓\(git.behind)")
                        }
                        .monospacedDigit()
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(git.upstream == nil
                  ? String(localized: "Branch not published")
                  : String(localized: "\(String(localized: "\(git.ahead) commits")) to push, \(git.behind) to pull"))

            if git.changedCount > 0 {
                Text("\(git.changedCount) changed")
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 4)
                    .help(String(localized: "\(git.changedCount) changed items in this folder"))
            }

            let editors = Editors.installed
            if !editors.isEmpty {
                Menu {
                    ForEach(editors, id: \.url) { editor in
                        Button("Open in \(editor.name)") { Editors.open(git.root, with: editor.url) }
                    }
                    Divider()
                    Button("Open in Terminal") { state.openInTerminal(git.root) }
                    Button("Go to Repository Root") { state.activePane.navigate(to: .folderAt(git.root)) }
                } label: {
                    HoverHighlight { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                } primaryAction: {
                    Editors.open(git.root, with: editors[0].url)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Open \(git.repositoryName) in \(editors[0].name)")
            }
        }
    }
}

/// Searchable branch list; typing a new name offers to create it.
private struct BranchPicker: View {
    let state: WindowState
    let git: GitInfo
    let dismiss: () -> Void

    @State private var branches: [GitBranch] = []
    @State private var query = ""
    @FocusState private var focused: Bool

    private var filtered: [GitBranch] {
        query.isEmpty ? branches : branches.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var canCreate: Bool {
        let name = query.trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && !name.contains(" ") && !branches.contains { $0.name == name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Find or create a branch…", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit {
                    if canCreate { create() } else if let first = filtered.first { select(first) }
                }
                .padding(10)

            Divider()

            List {
                if canCreate {
                    Button { create() } label: {
                        Label("Create branch “\(query)” from \(git.branch)", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                }
                let local = filtered.filter { !$0.isRemote }
                let remote = filtered.filter(\.isRemote)
                if !local.isEmpty {
                    Section("Branches") {
                        ForEach(local) { row($0) }
                    }
                }
                if !remote.isEmpty {
                    Section("Remote") {
                        ForEach(remote) { row($0) }
                    }
                }
            }
            .listStyle(.plain)
        }
        .frame(width: 320, height: 360)
        .task {
            branches = await Git.branches(in: git.root)
            focused = true
        }
    }

    private func row(_ branch: GitBranch) -> some View {
        Button { select(branch) } label: {
            HStack {
                Image(systemName: branch.isRemote ? "cloud" : "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                Text(branch.name).lineLimit(1)
                Spacer()
                if branch.isCurrent { Image(systemName: "checkmark").foregroundStyle(Color.themeAccent) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(branch.isCurrent)
    }

    private func select(_ branch: GitBranch) {
        dismiss()
        guard !branch.isCurrent else { return }
        state.gitSwitch(to: branch, in: git.root)
    }

    private func create() {
        dismiss()
        state.promptText = query.trimmingCharacters(in: .whitespaces)
        state.prompt = .createBranch(git.root)
        state.commitPrompt()
    }
}

/// Coloured status letter used in tables and lists.
struct GitStatusBadge: View {
    let status: GitStatus

    var body: some View {
        Text(status.letter)
            .font(.caption.weight(.bold).monospaced())
            .foregroundStyle(status.color)
            .help(status.title)
            .accessibilityLabel("Git: \(status.title)")
    }
}
