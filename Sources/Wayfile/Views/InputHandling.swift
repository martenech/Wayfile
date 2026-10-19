import AppKit
import SwiftUI

/// Hands the hosting NSWindow to SwiftUI (for event monitors that must only act on their own window).
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(view.window) }
    }
}

/// Gestures and Vim keys for one window: three-finger swipe and mouse buttons 4/5 go back/forward,
/// pinch resizes items, and (when enabled) Vim-style keys drive the active pane.
@MainActor
final class WindowInputController {
    private weak var window: NSWindow?
    private let state: WindowState
    private var monitors: [Any] = []
    private var keyObserver: NSObjectProtocol?
    private var pending = ""
    private var pendingTime = Date.distantPast

    init(state: WindowState) { self.state = state }

    func attach(to window: NSWindow?) {
        guard let window, window !== self.window else { return }
        self.window = window
        detach()
        WindowState.lastActive = state
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { WindowState.lastActive = self?.state }
        }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.swipe, .otherMouseDown, .magnify, .scrollWheel]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleGesture(event) ? nil : event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, AppSettings.shared.vimMode else { return event }
            return self.handleVim(event) ? nil : event
        } as Any)
    }

    func detach() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
    }

    // MARK: Gestures

    private func handleGesture(_ event: NSEvent) -> Bool {
        let pane = state.activePane
        switch event.type {
        case .swipe:
            // Three-finger swipe: fingers moving right (deltaX > 0) means "back", like Safari.
            if event.deltaX > 0 { pane.goBack(); return true }
            if event.deltaX < 0 { pane.goForward(); return true }
        case .otherMouseDown:
            if event.buttonNumber == 3 { pane.goBack(); return true }
            if event.buttonNumber == 4 { pane.goForward(); return true }
        case .scrollWheel:
            return handleScrollSwipe(event)
        case .magnify:
            guard pane.layout.supportsIconSize else { return false }
            let range = PaneState.iconSizeRange
            pane.iconSize = min(max(pane.iconSize * (1 + event.magnification), range.lowerBound), range.upperBound)
            return true
        default:
            break
        }
        return false
    }

    /// Two-finger swipe (trackpad) for back/forward, like Safari. Only when the view under the pointer
    /// can't scroll further sideways in that direction, so wide tables still scroll horizontally.
    private func handleScrollSwipe(_ event: NSEvent) -> Bool {
        guard event.phase == .began, event.hasPreciseScrollingDeltas, NSEvent.isSwipeTrackingFromScrollEventsEnabled,
              SwipeDecision.isHorizontalStart(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY) else { return false }
        let scrollView = window?.contentView?.hitTest(event.locationInWindow)?.enclosingScrollView
        let room = scrollView.map { view -> SwipeDecision.Room in
            let content = view.contentView.bounds
            let width = view.documentView?.frame.width ?? content.width
            return SwipeDecision.Room(offset: content.minX, visibleWidth: content.width, contentWidth: width)
        }
        guard SwipeDecision.navigates(dx: event.scrollingDeltaX, room: room) else { return false }
        let pane = state.activePane
        let canGoBack = !pane.backStack.isEmpty, canGoForward = !pane.forwardStack.isEmpty
        var done = false
        event.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount],
                              dampenAmountThresholdMin: canGoForward ? -1 : 0, max: canGoBack ? 1 : 0) { amount, phase, isComplete, _ in
            guard phase == .ended, isComplete, !done else { return }
            done = true
            MainActor.assumeIsolated {
                // Fingers moving right (positive amount) go back.
                if amount > 0 { pane.goBack() } else if amount < 0 { pane.goForward() }
            }
        }
        return true
    }

    // MARK: Vim

    var pendingKeys: String { pending }

    private func handleVim(_ event: NSEvent) -> Bool {
        // Never steal keys from text fields, sheets or anything with ⌘/⌃/⌥.
        if window?.firstResponder is NSText { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        guard flags.isEmpty, let key = event.charactersIgnoringModifiers, key.count == 1 else { return false }
        if Date().timeIntervalSince(pendingTime) > 1 { pending = "" }
        let pane = state.activePane
        let sequence = pending + key
        pending = ""

        switch sequence {
        case "j": move(pane, by: 1)
        case "k": move(pane, by: -1)
        case "h": pane.goUp()
        case "l", "o": state.openSelection(in: pane)
        case "H": pane.goBack()
        case "L": pane.goForward()
        case "G": select(pane, index: pane.displayedItems.count - 1)
        case "gg": select(pane, index: 0)
        case "/": state.focusSearchField = true
        case "dd": state.trashSelection()
        case "yy": state.copySelection(cut: false)
        case "x": state.copySelection(cut: true)
        case "p": state.paste()
        case "r": state.beginRename()
        case "u": state.undo()
        case "t": state.newTab(pane.location)
        case "g", "d", "y":
            pending = sequence
            pendingTime = Date()
        default:
            return false
        }
        state.vimPending = pending
        return true
    }

    private func move(_ pane: PaneState, by offset: Int) {
        let items = pane.displayedItems
        guard !items.isEmpty else { return }
        let current = items.lastIndex { pane.selection.contains($0.url) }
        let next = current.map { min(max($0 + offset, 0), items.count - 1) } ?? (offset > 0 ? 0 : items.count - 1)
        select(pane, index: next)
    }

    private func select(_ pane: PaneState, index: Int) {
        guard pane.displayedItems.indices.contains(index) else { return }
        pane.selection = [pane.displayedItems[index].url]
    }
}
