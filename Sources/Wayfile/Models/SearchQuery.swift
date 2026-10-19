import Foundation
import UniformTypeIdentifiers

/// A search with filters; also the payload of saved searches (and later Smart Collections).
struct SearchQuery: Codable, Hashable {
    enum Scope: Codable, Hashable {
        /// Only the folder itself, not its subfolders.
        case folder(URL)
        case subfolders(URL)
        case everywhere

        var root: URL? {
            switch self {
            case .folder(let url), .subfolders(let url): return url
            case .everywhere: return nil
            }
        }
    }

    enum Engine: String, Codable, CaseIterable, Identifiable {
        /// Fast, uses the Spotlight index (misses unindexed and excluded folders).
        case spotlight
        /// Walks the folder itself: slower, but sees everything (code folders, network drives).
        case scan
        var id: String { rawValue }
        var title: String { self == .spotlight ? "Spotlight" : "Scan Files" }
    }

    enum DateField: String, Codable, CaseIterable, Identifiable {
        case modified, created
        var id: String { rawValue }
        var title: String { self == .modified ? "Modified" : "Created" }
    }

    enum DateRange: Codable, Hashable {
        case anyTime, today, last7Days, last30Days, thisYear
        case between(Date, Date)

        static let presets: [DateRange] = [.anyTime, .today, .last7Days, .last30Days, .thisYear]

        var title: String {
            switch self {
            case .anyTime: return String(localized: "Any time")
            case .today: return String(localized: "Today")
            case .last7Days: return String(localized: "Last 7 days")
            case .last30Days: return String(localized: "Last 30 days")
            case .thisYear: return String(localized: "This year")
            case .between(let from, let to):
                return String(localized: "\(from.formatted(date: .abbreviated, time: .omitted)) – \(to.formatted(date: .abbreviated, time: .omitted))")
            }
        }

        /// Start (inclusive) and end (exclusive) of the range, or nil for "any time".
        func interval(now: Date = Date(), calendar: Calendar = .current) -> (Date, Date)? {
            let startOfToday = calendar.startOfDay(for: now)
            let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
            switch self {
            case .anyTime: return nil
            case .today: return (startOfToday, endOfToday)
            case .last7Days: return (calendar.date(byAdding: .day, value: -6, to: startOfToday)!, endOfToday)
            case .last30Days: return (calendar.date(byAdding: .day, value: -29, to: startOfToday)!, endOfToday)
            case .thisYear:
                return (calendar.date(from: calendar.dateComponents([.year], from: now))!, endOfToday)
            case .between(let from, let to):
                return (calendar.startOfDay(for: from), calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to))!)
            }
        }
    }

    enum Kind: String, Codable, CaseIterable, Identifiable {
        case folder, image, video, audio, pdf, document, text, archive, application

        var id: String { rawValue }

        var title: String {
            switch self {
            case .folder: return String(localized: "Folders")
            case .image: return String(localized: "Images")
            case .video: return String(localized: "Videos")
            case .audio: return String(localized: "Audio")
            case .pdf: return String(localized: "PDFs")
            case .document: return String(localized: "Documents")
            case .text: return String(localized: "Text & Code")
            case .archive: return String(localized: "Archives")
            case .application: return String(localized: "Applications")
            }
        }

        var symbol: String {
            switch self {
            case .folder: return "folder"
            case .image: return "photo"
            case .video: return "film"
            case .audio: return "music.note"
            case .pdf: return "doc.richtext"
            case .document: return "doc.text"
            case .text: return "chevron.left.forwardslash.chevron.right"
            case .archive: return "archivebox"
            case .application: return "app"
            }
        }

        /// Uniform type identifiers a file may conform to (any of them) to count as this kind.
        var typeIdentifiers: [String] {
            switch self {
            case .folder: return ["public.folder"]
            case .image: return ["public.image"]
            case .video: return ["public.movie"]
            case .audio: return ["public.audio"]
            case .pdf: return ["com.adobe.pdf"]
            case .document:
                return ["public.rtf", "org.openxmlformats.openxml", "com.microsoft.word.doc", "com.microsoft.excel.xls",
                        "com.microsoft.powerpoint.ppt", "public.spreadsheet", "public.presentation",
                        "com.apple.iwork.pages.sffpages", "com.apple.iwork.numbers.sffnumbers", "com.apple.iwork.keynote.sffkey",
                        "org.oasis-open.opendocument.text"]
            case .text: return ["public.plain-text", "public.source-code", "public.script", "public.json", "public.xml"]
            case .archive: return ["public.archive", "public.zip-archive", "org.gnu.gnu-zip-archive", "public.disk-image"]
            case .application: return ["com.apple.application-bundle"]
            }
        }
    }

    enum TextMatch: String, Codable, CaseIterable, Identifiable {
        case plain, glob, regex
        var id: String { rawValue }
        var title: String {
            switch self {
            case .plain: return String(localized: "Text")
            case .glob: return String(localized: "Glob (*.pdf)")
            case .regex: return String(localized: "Regex")
            }
        }
    }

    var text = ""
    var textMatch: TextMatch = .plain
    var matchContent = false
    /// Files not opened for at least this many days (never-opened files count by their modification date).
    var notOpenedForDays: Int?
    /// Custom metadata filter: "key=value" (substring) or "key" (has the field). Needs scanning.
    var metadata: String?
    var kinds: Set<Kind> = []
    var minSize: Int64?
    var maxSize: Int64?
    var dateField: DateField = .modified
    var dateRange: DateRange = .anyTime
    var tags: Set<String> = []
    var scope: Scope = .everywhere
    var engine: Engine = .spotlight

    /// True when there is nothing to search for (no text and no filters).
    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty && kinds.isEmpty && minSize == nil && maxSize == nil
            && dateRange == .anyTime && tags.isEmpty && notOpenedForDays == nil && (metadata ?? "").isEmpty
    }

    /// Name test for the given text mode (case- and diacritic-insensitive). Invalid regexes match nothing.
    func nameMatches(_ name: String) -> Bool {
        let pattern = text.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return true }
        switch textMatch {
        case .plain:
            return name.range(of: pattern, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        case .glob:
            return fnmatch(pattern.lowercased(), name.lowercased(), 0) == 0
        case .regex:
            return name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    var isValidPattern: Bool {
        guard textMatch == .regex, !text.isEmpty else { return true }
        return (try? NSRegularExpression(pattern: text)) != nil
    }

    private enum CodingKeys: String, CodingKey {
        case text, textMatch, matchContent, notOpenedForDays, metadata, kinds, minSize, maxSize, dateField, dateRange, tags, scope, engine
    }

    init() {}

    /// Tolerates searches saved by older versions (fields added later fall back to defaults).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        textMatch = try c.decodeIfPresent(TextMatch.self, forKey: .textMatch) ?? .plain
        matchContent = try c.decodeIfPresent(Bool.self, forKey: .matchContent) ?? false
        notOpenedForDays = try c.decodeIfPresent(Int.self, forKey: .notOpenedForDays)
        metadata = try c.decodeIfPresent(String.self, forKey: .metadata)
        kinds = try c.decodeIfPresent(Set<Kind>.self, forKey: .kinds) ?? []
        minSize = try c.decodeIfPresent(Int64.self, forKey: .minSize)
        maxSize = try c.decodeIfPresent(Int64.self, forKey: .maxSize)
        dateField = try c.decodeIfPresent(DateField.self, forKey: .dateField) ?? .modified
        dateRange = try c.decodeIfPresent(DateRange.self, forKey: .dateRange) ?? .anyTime
        tags = try c.decodeIfPresent(Set<String>.self, forKey: .tags) ?? []
        scope = try c.decodeIfPresent(Scope.self, forKey: .scope) ?? .everywhere
        engine = try c.decodeIfPresent(Engine.self, forKey: .engine) ?? .spotlight
    }

    var title: String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return String(localized: "Search “\(trimmed)”") }
        if kinds.count == 1, let kind = kinds.first { return kind.title }
        return String(localized: "Search")
    }
}
