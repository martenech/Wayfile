import Foundation
import Observation

/// Cards the Home dashboard can show.
enum HomeWidget: String, CaseIterable, Identifiable, Codable {
    case quickAccess, recentFiles, drives, cloudStorage, pinnedProjects, gitRepositories, tags, transferQueue
    case notes, scripts, smartCollections, timeline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quickAccess: return String(localized: "Quick Access")
        case .recentFiles: return String(localized: "Recent Files")
        case .drives: return String(localized: "Drives")
        case .cloudStorage: return String(localized: "Cloud Storage")
        case .pinnedProjects: return String(localized: "Pinned Projects")
        case .gitRepositories: return String(localized: "Git Repositories")
        case .tags: return String(localized: "Tags")
        case .transferQueue: return String(localized: "Transfer Queue")
        case .notes: return String(localized: "Notes")
        case .scripts: return String(localized: "Scripts")
        case .smartCollections: return String(localized: "Smart Collections")
        case .timeline: return String(localized: "Recent Activity")
        }
    }

    var symbol: String {
        switch self {
        case .quickAccess: return "pin.fill"
        case .recentFiles: return "clock"
        case .drives: return "internaldrive"
        case .cloudStorage: return "cloud.fill"
        case .pinnedProjects: return "folder.fill"
        case .gitRepositories: return "arrow.triangle.branch"
        case .tags: return "tag"
        case .transferQueue: return "arrow.left.arrow.right"
        case .notes: return "note.text"
        case .scripts: return "gearshape.2"
        case .smartCollections: return "sparkles.rectangle.stack"
        case .timeline: return "clock.arrow.circlepath"
        }
    }

    var summary: String {
        switch self {
        case .quickAccess: return String(localized: "Your favourite folders, one click away")
        case .recentFiles: return String(localized: "Files you opened lately")
        case .drives: return String(localized: "Disks with free space, network")
        case .cloudStorage: return String(localized: "iCloud, Google Drive, Dropbox, OneDrive")
        case .pinnedProjects: return String(localized: "Folders you work in, with their type")
        case .gitRepositories: return String(localized: "Branch and changes of your repositories")
        case .tags: return String(localized: "Jump to files by tag")
        case .transferQueue: return String(localized: "Copies and moves in progress")
        case .notes: return String(localized: "A scratchpad that's always here")
        case .scripts: return String(localized: "Run your scripts")
        case .smartCollections: return String(localized: "Recent documents, screenshots, large files…")
        case .timeline: return String(localized: "What you changed lately, with undo")
        }
    }

    /// Rough height in points, for spreading cards over columns.
    var estimatedHeight: Double {
        switch self {
        case .quickAccess: return 190
        case .recentFiles: return 290
        case .drives, .cloudStorage, .pinnedProjects, .gitRepositories, .scripts, .smartCollections, .timeline: return 260
        case .tags, .transferQueue: return 150
        case .notes: return 220
        }
    }
}

/// Ready-made dashboards.
enum HomePreset: String, CaseIterable, Identifiable, Codable {
    case everyday, developer, minimal, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .everyday: return String(localized: "Everyday")
        case .developer: return String(localized: "Developer")
        case .minimal: return String(localized: "Minimal")
        case .custom: return String(localized: "Custom")
        }
    }
    var symbol: String {
        switch self {
        case .everyday: return "desktopcomputer"
        case .developer: return "chevron.left.forwardslash.chevron.right"
        case .minimal: return "square.dashed"
        case .custom: return "slider.horizontal.3"
        }
    }
    var widgets: [HomeWidget] {
        switch self {
        case .everyday: return [.quickAccess, .recentFiles, .pinnedProjects, .drives, .cloudStorage, .tags, .transferQueue]
        case .developer: return [.quickAccess, .gitRepositories, .pinnedProjects, .recentFiles, .scripts, .transferQueue, .drives, .notes]
        case .minimal: return [.quickAccess, .recentFiles, .drives]
        case .custom: return []
        }
    }
}

@MainActor
@Observable
final class HomeConfig {
    static let shared = HomeConfig()

    /// Visible cards in order.
    var widgets: [HomeWidget] { didSet { save() } }
    var projects: [URL] { didSet { save() } }
    var notes: String { didSet { defaults.set(notes, forKey: "home.notes") } }
    var showGreeting: Bool { didSet { save() } }
    /// Name in the greeting; empty = first name from the user account.
    var displayName: String { didSet { defaults.set(displayName, forKey: "home.name") } }
    var showQuote: Bool { didSet { save() } }
    /// Optional picture behind the greeting.
    var backgroundImage: URL? { didSet { save() } }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        widgets = (defaults.stringArray(forKey: "home.widgets") ?? []).compactMap(HomeWidget.init(rawValue:))
        if defaults.stringArray(forKey: "home.widgets") == nil { widgets = HomePreset.everyday.widgets }
        projects = (defaults.stringArray(forKey: "home.projects") ?? []).map { URL(fileURLWithPath: $0, isDirectory: true).normalizedDirectory }
        notes = defaults.string(forKey: "home.notes") ?? ""
        showGreeting = defaults.object(forKey: "home.greeting") as? Bool ?? true
        displayName = defaults.string(forKey: "home.name") ?? ""
        showQuote = defaults.object(forKey: "home.quote") as? Bool ?? true
        backgroundImage = defaults.string(forKey: "home.background").map { URL(fileURLWithPath: $0) }
    }

    var preset: HomePreset {
        HomePreset.allCases.first { $0 != .custom && $0.widgets == widgets } ?? .custom
    }

    func apply(_ preset: HomePreset) {
        guard preset != .custom else { return }
        widgets = preset.widgets
    }

    func isShown(_ widget: HomeWidget) -> Bool { widgets.contains(widget) }

    func setShown(_ widget: HomeWidget, _ shown: Bool) {
        if shown { if !widgets.contains(widget) { widgets.append(widget) } } else { widgets.removeAll { $0 == widget } }
    }

    func move(_ widget: HomeWidget, by offset: Int) {
        guard let index = widgets.firstIndex(of: widget) else { return }
        let target = min(max(index + offset, 0), widgets.count - 1)
        guard target != index else { return }
        widgets.remove(at: index)
        widgets.insert(widget, at: target)
    }

    /// Drag & drop: put `widget` just before `target`.
    func move(_ widget: HomeWidget, before target: HomeWidget) {
        guard widget != target, let from = widgets.firstIndex(of: widget), widgets.contains(target) else { return }
        var updated = widgets
        updated.remove(at: from)
        updated.insert(widget, at: updated.firstIndex(of: target)!)
        widgets = updated
    }

    func reset() {
        widgets = HomePreset.everyday.widgets
        showGreeting = true
        showQuote = true
        backgroundImage = nil
    }

    func pinProject(_ url: URL) {
        let normalized = url.normalizedDirectory
        if !isProject(normalized) { projects.append(normalized) }
    }

    func unpinProject(_ url: URL) { projects.removeAll { $0.normalizedDirectory == url.normalizedDirectory } }

    func isProject(_ url: URL) -> Bool { projects.contains { $0.normalizedDirectory == url.normalizedDirectory } }

    private func save() {
        defaults.set(widgets.map(\.rawValue), forKey: "home.widgets")
        defaults.set(projects.map(\.path), forKey: "home.projects")
        defaults.set(showGreeting, forKey: "home.greeting")
        defaults.set(showQuote, forKey: "home.quote")
        defaults.set(backgroundImage?.path, forKey: "home.background")
    }

    // MARK: Layout

    /// Masonry: each card goes to the currently shortest column, keeping the user's order roughly left-to-right.
    static func columns(for widgets: [HomeWidget], count: Int) -> [[HomeWidget]] {
        guard count > 1 else { return [widgets] }
        var columns = Array(repeating: [HomeWidget](), count: count)
        var heights = Array(repeating: 0.0, count: count)
        for widget in widgets {
            let index = heights.indices.min { heights[$0] < heights[$1] - 1 || (abs(heights[$0] - heights[$1]) <= 1 && $0 < $1) }!
            columns[index].append(widget)
            heights[index] += widget.estimatedHeight
        }
        return columns
    }

    /// "Good morning / afternoon / evening".
    static func greeting(at date: Date = Date(), calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<12: return String(localized: "Good morning")
        case 12..<18: return String(localized: "Good afternoon")
        case 18..<23: return String(localized: "Good evening")
        default: return String(localized: "Good night")
        }
    }

    static let quotes = [
        String(localized: "A well organized workspace is a calmer mind."),
        String(localized: "Simplicity is the ultimate sophistication."),
        String(localized: "Clutter is just postponed decisions."),
        String(localized: "Find it fast. Get back to work."),
        String(localized: "Order is the shape upon which beauty depends."),
        String(localized: "A place for everything, everything in its place."),
    ]

    /// Same quote all day, a different one tomorrow.
    static func quote(for date: Date = Date(), calendar: Calendar = .current) -> String {
        let day = calendar.ordinality(of: .day, in: .era, for: date) ?? 0
        return quotes[day % quotes.count]
    }
}
