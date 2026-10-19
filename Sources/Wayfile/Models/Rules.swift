import Foundation
import UniformTypeIdentifiers

/// "When a file matching X is in folder Y, do Z." New files trigger it right away; age-based rules
/// are checked periodically; "Run Now" applies it to what is already there.
struct Rule: Codable, Identifiable, Hashable {
    enum Action: Codable, Hashable {
        case move(URL)
        case copy(URL)
        case trash
        case tag(String)
        /// Moves into a subfolder named after the kind ("Images", "Documents"…) inside the rule's folder.
        case sortByKind
        /// Moves into "<year>/<month>" subfolders by modification date.
        case sortByDate
        case runScript(String)

        var title: String {
            switch self {
            case .move(let url): return String(localized: "Move to \(url.lastPathComponent)")
            case .copy(let url): return String(localized: "Copy to \(url.lastPathComponent)")
            case .trash: return String(localized: "Move to Trash")
            case .tag(let name): return String(localized: "Tag “\(name)”")
            case .sortByKind: return String(localized: "Sort into kind folders")
            case .sortByDate: return String(localized: "Sort into year/month folders")
            case .runScript(let name): return String(localized: "Run script \(name)")
            }
        }
    }

    var id = UUID()
    var name = "New Rule"
    var enabled = true
    var folder: URL
    /// Name pattern; empty matches everything.
    var pattern = ""
    var patternMode: SearchQuery.TextMatch = .glob
    var kinds: Set<SearchQuery.Kind> = []
    var olderThanDays: Int?
    var minSize: Int64?
    var action: Action = .trash
    /// New matches wait in Automation → Rules until approved, instead of running right away.
    var requiresApproval = true

    init(folder: URL) {
        self.folder = folder
    }

    var isAgeBased: Bool { olderThanDays != nil }

    var summary: String {
        var parts: [String] = []
        if !pattern.isEmpty { parts.append("named \(pattern)") }
        if !kinds.isEmpty { parts.append(kinds.map(\.title).sorted().joined(separator: "/")) }
        if let days = olderThanDays { parts.append("older than \(days) days") }
        if let minSize { parts.append("over \(Formatters.size(minSize))") }
        let what = parts.isEmpty ? "Any file" : parts.joined(separator: ", ")
        return String(localized: "\(what) in \(folder.lastPathComponent) → \(action.title)")
    }
}

/// What a rule would do (or did) to one file: the simulator's line.
struct RuleStep: Identifiable, Hashable {
    let rule: Rule
    let url: URL
    /// Final location for moves/copies, nil otherwise.
    let destination: URL?
    var id: String { "\(rule.id)|\(url.path)" }

    var description: String {
        switch rule.action {
        case .move, .sortByKind, .sortByDate: return "\(url.lastPathComponent) → \(destination?.deletingLastPathComponent().path ?? "")"
        case .copy: return "Copy \(url.lastPathComponent) → \(destination?.deletingLastPathComponent().path ?? "")"
        case .trash: return "\(url.lastPathComponent) → Trash"
        case .tag(let name): return "Tag \(url.lastPathComponent) “\(name)”"
        case .runScript(let name): return "\(name) on \(url.lastPathComponent)"
        }
    }
}

enum RuleEngine {
    /// Files (not folders, packages count as files) directly in the rule's folder that match it.
    static func matches(_ rule: Rule, now: Date = Date()) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: rule.folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.filter { matches(rule, $0, now: now) }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func matches(_ rule: Rule, _ url: URL, now: Date = Date()) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey]) else { return false }
        if values.isDirectory == true && values.isPackage != true { return false }
        if FolderWatcher.isPartialDownload(url) { return false }
        if !rule.pattern.isEmpty {
            var query = SearchQuery()
            query.text = rule.pattern
            query.textMatch = rule.patternMode
            guard query.nameMatches(url.lastPathComponent) else { return false }
        }
        if !rule.kinds.isEmpty {
            guard let type = UTType(filenameExtension: url.pathExtension) ?? (values.isPackage == true ? .applicationBundle : nil),
                  rule.kinds.contains(where: { kind in kind.typeIdentifiers.contains { type.conforms(to: UTType($0) ?? .data) } })
            else { return false }
        }
        if let days = rule.olderThanDays {
            guard let modified = values.contentModificationDate, now.timeIntervalSince(modified) >= Double(days) * 86_400 else { return false }
        }
        if let minSize = rule.minSize, Int64(values.fileSize ?? 0) < minSize { return false }
        return true
    }

    /// The simulator: what running the rule on `files` would do.
    static func plan(_ rule: Rule, files: [URL]) -> [RuleStep] {
        files.map { RuleStep(rule: rule, url: $0, destination: destination(for: rule, $0)) }
    }

    static func destination(for rule: Rule, _ url: URL) -> URL? {
        switch rule.action {
        case .move(let dir), .copy(let dir): return dir.appendingPathComponent(url.lastPathComponent)
        case .sortByKind: return rule.folder.appendingPathComponent(kindFolder(for: url)).appendingPathComponent(url.lastPathComponent)
        case .sortByDate:
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            let parts = Calendar.current.dateComponents([.year, .month], from: modified)
            return rule.folder.appendingPathComponent(String(parts.year ?? 0))
                .appendingPathComponent(String(format: "%02d", parts.month ?? 1))
                .appendingPathComponent(url.lastPathComponent)
        case .trash, .tag, .runScript: return nil
        }
    }

    /// Folder name used by "sort into kind folders" and organization suggestions.
    static func kindFolder(for url: URL) -> String {
        let order: [SearchQuery.Kind] = [.image, .video, .audio, .pdf, .document, .archive, .application, .text]
        let type = UTType(filenameExtension: url.pathExtension)
        let kind = order.first { kind in
            kind.typeIdentifiers.contains { id in type?.conforms(to: UTType(id) ?? .data) == true }
        }
        switch kind {
        case .image: return "Images"
        case .video: return "Videos"
        case .audio: return "Audio"
        case .pdf, .document: return "Documents"
        case .archive: return "Archives"
        case .application: return "Applications"
        case .text: return "Text & Code"
        default: return "Other"
        }
    }

    /// Applies steps of file actions (scripts are run by the caller). Undo records go into `progress`.
    static func execute(_ steps: [RuleStep], progress: OperationProgress) throws -> [URL] {
        var results: [URL] = []
        for step in steps where FileManager.default.fileExists(atPath: step.url.path) {
            try progress.checkCancelled()
            switch step.rule.action {
            case .move, .sortByKind, .sortByDate, .copy:
                guard let dir = step.destination?.deletingLastPathComponent() else { continue }
                if !FileManager.default.fileExists(atPath: dir.path) {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    progress.record(.created([dir]))
                }
                let isCopy: Bool
                if case .copy = step.rule.action { isCopy = true } else { isCopy = false }
                results += try FileOps.transfer([step.url], to: dir, mode: isCopy ? .copy : .move, policy: .keepBoth, progress: progress)
            case .trash:
                _ = try FileOps.trash([step.url], progress: progress)
            case .tag(let name):
                let old = TagIO.read(step.url)
                guard !old.contains(where: { $0.name == name }) else { continue }
                let new = old + [TagIO.named(name)]
                try TagIO.write(new, to: step.url)
                progress.record(.tagged([TagChange(url: step.url, old: old, new: new)]))
                results.append(step.url)
            case .runScript:
                continue
            }
        }
        return results
    }
}

/// Folder-cleanup proposals: loose files grouped by kind, photos by year, stale installers, screenshots.
enum OrganizeSuggestions {
    struct Suggestion: Identifiable, Hashable {
        enum Kind: Hashable { case moveToFolder(String), trash }
        let id: String
        let title: String
        let detail: String
        let kind: Kind
        let files: [URL]
    }

    static func suggest(for folder: URL, now: Date = Date()) -> [Suggestion] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let files = urls.filter {
            let v = try? $0.resourceValues(forKeys: Set(keys))
            return !(v?.isDirectory == true && v?.isPackage != true)
        }
        var suggestions: [Suggestion] = []
        var used = Set<URL>()

        let screenshots = files.filter { name in
            let n = name.lastPathComponent
            return ["Screenshot", "Screen Shot", "Snímka obrazovky", "Bildschirmfoto", "Capture d’écran"].contains { n.hasPrefix($0) }
        }
        if screenshots.count >= 3 {
            suggestions.append(Suggestion(id: "screenshots", title: "Move \(screenshots.count) screenshots to “Screenshots”",
                                          detail: "Screenshots piling up in this folder", kind: .moveToFolder("Screenshots"), files: screenshots))
            used.formUnion(screenshots)
        }

        let installers = files.filter { url in
            guard ["dmg", "pkg", "mpkg"].contains(url.pathExtension.lowercased()), !used.contains(url) else { return false }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            return now.timeIntervalSince(modified) > 14 * 86_400
        }
        if !installers.isEmpty {
            let size = installers.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            suggestions.append(Suggestion(id: "installers", title: String(localized: "Trash \(installers.count) old installers"),
                                          detail: "Disk images and packages older than two weeks · \(Formatters.size(size))", kind: .trash, files: installers))
            used.formUnion(installers)
        }

        // Kind folders only pay off in a cluttered folder.
        let loose = files.filter { !used.contains($0) }
        if loose.count >= 12 {
            let grouped = Dictionary(grouping: loose, by: RuleEngine.kindFolder)
            for (name, group) in grouped.sorted(by: { $0.value.count > $1.value.count }) where group.count >= 3 && name != "Other" {
                suggestions.append(Suggestion(id: "kind-\(name)", title: "Move \(group.count) files to “\(name)”",
                                              detail: group.prefix(3).map(\.lastPathComponent).joined(separator: ", ") + (group.count > 3 ? "…" : ""),
                                              kind: .moveToFolder(name), files: group))
            }
        }
        return suggestions
    }

    static func apply(_ suggestion: Suggestion, in folder: URL, progress: OperationProgress) throws -> [URL] {
        switch suggestion.kind {
        case .trash:
            return try FileOps.trash(suggestion.files, progress: progress)
        case .moveToFolder(let name):
            let dir = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                progress.record(.created([dir]))
            }
            return try FileOps.transfer(suggestion.files, to: dir, mode: .move, policy: .keepBoth, progress: progress)
        }
    }
}
