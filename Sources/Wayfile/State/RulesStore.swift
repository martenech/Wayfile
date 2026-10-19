import Foundation
import Observation

/// Saved rules, their folder watching, and matches waiting for approval.
@MainActor
@Observable
final class RulesStore {
    static let shared = RulesStore(fileURL: ProcessInfo.processInfo.environment["WAYFILE_SCRIPTS_DIR"]
        .map { URL(fileURLWithPath: $0).appendingPathComponent("rules.json") } ?? RulesStore.defaultURL)

    var rules: [Rule] { didSet { save(); rewatch() } }
    /// New matches of rules that need approval.
    private(set) var pending: [RuleStep] = []

    private let fileURL: URL
    private var watcher: FolderWatcher?
    private var sweepTimer: Timer?
    private var running = false

    nonisolated static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Wayfile/rules.json")
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        rules = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([Rule].self, from: $0) } ?? []
    }

    func start() {
        rewatch()
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweepAgeRules() }
        }
        sweepAgeRules()
    }

    func add(_ rule: Rule) { rules.append(rule) }

    func update(_ rule: Rule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
    }

    func remove(_ rule: Rule) {
        rules.removeAll { $0.id == rule.id }
        pending.removeAll { $0.rule.id == rule.id }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(rules) { try? data.write(to: fileURL, options: .atomic) }
    }

    private func rewatch() {
        let folders = Set(rules.filter(\.enabled).map(\.folder.standardizedFileURL))
        watcher = FolderWatcher(folders: Array(folders), latency: 1.5) { [weak self] changes in
            self?.handle(changes)
        }
    }

    // MARK: Matching

    private func handle(_ changes: [FolderWatcher.Change]) {
        // Moves done by our own rules show up as changes too; ignore them while a rule runs.
        guard !running, Features.shared.isOn(.automation) else { return }
        let appeared = changes.filter(\.appeared).map(\.url)
        guard !appeared.isEmpty else { return }
        for rule in rules where rule.enabled && !rule.isAgeBased {
            let root = rule.folder.standardizedFileURL.path
            let files = appeared.filter {
                $0.deletingLastPathComponent().standardizedFileURL.path == root && RuleEngine.matches(rule, $0)
            }
            if !files.isEmpty { dispatch(rule, files: files) }
        }
    }

    /// Age-based rules can't fire on arrival; they are checked on launch and hourly.
    func sweepAgeRules() {
        guard Features.shared.isOn(.automation) else { return }
        for rule in rules where rule.enabled && rule.isAgeBased {
            let files = RuleEngine.matches(rule)
            if !files.isEmpty { dispatch(rule, files: files) }
        }
    }

    private func dispatch(_ rule: Rule, files: [URL]) {
        let steps = RuleEngine.plan(rule, files: files)
        if rule.requiresApproval {
            let known = Set(pending.map(\.id))
            pending += steps.filter { !known.contains($0.id) }
        } else {
            run(steps)
        }
    }

    // MARK: Running

    func approve(_ steps: [RuleStep]) {
        let ids = Set(steps.map(\.id))
        pending.removeAll { ids.contains($0.id) }
        run(steps)
    }

    func dismiss(_ steps: [RuleStep]) {
        let ids = Set(steps.map(\.id))
        pending.removeAll { ids.contains($0.id) }
    }

    /// Runs steps through the Operation Center (one Timeline entry per rule, undoable).
    func run(_ steps: [RuleStep]) {
        let byRule = Dictionary(grouping: steps, by: \.rule.id)
        for (_, group) in byRule {
            guard let rule = group.first?.rule else { continue }
            if case .runScript(let name) = rule.action {
                guard let script = AutomationCenter.shared.scripts.first(where: { $0.url.lastPathComponent == name || $0.name == name }) else { continue }
                AutomationCenter.shared.request(script, context: ScriptContext(selection: group.map(\.url), folder: rule.folder))
                continue
            }
            Task {
                running = true
                defer { running = false }
                _ = try? await OperationCenter.shared.run(String(localized: "Rule: \(rule.name) (\(String(localized: "\(group.count) items")))"), undoTitle: "Rule") { progress in
                    try RuleEngine.execute(group, progress: progress)
                }
                // Let the watcher's events for our own changes pass before listening again.
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
