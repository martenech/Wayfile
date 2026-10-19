import SwiftUI
import UniformTypeIdentifiers

struct TabBarView: View {
    let state: WindowState
    @Binding var sidebarVisible: Bool

    var body: some View {
        HStack(spacing: 0) {
            if !sidebarVisible {
                // Sidebar hidden: the tabs start at the window edge, so make room for the traffic lights.
                Color.clear.frame(width: TitleBar.trafficLightsWidth)
            }
            SidebarToggleButton(isVisible: $sidebarVisible)
                .padding(.leading, 6)
            // Tabs at their natural width with "+" right after them; scroll only when they don't fit.
            ViewThatFits(in: .horizontal) {
                tabs
                ScrollView(.horizontal, showsIndicators: false) { tabs }
            }
            .layoutPriority(1)
            Button {
                state.newTab()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Tab (⌘T)")
            .padding(.trailing, 8)
            // Empty title-bar space still drags the window.
            WindowDragArea()
        }
        .frame(height: TitleBar.height)
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(state.tabs) { tab in
                TabChip(state: state, tab: tab, isSelected: tab.id == state.selectedTabID)
            }
        }
        .padding(.horizontal, 6)
    }
}

private struct TabChip: View {
    let state: WindowState
    let tab: TabState
    let isSelected: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.activePane.location.symbol)
                .foregroundStyle(.secondary)
            Text(tab.title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button {
                state.closeTab(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isSelected ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 120, maxWidth: 220, minHeight: 26)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color(nsColor: .controlBackgroundColor) : (isHovering ? Color.primary.opacity(0.06) : .clear))
                .shadow(color: .black.opacity(isSelected ? 0.12 : 0), radius: 1, y: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { state.selectedTabID = tab.id }
        .onHover { isHovering = $0 }
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first.flatMap(UUID.init(uuidString:)) else { return false }
            state.moveTab(id, before: tab.id)
            return true
        }
        .contextMenu {
            Button("New Tab") { state.newTab() }
            Button("Duplicate Tab") { state.duplicateTab(tab) }
            Divider()
            Button("Close Tab") { state.closeTab(tab) }
            Button("Close Other Tabs") { state.closeOtherTabs(tab) }
                .disabled(state.tabs.count < 2)
        }
    }
}

/// Flexible empty space that moves the window when dragged (the title bar is hidden).
private struct WindowDragArea: View {
    var body: some View {
        if #available(macOS 15.0, *) {
            Color.clear
                .frame(minWidth: 20, maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
        } else {
            Color.clear.frame(minWidth: 20, maxWidth: .infinity)
        }
    }
}
