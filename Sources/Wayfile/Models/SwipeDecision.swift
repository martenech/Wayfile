import CoreGraphics

/// When a horizontal two-finger scroll should become back/forward navigation (testable without events).
enum SwipeDecision {
    struct Room: Equatable {
        var offset: CGFloat
        var visibleWidth: CGFloat
        var contentWidth: CGFloat
    }

    /// Clearly sideways, not a diagonal or vertical scroll.
    static func isHorizontalStart(dx: CGFloat, dy: CGFloat) -> Bool {
        abs(dx) > 0.5 && abs(dx) > abs(dy) * 1.5
    }

    /// Scrolling content right (dx > 0) is "back" and needs the view at its left edge; dx < 0 needs the right edge.
    static func navigates(dx: CGFloat, room: Room?) -> Bool {
        guard let room, room.contentWidth > room.visibleWidth + 1 else { return true }   // nothing to scroll sideways
        if dx > 0 { return room.offset <= 0.5 }
        return room.offset + room.visibleWidth >= room.contentWidth - 0.5
    }
}
