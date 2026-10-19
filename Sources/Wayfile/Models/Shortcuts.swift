import AppKit
import Observation
import SwiftUI

/// A key plus modifiers, storable and convertible to a SwiftUI `KeyboardShortcut`.
struct KeyCombo: Codable, Hashable {
    /// A lowercase character ("t", ".", "[") or a special key name ("up", "delete", "f2"…).
    var key: String
    var modifiers: Int

    static let command = 1, shift = 2, option = 4, control = 8

    /// Stored override meaning "no shortcut".
    static let none = KeyCombo(key: "", modifiers: 0)
    var isNone: Bool { key.isEmpty }

    init(key: String, modifiers: Int) {
        self.key = key
        self.modifiers = modifiers
    }

    init(_ key: String, _ modifiers: Int = KeyCombo.command) {
        self.init(key: key, modifiers: modifiers)
    }

    private static let specials: [String: (KeyEquivalent, String, UInt16)] = [
        "up": (.upArrow, "↑", 126), "down": (.downArrow, "↓", 125),
        "left": (.leftArrow, "←", 123), "right": (.rightArrow, "→", 124),
        "delete": (.delete, "⌫", 51), "forwardDelete": (.deleteForward, "⌦", 117),
        "tab": (.tab, "⇥", 48), "return": (.return, "↩", 36), "space": (.space, "Space", 49),
        "escape": (.escape, "⎋", 53), "home": (.home, "↖", 115), "end": (.end, "↘", 119),
        "pageUp": (.pageUp, "⇞", 116), "pageDown": (.pageDown, "⇟", 121),
    ]

    private static let functionKeyCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    var isFunctionKey: Bool { key.hasPrefix("f") && key.count > 1 && Int(key.dropFirst()) != nil }

    var keyEquivalent: KeyEquivalent? {
        if let special = Self.specials[key] { return special.0 }
        if isFunctionKey, let n = Int(key.dropFirst()), (1...12).contains(n),
           let scalar = UnicodeScalar(NSF1FunctionKey + n - 1) {
            return KeyEquivalent(Character(scalar))
        }
        guard key.count == 1, let char = key.first else { return nil }
        return KeyEquivalent(char)
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers & Self.command != 0 { result.insert(.command) }
        if modifiers & Self.shift != 0 { result.insert(.shift) }
        if modifiers & Self.option != 0 { result.insert(.option) }
        if modifiers & Self.control != 0 { result.insert(.control) }
        return result
    }

    var keyboardShortcut: KeyboardShortcut? {
        guard !isNone, let equivalent = keyEquivalent else { return nil }
        return KeyboardShortcut(equivalent, modifiers: eventModifiers)
    }

    var display: String {
        guard !isNone else { return "" }
        var text = ""
        if modifiers & Self.control != 0 { text += "⌃" }
        if modifiers & Self.option != 0 { text += "⌥" }
        if modifiers & Self.shift != 0 { text += "⇧" }
        if modifiers & Self.command != 0 { text += "⌘" }
        if let special = Self.specials[key] { return text + special.1 }
        return text + key.uppercased()
    }

    /// Builds a combo from a key press while recording. Printable keys need ⌘, ⌃ or ⌥ so they
    /// don't steal plain typing; function and navigation keys may stand alone.
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        var mods = 0
        if flags.contains(.command) { mods |= Self.command }
        if flags.contains(.shift) { mods |= Self.shift }
        if flags.contains(.option) { mods |= Self.option }
        if flags.contains(.control) { mods |= Self.control }

        if let index = Self.functionKeyCodes.firstIndex(of: event.keyCode) {
            self.init(key: "f\(index + 1)", modifiers: mods)
            return
        }
        if let special = Self.specials.first(where: { $0.value.2 == event.keyCode }) {
            guard special.key != "escape" else { return nil }
            self.init(key: special.key, modifiers: mods)
            return
        }
        guard mods & (Self.command | Self.control | Self.option) != 0,
              let char = event.characters(byApplyingModifiers: [])?.lowercased().first,
              !char.isWhitespace else { return nil }
        self.init(key: String(char), modifiers: mods)
    }
}

enum ShortcutAction: String, CaseIterable, Identifiable {
    // File
    case newTab, newFolder, newFile, open, properties, quickLook, rename, openTerminal, connectToServer, closeTab
    case copyToOtherPane, moveToOtherPane, duplicate, copyPath
    // Edit
    case undo, redo, cut, copy, paste, selectAll, trash, deletePermanently, selectMatching, invertSelection
    // View
    case commandPalette, layoutDetails, layoutList, layoutGrid, layoutCards, layoutColumns
    case previewPane, dualPane, hiddenFiles, refresh, nextTab, previousTab
    // Go
    case back, forward, enclosingFolder, home, desktop, documents, downloads, applications, goToPath, find, timeline
    // Tools
    case automation, toggleTerminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newTab: return String(localized: "New Tab")
        case .newFolder: return String(localized: "New Folder")
        case .newFile: return String(localized: "New File")
        case .open: return String(localized: "Open")
        case .properties: return String(localized: "Properties")
        case .quickLook: return String(localized: "Quick Look")
        case .rename: return String(localized: "Rename")
        case .openTerminal: return String(localized: "Open in Terminal")
        case .connectToServer: return String(localized: "Connect to Server")
        case .closeTab: return String(localized: "Close Tab")
        case .copyToOtherPane: return String(localized: "Copy to Other Pane")
        case .moveToOtherPane: return String(localized: "Move to Other Pane")
        case .duplicate: return String(localized: "Duplicate")
        case .copyPath: return String(localized: "Copy Path")
        case .undo: return String(localized: "Undo")
        case .redo: return String(localized: "Redo")
        case .cut: return String(localized: "Cut")
        case .copy: return String(localized: "Copy")
        case .paste: return String(localized: "Paste")
        case .selectAll: return String(localized: "Select All")
        case .selectMatching: return String(localized: "Select Matching")
        case .invertSelection: return String(localized: "Invert Selection")
        case .trash: return String(localized: "Move to Trash")
        case .deletePermanently: return String(localized: "Delete Permanently")
        case .commandPalette: return String(localized: "Command Palette")
        case .layoutDetails: return String(localized: "Details Layout")
        case .layoutList: return String(localized: "List Layout")
        case .layoutGrid: return String(localized: "Grid Layout")
        case .layoutCards: return String(localized: "Cards Layout")
        case .layoutColumns: return String(localized: "Columns Layout")
        case .previewPane: return String(localized: "Toggle Inspector")
        case .dualPane: return String(localized: "Toggle Dual Pane")
        case .hiddenFiles: return String(localized: "Toggle Hidden Files")
        case .refresh: return String(localized: "Refresh")
        case .nextTab: return String(localized: "Next Tab")
        case .previousTab: return String(localized: "Previous Tab")
        case .back: return String(localized: "Back")
        case .forward: return String(localized: "Forward")
        case .enclosingFolder: return String(localized: "Enclosing Folder")
        case .home: return String(localized: "Home")
        case .desktop: return String(localized: "Desktop")
        case .documents: return String(localized: "Documents")
        case .downloads: return String(localized: "Downloads")
        case .applications: return String(localized: "Applications")
        case .goToPath: return String(localized: "Go to Path")
        case .find: return String(localized: "Find")
        case .timeline: return String(localized: "Timeline")
        case .automation: return String(localized: "Automation")
        case .toggleTerminal: return String(localized: "Show / Hide Terminal")
        }
    }

    var category: String {
        switch self {
        case .newTab, .newFolder, .newFile, .open, .properties, .quickLook, .rename, .openTerminal, .connectToServer, .closeTab,
             .copyToOtherPane, .moveToOtherPane, .duplicate, .copyPath: return String(localized: "File")
        case .undo, .redo, .cut, .copy, .paste, .selectAll, .trash, .deletePermanently, .selectMatching, .invertSelection: return String(localized: "Edit")
        case .commandPalette, .layoutDetails, .layoutList, .layoutGrid, .layoutCards, .layoutColumns,
             .previewPane, .dualPane, .hiddenFiles, .refresh, .nextTab, .previousTab: return String(localized: "View")
        case .automation, .toggleTerminal: return String(localized: "Tools")
        default: return String(localized: "Go")
        }
    }

    var layout: LayoutMode? {
        switch self {
        case .layoutDetails: return .details
        case .layoutList: return .list
        case .layoutGrid: return .grid
        case .layoutCards: return .cards
        case .layoutColumns: return .columns
        default: return nil
        }
    }

    static func forLayout(_ mode: LayoutMode) -> ShortcutAction {
        allCases.first { $0.layout == mode }!
    }

    var defaultCombo: KeyCombo? {
        let cmd = KeyCombo.command, shift = KeyCombo.shift, opt = KeyCombo.option, ctrl = KeyCombo.control
        switch self {
        case .newTab: return KeyCombo("t")
        case .newFolder: return KeyCombo("n", cmd | shift)
        case .newFile: return KeyCombo("n", cmd | opt)
        case .open: return KeyCombo("down")
        case .properties: return KeyCombo("i")
        case .quickLook: return KeyCombo("y")
        case .rename: return KeyCombo("f2", 0)
        case .openTerminal: return KeyCombo("t", cmd | opt)
        case .connectToServer: return KeyCombo("k", cmd | shift)
        case .closeTab: return KeyCombo("w")
        case .copyToOtherPane: return KeyCombo("f5", 0)
        case .moveToOtherPane: return KeyCombo("f6", 0)
        case .duplicate: return KeyCombo("d")
        case .copyPath: return KeyCombo("c", cmd | opt)
        case .undo: return KeyCombo("z")
        case .redo: return KeyCombo("z", cmd | shift)
        case .cut: return KeyCombo("x")
        case .copy: return KeyCombo("c")
        case .paste: return KeyCombo("v")
        case .selectAll: return KeyCombo("a")
        case .selectMatching: return KeyCombo("a", cmd | opt)
        case .invertSelection: return KeyCombo("i", cmd | shift)
        case .trash: return KeyCombo("delete")
        case .deletePermanently: return KeyCombo("delete", cmd | opt)
        case .commandPalette: return KeyCombo("p", cmd | shift)
        case .layoutDetails: return KeyCombo("1")
        case .layoutList: return KeyCombo("2")
        case .layoutGrid: return KeyCombo("3")
        case .layoutCards: return KeyCombo("4")
        case .layoutColumns: return KeyCombo("5")
        case .previewPane: return KeyCombo("p", cmd | opt)
        case .dualPane: return KeyCombo("d", cmd | opt)
        case .hiddenFiles: return KeyCombo(".", cmd | shift)
        case .refresh: return KeyCombo("r")
        case .nextTab: return KeyCombo("tab", ctrl)
        case .previousTab: return KeyCombo("tab", ctrl | shift)
        case .back: return KeyCombo("[")
        case .forward: return KeyCombo("]")
        case .enclosingFolder: return KeyCombo("up")
        case .home: return KeyCombo("h", cmd | shift)
        case .desktop: return KeyCombo("d", cmd | shift)
        case .documents: return KeyCombo("o", cmd | shift)
        case .downloads: return KeyCombo("l", cmd | opt)
        case .applications: return KeyCombo("a", cmd | shift)
        case .goToPath: return KeyCombo("l")
        case .find: return KeyCombo("k")
        case .timeline: return KeyCombo("z", cmd | opt)
        case .automation: return KeyCombo("r", cmd | opt)
        case .toggleTerminal: return KeyCombo("`", ctrl)
        }
    }
}

@MainActor
@Observable
final class ShortcutStore {
    static let shared = ShortcutStore()

    private static let key = "shortcuts"

    /// Only user changes are stored; `KeyCombo.none` means the user removed the shortcut.
    private(set) var overrides: [String: KeyCombo]

    private init() {
        overrides = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: KeyCombo].self, from: $0) } ?? [:]
    }

    func combo(for action: ShortcutAction) -> KeyCombo? {
        if let override = overrides[action.rawValue] { return override.isNone ? nil : override }
        return action.defaultCombo
    }

    func keyboardShortcut(_ action: ShortcutAction) -> KeyboardShortcut? {
        combo(for: action)?.keyboardShortcut
    }

    func display(_ action: ShortcutAction) -> String {
        combo(for: action)?.display ?? ""
    }

    func isCustomized(_ action: ShortcutAction) -> Bool { overrides[action.rawValue] != nil }

    /// Another action already using `combo`, if any.
    func conflict(for combo: KeyCombo, excluding action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && self.combo(for: $0) == combo }
    }

    func set(_ combo: KeyCombo?, for action: ShortcutAction) {
        let value = combo ?? .none
        overrides[action.rawValue] = value == action.defaultCombo ? nil : value
        save()
    }

    func reset(_ action: ShortcutAction) {
        overrides[action.rawValue] = nil
        save()
    }

    func resetAll() {
        overrides.removeAll()
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(overrides), forKey: Self.key)
    }
}

extension View {
    /// Applies the user's (or default) shortcut for `action`.
    @MainActor
    func shortcut(_ action: ShortcutAction) -> some View {
        keyboardShortcut(ShortcutStore.shared.keyboardShortcut(action))
    }
}
