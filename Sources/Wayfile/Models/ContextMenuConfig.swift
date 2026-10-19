import Foundation
import Observation

/// Groups of the item context menu, separated by dividers; their order is customizable.
enum ContextMenuSection: String, Codable, CaseIterable, Identifiable {
    case open, typeSpecific, edit, path, transfer, organize, info

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: return String(localized: "Open")
        case .typeSpecific: return String(localized: "For the File Type")
        case .edit: return String(localized: "Edit")
        case .path: return String(localized: "Path & Tools")
        case .transfer: return String(localized: "Clipboard & Transfer")
        case .organize: return String(localized: "Organize")
        case .info: return String(localized: "Info")
        }
    }

    var items: [ContextMenuItem] { ContextMenuItem.allCases.filter { $0.section == self } }
}

/// Context menu entries that can be hidden (Open, Rename, Trash, Cut/Copy and Get Info always stay).
enum ContextMenuItem: String, Codable, CaseIterable, Identifiable {
    case openWith, openInTabs, quickLook
    case imageActions, packageContents, openInEditor, scripts, askAI
    case duplicate
    case copyPath, checksum, terminal, compare, findDuplicates, showInFinder, developer
    case dropStack, copyMoveTo, otherPane
    case compress, tags, favorites, links, security

    var id: String { rawValue }

    var section: ContextMenuSection {
        switch self {
        case .openWith, .openInTabs, .quickLook: return .open
        case .imageActions, .packageContents, .openInEditor, .scripts, .askAI: return .typeSpecific
        case .duplicate: return .edit
        case .copyPath, .checksum, .terminal, .compare, .findDuplicates, .showInFinder, .developer: return .path
        case .dropStack, .copyMoveTo, .otherPane: return .transfer
        case .compress, .tags, .favorites, .links, .security: return .organize
        }
    }

    /// Feature module the entry belongs to (hidden when the module is off).
    var module: FeatureModule? {
        switch self {
        case .scripts: return .automation
        case .developer, .openInEditor: return .developer
        case .security: return .security
        case .links: return .diskTools
        case .compare, .findDuplicates: return .compare
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .openWith: return String(localized: "Open With")
        case .openInTabs: return String(localized: "Open in New Tab / Other Pane")
        case .quickLook: return String(localized: "Quick Look")
        case .imageActions: return String(localized: "Image actions (desktop picture, rotate, convert)")
        case .packageContents: return String(localized: "Show Package Contents")
        case .openInEditor: return String(localized: "Open in code editor")
        case .scripts: return String(localized: "Scripts & Shortcuts")
        case .askAI: return String(localized: "Ask AI / Search with AI")
        case .duplicate: return String(localized: "Duplicate")
        case .copyPath: return String(localized: "Copy Path (and other formats)")
        case .checksum: return String(localized: "Copy SHA-256")
        case .terminal: return String(localized: "Open in Terminal")
        case .compare: return String(localized: "Compare With…")
        case .findDuplicates: return String(localized: "Find Duplicates…")
        case .showInFinder: return String(localized: "Show in Finder")
        case .developer: return String(localized: "Compare files, git changes & history")
        case .dropStack: return String(localized: "Add to Drop Stack")
        case .copyMoveTo: return String(localized: "Copy To / Move To")
        case .otherPane: return String(localized: "Copy / Move to other pane")
        case .compress: return String(localized: "Compress / Extract / Browse Archive")
        case .tags: return String(localized: "Tags")
        case .favorites: return String(localized: "Add to Favorites")
        case .links: return String(localized: "Make symbolic / hard link")
        case .security: return String(localized: "Permissions, quarantine, administrator")
        }
    }
}

@MainActor
@Observable
final class ContextMenuConfig {
    static let shared = ContextMenuConfig()

    var order: [ContextMenuSection] { didSet { save() } }
    var hidden: Set<ContextMenuItem> { didSet { save() } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = (defaults.stringArray(forKey: "contextMenu.order") ?? []).compactMap(ContextMenuSection.init(rawValue:))
        // Sections added in later versions go to their default place at the end.
        order = saved + ContextMenuSection.allCases.filter { !saved.contains($0) }
        hidden = Set((defaults.stringArray(forKey: "contextMenu.hidden") ?? []).compactMap(ContextMenuItem.init(rawValue:)))
    }

    func shows(_ item: ContextMenuItem) -> Bool {
        !hidden.contains(item) && (item.module.map { Features.shared.isOn($0) } ?? true)
    }

    func setShown(_ item: ContextMenuItem, _ shown: Bool) {
        if shown { hidden.remove(item) } else { hidden.insert(item) }
    }

    func move(_ section: ContextMenuSection, by offset: Int) {
        guard let index = order.firstIndex(of: section) else { return }
        let target = index + offset
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
    }

    func reset() {
        order = ContextMenuSection.allCases
        hidden = []
    }

    private func save() {
        defaults.set(order.map(\.rawValue), forKey: "contextMenu.order")
        defaults.set(hidden.map(\.rawValue), forKey: "contextMenu.hidden")
    }
}
