import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import AppKit
#if canImport(ScriptBridge)
import ScriptBridge
#endif

// MARK: - API reference

/// The JavaScript API, described once: drives the in-app reference, completion in the editor and the docs.
enum ScriptAPI {
    /// Bumped when members change; scripts can check `wayfile.version`.
    static let version = "1.1"

    struct Member: Identifiable, Hashable {
        /// "wayfile.copy", "wayfile.dialogs.confirm"…
        let name: String
        let signature: String
        let summary: String
        let returns: String
        var permission: Script.Permission?
        /// Only when the script was started from a window (not by a trigger or schedule).
        var interactive = false
        var id: String { name }
        var isFunction: Bool { signature.hasPrefix("(") }
    }

    /// A completion candidate: a member, or a namespace like `panel`.
    struct Completion: Hashable {
        let name: String
        let member: Member?
        /// Text inserted for it (functions get their opening parenthesis, namespaces a dot).
        var insertion: String { member.map { $0.isFunction ? name + "(" : name } ?? name + "." }
    }

    static let members: [Member] = [
        // Context
        .init(name: "wayfile.version", signature: "", summary: "API version, e.g. \"1.0\".", returns: "string"),
        .init(name: "wayfile.selection", signature: "", summary: "Paths of the selected items (or the files a trigger saw).", returns: "string[]"),
        .init(name: "wayfile.items", signature: "", summary: "The selection with attributes: path, name, ext, isDirectory, size, modified, created (ms).", returns: "object[]"),
        .init(name: "wayfile.count", signature: "", summary: "Number of selected items.", returns: "number"),
        .init(name: "wayfile.folder", signature: "", summary: "The active pane's folder.", returns: "string | null"),
        .init(name: "wayfile.otherFolder", signature: "", summary: "The other pane's folder in dual-pane mode.", returns: "string | null"),
        .init(name: "wayfile.home", signature: "", summary: "Your home folder.", returns: "string"),
        .init(name: "wayfile.dryRun", signature: "", summary: "True in a dry run: changes are only described, nothing is touched.", returns: "boolean"),
        .init(name: "wayfile.log", signature: "(...values)", summary: "Prints to the console (also console.log / info / warn / error).", returns: "undefined"),
        // Files
        .init(name: "wayfile.exists", signature: "(path)", summary: "Whether something exists at the path.", returns: "boolean"),
        .init(name: "wayfile.isDirectory", signature: "(path)", summary: "Whether the path is a folder.", returns: "boolean"),
        .init(name: "wayfile.size", signature: "(path)", summary: "Size in bytes.", returns: "number"),
        .init(name: "wayfile.modified", signature: "(path)", summary: "Modification date in ms since 1970 (use new Date(…)).", returns: "number"),
        .init(name: "wayfile.list", signature: "(folder)", summary: "Visible items in a folder, sorted.", returns: "string[]", permission: .read),
        .init(name: "wayfile.readText", signature: "(path)", summary: "Reads a UTF-8 text file.", returns: "string", permission: .read),
        .init(name: "wayfile.checksum", signature: "(path, algorithm = \"sha256\")", summary: "Hex checksum: \"md5\", \"sha1\" or \"sha256\".", returns: "string", permission: .read),
        .init(name: "wayfile.metadata", signature: "(path)", summary: "Details: dates, size, type, uti, tags, and for images width, height and EXIF / GPS.", returns: "object", permission: .metadata),
        .init(name: "wayfile.writeText", signature: "(path, text)", summary: "Writes a text file; an existing file goes to the Trash first (undoable).", returns: "string", permission: .write),
        .init(name: "wayfile.mkdir", signature: "(path)", summary: "Creates a folder (with intermediate folders).", returns: "string", permission: .write),
        .init(name: "wayfile.copy", signature: "(path, toFolder)", summary: "Copies into a folder; name clashes keep both.", returns: "string", permission: .write),
        .init(name: "wayfile.move", signature: "(path, toFolder)", summary: "Moves into a folder; name clashes keep both.", returns: "string", permission: .write),
        .init(name: "wayfile.transfer", signature: "(paths, toFolder, {mode, conflict})", summary: "Copies or moves many items through the transfer engine. mode: \"copy\" | \"move\"; conflict: \"keepBoth\" | \"skip\" | \"replace\" (replace needs delete).", returns: "string[]", permission: .write),
        .init(name: "wayfile.rename", signature: "(path, newName)", summary: "Renames in place.", returns: "string", permission: .write),
        .init(name: "wayfile.tag", signature: "(path, tagName)", summary: "Adds a Finder tag.", returns: "string", permission: .write),
        .init(name: "wayfile.trash", signature: "(path)", summary: "Moves to the Trash (undoable).", returns: "undefined", permission: .delete),
        .init(name: "wayfile.fetch", signature: "(url, {method, headers, body})", summary: "HTTP request (30 s timeout).", returns: "{status, ok, text, headers}", permission: .network),
        .init(name: "wayfile.sleep", signature: "(ms)", summary: "Waits; Stop still works.", returns: "undefined"),
        .init(name: "wayfile.open", signature: "(pathOrURL)", summary: "Opens a file in its app, or an http(s) / maps / mailto link.", returns: "undefined", interactive: true),
        // Storage
        .init(name: "wayfile.storage.get", signature: "(key)", summary: "A value this script saved earlier (kept across runs and launches), or null.", returns: "any"),
        .init(name: "wayfile.storage.set", signature: "(key, value)", summary: "Saves a JSON value for this script (1 MB in total).", returns: "undefined"),
        .init(name: "wayfile.storage.remove", signature: "(key)", summary: "Forgets a saved value.", returns: "undefined"),
        .init(name: "wayfile.storage.keys", signature: "()", summary: "Keys this script saved.", returns: "string[]"),
        // Images
        .init(name: "wayfile.images.convert", signature: "(paths, {format, maxSize, quality, toFolder, suffix})", summary: "Resized / converted copies; format \"jpeg\" | \"png\" | \"heic\" | \"tiff\" | \"webp\" (if the system can write it), maxSize in pixels, quality 0–1. Originals stay.", returns: "string[]", permission: .write),
        .init(name: "wayfile.images.formats", signature: "()", summary: "Formats images.convert can write on this Mac.", returns: "string[]"),
        // Git
        .init(name: "wayfile.git.status", signature: "(folder)", summary: "Branch, ahead / behind and changed files of the repository containing the folder, or null.", returns: "object | null", permission: .read),
        // Panels
        .init(name: "wayfile.panel.path", signature: "", summary: "The active pane's folder.", returns: "string | null"),
        .init(name: "wayfile.panel.otherPath", signature: "", summary: "The other pane's folder.", returns: "string | null"),
        .init(name: "wayfile.panel.open", signature: "(folder)", summary: "Shows a folder in the active pane.", returns: "undefined", interactive: true),
        .init(name: "wayfile.panel.select", signature: "(paths)", summary: "Selects items in the active pane.", returns: "undefined", interactive: true),
        .init(name: "wayfile.panel.refresh", signature: "()", summary: "Reloads the panes (does nothing without a window).", returns: "undefined"),
        // Dialogs
        .init(name: "wayfile.dialogs.alert", signature: "(message, detail?)", summary: "Shows a message.", returns: "undefined", interactive: true),
        .init(name: "wayfile.dialogs.confirm", signature: "(message, detail?)", summary: "OK / Cancel question.", returns: "boolean", interactive: true),
        .init(name: "wayfile.dialogs.prompt", signature: "(message, defaultValue?)", summary: "Asks for text.", returns: "string | null", interactive: true),
        .init(name: "wayfile.dialogs.chooseFile", signature: "({folders, multiple, message})", summary: "Open panel; returns chosen paths.", returns: "string[] | null", interactive: true),
        // Workspaces
        .init(name: "wayfile.workspaces.list", signature: "()", summary: "Names of saved workspaces.", returns: "string[]", interactive: true),
        .init(name: "wayfile.workspaces.open", signature: "(name)", summary: "Switches to a saved workspace.", returns: "boolean", interactive: true),
    ]

    /// Candidates for what's typed so far, e.g. "wayfile.dia" → `dialogs`; "wayfile.dialogs.c" → `confirm`, `chooseFile`.
    static func completions(for expression: String) -> [Completion] {
        guard let dot = expression.lastIndex(of: ".") else { return [] }
        let object = String(expression[..<dot]) + "."
        let partial = expression[expression.index(after: dot)...]
        var seen = Set<String>()
        var result: [Completion] = []
        for member in members where member.name.hasPrefix(object) {
            let rest = member.name.dropFirst(object.count)
            guard rest.hasPrefix(partial) else { continue }
            let segment = String(rest.split(separator: ".").first ?? "")
            guard !segment.isEmpty, seen.insert(segment).inserted else { continue }
            result.append(Completion(name: segment, member: rest.contains(".") ? nil : member))
        }
        return result
    }
}

struct ScriptPermissionError: LocalizedError {
    let permission: Script.Permission
    var errorDescription: String? { String(localized: "The script needs the “\(permission.rawValue)” permission (add it to @permissions).") }
}

struct ScriptInteractiveError: LocalizedError {
    let member: String
    var errorDescription: String? { String(localized: "\(member) needs a window — it isn't available when a trigger or schedule runs the script.") }
}

// MARK: - Host

/// Runs a JavaScript script with a `wayfile` object. Normally in `wayfile-script-runner`, a helper
/// process in a sandbox with no file, network or process access, so a script's only way to the system is
/// the API below — checked here against its declared permissions. File changes go through FileOps (undoable);
/// in a dry run they are only planned. Without the helper (tests, odd installs) it runs in-process.
final class JSScriptHost {
    private let script: Script
    private let api: ScriptAPIHost
    private let progress: OperationProgress
    private let output: ScriptRunner.Output
    private let context: ScriptContext

    init(script: Script, context: ScriptContext, progress: OperationProgress, output: @escaping ScriptRunner.Output) {
        self.script = script
        self.context = context
        self.progress = progress
        self.output = output
        api = ScriptAPIHost(script: script, context: context, progress: progress, output: output)
    }

    /// The helper: `WAYFILE_SCRIPT_RUNNER` (a path, or "none" for in-process), else next to the app's executable.
    static var runnerURL: URL? {
        if let override = ProcessInfo.processInfo.environment["WAYFILE_SCRIPT_RUNNER"] {
            return override == "none" ? nil : URL(fileURLWithPath: override)
        }
        let url = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("wayfile-script-runner")
        return url.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    static var isIsolated: Bool { runnerURL != nil }

    func run(_ source: String) throws -> ScriptResult {
        let outcome: ScriptEngine.Outcome
        let jsContext = engineContext()
        let log: ScriptEngine.Log = { [output] stream, text in output(ScriptOutputLine(stream: stream == "stderr" ? .stderr : .stdout, text: text)) }
        if let runner = Self.runnerURL {
            outcome = try IsolatedScriptRun(runner: runner, progress: progress)
                .run(source: source, url: script.url, context: jsContext, call: api.call, log: log)
        } else {
            outcome = ScriptEngine().run(source: source, sourceURL: script.url, context: jsContext, call: api.call, log: log)
        }
        switch outcome {
        case .failure(let message, let line):
            if progress.isCancelled { throw CancellationError() }
            output(ScriptOutputLine(stream: .stderr, text: line.map { "Line \($0): \(message)" } ?? message))
            return ScriptResult(status: 1, outputPaths: [], errorLine: line)
        case .success(let value):
            let returned = (value as? [Any]) ?? (value as? String).map { [$0] } ?? []
            let paths = returned.compactMap { $0 as? String }.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            return ScriptResult(status: 0, outputPaths: paths)
        }
    }

    /// Checks syntax without running anything.
    static func checkSyntax(_ source: String) -> (message: String, line: Int?)? { ScriptEngine.checkSyntax(source) }

    private func engineContext() -> [String: Any] { Self.engineContext(for: context) }

    /// Values and function names for the `wayfile` object (built by the engine's prelude).
    static func engineContext(for context: ScriptContext) -> [String: Any] {
        var values: [String: Any] = [
            "version": ScriptAPI.version,
            "selection": context.selection.map(\.path),
            "items": context.selection.map { ScriptWire.plain(ScriptAPIHost.attributes($0)) },
            "count": context.selection.count,
            "home": FileManager.default.homeDirectoryForCurrentUser.path,
            "dryRun": context.dryRun,
        ]
        values["folder"] = context.folder.map { $0.path as Any } ?? NSNull()
        values["otherFolder"] = context.otherFolder.map { $0.path as Any } ?? NSNull()
        var functions: [String] = []
        var spaces: [String: [String]] = [:]
        for member in ScriptAPI.members where member.isFunction && member.name != "wayfile.log" {
            let parts = member.name.split(separator: ".").map(String.init)
            if parts.count == 2 { functions.append(parts[1]) } else if parts.count == 3 { spaces[parts[1], default: []].append(parts[2]) }
        }
        return ["values": values, "functions": functions, "spaces": spaces,
                "spaceValues": ["panel": ["path": values["folder"]!, "otherPath": values["otherFolder"]!]]]
    }
}

/// Talks to `wayfile-script-runner`: sends the script, answers its API calls, collects output.
/// Stop terminates the process — that ends even a script stuck in an endless loop.
final class IsolatedScriptRun {
    private let runner: URL
    private let progress: OperationProgress

    init(runner: URL, progress: OperationProgress) {
        self.runner = runner
        self.progress = progress
    }

    func run(source: String, url: URL, context: [String: Any], call: ScriptEngine.Call, log: ScriptEngine.Log) throws -> ScriptEngine.Outcome {
        let connection = try RunnerConnection(runner: runner)
        defer { connection.close() }
        try connection.send(["type": "start", "source": source, "url": url.path, "context": context])
        return try connection.wait(call: call, log: log, progress: progress)
    }
}

/// One `wayfile-script-runner` process and its pipes.
final class RunnerConnection: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let lines = LineQueue()
    private let stderrLines = LineQueue()

    init(runner: URL) throws {
        process.executableURL = runner
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [lines] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; lines.close() } else { lines.feed(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [stderrLines] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { stderrLines.feed(data) }
        }
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    func send(_ message: [String: Any]) throws {
        try input.fileHandleForWriting.write(contentsOf: ScriptWire.encode(message))
    }

    /// Answers API calls and forwards output until the runner reports `done` or `failed`.
    func wait(call: ScriptEngine.Call, log: ScriptEngine.Log, progress: OperationProgress) throws -> ScriptEngine.Outcome {
        while true {
            guard let line = lines.next(timeout: 0.1) else {
                if progress.isCancelled { close(); throw CancellationError() }
                if lines.isClosed {
                    process.waitUntilExit()
                    if progress.isCancelled { throw CancellationError() }
                    let detail = stderrLines.drain().trimmingCharacters(in: .whitespacesAndNewlines)
                    return .failure(message: "The script runner stopped unexpectedly (status \(process.terminationStatus))" + (detail.isEmpty ? "" : ": " + detail), line: nil)
                }
                continue
            }
            guard let message = ScriptWire.decode(line) else { continue }
            switch message["type"] as? String {
            case "call":
                let name = message["name"] as? String ?? ""
                let args = message["args"] as? [Any] ?? []
                do {
                    let value = try call(name, args)
                    try send(["type": "result", "value": ScriptWire.plain(value)])
                } catch is CancellationError {
                    close()
                    throw CancellationError()
                } catch {
                    try send(["type": "error", "message": error.localizedDescription])
                }
            case "log":
                log(message["stream"] as? String ?? "stdout", message["text"] as? String ?? "")
            case "done":
                let value = message["value"]
                return .success(value is NSNull ? nil : value)
            case "failed":
                return .failure(message: message["message"] as? String ?? "JavaScript error", line: message["line"] as? Int)
            default:
                continue
            }
        }
    }

    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
    }
}

/// A JavaScript script kept alive between calls — what plugin panels run on. Loads once, then each
/// `invoke` calls one of its functions (`render`, `action`…) with fresh context; the script's own
/// variables survive. Same isolation and permission checks as a script run; one call at a time.
final class ScriptSession: @unchecked Sendable {
    private let script: Script
    private let queue = DispatchQueue(label: "dev.wayfile.plugin-session")
    private var engine: ScriptEngine?
    private var connection: RunnerConnection?
    /// Who answers API calls for the call in progress (in-process engine).
    private var host: ScriptAPIHost?

    init(script: Script) {
        self.script = script
    }

    /// Loads the script; `context` also fills `wayfile.*`.
    func start(context: ScriptContext, output: @escaping ScriptRunner.Output) async throws -> ScriptEngine.Outcome {
        let source = try String(contentsOf: script.url, encoding: .utf8)
        return try await onQueue { [self] in
            let progress = OperationProgress()
            let api = ScriptAPIHost(script: script, context: context, progress: progress, output: output)
            let jsContext = JSScriptHost.engineContext(for: context)
            let log = Self.log(output)
            if let runner = JSScriptHost.runnerURL {
                let connection = try RunnerConnection(runner: runner)
                self.connection = connection
                try connection.send(["type": "start", "source": source, "url": script.url.path, "context": jsContext, "session": true])
                return try connection.wait(call: api.call, log: log, progress: progress)
            }
            let engine = ScriptEngine()
            self.engine = engine
            host = api
            return engine.load(source: source, sourceURL: script.url, context: jsContext, call: { [weak self] in try self?.host?.call($0, $1) }, log: log)
        }
    }

    /// Calls `function(args…)`; `wayfile.*` is updated to `context` first. File changes are recorded in `progress`.
    func invoke(_ function: String, args: [Any], context: ScriptContext, progress: OperationProgress,
                output: @escaping ScriptRunner.Output) async throws -> ScriptEngine.Outcome {
        try await onQueue { [self] in
            let api = ScriptAPIHost(script: script, context: context, progress: progress, output: output)
            let values = JSScriptHost.engineContext(for: context)["values"] as? [String: Any] ?? [:]
            let plainArgs = args.map { ScriptWire.plain($0) }
            if let connection {
                guard connection.isRunning else { return .failure(message: "The plugin stopped — reopen it.", line: nil) }
                try connection.send(["type": "invoke", "function": function, "args": plainArgs, "values": values])
                return try connection.wait(call: api.call, log: Self.log(output), progress: progress)
            }
            guard let engine else { return .failure(message: "The plugin isn't loaded.", line: nil) }
            host = api
            defer { host = nil }
            return engine.invoke(function, args: plainArgs, values: values)
        }
    }

    func close() {
        queue.async { [self] in
            connection?.close()
            connection = nil
            engine = nil
        }
    }

    deinit { connection?.close() }

    private static func log(_ output: @escaping ScriptRunner.Output) -> ScriptEngine.Log {
        { stream, text in output(ScriptOutputLine(stream: stream == "stderr" ? .stderr : .stdout, text: text)) }
    }

    private func onQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Lines from a pipe, handed to a waiting reader (thread-safe).
private final class LineQueue: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var ready: [Data] = []
    private(set) var isClosed = false

    func feed(_ data: Data) {
        lock.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                ready.append(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                signal.signal()
            }
        }
    }

    func close() {
        lock.withLock { isClosed = true }
        signal.signal()
    }

    func next(timeout: TimeInterval) -> Data? {
        if let line = lock.withLock({ ready.isEmpty ? nil : ready.removeFirst() }) { return line }
        _ = signal.wait(timeout: .now() + timeout)
        return lock.withLock { ready.isEmpty ? nil : ready.removeFirst() }
    }

    func drain() -> String {
        lock.withLock { String(decoding: ready.reduce(Data(), +) + buffer, as: UTF8.self) }
    }
}

/// The `wayfile` API, on plain values: what both the in-process engine and the runner call into.
final class ScriptAPIHost {
    private let script: Script
    private let context: ScriptContext
    private let progress: OperationProgress
    private let output: ScriptRunner.Output

    init(script: Script, context: ScriptContext, progress: OperationProgress, output: @escaping ScriptRunner.Output) {
        self.script = script
        self.context = context
        self.progress = progress
        self.output = output
    }

    // swiftlint:disable:next cyclomatic_complexity
    func call(_ name: String, _ raw: [Any]) throws -> Any? {
        let args = raw.map { $0 is NSNull ? nil : $0 } as [Any?]
        switch name {
        case "list":
            try require(.read)
            let url = try path(args, 0)
            return try FileManager.default.contentsOfDirectory(atPath: url.path)
                .filter { !$0.hasPrefix(".") }.sorted().map { url.appendingPathComponent($0).path }
        case "exists": return FileManager.default.fileExists(atPath: try path(args, 0).path)
        case "isDirectory": return FileSystem.isDirectory(try path(args, 0))
        case "modified":
            let values = try path(args, 0).resourceValues(forKeys: [.contentModificationDateKey])
            return (values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000
        case "size": return Double((try path(args, 0).resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
        case "readText":
            try require(.read)
            return try String(contentsOf: try path(args, 0), encoding: .utf8)
        case "checksum":
            try require(.read)
            return try Self.checksum(try path(args, 0), algorithm: string(args, 1)?.lowercased() ?? "sha256", progress: progress)
        case "metadata":
            try require(.metadata, or: .read)
            return try Self.metadata(try path(args, 0))
        case "writeText":
            try require(.write)
            let url = try path(args, 0)
            let text = string(args, 1) ?? ""
            if context.dryRun {
                let exists = FileManager.default.fileExists(atPath: url.path)
                return plan(ScriptPlanStep(action: exists ? .write : .create, path: url.path, target: url.path,
                                           conflict: exists ? "the current file goes to the Trash" : nil))
            }
            if FileManager.default.fileExists(atPath: url.path) { _ = try FileOps.trash([url], progress: progress) }
            try text.write(to: url, atomically: true, encoding: .utf8)
            progress.record(.created([url]))
            return url.path
        case "mkdir":
            try require(.write)
            let url = try path(args, 0)
            if FileManager.default.fileExists(atPath: url.path) { return url.path }
            if context.dryRun { return plan(ScriptPlanStep(action: .mkdir, path: url.path, target: url.path)) }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            progress.record(.created([url]))
            return url.path
        case "move", "copy":
            return try transfer([try path(args, 0)], to: try path(args, 1), move: name == "move", policy: .keepBoth).first
        case "transfer":
            guard args.count > 1 else { throw ShellError(message: "transfer(paths, toFolder, options) needs a destination") }
            let sources = try paths(args, 0)
            let options = args.count > 2 ? args[2] as? [String: Any] : nil
            let mode = options?["mode"] as? String ?? "copy"
            guard mode == "copy" || mode == "move" else { throw ShellError(message: "transfer: mode must be \"copy\" or \"move\"") }
            let policy: FileOps.ConflictPolicy
            switch options?["conflict"] as? String ?? "keepBoth" {
            case "skip": policy = .skip
            case "replace":
                try require(.delete)
                policy = .replace
            case "keepBoth": policy = .keepBoth
            case let other: throw ShellError(message: "transfer: unknown conflict policy “\(other)”")
            }
            return try transfer(sources, to: try path(args, 1), move: mode == "move", policy: policy)
        case "rename":
            try require(.write)
            let url = try path(args, 0)
            guard let newName = string(args, 1), !newName.isEmpty else { throw ShellError(message: "rename(path, newName) needs a new name") }
            let target = url.deletingLastPathComponent().appendingPathComponent(newName)
            if context.dryRun {
                let clash = FileManager.default.fileExists(atPath: target.path) && target.path.lowercased() != url.path.lowercased()
                return plan(ScriptPlanStep(action: .rename, path: url.path, target: target.path, conflict: clash ? "“\(newName)” already exists" : nil))
            }
            let renamed = try FileOps.rename(url, to: newName)
            progress.record(.moved([MovedItem(from: url, to: renamed)]))
            return renamed.path
        case "trash":
            try require(.delete)
            let url = try path(args, 0)
            if context.dryRun {
                _ = plan(ScriptPlanStep(action: .trash, path: url.path))
                return nil
            }
            _ = try FileOps.trash([url], progress: progress)
            return nil
        case "tag":
            try require(.write)
            let url = try path(args, 0)
            guard let tagName = string(args, 1), !tagName.isEmpty else { throw ShellError(message: "tag(path, name) needs a tag name") }
            if context.dryRun { return plan(ScriptPlanStep(action: .tag, path: url.path, target: url.path, detail: tagName)) }
            let old = TagIO.read(url)
            guard !old.contains(where: { $0.name == tagName }) else { return url.path }
            let new = old + [TagIO.named(tagName)]
            try TagIO.write(new, to: url)
            progress.record(.tagged([TagChange(url: url, old: old, new: new)]))
            return url.path
        case "fetch":
            try require(.network)
            guard let text = string(args, 0), let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw ShellError(message: "fetch(url) needs an http(s) URL")
            }
            return try fetch(url, options: args.count > 1 ? args[1] as? [String: Any] : nil)
        case "sleep":
            var remaining = (args.first as? NSNumber)?.doubleValue ?? 0
            while remaining > 0 {
                try progress.checkCancelled()
                Thread.sleep(forTimeInterval: min(remaining, 50) / 1000)
                remaining -= 50
            }
            return nil

        case "panel.open":
            let url = try path(args, 0)
            let ui = try self.ui(name)
            onMain { ui.open(url) }
            return nil
        case "panel.select":
            let urls = try paths(args, 0)
            let ui = try self.ui(name)
            onMain { ui.select(urls) }
            return nil
        case "panel.refresh":
            // Nothing to refresh without a window — not an error.
            guard let ui = context.ui else { return nil }
            onMain { ui.refresh() }
            return nil

        case "dialogs.alert":
            _ = try ui(name)
            let (message, detail) = (string(args, 0) ?? "", string(args, 1))
            onMain { _ = Self.alert(message, detail, buttons: ["OK"]) }
            return nil
        case "dialogs.confirm":
            _ = try ui(name)
            let (message, detail) = (string(args, 0) ?? "", string(args, 1))
            return onMain { Self.alert(message, detail, buttons: ["OK", "Cancel"]) == 0 }
        case "dialogs.prompt":
            _ = try ui(name)
            let (message, value) = (string(args, 0) ?? "", string(args, 1) ?? "")
            return onMain { Self.prompt(message, value) }
        case "dialogs.chooseFile":
            _ = try ui(name)
            let options = args.first as? [String: Any]
            let folders = options?["folders"] as? Bool ?? false
            let multiple = options?["multiple"] as? Bool ?? false
            let message = options?["message"] as? String
            return onMain { Self.choose(folders: folders, multiple: multiple, message: message) }

        case "workspaces.list":
            let ui = try self.ui(name)
            return onMain { ui.workspaces() }
        case "workspaces.open":
            let ui = try self.ui(name)
            let workspace = string(args, 0) ?? ""
            return onMain { ui.openWorkspace(workspace) }

        case "open":
            let _ = try ui(name)
            guard let target = string(args, 0), !target.isEmpty else { throw ShellError(message: "open(pathOrURL) needs a path or a link") }
            if let url = URL(string: target), let scheme = url.scheme?.lowercased(), scheme != "file" {
                guard ["http", "https", "maps", "mailto"].contains(scheme) else { throw ShellError(message: "open: “\(scheme):” links aren't allowed") }
                onMain { _ = NSWorkspace.shared.open(url) }
            } else {
                try require(.read)
                let url = resolve(target)
                guard FileManager.default.fileExists(atPath: url.path) else { throw ShellError(message: "No such file: \(url.path)") }
                onMain { _ = NSWorkspace.shared.open(url) }
            }
            return nil

        case "storage.get":
            return ScriptStorage.load(for: script)[string(args, 0) ?? ""]
        case "storage.set":
            guard let key = string(args, 0), !key.isEmpty else { throw ShellError(message: "storage.set(key, value) needs a key") }
            try ScriptStorage.update(for: script) { $0[key] = args.count > 1 ? args[1] ?? NSNull() : NSNull() }
            return nil
        case "storage.remove":
            let key = string(args, 0) ?? ""
            try ScriptStorage.update(for: script) { $0[key] = nil }
            return nil
        case "storage.keys":
            return ScriptStorage.load(for: script).keys.sorted()

        case "images.formats":
            return ImageConverter.writableFormats
        case "images.convert":
            try require(.read)
            try require(.write)
            let options = args.count > 1 ? args[1] as? [String: Any] ?? [:] : [:]
            let request = try ImageConverter.Request(options: options)
            var created: [String] = []
            for source in try paths(args, 0) {
                try progress.checkCancelled()
                let folder = (options["toFolder"] as? String).map(resolve) ?? source.deletingLastPathComponent()
                let target = FileOps.uniqueURL(folder.appendingPathComponent(request.fileName(for: source)))
                if context.dryRun {
                    if let path = plan(ScriptPlanStep(action: .create, path: target.path, target: target.path, detail: "from \(source.lastPathComponent)")) { created.append(path) }
                    continue
                }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try ImageConverter.convert(source, to: target, request: request)
                progress.record(.created([target]))
                created.append(target.path)
            }
            return created

        case "git.status":
            try require(.read)
            let folder = try path(args, 0)
            let box = GitBox()
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                box.info = await Git.info(for: folder)
                done.signal()
            }
            done.wait()
            guard let info = box.info else { return NSNull() }
            return [
                "root": info.root.path, "branch": info.branch, "upstream": info.upstream ?? NSNull(),
                "ahead": info.ahead, "behind": info.behind, "changed": info.changedCount,
                "changes": info.statuses.sorted { $0.key < $1.key }.map { ["path": $0.key, "status": $0.value.rawValue] },
            ] as [String: Any]

        default:
            throw ShellError(message: "Unknown API function “\(name)”")
        }
    }

    // MARK: Helpers

    private func transfer(_ sources: [URL], to dir: URL, move: Bool, policy: FileOps.ConflictPolicy) throws -> [String] {
        try require(.write)
        if context.dryRun {
            let clashes = Set(FileOps.conflicts(sources, in: dir).map(\.lastPathComponent))
            return sources.compactMap { src in
                let target = dir.appendingPathComponent(src.lastPathComponent).path
                guard clashes.contains(src.lastPathComponent) else {
                    return plan(ScriptPlanStep(action: move ? .move : .copy, path: src.path, target: target))
                }
                switch policy {
                case .skip:
                    _ = plan(ScriptPlanStep(action: .skip, path: src.path, target: target, conflict: "already in \(dir.lastPathComponent)"))
                    return nil
                case .replace:
                    return plan(ScriptPlanStep(action: move ? .move : .copy, path: src.path, target: target, conflict: "replaces the existing one"))
                case .keepBoth:
                    return plan(ScriptPlanStep(action: move ? .move : .copy, path: src.path, target: target, conflict: "exists — keeps both"))
                }
            }
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try FileOps.transfer(sources, to: dir, mode: move ? .move : .copy, policy: policy, progress: progress).map(\.path)
    }

    private func fetch(_ url: URL, options: [String: Any]?) throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 30)
        if let method = options?["method"] as? String { request.httpMethod = method.uppercased() }
        if let body = options?["body"] as? String { request.httpBody = body.data(using: .utf8) }
        if let headers = options?["headers"] as? [String: Any] {
            for (key, value) in headers { request.setValue("\(value)", forHTTPHeaderField: key) }
        }
        let box = FetchBox()
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            box.set(data, response as? HTTPURLResponse, error)
            semaphore.signal()
        }
        task.resume()
        while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
            if progress.isCancelled {
                task.cancel()
                throw CancellationError()
            }
        }
        let (data, response, error) = box.get()
        if let error { throw error }
        let status = response?.statusCode ?? 0
        let headers = (response?.allHeaderFields ?? [:]).reduce(into: [String: String]()) { $0["\($1.key)".lowercased()] = "\($1.value)" }
        return ["status": status, "ok": (200..<300).contains(status), "text": String(decoding: data ?? Data(), as: UTF8.self), "headers": headers]
    }

    /// Dry run: reports the change instead of making it; returns the path it would produce.
    private func plan(_ step: ScriptPlanStep) -> String? {
        output(ScriptOutputLine(stream: .info, text: step.sentence, plan: step))
        return step.target
    }

    private func require(_ permission: Script.Permission, or alternative: Script.Permission? = nil) throws {
        try progress.checkCancelled()
        if let alternative, script.permissions.contains(alternative) { return }
        guard script.permissions.contains(permission) else { throw ScriptPermissionError(permission: permission) }
    }

    private func ui(_ member: String) throws -> ScriptUI {
        try progress.checkCancelled()
        guard let ui = context.ui else { throw ScriptInteractiveError(member: member) }
        return ui
    }

    /// Runs on the main thread and waits (scripts run on a background thread).
    private func onMain<T>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(body) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    private func string(_ args: [Any?], _ index: Int) -> String? {
        guard args.count > index, let value = args[index] else { return nil }
        return value as? String ?? "\(value)"
    }

    /// Argument `index` as a file URL; relative paths resolve against the current folder.
    private func path(_ args: [Any?], _ index: Int) throws -> URL {
        guard let text = string(args, index), !text.isEmpty else { throw ShellError(message: "Missing path argument \(index + 1)") }
        return resolve(text)
    }

    /// A path or an array of paths.
    private func paths(_ args: [Any?], _ index: Int) throws -> [URL] {
        if args.count > index, let list = args[index] as? [Any] { return list.compactMap { $0 as? String }.map(resolve) }
        return [try path(args, index)]
    }

    private func resolve(_ text: String) -> URL {
        let path = (text as NSString).expandingTildeInPath
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return (context.folder ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).appendingPathComponent(path)
    }

    // MARK: File details

    static func attributes(_ url: URL) -> [String: Any] {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey, .isDirectoryKey])
        return [
            "path": url.path,
            "name": url.lastPathComponent,
            "ext": url.pathExtension.lowercased(),
            "isDirectory": values?.isDirectory ?? false,
            "size": Double(values?.fileSize ?? 0),
            "modified": (values?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000,
            "created": (values?.creationDate?.timeIntervalSince1970 ?? 0) * 1000,
        ]
    }

    static func metadata(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ShellError(message: "No such file: \(url.path)") }
        var info = attributes(url)
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .localizedTypeDescriptionKey, .isHiddenKey, .contentAccessDateKey])
        info["type"] = values?.localizedTypeDescription ?? ""
        info["uti"] = values?.contentType?.identifier ?? ""
        info["hidden"] = values?.isHidden ?? false
        info["accessed"] = (values?.contentAccessDate?.timeIntervalSince1970 ?? 0) * 1000
        info["tags"] = TagIO.read(url).map(\.name)
        if values?.contentType?.conforms(to: .image) == true, let image = imageMetadata(url) { info["image"] = image }
        return info
    }

    /// Width, height, orientation and the EXIF / TIFF / GPS dictionaries as plain values.
    static func imageMetadata(_ url: URL) -> [String: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
        var image: [String: Any] = [:]
        image["width"] = props[kCGImagePropertyPixelWidth as String] ?? 0
        image["height"] = props[kCGImagePropertyPixelHeight as String] ?? 0
        if let orientation = props[kCGImagePropertyOrientation as String] { image["orientation"] = orientation }
        for (key, name) in [(kCGImagePropertyExifDictionary, "exif"), (kCGImagePropertyTIFFDictionary, "tiff"), (kCGImagePropertyGPSDictionary, "gps")] {
            if let dict = props[key as String] { image[name] = plain(dict) }
        }
        return image
    }

    /// Property-list values as JSON-like values JavaScript understands.
    static func plain(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]: return dict.mapValues(plain)
        case let array as [Any]: return array.map(plain)
        case let number as NSNumber: return number
        case let string as String: return string
        case let date as Date: return date.timeIntervalSince1970 * 1000
        case let data as Data: return data.base64EncodedString()
        default: return "\(value)"
        }
    }

    static func checksum(_ url: URL, algorithm: String, progress: OperationProgress) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        func digest<H: HashFunction>(_ hasher: inout H) throws -> String {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                try progress.checkCancelled()
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        switch algorithm {
        case "md5": var h = Insecure.MD5(); return try digest(&h)
        case "sha1": var h = Insecure.SHA1(); return try digest(&h)
        case "sha256": var h = SHA256(); return try digest(&h)
        default: throw ShellError(message: "checksum: unknown algorithm “\(algorithm)” (md5, sha1, sha256)")
        }
    }

    // MARK: Dialogs (main thread)

    @MainActor
    static func alert(_ message: String, _ detail: String?, buttons: [String]) -> Int {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail ?? ""
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    @MainActor
    static func prompt(_ message: String, _ value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    @MainActor
    static func choose(folders: Bool, multiple: Bool, message: String?) -> [String]? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folders
        panel.canChooseFiles = !folders
        panel.allowsMultipleSelection = multiple
        if let message { panel.message = message }
        return panel.runModal() == .OK ? panel.urls.map(\.path) : nil
    }
}

private final class FetchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (Data?, HTTPURLResponse?, Error?) = (nil, nil, nil)
    func set(_ data: Data?, _ response: HTTPURLResponse?, _ error: Error?) { lock.withLock { value = (data, response, error) } }
    func get() -> (Data?, HTTPURLResponse?, Error?) { lock.withLock { value } }
}

private final class GitBox: @unchecked Sendable { var info: GitInfo? }

// MARK: - Script storage

/// Per-script saved values (`wayfile.storage`): JSON in Application Support/Wayfile/ScriptData/<file name>.json.
enum ScriptStorage {
    static let limit = 1_000_000
    private static let lock = NSLock()

    static var folder: URL {
        if let custom = ProcessInfo.processInfo.environment["WAYFILE_SCRIPT_DATA_DIR"] { return URL(fileURLWithPath: custom, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Wayfile/ScriptData", isDirectory: true)
    }

    static func url(for script: Script) -> URL { folder.appendingPathComponent(script.url.lastPathComponent + ".json") }

    static func load(for script: Script) -> [String: Any] {
        lock.withLock { read(url(for: script)) }
    }

    static func update(for script: Script, _ change: (inout [String: Any]) -> Void) throws {
        try lock.withLock {
            let url = url(for: script)
            var values = read(url)
            change(&values)
            let data = try JSONSerialization.data(withJSONObject: values.mapValues { ScriptWire.plain($0) }, options: [.sortedKeys])
            guard data.count <= limit else { throw ShellError(message: "storage is full (1 MB per script)") }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    private static func read(_ url: URL) -> [String: Any] {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
}

// MARK: - Images

/// Resizing and format conversion with ImageIO (orientation applied, metadata kept where the format allows).
enum ImageConverter {
    struct Request {
        let format: String
        let maxSize: Int?
        let quality: Double
        let suffix: String?

        init(options: [String: Any]) throws {
            format = (options["format"] as? String ?? "jpeg").lowercased().replacingOccurrences(of: "jpg", with: "jpeg")
            guard ImageConverter.types[format] != nil else { throw ShellError(message: "images.convert: unknown format “\(format)”") }
            guard ImageConverter.writableFormats.contains(format) else { throw ShellError(message: "images.convert: this Mac can't write \(format)") }
            maxSize = (options["maxSize"] as? NSNumber).map(\.intValue).flatMap { $0 > 0 ? $0 : nil }
            quality = min(max((options["quality"] as? NSNumber)?.doubleValue ?? 0.85, 0.05), 1)
            suffix = options["suffix"] as? String
        }

        func fileName(for source: URL) -> String {
            let base = source.deletingPathExtension().lastPathComponent
            let ext = ImageConverter.extensions[format] ?? format
            let sameFormat = source.pathExtension.lowercased() == ext || (ext == "jpg" && source.pathExtension.lowercased() == "jpeg")
            let suffix = self.suffix ?? (maxSize != nil ? "-\(maxSize!)" : sameFormat ? "-copy" : "")
            return base + suffix + "." + ext
        }
    }

    static let types: [String: String] = ["jpeg": "public.jpeg", "png": "public.png", "heic": "public.heic", "tiff": "public.tiff", "webp": "org.webmproject.webp"]
    static let extensions: [String: String] = ["jpeg": "jpg", "png": "png", "heic": "heic", "tiff": "tiff", "webp": "webp"]

    static var writableFormats: [String] {
        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        return ["jpeg", "png", "heic", "tiff", "webp"].filter { writable.contains(types[$0]!) }
    }

    static func convert(_ source: URL, to target: URL, request: Request) throws {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(input) > 0 else {
            throw ShellError(message: "Not an image: \(source.lastPathComponent)")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any] ?? [:]
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0, height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(request.maxSize ?? max(width, height), max(width, height, 1)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary),
              let output = CGImageDestinationCreateWithURL(target as CFURL, types[request.format]! as CFString, 1, nil) else {
            throw ShellError(message: "Couldn't convert \(source.lastPathComponent)")
        }
        var meta = props
        // The transform is already applied; keep EXIF / GPS but not the old orientation and size.
        meta[kCGImagePropertyOrientation] = 1
        meta[kCGImagePropertyPixelWidth] = nil
        meta[kCGImagePropertyPixelHeight] = nil
        meta[kCGImageDestinationLossyCompressionQuality] = request.quality
        CGImageDestinationAddImage(output, image, meta as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw ShellError(message: "Couldn't write \(target.lastPathComponent)") }
    }
}
