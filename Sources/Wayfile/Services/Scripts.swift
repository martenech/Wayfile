import Foundation
import JavaScriptCore

// MARK: - Model

/// A user script: a file in the Scripts folder whose header comments declare how it is used.
///
///     #!/bin/zsh
///     # @name Resize for Web
///     # @description Makes 1600 px JPEG copies
///     # @extensions jpg, jpeg, png, heic
///     # @count 1+
///     # @permissions read, write
///
/// Other keys: `@version 1.2`, `@folders yes` (applies to folders), `@menu no|pin` (hide from / pin to context menus),
/// `@shortcut cmd+shift+L`, `@after copy, move` (run on what those operations produced),
/// `@trigger <folder>` (run on new files there), `@schedule <minutes>` (run periodically).
struct Script: Identifiable, Hashable, Sendable {
    enum Language: String, Sendable, CaseIterable {
        case sh, zsh, bash, python, applescript, javascript, pipeline

        init?(fileExtension: String) {
            switch fileExtension.lowercased() {
            case "sh": self = .sh
            case "zsh": self = .zsh
            case "bash": self = .bash
            case "py": self = .python
            case "applescript", "scpt": self = .applescript
            case "js": self = .javascript
            case "pipeline": self = .pipeline
            default: return nil
            }
        }

        var title: String {
            switch self {
            case .sh: return String(localized: "Shell")
            case .zsh: return String(localized: "zsh")
            case .bash: return String(localized: "bash")
            case .python: return String(localized: "Python")
            case .applescript: return String(localized: "AppleScript")
            case .javascript: return String(localized: "JavaScript")
            case .pipeline: return String(localized: "Pipeline")
            }
        }

        var fileExtension: String {
            switch self {
            case .python: return "py"
            case .javascript: return "js"
            default: return rawValue
            }
        }

        var symbol: String {
            switch self {
            case .sh, .zsh, .bash: return "terminal"
            case .python: return "chevron.left.forwardslash.chevron.right"
            case .applescript: return "applescript"
            case .javascript: return "curlybraces"
            case .pipeline: return "arrow.triangle.branch"
            }
        }

        /// Line comment used for the metadata header.
        var commentPrefix: String {
            switch self {
            case .javascript: return "//"
            case .applescript: return "--"
            default: return "#"
            }
        }
    }

    /// What a script may do; JavaScript scripts are held to it, others are trusted after confirmation.
    enum Permission: String, Sendable, CaseIterable, Comparable {
        case read, metadata, write, delete, network

        var title: String {
            switch self {
            case .read: return String(localized: "Read files")
            case .metadata: return String(localized: "Read file details (type, EXIF, tags)")
            case .write: return String(localized: "Create, move and rename files")
            case .delete: return String(localized: "Move files to the Trash")
            case .network: return String(localized: "Use the network")
            }
        }

        static func < (a: Permission, b: Permission) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    /// How many selected items the script accepts.
    struct CountRange: Hashable, Sendable {
        var min: Int
        var max: Int?

        static let any = CountRange(min: 0, max: nil)

        /// "1", "1+", "2-5", "0", "any".
        init?(_ text: String) {
            let t = text.trimmingCharacters(in: .whitespaces).lowercased()
            if t == "any" || t == "*" { self = .any; return }
            if t.hasSuffix("+"), let n = Int(t.dropLast()) { self.init(min: n, max: nil); return }
            let parts = t.split(separator: "-").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2, let a = parts[0], let b = parts[1], a <= b { self.init(min: a, max: b); return }
            if let n = Int(t) { self.init(min: n, max: n); return }
            return nil
        }

        init(min: Int, max: Int?) {
            self.min = min
            self.max = max
        }

        func contains(_ count: Int) -> Bool { count >= min && (max.map { count <= $0 } ?? true) }
    }

    let url: URL
    let language: Language
    var name: String
    var summary = ""
    var extensions: Set<String> = []
    var count: CountRange = .any
    var appliesToFolders = false
    var foldersOnly = false
    var permissions: Set<Permission> = []
    var showInMenu = true
    /// `@menu pin`: listed directly in the context menu, not only in the Scripts submenu.
    var pinned = false
    /// `@shortcut cmd+shift+L`
    var shortcut: ScriptShortcut?
    /// `@after copy, move, rename, trash, create`: runs on the result of those Wayfile operations.
    var after: Set<ScriptAfter> = []
    /// `@panel inspector|window`: a plugin with its own interface (JavaScript defining `render` / `action`).
    var panel: ScriptPanel?
    /// `@version`, free-form ("1.2").
    var version: String?
    var triggerFolder: URL?
    var scheduleMinutes: Int?

    var id: URL { url }

    /// Parses the header of `text` (comment lines before the first code line).
    init?(url: URL, text: String) {
        guard let language = Language(fileExtension: url.pathExtension) else { return nil }
        self.url = url
        self.language = language
        name = url.deletingPathExtension().lastPathComponent
        for (key, value) in Script.header(text, prefix: language.commentPrefix) {
            switch key {
            case "name": name = value
            case "description": summary = value
            case "extensions":
                extensions = Set(value.split(whereSeparator: { $0 == "," || $0 == " " })
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased() }
                    .filter { !$0.isEmpty })
            case "count": count = CountRange(value) ?? .any
            case "folders":
                foldersOnly = value.lowercased() == "only"
                appliesToFolders = foldersOnly || Script.bool(value)
            case "permissions":
                permissions = Set(value.split(whereSeparator: { $0 == "," || $0 == " " })
                    .compactMap { Permission(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) })
            case "menu":
                pinned = value.lowercased() == "pin"
                showInMenu = pinned || Script.bool(value)
            case "shortcut": shortcut = ScriptShortcut(value)
            case "after":
                after = Set(value.split(whereSeparator: { $0 == "," || $0 == " " })
                    .compactMap { ScriptAfter(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) })
            case "version": version = value.isEmpty ? nil : value
            case "panel": panel = language == .javascript ? ScriptPanel(rawValue: value.lowercased()) : nil
            case "trigger":
                let path = (value as NSString).expandingTildeInPath
                if !path.isEmpty { triggerFolder = URL(fileURLWithPath: path, isDirectory: true) }
            case "schedule": scheduleMinutes = Int(value).flatMap { $0 > 0 ? $0 : nil }
            default: break
            }
        }
    }

    static func load(_ url: URL) -> Script? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Script(url: url, text: text)
    }

    /// `@key value` pairs from the leading comment block (a shebang line is skipped).
    static func header(_ text: String, prefix: String) -> [(String, String)] {
        var pairs: [(String, String)] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#!") || line.isEmpty { continue }
            guard line.hasPrefix(prefix) else { break }
            let body = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            guard body.hasPrefix("@") else { continue }
            let parts = body.dropFirst().split(separator: " ", maxSplits: 1)
            guard let key = parts.first else { continue }
            pairs.append((key.lowercased(), parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""))
        }
        return pairs
    }

    private static func bool(_ value: String) -> Bool {
        ["yes", "true", "1", "on"].contains(value.lowercased())
    }

    /// Whether the script fits the selection: item count, then each item — files by `@extensions`
    /// (none = any file), folders only with `@folders yes|only` or when no extensions are declared.
    func applies(to selection: [URL]) -> Bool {
        count.contains(selection.count) && selection.allSatisfy(accepts)
    }

    func accepts(_ url: URL) -> Bool {
        if FileSystem.isDirectory(url) && !FileSystem.isPackage(url) {
            return appliesToFolders || extensions.isEmpty
        }
        return !foldersOnly && (extensions.isEmpty || extensions.contains(url.pathExtension.lowercased()))
    }
}

// MARK: - Library folder

enum ScriptLibrary {
    nonisolated static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wayfile/Scripts", isDirectory: true)
    }

    static func scripts(in folder: URL = folder) -> [Script] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap(Script.load)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Creates a new script from a skeleton for the language, with a unique file name.
    static func create(named name: String, language: Script.Language, in folder: URL = folder) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = FileOps.uniqueURL(folder.appendingPathComponent(name).appendingPathExtension(language.fileExtension))
        try skeleton(name: name, language: language).write(to: url, atomically: true, encoding: .utf8)
        if language.isExecutableFile {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return url
    }

    /// A JavaScript plugin with an interface, for the Inspector or its own window.
    static func createPlugin(named name: String, panel: ScriptPanel, in folder: URL = folder) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = FileOps.uniqueURL(folder.appendingPathComponent(name).appendingPathExtension("js"))
        try pluginSkeleton(name: name, panel: panel).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func pluginSkeleton(name: String, panel: ScriptPanel) -> String {
        """
        // @name \(name)
        // @description What this plugin shows
        // @panel \(panel.rawValue)
        // @count \(panel == .inspector ? "1+" : "any")
        // @permissions read
        // render(ctx) returns the interface (ui.vstack, ui.text, ui.button, ui.textField, ui.toggle, ui.picker,
        // ui.list, ui.progress, ui.row, ui.badge, ui.image, ui.section…). It runs again after every action.
        // ctx: selection, items, folder, values (what's typed in the controls).
        let clicks = 0

        function render(ctx) {
          return ui.vstack(
            ui.heading(`${ctx.items.length} item(s) selected`),
            ctx.items.slice(0, 5).map(item => ui.row(item.name, `${item.size} B`)),
            ui.hstack(ui.textField('note', { placeholder: 'Type something' }), ui.button('Click', 'click', { style: 'prominent' })),
            clicks > 0 && ui.caption(`Clicked ${clicks}× — last note: ${ctx.values.note || '(empty)'}`)
          )
        }

        // id: the button / row / control that was used; values: every control's value.
        function action(id, values, ctx) {
          if (id === 'click') clicks++
        }

        """
    }

    static func skeleton(name: String, language: Script.Language) -> String {
        let c = language.commentPrefix
        let header = """
        \(c) @name \(name)
        \(c) @description What this script does
        \(c) @extensions
        \(c) @count 1+
        \(c) @permissions read

        """
        switch language {
        case .sh, .zsh, .bash:
            let shell = language == .sh ? "/bin/sh" : "/bin/\(language.rawValue)"
            return "#!\(shell)\n" + header + """
            # Selected items are the arguments; also $WAYFILE_FOLDER, $WAYFILE_OTHER_FOLDER, $WAYFILE_DRY_RUN.
            for file in "$@"; do
              echo "$file"
            done

            """
        case .python:
            return "#!/usr/bin/env python3\n" + header + """
            import os, sys

            # Selected items are sys.argv[1:]; also WAYFILE_FOLDER, WAYFILE_DRY_RUN in os.environ.
            for path in sys.argv[1:]:
                print(path)

            """
        case .applescript:
            return header + """
            on run argv
            \trepeat with p in argv
            \t\tlog (p as text)
            \tend repeat
            end run

            """
        case .javascript:
            return header + """
            // wayfile.selection / .items, .folder, .dryRun — files: readText(), copy(), move(), rename(), trash(), tag()…
            // wayfile.panel, .dialogs, .workspaces, metadata(), checksum(), fetch() — see the API reference.
            // Changes are undoable from the Timeline; a dry run only describes them.
            for (const path of wayfile.selection) {
              wayfile.log(path)
            }

            """
        case .pipeline:
            return header + """
            # One step per line: a script file name from the Scripts folder, or "shortcut: Name".
            # Paths a step prints (or returns, for JavaScript) become the next step's selection.

            """
        }
    }
}

// MARK: - Shortcuts & operation hooks

/// A script's keyboard shortcut: "cmd+shift+L", "ctrl+alt+f5" or "⌘⇧L". Needs ⌘ or ⌃ so typing never triggers it.
struct ScriptShortcut: Hashable, Sendable {
    struct Modifiers: OptionSet, Hashable, Sendable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1)
        static let shift = Modifiers(rawValue: 2)
        static let option = Modifiers(rawValue: 4)
        static let control = Modifiers(rawValue: 8)
    }

    /// A lowercased character, or "f1"…"f12".
    let key: String
    let modifiers: Modifiers

    init(key: String, modifiers: Modifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    init?(_ text: String) {
        var modifiers: Modifiers = []
        var rest = text.trimmingCharacters(in: .whitespaces)
        let symbols: [(Character, Modifiers)] = [("⌘", .command), ("⇧", .shift), ("⌥", .option), ("⌃", .control)]
        while let first = rest.first, let match = symbols.first(where: { $0.0 == first }) {
            modifiers.insert(match.1)
            rest.removeFirst()
        }
        var parts = rest.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let key = parts.popLast(), !key.isEmpty else { return nil }
        for part in parts {
            switch part {
            case "cmd", "command": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "alt", "opt", "option": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            default: return nil
            }
        }
        let functionKey = key.hasPrefix("f") && Int(key.dropFirst()).map { (1...12).contains($0) } == true
        guard key.count == 1 || functionKey, !modifiers.isDisjoint(with: [.command, .control]) else { return nil }
        self.key = key
        self.modifiers = modifiers
    }

    /// "⌃⌥⇧⌘L" in the system's order.
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key.uppercased()
    }

    /// Key codes of F1–F12 (they have no character to compare).
    static let functionKeyCodes: [UInt16: String] = [122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
                                                      98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12"]

    /// Whether a key press (its character ignoring modifiers, or key code) matches.
    func matches(characters: String?, keyCode: UInt16, modifiers pressed: Modifiers) -> Bool {
        guard pressed == modifiers else { return false }
        if let name = Self.functionKeyCodes[keyCode] { return name == key }
        return characters?.lowercased() == key
    }
}

/// Where a plugin's interface appears.
enum ScriptPanel: String, Sendable, CaseIterable {
    /// A section in the Inspector, for selections the script applies to.
    case inspector
    /// Its own window (Scripts menu, command palette, Automation).
    case window
}

/// Wayfile operations a script can follow with `@after`.
enum ScriptAfter: String, Sendable, CaseIterable, Hashable {
    case copy, move, rename, trash, create

    var title: String { rawValue.capitalized }
}

// MARK: - Versions

/// Earlier versions of a script, kept on every save in `Scripts/.versions/<file name>/`.
enum ScriptVersions {
    struct Version: Identifiable, Hashable {
        let url: URL
        let date: Date
        var id: URL { url }
    }

    static let limit = 30

    static func folder(for script: URL) -> URL {
        script.deletingLastPathComponent().appendingPathComponent(".versions", isDirectory: true)
            .appendingPathComponent(script.lastPathComponent, isDirectory: true)
    }

    /// Newest first.
    static func list(for script: URL) -> [Version] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder(for: script), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.compactMap { url in
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
            return Version(url: url, date: date)
        }
        .sorted { $0.date > $1.date }
    }

    /// Keeps `text` (the content about to be replaced) unless it's the same as the newest version.
    @discardableResult
    static func keep(_ text: String, for script: URL, now: Date = Date()) throws -> Version? {
        guard !text.isEmpty else { return nil }
        if let newest = list(for: script).first, (try? String(contentsOf: newest.url, encoding: .utf8)) == text { return nil }
        let dir = folder(for: script)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSS"
        let url = FileOps.uniqueURL(dir.appendingPathComponent(formatter.string(from: now)).appendingPathExtension(script.pathExtension))
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        for old in list(for: script).dropFirst(limit) { try? FileManager.default.removeItem(at: old.url) }
        return Version(url: url, date: now)
    }

    /// Saves new content, keeping what was there as a version.
    static func save(_ text: String, to script: URL) throws {
        if let current = try? String(contentsOf: script, encoding: .utf8), current != text { try keep(current, for: script) }
        try text.write(to: script, atomically: true, encoding: .utf8)
    }

    /// Puts a version back (the current content becomes a version itself).
    static func restore(_ version: Version, to script: URL) throws {
        try save(try String(contentsOf: version.url, encoding: .utf8), to: script)
    }
}

extension Script.Language {
    var isExecutableFile: Bool { [.sh, .zsh, .bash, .python].contains(self) }
}

// MARK: - Running

/// What a script runs on.
struct ScriptContext: Sendable {
    var selection: [URL]
    var folder: URL?
    var otherFolder: URL?
    var dryRun = false
    /// The window the script was started from; nil for automatic runs (no dialogs or panel control then).
    var ui: ScriptUI?

    var environment: [String: String] {
        var env = [
            "WAYFILE_SELECTION": selection.map(\.path).joined(separator: "\n"),
            "WAYFILE_COUNT": String(selection.count),
            "WAYFILE_DRY_RUN": dryRun ? "1" : "0",
        ]
        if let folder { env["WAYFILE_FOLDER"] = folder.path }
        if let otherFolder { env["WAYFILE_OTHER_FOLDER"] = otherFolder.path }
        return env
    }
}

/// What a JavaScript script may ask of the window it was started from. Called on the main thread.
struct ScriptUI: Sendable {
    var open: @MainActor @Sendable (URL) -> Void
    var refresh: @MainActor @Sendable () -> Void
    var select: @MainActor @Sendable ([URL]) -> Void
    var workspaces: @MainActor @Sendable () -> [String]
    var openWorkspace: @MainActor @Sendable (String) -> Bool
}

struct ScriptOutputLine: Sendable, Hashable {
    enum Stream: Sendable { case stdout, stderr, info }
    let stream: Stream
    let text: String
    /// In a JavaScript dry run: the change this line describes.
    var plan: ScriptPlanStep? = nil
}

/// One change a JavaScript dry run would make. Only changes made through the Wayfile API can be
/// planned — a shell or Python script's side effects can't.
struct ScriptPlanStep: Sendable, Hashable {
    enum Action: String, Sendable, CaseIterable {
        case create, write, mkdir, rename, move, copy, tag, trash, skip

        var title: String {
            switch self {
            case .create: return String(localized: "Create")
            case .write: return String(localized: "Overwrite")
            case .mkdir: return String(localized: "New folder")
            case .rename: return String(localized: "Rename")
            case .move: return String(localized: "Move")
            case .copy: return String(localized: "Copy")
            case .tag: return String(localized: "Tag")
            case .trash: return String(localized: "Trash")
            case .skip: return String(localized: "Skip")
            }
        }

        var symbol: String {
            switch self {
            case .create: return "doc.badge.plus"
            case .write: return "square.and.pencil"
            case .mkdir: return "folder.badge.plus"
            case .rename: return "character.cursor.ibeam"
            case .move: return "arrow.right"
            case .copy: return "doc.on.doc"
            case .tag: return "tag"
            case .trash: return "trash"
            case .skip: return "forward"
            }
        }
    }

    let action: Action
    let path: String
    var target: String?
    /// Extra detail, e.g. the tag name.
    var detail: String?
    /// Why this might not go as planned (a name clash, an overwritten file).
    var conflict: String?

    var name: String { (path as NSString).lastPathComponent }

    /// The console line: "Would rename a.txt → b.txt".
    var sentence: String {
        let target = self.target.map { ($0 as NSString).lastPathComponent }
        let folder = self.target.map { ($0 as NSString).deletingLastPathComponent }
        var text: String
        switch action {
        case .create: text = "create \(path)"
        case .write: text = "overwrite \(path)"
        case .mkdir: text = "create folder \(path)"
        case .rename: text = "rename \(name) → \(target ?? "")"
        case .move: text = "move \(name) → \(folder ?? "")"
        case .copy: text = "copy \(name) → \(folder ?? "")"
        case .tag: text = "tag \(name) “\(detail ?? "")”"
        case .trash: text = "move \(name) to the Trash"
        case .skip: text = "skip \(name)"
        }
        if let conflict { text += " (\(conflict))" }
        return "Would " + text
    }

    /// Counts per action in a fixed order, for the plan's summary line.
    static func summary(_ steps: [ScriptPlanStep]) -> [(action: Action, count: Int)] {
        Action.allCases.compactMap { action in
            let count = steps.filter { $0.action == action }.count
            return count > 0 ? (action, count) : nil
        }
    }
}

struct ScriptResult: Sendable {
    let status: Int32
    /// Paths the script produced (printed existing paths, or what a JavaScript script returned).
    let outputPaths: [URL]
    /// JavaScript: the line an uncaught error came from.
    var errorLine: Int? = nil
}

enum ScriptRunner {
    typealias Output = @Sendable (ScriptOutputLine) -> Void

    static func run(_ script: Script, context: ScriptContext, progress: OperationProgress, output: @escaping Output) async throws -> ScriptResult {
        switch script.language {
        case .javascript:
            let source = try String(contentsOf: script.url, encoding: .utf8)
            return try await Task.detached {
                try JSScriptHost(script: script, context: context, progress: progress, output: output).run(source)
            }.value
        case .pipeline:
            return try await runPipeline(script, context: context, progress: progress, output: output)
        default:
            let (executable, arguments) = command(for: script, selection: context.selection)
            return try await process(executable, arguments, cwd: context.folder, environment: context.environment, progress: progress, output: output)
        }
    }

    static func command(for script: Script, selection: [URL]) -> (String, [String]) {
        let paths = selection.map(\.path)
        switch script.language {
        case .sh: return ("/bin/sh", [script.url.path] + paths)
        case .zsh: return ("/bin/zsh", [script.url.path] + paths)
        case .bash: return ("/bin/bash", [script.url.path] + paths)
        case .python: return ("/usr/bin/env", ["python3", script.url.path] + paths)
        case .applescript: return ("/usr/bin/osascript", [script.url.path] + paths)
        case .javascript, .pipeline: return ("/usr/bin/true", [])
        }
    }

    /// Runs a process, streaming its output line by line; cancelling the task terminates it.
    static func process(_ executable: String, _ arguments: [String], cwd: URL?, environment: [String: String],
                        progress: OperationProgress, output: @escaping Output) async throws -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let collector = LineCollector(output: output)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { collector.feed($0.availableData, .stdout) }
        err.fileHandleForReading.readabilityHandler = { collector.feed($0.availableData, .stderr) }

        // Stop arrives either as task cancellation or through `progress` (operations run detached).
        let watcher = Thread {
            while !Thread.current.isCancelled {
                if progress.isCancelled, process.isRunning { process.terminate() }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        watcher.start()
        defer { watcher.cancel() }
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    collector.feed(out.fileHandleForReading.readDataToEndOfFile(), .stdout)
                    collector.feed(err.fileHandleForReading.readDataToEndOfFile(), .stderr)
                    collector.flush()
                    continuation.resume(returning: finished.terminationStatus)
                }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            process.terminate()
        }
        if Task.isCancelled || progress.isCancelled { throw CancellationError() }
        let paths = collector.stdoutLines.compactMap { line -> URL? in
            let path = (line.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
        return ScriptResult(status: status, outputPaths: paths)
    }

    /// Steps run in order; each step's output paths (if any) become the next step's selection.
    static func runPipeline(_ script: Script, context: ScriptContext, progress: OperationProgress, output: @escaping Output) async throws -> ScriptResult {
        let text = try String(contentsOf: script.url, encoding: .utf8)
        let steps = pipelineSteps(text)
        guard !steps.isEmpty else { throw ShellError(message: "The pipeline has no steps.") }
        var current = context
        for (index, step) in steps.enumerated() {
            try progress.checkCancelled()
            output(ScriptOutputLine(stream: .info, text: "▸ Step \(index + 1): \(step)"))
            let result: ScriptResult
            if step.lowercased().hasPrefix("shortcut:") {
                let name = step.dropFirst("shortcut:".count).trimmingCharacters(in: .whitespaces)
                result = try await Shortcuts.run(name, input: current.selection, progress: progress, output: output)
            } else {
                let url = script.url.deletingLastPathComponent().appendingPathComponent(step)
                guard let stepScript = Script.load(url), stepScript.language != .pipeline else {
                    throw ShellError(message: "Pipeline step “\(step)” is not a script in the Scripts folder.")
                }
                result = try await run(stepScript, context: current, progress: progress, output: output)
            }
            guard result.status == 0 else {
                throw ShellError(message: "Pipeline stopped: step \(index + 1) (\(step)) exited with status \(result.status).")
            }
            if !result.outputPaths.isEmpty { current.selection = result.outputPaths }
        }
        return ScriptResult(status: 0, outputPaths: current.selection)
    }

    static func pipelineSteps(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}

/// Splits streamed output into lines (thread-safe; pipes deliver on background queues).
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [ScriptOutputLine.Stream: Data] = [:]
    private(set) var stdoutLines: [String] = []
    private let output: ScriptRunner.Output

    init(output: @escaping ScriptRunner.Output) { self.output = output }

    func feed(_ data: Data, _ stream: ScriptOutputLine.Stream) {
        guard !data.isEmpty else { return }
        var lines: [String] = []
        lock.withLock {
            var buffer = buffers[stream, default: Data()]
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            buffers[stream] = buffer
            if stream == .stdout { stdoutLines += lines }
        }
        lines.forEach { output(ScriptOutputLine(stream: stream, text: $0)) }
    }

    func flush() {
        var rest: [(ScriptOutputLine.Stream, String)] = []
        lock.withLock {
            for (stream, buffer) in buffers where !buffer.isEmpty {
                let line = String(decoding: buffer, as: UTF8.self)
                rest.append((stream, line))
                if stream == .stdout { stdoutLines.append(line) }
            }
            buffers.removeAll()
        }
        rest.forEach { output(ScriptOutputLine(stream: $0.0, text: $0.1)) }
    }
}

// MARK: - Apple Shortcuts

enum Shortcuts {
    static func list() async -> [String] {
        let output = await Shell.run("/usr/bin/shortcuts", ["list"])
        return output.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func run(_ name: String, input: [URL], progress: OperationProgress, output: @escaping ScriptRunner.Output) async throws -> ScriptResult {
        var arguments = ["run", name]
        for url in input { arguments += ["--input-path", url.path] }
        return try await ScriptRunner.process("/usr/bin/shortcuts", arguments, cwd: nil, environment: [:], progress: progress, output: output)
    }
}
