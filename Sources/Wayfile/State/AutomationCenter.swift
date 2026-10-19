import AppKit
import CryptoKit
import Foundation
import Observation

/// One script run as shown in the console.
@MainActor
@Observable
final class ScriptRun: Identifiable {
    enum Status: Equatable {
        case running, finished(Int32), failed(String), cancelled
    }

    let id = UUID()
    /// The persisted record in ScriptRunLog.
    let recordID = UUID()
    let title: String
    let trigger: String
    let dryRun: Bool
    let started = Date()
    var finished: Date?
    var status: Status = .running
    var lines: [ScriptOutputLine] = []
    var task: Task<Void, Never>?
    /// For a dry run: runs the same script on the same items for real.
    var runForReal: (() -> Void)?

    /// What a JavaScript dry run would change.
    var plan: [ScriptPlanStep] { lines.compactMap(\.plan) }

    init(title: String, trigger: String, dryRun: Bool) {
        self.title = title
        self.trigger = trigger
        self.dryRun = dryRun
    }

    var succeeded: Bool { status == .finished(0) }

    /// Output callback for the runner: lines hop to the main queue in order.
    nonisolated var appender: ScriptRunner.Output {
        { [weak self] line in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.lines.append(line) } }
        }
    }
}

struct ScriptExitError: LocalizedError {
    let status: Int32
    var errorDescription: String? { String(localized: "The script exited with status \(status).") }
}

/// Scripts, Shortcuts and their runs: approvals, console, folder triggers and schedules.
@MainActor
@Observable
final class AutomationCenter {
    static let shared = AutomationCenter(folder: ProcessInfo.processInfo.environment["WAYFILE_SCRIPTS_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? ScriptLibrary.folder)

    private(set) var scripts: [Script] = []
    private(set) var runs: [ScriptRun] = []
    private(set) var shortcuts: [String] = []
    let folder: URL
    private var libraryWatcher: FolderWatcher?
    private var triggerWatcher: FolderWatcher?
    private var scheduleTimer: Timer?
    private var lastScheduledRun: [URL: Date] = [:]
    private var runningScripts: Set<URL> = []
    private var pendingTriggered: [URL: Set<URL>] = [:]
    private var triggerFlush: Task<Void, Never>?
    private static let runLimit = 50

    init(folder: URL = ScriptLibrary.folder) {
        self.folder = folder
    }

    private var keyMonitor: Any?
    private var operationObserver: NSObjectProtocol?

    /// Loads scripts and starts watching the library, trigger folders and schedules.
    func start() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleShortcut(event) == true ? nil : event }
        }
        operationObserver = NotificationCenter.default.addObserver(forName: .operationRecorded, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["entry"] as? UUID else { return }
            MainActor.assumeIsolated { self?.operationFinished(id) }
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        reload()
        #if DEBUG
        // Dev aid: WAYFILE_APPROVE_SCRIPTS=1 allows every script in the (test) Scripts folder.
        if ProcessInfo.processInfo.environment["WAYFILE_APPROVE_SCRIPTS"] != nil { scripts.forEach(approve) }
        #endif
        libraryWatcher = FolderWatcher(folders: [folder], latency: 0.3) { [weak self] _ in self?.reload() }
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runDueSchedules() }
        }
        Task { await loadShortcuts() }
    }

    func reload() {
        scripts = ScriptLibrary.scripts(in: folder)
        let folders = Set(scripts.compactMap(\.triggerFolder).map(\.standardizedFileURL))
        triggerWatcher = FolderWatcher(folders: Array(folders), latency: 1) { [weak self] changes in
            self?.handle(changes)
        }
    }

    func loadShortcuts() async {
        shortcuts = await Shortcuts.list()
    }

    /// Scripts to run on a selection (plugins are opened, not run, so they're not listed).
    func scripts(for selection: [URL]) -> [Script] {
        scripts.filter { $0.panel == nil && $0.showInMenu && isEnabled($0) && $0.applies(to: selection) }
    }

    /// Plugins with an interface: Inspector ones for a selection they apply to, or window ones.
    func panels(_ placement: ScriptPanel, for selection: [URL] = []) -> [Script] {
        scripts.filter { $0.panel == placement && isEnabled($0) && (placement == .window || $0.applies(to: selection)) }
    }

    /// Asks once before a plugin's code runs (plugins run as soon as they're shown).
    func requestApproval(_ script: Script) -> Bool {
        isApproved(script) || confirm(script)
    }

    // MARK: Enabled

    /// Disabled scripts stay in the manager but aren't offered in menus and never run automatically.
    private var disabled: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "scripts.disabled") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "scripts.disabled") }
    }

    func isEnabled(_ script: Script) -> Bool {
        _ = approvalVersion
        return !disabled.contains(script.url.lastPathComponent)
    }

    func setEnabled(_ script: Script, _ enabled: Bool) {
        if enabled { disabled.remove(script.url.lastPathComponent) } else { disabled.insert(script.url.lastPathComponent) }
        approvalVersion += 1
    }

    /// Scripts that may run on their own (trigger, schedule, @after).
    private func mayRunAutomatically(_ script: Script) -> Bool {
        Features.shared.isOn(.automation) && isEnabled(script) && isApproved(script) && allowsAutomaticRuns(script)
            && !runningScripts.contains(script.url)
    }

    // MARK: Import

    /// Imported scripts run only when you start them, until automatic runs are allowed for them.
    private var manualOnly: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "scripts.manualOnly") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "scripts.manualOnly") }
    }

    func allowsAutomaticRuns(_ script: Script) -> Bool {
        _ = approvalVersion
        return !manualOnly.contains(script.url.lastPathComponent)
    }

    func setAllowsAutomaticRuns(_ script: Script, _ allowed: Bool) {
        if allowed { manualOnly.remove(script.url.lastPathComponent) } else { manualOnly.insert(script.url.lastPathComponent) }
        approvalVersion += 1
    }

    /// Installs a reviewed package: not approved (asks before the first run) and with automatic runs off.
    @discardableResult
    func install(_ package: ScriptPackage, language: Script.Language) throws -> URL {
        let url = try ScriptPackage.install(package, language: language, in: folder)
        manualOnly.insert(url.lastPathComponent)
        // A stale approval for an earlier script at this path must not carry over.
        approvals[url.path] = nil
        approvalVersion += 1
        reload()
        return url
    }

    // MARK: Approval

    private var approvals: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "scripts.approved") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "scripts.approved") }
    }

    /// Approval is tied to the script's exact contents: editing it asks again.
    func isApproved(_ script: Script) -> Bool {
        _ = approvalVersion
        return approvals[script.url.path] == Self.fingerprint(script.url)
    }

    func approve(_ script: Script) {
        approvals[script.url.path] = Self.fingerprint(script.url)
        approvalVersion += 1
    }

    /// Bumped on approval changes so views re-read `isApproved`.
    private(set) var approvalVersion = 0

    nonisolated static func fingerprint(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Running

    /// Runs a script for the user; the first run (and the first after an edit) needs approval.
    func request(_ script: Script, context: ScriptContext) {
        guard isApproved(script) || confirm(script) else { return }
        run(script, context: context, trigger: "Manual")
    }

    /// Declared permissions are shown; only JavaScript is actually held to them.
    private func confirm(_ script: Script) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Run “\(script.name)”?")
        let declared = script.permissions.sorted().map { "• \($0.title)" }.joined(separator: "\n")
        var parts = [declared.isEmpty ? String(localized: "The script declares no permissions.") : String(localized: "The script declares:\n\(declared)")]
        if script.language == .javascript {
            parts.append(JSScriptHost.isIsolated
                ? String(localized: "JavaScript scripts run in a sandboxed helper with no file, network or process access of their own — they can only do what they declare, through Wayfile. Their changes can be undone from the Timeline.")
                : String(localized: "JavaScript scripts can only do what they declare. Their changes can be undone from the Timeline."))
        } else {
            parts.append(String(localized: "\(script.language.title) scripts run with your user's full access; declared permissions are informational. Only run scripts you trust."))
        }
        if script.triggerFolder != nil || script.scheduleMinutes != nil || !script.after.isEmpty {
            parts.append(allowsAutomaticRuns(script)
                ? String(localized: "Allowing it also enables its automatic runs (folder trigger / schedule / after operations).")
                : String(localized: "It was imported: its automatic runs stay off until you allow them in Automation."))
        }
        let info = parts.joined(separator: "\n\n")
        alert.informativeText = info
        alert.addButton(withTitle: String(localized: "Always Allow"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.alertStyle = script.language == .javascript ? .informational : .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        approve(script)
        return true
    }

    func revoke(_ script: Script) {
        approvals[script.url.path] = nil
        approvalVersion += 1
    }

    @discardableResult
    func run(_ script: Script, context: ScriptContext, trigger: String) -> ScriptRun {
        let title = (context.dryRun ? "Dry run: " : "") + script.name
        let run = ScriptRun(title: title, trigger: trigger, dryRun: context.dryRun)
        add(run, script: script.name, path: script.url.path, language: script.language.title)
        runningScripts.insert(script.url)
        if context.dryRun {
            run.runForReal = { [weak self] in
                var real = context
                real.dryRun = false
                self?.request(Script.load(script.url) ?? script, context: real)
            }
        }
        let entryID = UUID()
        run.task = Task {
            defer { runningScripts.remove(script.url) }
            do {
                _ = try await OperationCenter.shared.run("Script: \(title)", undoTitle: "Script", entryID: entryID) { progress in
                    let result = try await ScriptRunner.run(script, context: context, progress: progress, output: run.appender)
                    // A failing script is a failed operation (the Timeline shows it), but what it changed stays undoable.
                    if result.status != 0 { throw ScriptExitError(status: result.status) }
                    return result.outputPaths
                }
                run.status = .finished(0)
            } catch let exit as ScriptExitError {
                run.status = .finished(exit.status)
            } catch is CancellationError {
                run.status = .cancelled
            } catch {
                run.status = .failed(error.localizedDescription)
            }
            finish(run, timelineEntry: entryID)
        }
        return run
    }

    func runShortcut(_ name: String, input: [URL]) {
        let run = ScriptRun(title: "Shortcut: \(name)", trigger: "Manual", dryRun: false)
        add(run, script: name, path: "", language: "Shortcut")
        run.task = Task {
            do {
                let result = try await Shortcuts.run(name, input: input, progress: OperationProgress(), output: run.appender)
                run.status = .finished(result.status)
            } catch is CancellationError {
                run.status = .cancelled
            } catch {
                run.status = .failed(error.localizedDescription)
            }
            finish(run)
        }
    }

    /// Runs a shell command line (project commands) in a login shell, output in the console.
    func runCommand(_ command: String, title: String, in folder: URL) {
        let run = ScriptRun(title: title, trigger: folder.lastPathComponent, dryRun: false)
        add(run, script: title, path: "", language: "Command")
        run.lines.append(ScriptOutputLine(stream: .info, text: "$ \(command)"))
        run.task = Task {
            do {
                let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                let result = try await ScriptRunner.process(shell, ["-l", "-c", command], cwd: folder, environment: [:],
                                                            progress: OperationProgress(), output: run.appender)
                run.status = .finished(result.status)
            } catch is CancellationError {
                run.status = .cancelled
            } catch {
                run.status = .failed(error.localizedDescription)
            }
            finish(run)
        }
    }

    func clearRuns() {
        runs.removeAll { $0.status != .running }
    }

    private func add(_ run: ScriptRun, script: String, path: String, language: String) {
        runs.insert(run, at: 0)
        if runs.count > Self.runLimit { runs.removeLast(runs.count - Self.runLimit) }
        ScriptRunLog.shared.start(ScriptRunRecord(id: run.recordID, scriptName: script, scriptPath: path, language: language,
                                                  trigger: run.trigger, dryRun: run.dryRun, started: run.started))
    }

    /// Ends the run in the console and the persisted log, with the files its Timeline entry changed.
    private func finish(_ run: ScriptRun, timelineEntry: UUID? = nil) {
        run.finished = Date()
        let outcome: ScriptRunRecord.Outcome
        switch run.status {
        case .running, .finished(0): outcome = .succeeded
        case .finished(let status): outcome = .exited(status)
        case .failed(let message): outcome = .failed(message)
        case .cancelled: outcome = .cancelled
        }
        let entry = timelineEntry.flatMap { TimelineStore.shared.entry($0) }
        let changed = entry.map { ActivityModel.events(from: [$0]).map(\.path) } ?? []
        // Output lines arrive on the main queue after the process ends; let them land first.
        DispatchQueue.main.async {
            ScriptRunLog.shared.finish(run.recordID, outcome: outcome, output: run.lines, changedPaths: changed,
                                       timelineEntry: entry?.record == nil ? nil : entry?.id)
        }
    }

    // MARK: Triggers & schedules

    private func handle(_ changes: [FolderWatcher.Change]) {
        guard Features.shared.isOn(.automation) else { return }
        for script in scripts {
            guard let root = script.triggerFolder?.standardizedFileURL.path, isApproved(script), isEnabled(script), allowsAutomaticRuns(script) else { continue }
            let fresh = changes.filter {
                $0.appeared && !FolderWatcher.isPartialDownload($0.url)
                    && $0.url.deletingLastPathComponent().standardizedFileURL.path == root
                    && script.accepts($0.url)
            }.map(\.url)
            // Files a running copy of this script creates there must not trigger it again.
            guard !fresh.isEmpty, !runningScripts.contains(script.url) else { continue }
            pendingTriggered[script.url, default: []].formUnion(fresh)
        }
        triggerFlush?.cancel()
        triggerFlush = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            flushTriggered()
        }
    }

    private func flushTriggered() {
        let batches = pendingTriggered
        pendingTriggered = [:]
        for (scriptURL, files) in batches {
            guard let script = scripts.first(where: { $0.url == scriptURL }) else { continue }
            let existing = files.filter { FileManager.default.fileExists(atPath: $0.path) }.sorted { $0.path < $1.path }
            guard !existing.isEmpty, script.count.contains(existing.count) || script.count.max == nil else { continue }
            run(script, context: ScriptContext(selection: existing, folder: script.triggerFolder), trigger: "New files")
        }
    }

    func runDueSchedules(now: Date = Date()) {
        guard Features.shared.isOn(.automation) else { return }
        for script in scripts {
            guard let minutes = script.scheduleMinutes, mayRunAutomatically(script) else { continue }
            let last = lastScheduledRun[script.url] ?? .distantPast
            // The first check after launch only starts the clock; runs then follow the interval.
            if last == .distantPast { lastScheduledRun[script.url] = now; continue }
            guard now.timeIntervalSince(last) >= Double(minutes) * 60 else { continue }
            lastScheduledRun[script.url] = now
            run(script, context: ScriptContext(selection: [], folder: script.triggerFolder), trigger: "Every \(minutes) min")
        }
    }

    // MARK: Shortcuts & operation hooks

    /// A script's `@shortcut` in a browser window runs it on the selection (the first run still asks).
    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard Features.shared.isOn(.automation), let state = WindowState.lastActive,
              // Not while editing scripts in the Automation window.
              event.window?.identifier?.rawValue.hasPrefix("automation") != true else { return false }
        var pressed: ScriptShortcut.Modifiers = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { pressed.insert(.command) }
        if flags.contains(.shift) { pressed.insert(.shift) }
        if flags.contains(.option) { pressed.insert(.option) }
        if flags.contains(.control) { pressed.insert(.control) }
        guard let script = scripts.first(where: {
            isEnabled($0) && $0.shortcut?.matches(characters: event.charactersIgnoringModifiers, keyCode: event.keyCode, modifiers: pressed) == true
        }) else { return false }
        let selection = Array(state.activePane.selection).sorted { $0.path < $1.path }
        guard script.applies(to: selection) else {
            NSSound.beep()
            return true
        }
        request(script, context: state.scriptContext(for: selection))
        return true
    }

    /// `@after` scripts follow finished Wayfile operations — never ones made by scripts (no loops).
    private func operationFinished(_ id: UUID) {
        guard let entry = TimelineStore.shared.entry(id), entry.status == .completed, !entry.title.hasPrefix("Script:") else { return }
        let events = ActivityModel.events(from: [entry])
        guard !events.isEmpty else { return }
        for script in scripts where !script.after.isEmpty && mayRunAutomatically(script) {
            let input = script.afterInput(events)
            guard !input.isEmpty else { continue }
            let kinds = Set(events.compactMap { ScriptAfter($0.kind) }).intersection(script.after).map(\.title).sorted().joined(separator: ", ")
            run(script, context: ScriptContext(selection: input, folder: input[0].deletingLastPathComponent()), trigger: "After \(kinds)")
        }
    }
}

extension Notification.Name {
    /// Asks a main window to open the Automation window (for code without `openWindow`).
    static let openAutomation = Notification.Name("WayfileOpenAutomation")
    /// Same for any single tool window; `object` is the window id ("docker"…).
    static let openToolWindow = Notification.Name("WayfileOpenToolWindow")
    /// Opens a window plugin; `object` is the script's path.
    static let openPlugin = Notification.Name("WayfileOpenPlugin")
}
