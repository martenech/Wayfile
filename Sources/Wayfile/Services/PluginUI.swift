import Foundation

/// One element of a plugin's interface, as returned by its `render(ctx)` (built with the `ui.*` helpers).
/// Wayfile draws these natively; unknown types are shown as a note instead of failing.
struct PluginNode: Identifiable {
    enum Kind: String {
        case vstack, hstack, section, text, button, textField, toggle, picker, progress, row, list, image, badge, divider, spacer
    }

    let id: String
    let type: String
    let props: [String: Any]
    let children: [PluginNode]

    var kind: Kind? { Kind(rawValue: type) }

    /// Children get positional ids ("0.2.1") so SwiftUI keeps state stable across renders.
    init?(_ value: Any?, path: String = "0") {
        guard let dict = value as? [String: Any], let type = dict["type"] as? String else { return nil }
        self.id = path
        self.type = type
        var props = dict
        props["type"] = nil
        props["children"] = nil
        self.props = props
        let raw = dict["children"] as? [Any] ?? []
        children = raw.enumerated().compactMap { PluginNode($0.element, path: "\(path).\($0.offset)") }
    }

    func string(_ key: String) -> String? {
        switch props[key] {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    func double(_ key: String) -> Double? { (props[key] as? NSNumber)?.doubleValue }
    func bool(_ key: String) -> Bool { (props[key] as? NSNumber)?.boolValue ?? false }

    /// The control's id (text fields, toggles, pickers, buttons).
    var controlID: String? { string("id") }

    /// Rows of a `list`.
    var listItems: [PluginListItem] {
        (props["items"] as? [Any] ?? []).enumerated().compactMap { index, value in
            guard let dict = value as? [String: Any] else {
                return (value as? String).map { PluginListItem(index: index, title: $0) }
            }
            return PluginListItem(index: index, title: dict["title"] as? String ?? "", subtitle: dict["subtitle"] as? String,
                                  detail: dict["detail"] as? String ?? (dict["detail"] as? NSNumber)?.stringValue,
                                  symbol: dict["symbol"] as? String, path: dict["path"] as? String, action: dict["id"] as? String)
        }
    }

    /// Every input control with its initial value, for the form state.
    var inputs: [(id: String, value: Any)] {
        var found: [(String, Any)] = []
        if let id = controlID {
            switch kind {
            case .textField: found.append((id, string("value") ?? ""))
            case .toggle: found.append((id, bool("value")))
            case .picker: found.append((id, string("value") ?? (props["options"] as? [String])?.first ?? ""))
            default: break
            }
        }
        return found + children.flatMap(\.inputs)
    }
}

struct PluginListItem: Identifiable {
    let index: Int
    let title: String
    var subtitle: String?
    var detail: String?
    var symbol: String?
    var path: String?
    /// Clicking the row calls `action(id)`.
    var action: String?
    var id: Int { index }
}

/// What the user entered in a panel's controls. A value the plugin renders anew (it changed `value`)
/// replaces what was typed; otherwise typing is kept across renders.
struct PluginFormState {
    private(set) var values: [String: Any] = [:]
    private var rendered: [String: String] = [:]

    mutating func adopt(_ node: PluginNode) {
        for (id, value) in node.inputs {
            let fingerprint = "\(value)"
            if rendered[id] != fingerprint || values[id] == nil { values[id] = value }
            rendered[id] = fingerprint
        }
    }

    mutating func set(_ id: String, _ value: Any) { values[id] = value }

    func text(_ id: String) -> String { values[id] as? String ?? "" }
    func flag(_ id: String) -> Bool { values[id] as? Bool ?? false }
}
