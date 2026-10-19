import Foundation

/// A kind of file the "New" menu can create: a built-in starter or a file from the user's templates folder.
struct FileTemplate: Hashable, Identifiable {
    enum Source: Hashable {
        case text(String)
        case file(URL)
    }

    let id: String
    let title: String
    /// Suggested name, including the extension.
    let fileName: String
    let symbol: String
    let source: Source

    /// Scripts get the executable bit so they can run straight away.
    var isExecutable: Bool {
        if case .text(let text) = source { return text.hasPrefix("#!") }
        return false
    }

    func contents() throws -> Data {
        switch source {
        case .text(let text): return Data(text.utf8)
        case .file(let url): return try Data(contentsOf: url)
        }
    }

    static let text = FileTemplate(id: "txt", title: String(localized: "Text Document"), fileName: String(localized: "New Text Document") + ".txt",
                                   symbol: "doc.text", source: .text(""))

    static let builtIn: [FileTemplate] = [
        text,
        FileTemplate(id: "md", title: String(localized: "Markdown"), fileName: String(localized: "New Document") + ".md", symbol: "text.document",
                     source: .text("# Title\n\n")),
        FileTemplate(id: "json", title: "JSON", fileName: "new.json", symbol: "curlybraces",
                     source: .text("{\n  \n}\n")),
        FileTemplate(id: "html", title: "HTML", fileName: "index.html", symbol: "chevron.left.forwardslash.chevron.right",
                     source: .text("""
                     <!doctype html>
                     <html lang="en">
                     <head>
                       <meta charset="utf-8">
                       <meta name="viewport" content="width=device-width, initial-scale=1">
                       <title>Untitled</title>
                     </head>
                     <body>

                     </body>
                     </html>

                     """)),
        FileTemplate(id: "csv", title: "CSV", fileName: String(localized: "New Spreadsheet") + ".csv", symbol: "tablecells",
                     source: .text("Column 1,Column 2,Column 3\n")),
        FileTemplate(id: "rtf", title: String(localized: "Rich Text"), fileName: String(localized: "New Document") + ".rtf", symbol: "doc.richtext",
                     source: .text("{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica;}}\\f0\\fs24\n}\n")),
        FileTemplate(id: "swift", title: "Swift", fileName: "main.swift", symbol: "swift",
                     source: .text("import Foundation\n\n")),
        FileTemplate(id: "py", title: "Python", fileName: "script.py", symbol: "chevron.left.forwardslash.chevron.right",
                     source: .text("#!/usr/bin/env python3\n\n\ndef main():\n    pass\n\n\nif __name__ == \"__main__\":\n    main()\n")),
        FileTemplate(id: "sh", title: String(localized: "Shell Script"), fileName: "script.sh", symbol: "terminal",
                     source: .text("#!/bin/zsh\nset -euo pipefail\n\n")),
        FileTemplate(id: "yaml", title: "YAML", fileName: "config.yaml", symbol: "list.bullet.indent",
                     source: .text("# Configuration\n")),
        FileTemplate(id: "xml", title: "XML", fileName: "document.xml", symbol: "chevron.left.forwardslash.chevron.right",
                     source: .text("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<root>\n</root>\n")),
        FileTemplate(id: "empty", title: String(localized: "Empty File"), fileName: String(localized: "untitled"), symbol: "doc",
                     source: .text("")),
    ]

    /// Drop any file here and it appears in the New menu; its contents become the new file's contents.
    static var userFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wayfile/Templates", isDirectory: true)
    }

    static func userTemplates(in folder: URL = userFolder) -> [FileTemplate] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                FileTemplate(id: "user:\(url.path)", title: url.deletingPathExtension().lastPathComponent,
                             fileName: url.lastPathComponent, symbol: "doc.on.doc", source: .file(url))
            }
    }

    /// Creates the templates folder so "Open Templates Folder" always has somewhere to go.
    static func ensureUserFolder() throws -> URL {
        let folder = userFolder
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }
}
