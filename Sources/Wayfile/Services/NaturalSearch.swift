import Foundation

/// Plain-language file search ("PDFs over 5 MB from last week in Downloads", "fotky z dovolenky na ploche"):
/// the configured language model (Settings → AI) turns the request into search filters.
enum NaturalSearch {
    struct Result: Equatable {
        var query: SearchQuery
        /// What was understood ("PDFs · over 5 MB · last 7 days · in Downloads").
        var summary: [String]
    }

    /// Where folder words point.
    struct Places: Sendable {
        var current: URL?
        var home = FileManager.default.homeDirectoryForCurrentUser
    }

    static let instructions = """
    You turn a request to find files on a Mac into JSON search filters. The request may be in any language (often Slovak or English).
    Reply with one JSON object only, no prose, with these keys:
    "text": words that should be in the file name (string, "" if none; never put file kinds, dates, sizes or folders here),
    "kinds": array from ["folder","image","video","audio","pdf","document","text","archive","application"],
    "minSizeMB": number or null, "maxSizeMB": number or null,
    "date": one of ["any","today","yesterday","last7days","last30days","thisYear"], or a year like "2024",
    "dateField": "modified" or "created",
    "tags": array of tag names,
    "folder": one of ["everywhere","current","home","desktop","documents","downloads","pictures"] ("current" = "here", "this folder"),
    "notOpenedDays": number or null (for "unused", "not opened for…"),
    "content": true only if the words must appear inside the files.
    Example: "large videos from this year on the desktop" → {"text":"","kinds":["video"],"minSizeMB":100,"maxSizeMB":null,"date":"thisYear","dateField":"modified","tags":[],"folder":"desktop","notOpenedDays":null,"content":false}
    """

    static func interpret(_ request: String, places: Places, tagNames: [String], configuration: AIConfiguration) async throws -> Result {
        let system = instructions + (tagNames.isEmpty ? "" : "\nTags that exist: \(tagNames.joined(separator: ", ")).")
        let answer = try await AIClient.complete(system: system, user: request, configuration: configuration)
        guard let result = query(fromModelJSON: answer, places: places, tagNames: tagNames) else {
            throw AIError(message: "The model didn’t return usable search filters. Try rephrasing, or another model.")
        }
        return result
    }

    /// Builds the search from the model's JSON (tolerates prose or code fences around it).
    static func query(fromModelJSON raw: String, places: Places, tagNames: [String], now: Date = Date()) -> Result? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8)) as? [String: Any] else { return nil }
        var query = SearchQuery()
        var summary: [String] = []

        let kinds = (object["kinds"] as? [String] ?? []).compactMap { SearchQuery.Kind(rawValue: $0.lowercased()) }
        query.kinds = Set(kinds)
        if !query.kinds.isEmpty { summary.append(query.kinds.map(\.title).sorted().joined(separator: " or ")) }

        query.text = (object["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        query.matchContent = (object["content"] as? Bool ?? false) && !query.text.isEmpty
        if !query.text.isEmpty { summary.append(query.matchContent ? "containing “\(query.text)”" : "named “\(query.text)”") }

        if let min = number(object["minSizeMB"]), min > 0 { query.minSize = Int64(min * 1_000_000); summary.append("over \(Formatters.size(query.minSize!))") }
        if let max = number(object["maxSizeMB"]), max >= 0 { query.maxSize = Int64(max * 1_000_000); summary.append("under \(Formatters.size(query.maxSize!))") }

        let calendar = Calendar.current
        let date = (object["date"] as? String ?? (object["date"] as? NSNumber)?.stringValue ?? "any").lowercased()
        switch date {
        case "today": query.dateRange = .today
        case "yesterday":
            let day = calendar.date(byAdding: .day, value: -1, to: now) ?? now
            query.dateRange = .between(day, day)
        case "last7days": query.dateRange = .last7Days
        case "last30days": query.dateRange = .last30Days
        case "thisyear": query.dateRange = .thisYear
        default:
            if let year = Int(date), (1970...2100).contains(year),
               let from = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
               let to = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) {
                query.dateRange = .between(from, to)
            }
        }
        if (object["dateField"] as? String)?.lowercased() == "created" { query.dateField = .created }
        if query.dateRange != .anyTime { summary.append((query.dateField == .created ? "created " : "") + query.dateRange.title.lowercased()) }

        let known = Dictionary(tagNames.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        query.tags = Set((object["tags"] as? [String] ?? []).compactMap { known[$0.lowercased()] })
        query.tags.sorted().forEach { summary.append("tagged \($0)") }

        if let days = number(object["notOpenedDays"]), days > 0 {
            query.notOpenedForDays = Int(days)
            summary.append("not opened for \(Int(days)) days")
        }

        let home = places.home
        switch (object["folder"] as? String)?.lowercased() {
        case "current": if let current = places.current { query.scope = .subfolders(current); summary.append("in this folder") }
        case "home": query.scope = .subfolders(home); summary.append("in Home")
        case "desktop": query.scope = .subfolders(home.appendingPathComponent("Desktop")); summary.append("on Desktop")
        case "documents": query.scope = .subfolders(home.appendingPathComponent("Documents")); summary.append("in Documents")
        case "downloads": query.scope = .subfolders(home.appendingPathComponent("Downloads")); summary.append("in Downloads")
        case "pictures": query.scope = .subfolders(home.appendingPathComponent("Pictures")); summary.append("in Pictures")
        default: query.scope = .everywhere
        }
        guard !query.isEmpty else { return nil }
        return Result(query: query, summary: summary)
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s.replacingOccurrences(of: ",", with: ".")) }
        return nil
    }
}
