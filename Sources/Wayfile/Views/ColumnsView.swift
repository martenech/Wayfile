import SwiftUI

/// Miller columns: one column per folder from the anchor down to the pane's current folder.
/// The last column is the live pane listing, so selection, preview and commands work as usual;
/// picking a folder in any column navigates the pane there.
struct ColumnsView: View {
    let state: WindowState
    @Bindable var pane: PaneState

    private let columnWidth: CGFloat = 240

    var body: some View {
        let folders = pane.columnFolders
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(folders.enumerated()), id: \.element) { index, folder in
                        Group {
                            if index == folders.count - 1 {
                                currentColumn
                            } else {
                                AncestorColumn(state: state, pane: pane, folder: folder, highlighted: folders[index + 1])
                            }
                        }
                        .frame(width: columnWidth)
                        .id(folder)
                        Divider()
                    }
                }
            }
            .onChange(of: folders.last) { _, last in
                guard let last else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last, anchor: .trailing) }
            }
            .onAppear {
                // Wait for the first layout pass, otherwise there is nothing to scroll yet.
                guard let last = folders.last else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { proxy.scrollTo(last, anchor: .trailing) }
            }
        }
        .themedContentBackground()
    }

    private var currentColumn: some View {
        List(selection: Binding(
            get: { pane.selection },
            set: { newSelection in
                // A single folder click drills in, like Finder/Files column view.
                if newSelection.count == 1, let url = newSelection.first,
                   let item = pane.displayedItems.first(where: { $0.url == url }), item.isFolderLike {
                    pane.navigate(to: .folderAt(url))
                } else {
                    pane.selection = newSelection
                }
            }
        )) {
            ForEach(pane.displayedItems) { item in
                ColumnRow(item: item)
                    .tag(item.url)
                    .draggable(item.url)
            }
        }
        .listStyle(.plain)
        .themedContentBackground()
        .contextMenu(forSelectionType: URL.self) { urls in
            FileContextMenu(state: state, pane: pane, urls: urls)
        } primaryAction: { urls in
            pane.selection = urls
            state.openSelection(in: pane)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let dir = pane.location.folderURL else { return false }
            return state.drop(urls, into: dir)
        }
        .onKeyPress(.space) {
            state.toggleQuickLook()
            return .handled
        }
        .onKeyPress(.return) {
            state.handleReturnKey(in: pane)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            pane.goUp()
            return .handled
        }
        .overlay {
            if pane.displayedItems.isEmpty && !pane.isLoading {
                Text("Empty").foregroundStyle(.tertiary)
            }
        }
    }
}

/// A parent folder's column; its highlighted row is the folder shown in the next column.
private struct AncestorColumn: View {
    let state: WindowState
    let pane: PaneState
    let folder: URL
    let highlighted: URL

    @State private var items: [FileItem] = []

    var body: some View {
        List(selection: Binding<URL?>(
            get: { items.first { $0.url.standardizedFileURL.path == highlighted.standardizedFileURL.path }?.url },
            set: { url in
                guard let url, let item = items.first(where: { $0.url == url }) else { return }
                if item.isFolderLike {
                    pane.navigate(to: .folderAt(url))
                } else {
                    pane.navigate(to: .folderAt(folder))
                    pane.selection = [url]
                }
            }
        )) {
            ForEach(items) { item in
                ColumnRow(item: item)
                    .tag(item.url)
                    .draggable(item.url)
                    .dropDestination(for: URL.self) { urls, _ in
                        item.isFolderLike ? state.drop(urls, into: item.url) : false
                    }
            }
        }
        .listStyle(.plain)
        .themedContentBackground()
        .task(id: TaskKey(folder: folder, showHidden: pane.showHidden, foldersFirst: pane.foldersFirst)) {
            let url = folder
            let listing = await Task.detached { (try? FileSystem.list(url)) ?? [] }.value
            items = pane.arrange(listing)
            // Keep the column current while it is shown.
            for await _ in FolderMonitor.changes(of: url) {
                try? await Task.sleep(for: .milliseconds(150))
                let fresh = await Task.detached { (try? FileSystem.list(url)) ?? [] }.value
                items = pane.arrange(fresh)
            }
        }
    }

    private struct TaskKey: Equatable {
        let folder: URL
        let showHidden: Bool
        let foldersFirst: Bool
    }
}

private struct ColumnRow: View {
    let item: FileItem

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: IconCache.icon(for: item.url))
                .resizable()
                .frame(width: 16, height: 16)
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(item.isHidden ? 0.55 : 1)
            Spacer(minLength: 4)
            TagDots(tags: item.fileTags)
            if item.isFolderLike {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
