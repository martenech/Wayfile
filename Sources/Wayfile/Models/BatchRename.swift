import Foundation
import ImageIO

/// Rules for renaming many items at once. Applied in order: find/replace → trim → case →
/// prefix/suffix → numbering → date.
struct BatchRenameRules: Codable, Equatable {
    enum CaseChange: String, Codable, CaseIterable, Identifiable {
        case none, lower, upper, title
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: return String(localized: "Keep")
            case .lower: return String(localized: "lowercase")
            case .upper: return String(localized: "UPPERCASE")
            case .title: return String(localized: "Title Case")
            }
        }
    }

    enum Position: String, Codable, CaseIterable, Identifiable {
        case before, after, replace
        var id: String { rawValue }
        var title: String {
            switch self {
            case .before: return String(localized: "Before name")
            case .after: return String(localized: "After name")
            case .replace: return String(localized: "Replace name")
            }
        }
    }

    enum DateSource: String, Codable, CaseIterable, Identifiable {
        case modified, created, photoTaken
        var id: String { rawValue }
        var title: String {
            switch self {
            case .modified: return String(localized: "Date modified")
            case .created: return String(localized: "Date created")
            case .photoTaken: return String(localized: "Photo taken (EXIF)")
            }
        }
    }

    var find = ""
    var replace = ""
    var useRegex = false
    var caseSensitive = false

    var trimWhitespace = false
    var caseChange: CaseChange = .none

    var prefix = ""
    var suffix = ""

    var numbering = false
    var numberStart = 1
    var numberStep = 1
    var numberPadding = 2
    var numberPosition: Position = .after
    var numberSeparator = " "

    var addDate = false
    var dateSource: DateSource = .modified
    var dateFormat = "yyyy-MM-dd"
    var datePosition: Position = .before
    var dateSeparator = " "

    /// Off by default: rules only touch the name, the extension is kept.
    var includeExtension = false

    var isEmpty: Bool { self == BatchRenameRules() }
}

struct BatchRenameItem {
    let url: URL
    let isDirectory: Bool
    let modified: Date
    let created: Date

    var name: String { url.lastPathComponent }

    init(url: URL, isDirectory: Bool, modified: Date, created: Date) {
        self.url = url
        self.isDirectory = isDirectory
        self.modified = modified
        self.created = created
    }

    init(_ item: FileItem) {
        self.init(url: item.url, isDirectory: item.isDirectory, modified: item.modified, created: item.created)
    }
}

struct BatchRenameRow: Identifiable {
    enum Status: Equatable {
        case unchanged, ok
        case conflict(String)
        case invalid(String)

        var isProblem: Bool {
            switch self {
            case .conflict, .invalid: return true
            default: return false
            }
        }
    }

    let url: URL
    let oldName: String
    let newName: String
    let status: Status

    var id: URL { url }
}

struct BatchRenameError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum BatchRename {
    /// The new name for one item. Throws only for an invalid regular expression.
    static func newName(for item: BatchRenameItem, index: Int, rules: BatchRenameRules) throws -> String {
        let name = item.name
        let ext = item.isDirectory ? "" : (name as NSString).pathExtension
        let keepsExtension = !rules.includeExtension && !ext.isEmpty
        var target = keepsExtension ? (name as NSString).deletingPathExtension : name

        if !rules.find.isEmpty {
            if rules.useRegex {
                let regex: NSRegularExpression
                do {
                    regex = try NSRegularExpression(pattern: rules.find, options: rules.caseSensitive ? [] : [.caseInsensitive])
                } catch {
                    throw BatchRenameError(message: "Invalid regular expression")
                }
                target = regex.stringByReplacingMatches(
                    in: target, range: NSRange(target.startIndex..., in: target), withTemplate: rules.replace
                )
            } else {
                target = target.replacingOccurrences(
                    of: rules.find, with: rules.replace, options: rules.caseSensitive ? [] : [.caseInsensitive]
                )
            }
        }

        if rules.trimWhitespace {
            target = target.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        }

        switch rules.caseChange {
        case .none: break
        case .lower: target = target.lowercased()
        case .upper: target = target.uppercased()
        case .title: target = target.capitalized
        }

        target = rules.prefix + target + rules.suffix

        if rules.numbering {
            let value = rules.numberStart + index * rules.numberStep
            let digits = String(abs(value))
            let padded = String(repeating: "0", count: max(rules.numberPadding - digits.count, 0)) + digits
            target = place(value < 0 ? "-" + padded : padded, in: target, position: rules.numberPosition, separator: rules.numberSeparator)
        }

        if rules.addDate {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = rules.dateFormat.isEmpty ? "yyyy-MM-dd" : rules.dateFormat
            let stamp = formatter.string(from: date(for: item, source: rules.dateSource))
            target = place(stamp, in: target, position: rules.datePosition, separator: rules.dateSeparator)
        }

        return keepsExtension ? target + "." + ext : target
    }

    private static func place(_ token: String, in name: String, position: BatchRenameRules.Position, separator: String) -> String {
        switch position {
        case .before: return name.isEmpty ? token : token + separator + name
        case .after: return name.isEmpty ? token : name + separator + token
        case .replace: return token
        }
    }

    static func date(for item: BatchRenameItem, source: BatchRenameRules.DateSource) -> Date {
        switch source {
        case .modified: return item.modified
        case .created: return item.created
        case .photoTaken: return photoDate(item.url) ?? item.created
        }
    }

    /// EXIF DateTimeOriginal ("yyyy:MM:dd HH:mm:ss"), if the file is a photo that has one.
    static func photoDate(_ url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }

    /// Preview with per-row status. `existingNames` maps a folder path to the names in it;
    /// pass nil to read folders from disk.
    static func preview(
        _ items: [BatchRenameItem], rules: BatchRenameRules, existingNames: [String: Set<String>]? = nil
    ) throws -> [BatchRenameRow] {
        let newNames = try items.enumerated().map { try newName(for: $1, index: $0, rules: rules) }

        // Names in each folder that stay put: everything on disk except the items being renamed.
        var occupied: [String: Set<String>] = [:]
        for item in items {
            let folder = item.url.deletingLastPathComponent().path
            if occupied[folder] == nil {
                let names = existingNames?[folder].map(Array.init)
                    ?? (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
                occupied[folder] = Set(names.map { $0.lowercased() })
            }
        }
        for item in items {
            occupied[item.url.deletingLastPathComponent().path]?.remove(item.name.lowercased())
        }

        // APFS/HFS+ are case-insensitive by default, so compare names case-insensitively.
        var seen: [String: Int] = [:]
        for (item, name) in zip(items, newNames) {
            seen[item.url.deletingLastPathComponent().path + "/" + name.lowercased(), default: 0] += 1
        }

        return zip(items, newNames).map { item, name in
            let folder = item.url.deletingLastPathComponent().path
            let status: BatchRenameRow.Status
            if name.isEmpty || name == "." || name == ".." {
                status = .invalid("Empty name")
            } else if name.contains("/") {
                status = .invalid("Contains “/”")
            } else if name == item.name {
                status = .unchanged
            } else if (seen[folder + "/" + name.lowercased()] ?? 0) > 1 {
                status = .conflict("Same name as another renamed item")
            } else if occupied[folder]?.contains(name.lowercased()) == true {
                status = .conflict("An item with this name already exists")
            } else {
                status = .ok
            }
            return BatchRenameRow(url: item.url, oldName: item.name, newName: name, status: status)
        }
    }

    /// Renames the changed rows in two passes (to temporary names, then to the final ones) so swaps
    /// like a↔b and case-only changes work. Undo reverses both passes as a single step.
    static func apply(_ rows: [BatchRenameRow], progress: OperationProgress) throws -> [URL] {
        let changes = rows.filter { $0.status == .ok }
        guard rows.allSatisfy({ !$0.status.isProblem }) else {
            throw BatchRenameError(message: "Fix the conflicts before renaming.")
        }
        let fm = FileManager.default
        progress.setTotals(bytes: 0, items: changes.count)

        var toTemporary: [MovedItem] = []
        var toFinal: [MovedItem] = []
        // Whatever succeeded is recorded even if a later step fails, so undo can put it back.
        defer {
            if let record = UndoRecord.combine([toTemporary.isEmpty ? nil : UndoRecord.moved(toTemporary),
                                                toFinal.isEmpty ? nil : UndoRecord.moved(toFinal)].compactMap { $0 }) {
                progress.record(record)
            }
        }

        do {
            for row in changes {
                try progress.checkCancelled()
                let temporary = row.url.deletingLastPathComponent().appendingPathComponent(".wayfile-rename-\(UUID().uuidString)")
                try fm.moveItem(at: row.url, to: temporary)
                toTemporary.append(MovedItem(from: row.url, to: temporary))
            }
            for (row, moved) in zip(changes, toTemporary) {
                progress.begin(row.newName)
                let final = row.url.deletingLastPathComponent().appendingPathComponent(row.newName)
                try fm.moveItem(at: moved.to, to: final)
                toFinal.append(MovedItem(from: moved.to, to: final))
                progress.finishItem(baseline: 0, size: 0)
            }
        } catch {
            // Never leave items under hidden temporary names: put back everything not yet finished.
            for moved in toTemporary[toFinal.count...] {
                try? fm.moveItem(at: moved.to, to: moved.from)
            }
            toTemporary.removeSubrange(toFinal.count...)
            throw error
        }
        return toFinal.map(\.to)
    }
}
