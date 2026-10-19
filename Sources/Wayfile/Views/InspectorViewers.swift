import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// What kind of built-in viewer suits a file.
enum ViewerKind: Equatable {
    case web, image, pdf, markdown, json, yaml, code(String), archive, log, binary, other

    static let codeExtensions: [String: String] = [
        "swift": "swift", "js": "js", "mjs": "js", "ts": "js", "tsx": "js", "jsx": "js", "py": "python", "rb": "ruby",
        "go": "go", "rs": "rust", "c": "c", "h": "c", "m": "c", "mm": "c", "cpp": "c", "cc": "c", "hpp": "c",
        "java": "java", "kt": "java", "cs": "java", "php": "php", "sh": "shell", "zsh": "shell", "bash": "shell",
        "css": "css", "scss": "css", "xml": "xml", "plist": "xml", "svg": "xml", "yaml": "yaml", "yml": "yaml",
        "toml": "yaml", "ini": "yaml", "sql": "sql", "gradle": "java", "dockerfile": "shell", "makefile": "shell",
    ]

    static func of(_ item: FileItem) -> ViewerKind {
        if item.isFolderLike { return .other }
        let ext = item.url.pathExtension.lowercased()
        let name = item.name.lowercased()
        if ["html", "htm", "xhtml"].contains(ext) { return .web }
        if ["md", "markdown", "mdown"].contains(ext) { return .markdown }
        if ext == "json" || ext == "geojson" { return .json }
        if ext == "yaml" || ext == "yml" { return .yaml }
        if ext == "log" { return .log }
        if let language = codeExtensions[ext] ?? codeExtensions[name] { return .code(language) }
        if item.isArchive { return .archive }
        guard let type = UTType(filenameExtension: ext) else { return item.isPackage ? .other : .binary }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .sourceCode) { return .code("c") }
        // Very large plain text reads better in the log viewer than in Quick Look.
        if type.conforms(to: .plainText), item.size > 2 << 20 { return .log }
        if type.conforms(to: .text) || type.conforms(to: .audiovisualContent) || type.conforms(to: .compositeContent)
            || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet) || type.conforms(to: .font) { return .other }
        // Archive formats bsdtar can't list (e.g. MacBinary .bin) and unknown data: show the bytes.
        if type.conforms(to: .archive) { return .binary }
        return type == .data || type.conforms(to: .executable) || !type.isDeclared ? .binary : .other
    }

    var zoomable: Bool { self == .web || self == .image || self == .pdf || self == .markdown }
}

// MARK: - Markdown

/// A small Markdown → HTML converter (headings, lists, quotes, code, emphasis, links, images, rules).
enum MarkdownHTML {
    static func render(_ markdown: String) -> String {
        var html: [String] = []
        var paragraph: [String] = []
        var list: String?
        var inCode = false
        var code: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty { html.append("<p>\(inline(paragraph.joined(separator: " ")))</p>") }
            paragraph = []
        }
        func closeList() {
            if let tag = list { html.append("</\(tag)>") }
            list = nil
        }

        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inCode {
                    html.append("<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>")
                    code = []
                } else {
                    flushParagraph(); closeList()
                }
                inCode.toggle()
                continue
            }
            if inCode { code.append(raw); continue }
            if line.isEmpty { flushParagraph(); closeList(); continue }
            if let level = headingLevel(line) {
                flushParagraph(); closeList()
                html.append("<h\(level)>\(inline(String(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))))</h\(level)>")
            } else if line == "---" || line == "***" || line == "___" {
                flushParagraph(); closeList()
                html.append("<hr>")
            } else if line.hasPrefix(">") {
                flushParagraph(); closeList()
                html.append("<blockquote>\(inline(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))</blockquote>")
            } else if let item = listItem(line, ordered: false) {
                flushParagraph()
                if list != "ul" { closeList(); html.append("<ul>"); list = "ul" }
                html.append("<li>\(inline(item))</li>")
            } else if let item = listItem(line, ordered: true) {
                flushParagraph()
                if list != "ol" { closeList(); html.append("<ol>"); list = "ol" }
                html.append("<li>\(inline(item))</li>")
            } else {
                closeList()
                paragraph.append(line)
            }
        }
        if inCode { html.append("<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>") }
        flushParagraph(); closeList()
        return document(html.joined(separator: "\n"))
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func listItem(_ line: String, ordered: Bool) -> String? {
        if !ordered {
            for marker in ["- [ ] ", "- [x] ", "- ", "* ", "+ "] where line.hasPrefix(marker) {
                let text = String(line.dropFirst(marker.count))
                return marker == "- [ ] " ? "☐ " + text : marker == "- [x] " ? "☑︎ " + text : text
            }
            return nil
        }
        guard let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
              line[line.index(after: dot)...].first == " " else { return nil }
        return String(line[line.index(dot, offsetBy: 2)...])
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func inline(_ text: String) -> String {
        var s = escape(text)
        let rules: [(String, String)] = [
            (#"`([^`]+)`"#, "<code>$1</code>"),
            (#"!\[([^\]]*)\]\(([^)\s]+)\)"#, "<img alt=\"$1\" src=\"$2\">"),
            (#"\[([^\]]+)\]\(([^)\s]+)\)"#, "<a href=\"$2\">$1</a>"),
            (#"\*\*([^*]+)\*\*"#, "<strong>$1</strong>"),
            (#"__([^_]+)__"#, "<strong>$1</strong>"),
            (#"(?<![\w*])\*([^*]+)\*(?![\w*])"#, "<em>$1</em>"),
            (#"(?<![\w_])_([^_]+)_(?![\w_])"#, "<em>$1</em>"),
            (#"~~([^~]+)~~"#, "<del>$1</del>"),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s
    }

    private static func document(_ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root { color-scheme: light dark; }
        body { font: 14px -apple-system, sans-serif; line-height: 1.55; margin: 18px 22px; max-width: 760px; }
        h1, h2 { border-bottom: 1px solid rgba(127,127,127,.25); padding-bottom: .25em; }
        code { font: 12px ui-monospace, Menlo, monospace; background: rgba(127,127,127,.15); padding: 1px 4px; border-radius: 4px; }
        pre { background: rgba(127,127,127,.12); padding: 10px 12px; border-radius: 8px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote { margin: 0; padding-left: 12px; border-left: 3px solid rgba(127,127,127,.4); color: gray; }
        img { max-width: 100%; }
        a { color: #2f6fe4; }
        </style></head><body>
        \(body)
        </body></html>
        """
    }
}

/// Renders an HTML string with WebKit (relative links/images resolve against `baseURL`).
struct HTMLStringPreview: NSViewRepresentable {
    let html: String
    let baseURL: URL
    var pageZoom: CGFloat = 1

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if context.coordinator.loaded != html {
            context.coordinator.loaded = html
            view.loadHTMLString(html, baseURL: baseURL)
        }
        if abs(view.pageZoom - max(pageZoom, 0.1)) > 0.001 { view.pageZoom = max(pageZoom, 0.1) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var loaded: String? }
}

// MARK: - Code

/// Lightweight regex-based syntax highlighting (comments, strings, numbers, keywords).
enum CodeHighlighter {
    static let keywords: [String: Set<String>] = [
        "swift": ["func", "let", "var", "if", "else", "guard", "return", "struct", "class", "enum", "case", "switch", "for", "in", "while",
                  "import", "protocol", "extension", "private", "public", "static", "self", "true", "false", "nil", "try", "throws", "async", "await", "init", "some", "where", "defer"],
        "js": ["function", "const", "let", "var", "if", "else", "return", "for", "while", "class", "import", "export", "from", "new", "this",
               "true", "false", "null", "undefined", "async", "await", "try", "catch", "switch", "case", "default", "interface", "type"],
        "python": ["def", "class", "if", "elif", "else", "return", "for", "while", "import", "from", "as", "with", "try", "except",
                   "finally", "True", "False", "None", "lambda", "yield", "async", "await", "in", "is", "not", "and", "or", "pass", "self"],
        "shell": ["if", "then", "else", "fi", "for", "do", "done", "while", "case", "esac", "function", "export", "local", "return", "echo", "set"],
        "go": ["func", "package", "import", "var", "const", "type", "struct", "interface", "if", "else", "for", "range", "return", "go", "defer", "nil", "true", "false"],
        "rust": ["fn", "let", "mut", "if", "else", "match", "for", "in", "while", "loop", "return", "struct", "enum", "impl", "trait", "pub", "use", "mod", "self", "true", "false"],
    ]

    static func highlight(_ text: String, language: String) -> AttributedString {
        var result = AttributedString(text)
        let ns = text as NSString
        func color(_ pattern: String, _ nsColor: NSColor, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let range = Range(match.range, in: text), let attributed = Range(range, in: result) else { continue }
                result[attributed].foregroundColor = Color(nsColor: nsColor)
            }
        }
        let words = keywords[language] ?? keywords["js"]!
        if !words.isEmpty { color("\\b(" + words.sorted().joined(separator: "|") + ")\\b", .systemPurple) }
        color(#"\b\d+(\.\d+)?\b"#, .systemBlue)
        if language == "xml" { color(#"</?[A-Za-z][\w:.-]*"#, .systemPurple); color(#"\b[\w:-]+(?==)"#, .systemTeal) }
        if language == "yaml" { color(#"^\s*[\w.-]+(?=:)"#, .systemTeal, options: .anchorsMatchLines) }
        if language == "css" { color(#"[\w-]+(?=\s*:)"#, .systemTeal) }
        color(#""(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'"#, .systemRed)
        let lineComment = ["python", "shell", "yaml", "ruby"].contains(language) ? "#" : language == "sql" ? "--" : "//"
        color(NSRegularExpression.escapedPattern(for: lineComment) + ".*$", .systemGray, options: .anchorsMatchLines)
        if !["python", "shell", "yaml", "ruby", "sql"].contains(language) { color(#"/\*[\s\S]*?\*/"#, .systemGray) }
        if language == "xml" { color(#"<!--[\s\S]*?-->"#, .systemGray) }
        return result
    }
}

struct CodePreview: View {
    let url: URL
    let language: String

    @State private var content: AttributedString?
    @State private var truncated = false

    var body: some View {
        GeometryReader { geo in
            ScrollView([.vertical, .horizontal]) {
                Group {
                    if let content {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(content)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize()
                            if truncated { Text("… (first 200 KB)").font(.caption).foregroundStyle(.secondary) }
                        }
                        .padding(8)
                    } else {
                        ProgressView().padding()
                    }
                }
                // Top-left like an editor, not centred when the file is short.
                .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
            }
        }
        .task(id: url) {
            let (text, cut) = await Task.detached { () -> (String, Bool) in
                guard let handle = try? FileHandle(forReadingFrom: url) else { return ("", false) }
                defer { try? handle.close() }
                let data = (try? handle.read(upToCount: 200_000)) ?? Data()
                let more = ((try? handle.read(upToCount: 1)) ?? Data()).isEmpty == false
                return (String(decoding: data, as: UTF8.self), more)
            }.value
            truncated = cut
            content = await Task.detached { CodeHighlighter.highlight(text, language: language) }.value
        }
    }
}

// MARK: - JSON

struct JSONNode: Identifiable {
    let id = UUID()
    let key: String
    let summary: String
    let color: Color
    let children: [JSONNode]?

    static func build(_ key: String, _ value: Any) -> JSONNode {
        switch value {
        case let dict as [String: Any]:
            let kids = dict.keys.sorted().map { build($0, dict[$0]!) }
            return JSONNode(key: key, summary: "{ \(dict.count) }", color: .secondary, children: kids)
        case let array as [Any]:
            let kids = array.prefix(1000).enumerated().map { build("[\($0.offset)]", $0.element) }
            return JSONNode(key: key, summary: "[ \(array.count) ]", color: .secondary, children: kids)
        case let string as String:
            return JSONNode(key: key, summary: "\"\(string)\"", color: .red, children: nil)
        case let number as NSNumber:
            let isBool = CFGetTypeID(number) == CFBooleanGetTypeID()
            return JSONNode(key: key, summary: isBool ? (number.boolValue ? "true" : "false") : number.stringValue,
                            color: isBool ? .purple : .blue, children: nil)
        default:
            return JSONNode(key: key, summary: "null", color: .purple, children: nil)
        }
    }

    static func parse(_ data: Data) -> JSONNode? {
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return build("root", value)
    }
}

struct JSONTreePreview: View {
    let url: URL

    @State private var root: JSONNode?
    @State private var failed = false

    var body: some View {
        Group {
            if let root {
                List(root.children ?? [root], children: \.children) { node in
                    HStack(spacing: 6) {
                        Text(node.key).fontWeight(.medium)
                        Text(node.summary).foregroundStyle(node.color).lineLimit(1).truncationMode(.tail)
                    }
                    .font(.system(size: 11, design: .monospaced))
                }
                .listStyle(.plain)
            } else if failed {
                Text("Not valid JSON (or larger than 10 MB)").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            let parsed = await Task.detached { () -> JSONNode? in
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 10 << 20,
                      let data = try? Data(contentsOf: url) else { return nil }
                return JSONNode.parse(data)
            }.value
            root = parsed
            failed = parsed == nil
        }
    }
}

// MARK: - Hex

enum HexDump {
    /// "00000010  48 65 6c 6c 6f …  |Hello…|" lines, 16 bytes each.
    static func lines(_ data: Data, offset: Int = 0) -> [String] {
        stride(from: 0, to: data.count, by: 16).map { start in
            let chunk = data[data.index(data.startIndex, offsetBy: start)..<data.index(data.startIndex, offsetBy: min(start + 16, data.count))]
            let hex = chunk.map { String(format: "%02x", $0) }
            let padded = (hex + Array(repeating: "  ", count: 16 - hex.count))
            let left = padded[0..<8].joined(separator: " "), right = padded[8..<16].joined(separator: " ")
            let ascii = String(chunk.map { (0x20...0x7e).contains($0) ? Character(UnicodeScalar($0)) : "." })
            return String(format: "%08x", offset + start) + "  \(left)  \(right)  |\(ascii)|"
        }
    }
}

struct HexPreview: View {
    let url: URL

    @State private var lines: [String] = []
    @State private var total: Int64 = 0

    nonisolated private static let limit = 16 * 1024

    var body: some View {
        GeometryReader { geo in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                    }
                    if total > Self.limit {
                        Text("First \(Formatters.size(Int64(Self.limit))) of \(Formatters.size(total))").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    }
                }
                .fixedSize()
                .padding(8)
                .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
            }
        }
        .task(id: url) {
            let (dump, size) = await Task.detached { () -> ([String], Int64) in
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], size) }
                defer { try? handle.close() }
                return (HexDump.lines((try? handle.read(upToCount: Self.limit)) ?? Data()), size)
            }.value
            lines = dump
            total = size
        }
    }
}

// MARK: - Archives

enum ArchiveListing {
    /// Entry names inside an archive (zip, tar, gz, bz2, xz, 7z, rar via bsdtar).
    static func entries(of url: URL) async -> [String]? {
        let output = await Shell.run("/usr/bin/tar", ["-tf", url.path])
        guard output.status == 0 else { return nil }
        return output.stdout.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("__MACOSX/") }
    }
}

struct ArchivePreview: View {
    let url: URL

    @State private var entries: [String]?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let entries {
                let files = entries.filter { !$0.hasSuffix("/") }
                Text(verbatim: String(localized: "\(files.count) files") + " · " + String(localized: "\(entries.count - files.count) folders"))
                    .font(.caption).foregroundStyle(.secondary).padding(8)
                List(Array(entries.prefix(5000).enumerated()), id: \.offset) { _, entry in
                    Label(entry, systemImage: entry.hasSuffix("/") ? "folder" : "doc")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .listStyle(.plain)
            } else if failed {
                Text("Can’t read this archive.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            entries = await ArchiveListing.entries(of: url)
            failed = entries == nil
        }
    }
}

// MARK: - Log viewer

/// Tail of a large text/log file with filtering, level colours and live follow.
struct LogViewerView: View {
    let url: URL

    @State private var lines: [String] = []
    @State private var query = ""
    @State private var follow = true
    @State private var offset: UInt64 = 0
    @State private var watcher: DispatchSourceFileSystemObject?

    private static let tailBytes = 2 << 20

    private var shown: [(Int, String)] {
        let all = Array(lines.enumerated())
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? all : all.filter { $0.element.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter lines", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Toggle("Follow", isOn: $follow)
                Spacer()
                Text("\(shown.count) of \(lines.count) lines").foregroundStyle(.secondary)
                Button("Reload") { load() }
            }
            .controlSize(.small)
            .padding(8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown, id: \.0) { index, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Self.color(for: line))
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .fixedSize()
                    .padding(8)
                }
                .onChange(of: lines.count) {
                    if follow, let last = shown.last?.0 { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .navigationTitle(url.lastPathComponent)
        .onAppear { load(); startWatching() }
        .onDisappear { watcher?.cancel() }
    }

    static func color(for line: String) -> Color {
        let upper = line.uppercased()
        if upper.contains("ERROR") || upper.contains("FATAL") || upper.contains("CRITICAL") { return .red }
        if upper.contains("WARN") { return .orange }
        if upper.contains("DEBUG") || upper.contains("TRACE") { return .secondary }
        return .primary
    }

    private func load() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(Self.tailBytes) ? size - UInt64(Self.tailBytes) : 0
        try? handle.seek(toOffset: start)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        var all = text.components(separatedBy: "\n")
        if start > 0, !all.isEmpty { all.removeFirst() } // drop the partial first line
        if all.last == "" { all.removeLast() }
        lines = all
        offset = size
    }

    private func startWatching() {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.extend, .write], queue: .main)
        source.setEventHandler { appendNew() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func appendNew() {
        guard follow, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > offset else { if size < offset { load() }; return } // truncated/rotated → reload
        try? handle.seek(toOffset: offset)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        offset = size
        var new = text.components(separatedBy: "\n")
        if new.last == "" { new.removeLast() }
        lines.append(contentsOf: new)
    }
}

/// First lines of a log in the inspector, with a button for the full viewer.
struct LogSnippet: View {
    let url: URL
    let open: () -> Void

    @State private var lines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 10, design: .monospaced)).foregroundStyle(LogViewerView.color(for: line)).lineLimit(1)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Open Log Viewer", systemImage: "text.alignleft", action: open)
                .controlSize(.small)
                .padding([.leading, .bottom], 6)
        }
        .task(id: url) {
            lines = await Task.detached { () -> [String] in
                guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
                defer { try? handle.close() }
                let size = (try? handle.seekToEnd()) ?? 0
                try? handle.seek(toOffset: size > 8000 ? size - 8000 : 0)
                return Array(String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
                    .components(separatedBy: "\n").suffix(40))
            }.value
        }
    }
}

