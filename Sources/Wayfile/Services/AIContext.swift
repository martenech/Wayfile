import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
import Vision

/// What an "Ask AI" conversation is about: text of the chosen files (or a folder's listing and small text
/// files), within a size budget so requests stay fast and cheap.
enum AIContext {
    struct Built: Equatable {
        let text: String
        /// Items whose content was included vs. only described (shown to the user).
        let included: [String]
        let describedOnly: [String]
        let truncated: Bool
    }

    static let defaultBudget = 60_000
    static let perFileLimit = 24_000
    static let listingLimit = 400
    static let perFileInFolder = 8_000
    static let maxImagesPerFolder = 5
    static let maxFilesConsidered = 300
    /// Folders whose contents are generated or vendored — not what the user asks about.
    static let skippedFolders: Set<String> = [".git", "node_modules", "build", ".build", "DerivedData", "Pods", "vendor", "dist", ".venv", "venv", "__pycache__", "target"]

    static func build(for urls: [URL], budget: Int = defaultBudget) -> Built {
        var parts: [String] = []
        var included: [String] = [], described: [String] = []
        var remaining = budget
        var truncated = false

        func add(_ text: String) {
            if text.count > remaining { parts.append(String(text.prefix(max(0, remaining))) + "\n[…truncated]"); truncated = true; remaining = 0 }
            else { parts.append(text); remaining -= text.count }
        }

        for url in urls {
            guard remaining > 0 else { truncated = true; break }
            if FileSystem.isDirectory(url) && !FileSystem.isPackage(url) {
                add(folderDescription(url))
                included.append(url.lastPathComponent + "/")
                // Then the files themselves, as far as the budget goes: readmes first, then documents
                // and text (small before large), then a few images through OCR.
                var images = 0
                for child in readableFiles(in: url) where remaining > 1_500 {
                    let isImage = UTType(filenameExtension: child.pathExtension)?.conforms(to: .image) == true
                    if isImage { guard images < maxImagesPerFolder else { continue }; images += 1 }
                    let share = max(1_500, min(perFileInFolder, remaining / 2))
                    if let text = readText(child, limit: share) {
                        let relative = relativePath(of: child, in: url)
                        add("\n--- \(url.lastPathComponent)/\(relative) ---\n\(text)\n")
                        included.append(url.lastPathComponent + "/" + relative)
                    }
                }
            } else if let text = readText(url, limit: min(perFileLimit, remaining)) {
                add("\n=== File: \(url.lastPathComponent) (\(metadataLine(url))) ===\n\(text)\n")
                included.append(url.lastPathComponent)
            } else {
                add("\n=== File: \(url.lastPathComponent) (\(metadataLine(url))) — content not readable as text ===\n")
                described.append(url.lastPathComponent)
            }
        }
        return Built(text: parts.joined(), included: included, describedOnly: described, truncated: truncated)
    }

    /// Text of documents the model can use: plain text and code, PDFs, Word / RTF / ODT / HTML, Excel,
    /// PowerPoint, Pages / Numbers / Keynote, and text in images (OCR). Nil when there's nothing readable.
    static func readText(_ url: URL, limit: Int) -> String? {
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        if ["docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "webarchive", "wordml"].contains(ext) {
            return richText(url, limit: limit)
        }
        if ext == "xlsx" { return xlsxText(url, limit: limit) }
        if ext == "pptx" { return pptxText(url, limit: limit) }
        if ["pages", "numbers", "key"].contains(ext) { return iWorkText(url, limit: limit) }
        if type?.conforms(to: .image) == true { return ocrText(url, limit: limit) }
        if type?.conforms(to: .pdf) == true {
            guard let document = PDFDocument(url: url) else { return nil }
            var text = ""
            for index in 0..<document.pageCount where text.count < limit {
                if let page = document.page(at: index)?.string { text += "\n[Page \(index + 1)]\n" + page }
            }
            return text.isEmpty ? nil : String(text.prefix(limit))
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: limit * 2)
        guard !data.isEmpty, !data.prefix(4096).contains(0) else { return nil }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let isTextType = type.map { $0.conforms(to: .text) || $0.conforms(to: .sourceCode) || $0.conforms(to: .json) || $0.conforms(to: .xml) } ?? true
        guard isTextType || url.pathExtension.isEmpty || ["log", "csv", "tsv", "md", "yml", "yaml", "toml", "ini", "env", "conf"].contains(url.pathExtension.lowercased()) else { return nil }
        return String(text.prefix(limit))
    }

    /// Word, RTF, ODT, HTML through AppKit's document readers.
    static func richText(_ url: URL, limit: Int) -> String? {
        guard let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) else { return nil }
        let text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(limit))
    }

    /// A member of a zip-based document (Office, iWork).
    static func zipMember(_ archive: URL, _ member: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, member]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 && !data.isEmpty ? data : nil
    }

    static func zipMembers(_ archive: URL) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-1", archive.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// Text inside XML elements with the given local name (e.g. "t" in Office XML), in document order.
    static func xmlTexts(_ data: Data, element: String) -> [String] {
        final class Collector: NSObject, XMLParserDelegate {
            let element: String
            var texts: [String] = []
            var current: String?
            init(element: String) { self.element = element }
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
                if name == element || name.hasSuffix(":" + element) { current = "" }
            }
            func parser(_ parser: XMLParser, foundCharacters string: String) { current? += string }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                if (name == element || name.hasSuffix(":" + element)), let text = current { texts.append(text); current = nil }
            }
        }
        let collector = Collector(element: element)
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        return collector.texts
    }

    /// Excel: each sheet as tab-separated rows (shared strings resolved).
    static func xlsxText(_ url: URL, limit: Int) -> String? {
        let shared = zipMember(url, "xl/sharedStrings.xml").map { data -> [String] in
            // Each <si> may hold several <t> runs; join runs per item.
            final class SI: NSObject, XMLParserDelegate {
                var items: [String] = [], current: String?, inT = false
                func parser(_ p: XMLParser, didStartElement n: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
                    if n == "si" { current = "" } else if n == "t" { inT = true }
                }
                func parser(_ p: XMLParser, foundCharacters s: String) { if inT { current? += s } }
                func parser(_ p: XMLParser, didEndElement n: String, namespaceURI: String?, qualifiedName: String?) {
                    if n == "t" { inT = false } else if n == "si" { items.append(current ?? ""); current = nil }
                }
            }
            let delegate = SI()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.parse()
            return delegate.items
        } ?? []
        let sheets = zipMembers(url).filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var output = ""
        for sheet in sheets where output.count < limit {
            guard let data = zipMember(url, sheet) else { continue }
            final class Cells: NSObject, XMLParserDelegate {
                var rows: [[String]] = [], row: [String] = [], value = "", isShared = false, inValue = false, inline = false
                let shared: [String]
                init(shared: [String]) { self.shared = shared }
                func parser(_ p: XMLParser, didStartElement n: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
                    switch n {
                    case "row": row = []
                    case "c": isShared = a["t"] == "s"; inline = a["t"] == "inlineStr"; value = ""
                    case "v": inValue = true
                    case "t": if inline { inValue = true }
                    default: break
                    }
                }
                func parser(_ p: XMLParser, foundCharacters s: String) { if inValue { value += s } }
                func parser(_ p: XMLParser, didEndElement n: String, namespaceURI: String?, qualifiedName: String?) {
                    switch n {
                    case "v", "t": inValue = false
                    case "c": row.append(isShared ? (Int(value).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? value) : value)
                    case "row": if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                    default: break
                    }
                }
            }
            let cells = Cells(shared: shared)
            let parser = XMLParser(data: data)
            parser.delegate = cells
            parser.parse()
            let name = (sheet as NSString).lastPathComponent.replacingOccurrences(of: ".xml", with: "")
            output += "[\(name)]\n" + cells.rows.map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n"
        }
        return output.isEmpty ? nil : String(output.prefix(limit))
    }

    /// PowerPoint: text of each slide.
    static func pptxText(_ url: URL, limit: Int) -> String? {
        let slides = zipMembers(url).filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var output = ""
        for (index, slide) in slides.enumerated() where output.count < limit {
            guard let data = zipMember(url, slide) else { continue }
            output += "[Slide \(index + 1)]\n" + xmlTexts(data, element: "t").joined(separator: " ") + "\n"
        }
        return output.isEmpty ? nil : String(output.prefix(limit))
    }

    /// Pages / Numbers / Keynote keep a PDF preview inside the package or zip.
    static func iWorkText(_ url: URL, limit: Int) -> String? {
        var pdfData: Data?
        for member in ["QuickLook/Preview.pdf", "preview.pdf"] {
            if FileSystem.isDirectory(url) {
                pdfData = try? Data(contentsOf: url.appendingPathComponent(member))
            } else {
                pdfData = zipMember(url, member)
            }
            if pdfData != nil { break }
        }
        guard let pdfData, let document = PDFDocument(data: pdfData) else { return nil }
        var text = ""
        for index in 0..<document.pageCount where text.count < limit {
            if let page = document.page(at: index)?.string { text += page + "\n" }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(limit))
    }

    /// Text in images (screenshots, scans, photos of documents) via on-device OCR.
    static func ocrText(_ url: URL, limit: Int) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : "[Text recognized in the image]\n" + String(text.prefix(limit))
    }

    static func metadataLine(_ url: URL) -> String {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey])
        return [v?.localizedTypeDescription, v?.fileSize.map { Formatters.size(Int64($0)) },
                v?.contentModificationDate.map { "modified " + $0.formatted(date: .abbreviated, time: .omitted) }].compactMap { $0 }.joined(separator: ", ")
    }

    /// Folder overview: totals and a listing (two levels, biggest first), capped.
    static func folderDescription(_ folder: URL) -> String {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var lines: [String] = []
        var files = 0, folders = 0
        var total: Int64 = 0
        func line(_ url: URL, indent: String) -> String {
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true { return "\(indent)\(url.lastPathComponent)/" }
            let size = Int64(v?.fileSize ?? 0)
            let date = v?.contentModificationDate.map { $0.formatted(.iso8601.year().month().day()) } ?? ""
            return "\(indent)\(url.lastPathComponent)  \(Formatters.size(size))  \(date)"
        }
        for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDir { folders += 1 } else { files += 1; total += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            guard lines.count < listingLimit else { continue }
            lines.append(line(child, indent: "  "))
            if isDir {
                let inner = (try? FileManager.default.contentsOfDirectory(at: child, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
                for grandchild in inner.prefix(15) where lines.count < listingLimit { lines.append(line(grandchild, indent: "    ")) }
                if inner.count > 15 { lines.append("    … \(inner.count - 15) more") }
            }
        }
        if children.count > 0 && lines.count >= listingLimit { lines.append("  … listing shortened") }
        return "=== Folder: \(folder.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")) — \(files) files (\(Formatters.size(total))), \(folders) folders ===\n" + lines.joined(separator: "\n") + "\n"
    }

    /// Path of `child` inside `folder` (both resolved, so /var vs /private/var doesn't matter).
    static func relativePath(of child: URL, in folder: URL) -> String {
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let path = child.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : child.lastPathComponent
    }

    /// Files under a folder (two levels deep), ordered by how useful their text is likely to be.
    static func readableFiles(in folder: URL) -> [URL] {
        let notable = notableFiles(in: folder)
        var found: [(url: URL, rank: Int, size: Int)] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isPackageKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { return notable }
        while let url = enumerator.nextObject() as? URL, found.count < maxFilesConsidered {
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true && v?.isPackage != true {
                if skippedFolders.contains(url.lastPathComponent) || enumerator.level >= 2 { enumerator.skipDescendants() }
                continue
            }
            guard !notable.contains(url) else { continue }
            let ext = url.pathExtension.lowercased()
            let type = UTType(filenameExtension: ext)
            let rank: Int
            if ["md", "txt", "pdf", "docx", "doc", "rtf", "odt", "pages", "xlsx", "numbers", "pptx", "key", "csv"].contains(ext) { rank = 1 }
            else if type?.conforms(to: .sourceCode) == true || type?.conforms(to: .text) == true || type?.conforms(to: .json) == true { rank = 2 }
            else if type?.conforms(to: .image) == true { rank = 3 }
            else { continue }
            found.append((url, rank, v?.fileSize ?? 0))
        }
        return notable + found.sorted { ($0.rank, $0.size) < ($1.rank, $1.size) }.map(\.url)
    }

    static func notableFiles(in folder: URL) -> [URL] {
        let names = ["README.md", "README", "README.txt", "readme.md", "package.json", "Package.swift", "pyproject.toml", "Cargo.toml", "notes.txt", "NOTES.md"]
        return names.map { folder.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }.prefix(3).map { $0 }
    }

    static let instructions = """
    You are an assistant inside Wayfile, a file manager for macOS. The user asks about the files and folders whose content \
    (or listing) is given below. Answer in the user's language, concisely, using Markdown (short paragraphs, bullet lists, `code`). \
    Wayfile has already read the files for you: below is their extracted text (documents, spreadsheets, presentations, \
    PDFs, code, and text recognized in images). Never say you can't open or read files — use the content given. \
    If a file is listed without content, say its content wasn't included (it may be binary or too long), not that you lack access. \
    Base answers only on the given content. When you refer to a file, use its name.
    """

    /// One request containing the content, the conversation so far and the new question.
    static func prompt(context: Built, history: [(question: String, answer: String)], question: String) -> String {
        var text = "CONTENT:\n" + context.text
        if !history.isEmpty {
            text += "\n\nCONVERSATION SO FAR:\n" + history.map { "User: \($0.question)\nAssistant: \($0.answer)" }.joined(separator: "\n\n")
        }
        return text + "\n\nQUESTION: " + question
    }
}
