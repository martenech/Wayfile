import Foundation
import UniformTypeIdentifiers

enum SearchEngine {
    static let resultLimit = 2000

    static func run(_ query: SearchQuery, showHidden: Bool = false) async -> [URL] {
        guard !query.isEmpty, query.isValidPattern else { return [] }
        // Spotlight can't match regexes inside file contents or our custom metadata; those need reading the files.
        let needsScan = (query.textMatch == .regex && query.matchContent) || !(query.metadata ?? "").isEmpty
        let engine = needsScan ? .scan : query.engine
        switch engine {
        case .spotlight:
            let urls = await spotlight(query)
            // Regex names are filtered here, since Spotlight has no regex operator.
            return query.textMatch == .regex ? urls.filter { query.nameMatches($0.lastPathComponent) } : urls
        case .scan: return await scan(query, showHidden: showHidden)
        }
    }

    // MARK: Spotlight

    /// The raw `mdfind` query for everything except the scope.
    static func spotlightQuery(_ query: SearchQuery, now: Date = Date()) -> String {
        var clauses: [String] = []
        let text = query.text.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty, query.textMatch != .regex {
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            // Globs use Spotlight's own * and ? wildcards; plain text matches anywhere in the name.
            let pattern = query.textMatch == .glob ? escaped : "*\(escaped)*"
            let name = "kMDItemFSName == \"\(pattern)\"cd"
            clauses.append(query.matchContent ? "(\(name) || kMDItemTextContent == \"*\(escaped)*\"cd)" : name)
        }
        if !query.kinds.isEmpty {
            let types = query.kinds.sorted { $0.rawValue < $1.rawValue }
                .flatMap(\.typeIdentifiers)
                .map { "kMDItemContentTypeTree == \"\($0)\"" }
            clauses.append("(" + types.joined(separator: " || ") + ")")
        }
        if let min = query.minSize { clauses.append("kMDItemFSSize >= \(min)") }
        if let max = query.maxSize { clauses.append("kMDItemFSSize <= \(max)") }
        if let (from, to) = query.dateRange.interval(now: now) {
            let attribute = query.dateField == .modified ? "kMDItemFSContentChangeDate" : "kMDItemFSCreationDate"
            clauses.append("\(attribute) >= $time.iso(\(iso(from))) && \(attribute) < $time.iso(\(iso(to)))")
        }
        if let days = query.notOpenedForDays {
            let cutoff = iso(Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now)
            clauses.append("((kMDItemLastUsedDate < $time.iso(\(cutoff))) || (kMDItemLastUsedDate != * && kMDItemFSContentChangeDate < $time.iso(\(cutoff))))")
        }
        for tag in query.tags.sorted() {
            let escaped = tag.replacingOccurrences(of: "\"", with: "\\\"")
            clauses.append("kMDItemUserTags == \"\(escaped)\"")
        }
        return clauses.joined(separator: " && ")
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func spotlight(_ query: SearchQuery) async -> [URL] {
        var args: [String] = []
        if let root = query.scope.root { args += ["-onlyin", root.path] }
        args.append(spotlightQuery(query))
        let output = await Shell.run("/usr/bin/mdfind", args)
        var urls = output.stdout.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
        if case .folder(let root) = query.scope {
            let rootPath = root.standardizedFileURL.path
            urls = urls.filter { $0.deletingLastPathComponent().standardizedFileURL.path == rootPath }
        }
        return Array(urls.prefix(resultLimit))
    }

    // MARK: Scan

    static let scanKeys: Set<URLResourceKey> = [
        .nameKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey,
        .contentTypeKey, .tagNamesKey, .isHiddenKey, .contentAccessDateKey,
    ]

    /// Whether one file matches every filter (text in the name; content is checked separately).
    static func matchesFilters(_ values: URLResourceValues, query: SearchQuery, now: Date = Date()) -> Bool {
        if !query.kinds.isEmpty {
            guard let type = values.contentType else { return false }
            let matchesKind = query.kinds.contains { kind in
                kind.typeIdentifiers.contains { UTType($0).map(type.conforms(to:)) ?? false }
            }
            if !matchesKind { return false }
        }
        if query.minSize != nil || query.maxSize != nil {
            // Sizes only make sense for files.
            if values.isDirectory == true { return false }
            let size = Int64(values.fileSize ?? 0)
            if let min = query.minSize, size < min { return false }
            if let max = query.maxSize, size > max { return false }
        }
        if let (from, to) = query.dateRange.interval(now: now) {
            let date = query.dateField == .modified ? values.contentModificationDate : values.creationDate
            guard let date, date >= from, date < to else { return false }
        }
        if !query.tags.isEmpty {
            let tags = Set(values.tagNames ?? [])
            if !query.tags.isSubset(of: tags) { return false }
        }
        if let days = query.notOpenedForDays {
            if values.isDirectory == true { return false }
            let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
            let lastOpened = values.contentAccessDate ?? values.contentModificationDate ?? .distantPast
            if lastOpened >= cutoff { return false }
        }
        return true
    }

    /// Reads small text files to look for the query text (plain or regex; case-insensitive).
    static func contentContains(_ url: URL, values: URLResourceValues, query: SearchQuery) -> Bool {
        guard values.isDirectory != true, (values.fileSize ?? 0) <= 20 << 20,
              let type = values.contentType, type.conforms(to: .text),
              let data = try? Data(contentsOf: url) else { return false }
        let text = query.text.trimmingCharacters(in: .whitespaces)
        let options: String.CompareOptions = query.textMatch == .regex
            ? [.regularExpression, .caseInsensitive] : [.caseInsensitive, .diacriticInsensitive]
        return String(decoding: data, as: UTF8.self).range(of: text, options: options) != nil
    }

    private static func scan(_ query: SearchQuery, showHidden: Bool) async -> [URL] {
        let root = query.scope.root ?? FileManager.default.homeDirectoryForCurrentUser
        let recursive: Bool = { if case .folder = query.scope { return false } else { return true } }()
        // Detached so the walk runs off the main actor; cancellation is forwarded so a new query stops it.
        let task = Task.detached(priority: .userInitiated) { () -> [URL] in
            let text = query.text.trimmingCharacters(in: .whitespaces)
            var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
            if !showHidden { options.insert(.skipsHiddenFiles) }
            if !recursive { options.insert(.skipsSubdirectoryDescendants) }
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: Array(scanKeys), options: options, errorHandler: { _, _ in true }
            ) else { return [] }

            var results: [URL] = []
            while let url = enumerator.nextObject() as? URL {
                if Task.isCancelled || results.count >= resultLimit { break }
                guard let values = try? url.resourceValues(forKeys: scanKeys),
                      matchesFilters(values, query: query) else { continue }
                if let metadata = query.metadata, !metadata.isEmpty, !CustomMetadata.matches(url, filter: metadata) { continue }
                if !text.isEmpty {
                    let nameMatches = query.nameMatches(values.name ?? url.lastPathComponent)
                    if !nameMatches && !(query.matchContent && contentContains(url, values: values, query: query)) { continue }
                }
                results.append(url)
            }
            return results
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}
