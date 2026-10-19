import Foundation

enum Location: Hashable, Codable {
    case home
    case folder(URL)
    case search(SearchQuery)
    case tag(String)
    /// Files, apps and actions in chronological order.
    case timeline
    /// Former undo-history view; kept so saved sessions still decode — shows the Timeline.
    case activity

    static func folderAt(_ url: URL) -> Location { .folder(url.normalizedDirectory) }

    var folderURL: URL? {
        if case .folder(let url) = self { return url }
        return nil
    }

    var title: String {
        switch self {
        case .home: return String(localized: "Home")
        case .timeline: return String(localized: "Timeline")
        case .activity: return String(localized: "Timeline")
        case .folder(let url): return url.displayName
        case .search(let query): return query.title
        case .tag(let name): return name
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .timeline: return "clock"
        case .activity: return "clock"
        case .folder: return "folder"
        case .search: return "magnifyingglass"
        case .tag: return "tag"
        }
    }
}

enum LayoutMode: String, CaseIterable, Identifiable, Codable {
    case details, list, grid, cards, columns

    var id: String { rawValue }

    var title: String {
        switch self {
        case .details: return String(localized: "Details")
        case .list: return String(localized: "List")
        case .grid: return String(localized: "Grid")
        case .cards: return String(localized: "Cards")
        case .columns: return String(localized: "Columns")
        }
    }

    var symbol: String {
        switch self {
        case .details: return "list.bullet.rectangle"
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        case .cards: return "rectangle.grid.1x2"
        case .columns: return "rectangle.split.3x1"
        }
    }

    /// Layouts whose item size the size slider controls.
    var supportsIconSize: Bool { self == .list || self == .grid || self == .cards }

    /// Layouts that can show group sections.
    var supportsGrouping: Bool { self != .columns }
}
