import Foundation
import Observation

/// Groups of advanced tools that can be turned off to keep the app simple.
enum FeatureModule: String, CaseIterable, Identifiable, Codable {
    case automation, developer, remote, security, diskTools, compare

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automation: return String(localized: "Scripts & Automation")
        case .developer: return String(localized: "Developer Tools")
        case .remote: return String(localized: "Cloud Storage (S3)")
        case .security: return String(localized: "Permissions & Security")
        case .diskTools: return String(localized: "Disk & Archive Tools")
        case .compare: return String(localized: "Compare, Sync & Duplicates")
        }
    }

    var detail: String {
        switch self {
        case .automation: return String(localized: "Scripts, Shortcuts, rules, organization suggestions")
        case .developer: return String(localized: "Git window, project commands, Docker, compare files, developer links")
        case .remote: return String(localized: "S3, R2, MinIO browser (Connect to Server stays available)")
        case .security: return String(localized: "Permissions editor, ACLs, extended attributes, quarantine, encrypted vaults")
        case .diskTools: return String(localized: "Disk usage, archive browser, compression options, links, custom metadata")
        case .compare: return String(localized: "Folder compare & sync, duplicate finder, integrity fingerprints")
        }
    }

    var symbol: String {
        switch self {
        case .automation: return "gearshape.2"
        case .developer: return "chevron.left.forwardslash.chevron.right"
        case .remote: return "externaldrive.connected.to.line.below"
        case .security: return "lock.shield"
        case .diskTools: return "chart.pie"
        case .compare: return "arrow.left.arrow.right"
        }
    }
}

@MainActor
@Observable
final class Features {
    static let shared = Features()

    enum Mode: String, CaseIterable, Identifiable {
        /// Everyday file management; advanced tools hidden.
        case standard
        /// Everything on.
        case power
        /// Picked module by module.
        case custom

        var id: String { rawValue }
        var title: String {
            switch self {
            case .standard: return String(localized: "Standard")
            case .power: return String(localized: "Power")
            case .custom: return String(localized: "Custom")
            }
        }
    }

    private(set) var enabled: Set<FeatureModule>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.stringArray(forKey: "features.enabled") {
            enabled = Set(saved.compactMap(FeatureModule.init(rawValue:)))
        } else {
            enabled = Set(FeatureModule.allCases)
        }
    }

    static let standardModules: Set<FeatureModule> = [.compare]

    var mode: Mode {
        get {
            if enabled == Set(FeatureModule.allCases) { return .power }
            if enabled == Self.standardModules { return .standard }
            return .custom
        }
        set {
            switch newValue {
            case .standard: enabled = Self.standardModules
            case .power: enabled = Set(FeatureModule.allCases)
            case .custom: return
            }
            save()
        }
    }

    func isOn(_ module: FeatureModule) -> Bool { enabled.contains(module) }

    func set(_ module: FeatureModule, _ on: Bool) {
        if on { enabled.insert(module) } else { enabled.remove(module) }
        save()
    }

    private func save() { defaults.set(enabled.map(\.rawValue).sorted(), forKey: "features.enabled") }
}

/// Sidebar sections in the user's order; hidden ones are left out.
enum SidebarSection: String, CaseIterable, Identifiable, Codable {
    case home, favorites, cloud, locations, vaults, servers, workspaces, smartCollections, savedSearches, tags

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return String(localized: "Home & Timeline")
        case .favorites: return String(localized: "Favorites")
        case .cloud: return String(localized: "Cloud")
        case .locations: return String(localized: "Locations")
        case .vaults: return String(localized: "Vaults")
        case .servers: return String(localized: "Servers")
        case .workspaces: return String(localized: "Workspaces")
        case .smartCollections: return String(localized: "Smart Collections")
        case .savedSearches: return String(localized: "Saved Searches")
        case .tags: return String(localized: "Tags")
        }
    }
}

@MainActor
@Observable
final class SidebarConfig {
    static let shared = SidebarConfig()

    var order: [SidebarSection] { didSet { save() } }
    var hidden: Set<SidebarSection> { didSet { save() } }
    /// Single entries the user hid ("vol:/Volumes/X", "smart:largeFiles", "tag:Red"…).
    var hiddenItems: Set<String> { didSet { defaults.set(Array(hiddenItems), forKey: "sidebar.hiddenItems") } }
    /// Temporarily shows hidden sections and entries (dimmed) so they can be brought back.
    var revealHidden = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = (defaults.stringArray(forKey: "sidebar.order") ?? []).compactMap(SidebarSection.init(rawValue:))
        order = saved + SidebarSection.allCases.filter { !saved.contains($0) }
        hidden = Set((defaults.stringArray(forKey: "sidebar.hidden") ?? []).compactMap(SidebarSection.init(rawValue:)))
        hiddenItems = Set(defaults.stringArray(forKey: "sidebar.hiddenItems") ?? [])
    }

    var visibleSections: [SidebarSection] { revealHidden ? order : order.filter { !hidden.contains($0) } }

    func isHidden(_ item: String) -> Bool { hiddenItems.contains(item) }

    /// Whether an entry is listed right now (hidden ones only while revealing).
    func lists(_ item: String) -> Bool { revealHidden || !hiddenItems.contains(item) }

    /// A section with no listed rows isn't shown at all (it comes back while revealing hidden items).
    func listsAny(_ items: [String]) -> Bool { items.contains(where: lists) }

    func setItemHidden(_ item: String, _ hide: Bool) {
        if hide { hiddenItems.insert(item) } else { hiddenItems.remove(item) }
    }

    var hiddenCount: Int { hidden.count + hiddenItems.count }

    func move(_ section: SidebarSection, by offset: Int) {
        guard let index = order.firstIndex(of: section), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
    }

    func setVisible(_ section: SidebarSection, _ visible: Bool) {
        if visible { hidden.remove(section) } else { hidden.insert(section) }
    }

    func reset() {
        order = SidebarSection.allCases
        hidden = []
        hiddenItems = []
    }

    private func save() {
        defaults.set(order.map(\.rawValue), forKey: "sidebar.order")
        defaults.set(hidden.map(\.rawValue), forKey: "sidebar.hidden")
    }
}

/// Inspector sections the user turned off (Settings → Inspector).
@MainActor
@Observable
final class InspectorConfig {
    static let shared = InspectorConfig()
    static let sections = ["File Information", "Project", "Tags", "Quick Actions", "Links", "Custom Metadata", "Extended Attributes",
                           "Access Control", "Git", "Hashes", "Permissions", "More Metadata"]

    private(set) var hidden: Set<String> {
        didSet { UserDefaults.standard.set(Array(hidden), forKey: "inspector.hiddenSections") }
    }

    private init() { hidden = Set(UserDefaults.standard.stringArray(forKey: "inspector.hiddenSections") ?? []) }

    func isShown(_ title: String) -> Bool { !hidden.contains(title) }

    func setShown(_ title: String, _ shown: Bool) {
        if shown { hidden.remove(title) } else { hidden.insert(title) }
    }
}

extension FeatureModule {
    /// Feature module an action belongs to, from its id.
    static func forPaletteAction(_ id: String) -> FeatureModule? {
        let prefixes: [(String, FeatureModule)] = [
            ("automation", .automation), ("script.", .automation), ("shortcut.", .automation), ("organize", .automation),
            ("git.changes", .developer), ("git.log", .developer), ("project.", .developer), ("docker", .developer), ("compare.files", .developer),
            ("s3", .remote),
            ("vault", .security), ("permissions", .security),
            ("compare.panes", .compare), ("compare.with", .compare),
        ]
        return prefixes.first { id.hasPrefix($0.0) }?.1
    }
}

/// Palette commands used recently (most recent first), kept across launches.
@MainActor
final class PaletteHistory {
    static let shared = PaletteHistory()
    private(set) var recent: [String]
    private let defaults: UserDefaults
    static let limit = 8

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recent = defaults.stringArray(forKey: "palette.recent") ?? []
    }

    func record(_ id: String) {
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > Self.limit { recent.removeLast(recent.count - Self.limit) }
        defaults.set(recent, forKey: "palette.recent")
    }
}
