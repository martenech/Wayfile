import SwiftUI

/// Shelf above the status bar: drop files in from anywhere, drag them out, or copy/move them all here.
struct DropStackBar: View {
    let state: WindowState

    private var store: DropStackStore { .shared }
    @State private var isTargeted = false

    var body: some View {
        let destination = state.activePane.location.folderURL
        HStack(spacing: 8) {
            Label("Drop Stack", systemImage: "tray.full")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()

            if store.items.isEmpty {
                Text("Drag files here to collect them, then copy or move them all at once.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(store.items, id: \.self) { url in
                            DropStackChip(url: url) { store.remove([url]) }
                        }
                    }
                }
                Text("\(store.items.count)").foregroundStyle(.secondary).monospacedDigit()
                Button("Copy Here") {
                    if let destination { state.transfer(store.items, to: destination, mode: .copy) }
                }
                .disabled(destination == nil)
                .help(destination.map { "Copy everything to “\($0.displayName)”" } ?? String(localized: "Open a folder first"))
                Button("Move Here") {
                    guard let destination else { return }
                    let moving = store.items
                    state.transfer(moving, to: destination, mode: .move) { store.remove(moving) }
                }
                .disabled(destination == nil)
                Button("Clear") { store.clear() }
            }
            Button { store.isVisible = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Hide the Drop Stack (its items are kept)")
                .accessibilityLabel("Hide the Drop Stack (its items are kept)")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(isTargeted ? Color.themeAccent.opacity(0.12) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            store.add(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .onAppear { store.prune() }
    }
}

private struct DropStackChip: View {
    let url: URL
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(nsImage: IconCache.icon(for: url)).resizable().frame(width: 16, height: 16)
            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle).frame(maxWidth: 140)
            if hovering {
                Button(action: onRemove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .accessibilityLabel("Remove from Drop Stack")
                    .buttonStyle(.plain)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .onHover { hovering = $0 }
        .draggable(url)
        .help(url.path)
    }
}
