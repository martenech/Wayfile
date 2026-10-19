import SwiftUI
import AppKit
import Observation

/// Recent file and path copies made in Wayfile (other apps' clipboard contents are never recorded).
@MainActor
@Observable
final class ClipboardHistory {
    static let shared = ClipboardHistory()

    struct Entry: Codable, Identifiable, Hashable {
        enum Content: Codable, Hashable {
            case files([URL])
            case text(String)
        }
        var id = UUID()
        let date: Date
        let content: Content

        var title: String {
            switch content {
            case .files(let urls): return urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items (\(urls[0].lastPathComponent)…)"
            case .text(let text): return text.count > 60 ? String(text.prefix(57)) + "…" : text
            }
        }

        var symbol: String {
            if case .files = content { return "doc.on.doc" }
            return "link"
        }
    }

    private(set) var entries: [Entry] = []
    static let limit = 30
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: "clipboardHistory").flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    /// Records the pasteboard when it changed while Wayfile was the active app.
    func poll(pasteboard: NSPasteboard = .general, appIsActive: Bool? = nil) {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard appIsActive ?? NSApp.isActive else { return }
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty {
            record(.files(files))
        } else if let text = pasteboard.string(forType: .string), Self.looksLikePath(text) {
            record(.text(text))
        }
    }

    /// Only paths, file/web URLs and similar short, single-purpose text — not arbitrary text.
    static func looksLikePath(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 4000 else { return false }
        return trimmed.split(separator: "\n").allSatisfy { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            return l.hasPrefix("/") || l.hasPrefix("~/") || l.hasPrefix("'/") || l.contains("://") || l.hasPrefix("s3://")
                || (!l.contains(" ") && l.contains("/") && l.count < 300)
        }
    }

    func record(_ content: Entry.Content, date: Date = Date()) {
        entries.removeAll { $0.content == content }
        entries.insert(Entry(date: date, content: content), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    /// Puts an entry back on the clipboard (files as a copy, ready to paste).
    func restore(_ entry: Entry, to pasteboard: NSPasteboard = .general) {
        switch entry.content {
        case .files(let urls):
            let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !existing.isEmpty else { return }
            FileClipboard.shared.set(existing, cut: false)
        case .text(let text):
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        lastChangeCount = pasteboard.changeCount
        record(entry.content)
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: "clipboardHistory") }
    }
}

/// "Clipboard History" submenu (Edit menu, palette).
struct ClipboardHistoryMenu: View {
    var body: some View {
        Menu("Clipboard History") {
            let history = ClipboardHistory.shared
            ForEach(history.entries.prefix(20)) { entry in
                Button(entry.title, systemImage: entry.symbol) { history.restore(entry) }
            }
            if history.entries.isEmpty {
                Text("Copied files and paths appear here")
            } else {
                Divider()
                Button("Clear History") { history.clear() }
            }
        }
    }
}
