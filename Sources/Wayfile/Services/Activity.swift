import AppKit
import CoreServices
import Foundation
import Observation

// MARK: - Events

enum ActivityKind: String, Codable, CaseIterable, Identifiable {
    case opened, created, modified, moved, renamed, copied, deleted, appLaunched, script

    var id: String { rawValue }

    var title: String {
        switch self {
        case .opened: return String(localized: "Opened")
        case .created: return String(localized: "Created")
        case .modified: return String(localized: "Modified")
        case .moved: return String(localized: "Moved")
        case .renamed: return String(localized: "Renamed")
        case .copied: return String(localized: "Copied")
        case .deleted: return String(localized: "Deleted")
        case .appLaunched: return String(localized: "Launched")
        case .script: return String(localized: "Script")
        }
    }

    var symbol: String {
        switch self {
        case .opened: return "eye"
        case .created: return "plus"
        case .modified: return "pencil"
        case .moved: return "arrow.right"
        case .renamed: return "character.cursor.ibeam"
        case .copied: return "doc.on.doc"
        case .deleted: return "trash"
        case .appLaunched: return "app.badge"
        case .script: return "curlybraces"
        }
    }
}

/// Filter tabs.
enum ActivityFilter: String, CaseIterable, Identifiable {
    case all, opened, created, modified, moved, deleted, apps, scripts
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .opened: return String(localized: "Opened")
        case .created: return String(localized: "Created")
        case .modified: return String(localized: "Modified")
        case .moved: return String(localized: "Moved")
        case .deleted: return String(localized: "Deleted")
        case .apps: return String(localized: "Apps")
        case .scripts: return String(localized: "Scripts")
        }
    }
    var symbol: String {
        switch self {
        case .all: return "square.stack"
        case .opened: return "folder"
        case .created: return "doc.badge.plus"
        case .modified: return "square.and.pencil"
        case .moved: return "arrow.left.arrow.right"
        case .deleted: return "trash"
        case .apps: return "square.grid.2x2"
        case .scripts: return "curlybraces"
        }
    }
    func includes(_ kind: ActivityKind) -> Bool {
        switch self {
        case .all: return true
        case .opened: return kind == .opened
        case .created: return kind == .created || kind == .copied
        case .modified: return kind == .modified || kind == .renamed
        case .moved: return kind == .moved || kind == .renamed
        case .deleted: return kind == .deleted
        case .apps: return kind == .appLaunched
        case .scripts: return kind == .script
        }
    }
}

struct ActivityEvent: Codable, Identifiable, Hashable {
    enum Source: String, Codable { case spotlight, watcher, wayfile, workspace }

    var id = UUID()
    let date: Date
    let kind: ActivityKind
    let path: String
    var fromPath: String?
    var source: Source
    /// Only the day is known (Spotlight keeps earlier opens per day, not per minute).
    var approximateTime = false
    /// For Wayfile's own operations: the Timeline entry that can undo it.
    var timelineEntry: UUID?
    /// The operation was undone (it can be redone).
    var undone = false
    /// For script runs: the ScriptRunLog record.
    var scriptRun: UUID?

    init(id: UUID = UUID(), date: Date, kind: ActivityKind, path: String, fromPath: String? = nil, source: Source,
         approximateTime: Bool = false, timelineEntry: UUID? = nil, undone: Bool = false, scriptRun: UUID? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.path = path
        self.fromPath = fromPath
        self.source = source
        self.approximateTime = approximateTime
        self.timelineEntry = timelineEntry
        self.undone = undone
        self.scriptRun = scriptRun
    }

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { (path as NSString).lastPathComponent }
}

/// Date ranges of the picker.
enum ActivityRange: String, CaseIterable, Identifiable {
    case today, yesterday, last7Days, last30Days
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return String(localized: "Today")
        case .yesterday: return String(localized: "Yesterday")
        case .last7Days: return String(localized: "Last 7 Days")
        case .last30Days: return String(localized: "Last 30 Days")
        }
    }
    func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        switch self {
        case .today: return DateInterval(start: today, end: tomorrow)
        case .yesterday: return DateInterval(start: calendar.date(byAdding: .day, value: -1, to: today)!, end: today)
        case .last7Days: return DateInterval(start: calendar.date(byAdding: .day, value: -6, to: today)!, end: tomorrow)
        case .last30Days: return DateInterval(start: calendar.date(byAdding: .day, value: -29, to: today)!, end: tomorrow)
        }
    }
}

// MARK: - Filtering & grouping (pure)

enum ActivityModel {
    /// Folders that produce noise, not activity.
    static func isNoise(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        if path.hasPrefix(home + "/Library/") || path.hasPrefix(home + "/.") { return true }
        let parts = path.split(separator: "/")
        if parts.contains(where: { $0.hasPrefix(".") && $0 != ".Trash" }) { return true }
        let noisy: Set<Substring> = ["node_modules", "DerivedData", ".build", "Pods", "__pycache__", ".git", "venv", ".venv"]
        if parts.contains(where: noisy.contains) { return true }
        let name = parts.last.map(String.init) ?? ""
        return name == ".DS_Store" || name.hasSuffix(".crdownload") || name.hasSuffix(".download") || name.hasSuffix(".tmp")
            || name.hasPrefix("~$") || name.hasSuffix(".swp")
    }

    /// Merges sources: the same thing seen twice (e.g. Spotlight and the watcher) within two minutes counts once;
    /// Wayfile's own records win because they can be undone.
    static func merge(_ events: [ActivityEvent]) -> [ActivityEvent] {
        let priority: [ActivityEvent.Source: Int] = [.wayfile: 0, .watcher: 1, .workspace: 1, .spotlight: 2]
        var kept: [ActivityEvent] = []
        var seen: [String: [Date]] = [:]
        for event in events.sorted(by: { (priority[$0.source] ?? 9, $1.date) < (priority[$1.source] ?? 9, $0.date) }) {
            // Every script run counts, even the same script twice in a minute.
            if event.kind == .script { kept.append(event); continue }
            let key = "\(event.kind.rawValue)|\(event.path)"
            if let dates = seen[key], dates.contains(where: { abs($0.timeIntervalSince(event.date)) < 120 || (event.approximateTime && Calendar.current.isDate($0, inSameDayAs: event.date)) }) {
                continue
            }
            seen[key, default: []].append(event.date)
            kept.append(event)
        }
        return kept.sorted { $0.date > $1.date }
    }

    static func filter(_ events: [ActivityEvent], by filter: ActivityFilter, search: String) -> [ActivityEvent] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return events.filter { event in
            filter.includes(event.kind)
                && (query.isEmpty || event.name.localizedCaseInsensitiveContains(query) || event.path.localizedCaseInsensitiveContains(query))
        }
    }

    struct Day: Identifiable {
        let date: Date
        let events: [ActivityEvent]
        var id: Date { date }
    }

    static func days(_ events: [ActivityEvent], calendar: Calendar = .current) -> [Day] {
        Dictionary(grouping: events) { calendar.startOfDay(for: $0.date) }
            .map { Day(date: $0.key, events: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.date > $1.date }
    }

    /// Counts per bucket: hours for a single day, days for longer ranges.
    static func histogram(_ events: [ActivityEvent], range: DateInterval, calendar: Calendar = .current) -> [Int] {
        let singleDay = range.duration <= 86_400 + 3_600
        let buckets = singleDay ? 24 : max(1, Int((range.duration / 86_400).rounded()))
        var counts = Array(repeating: 0, count: buckets)
        for event in events where range.contains(event.date) && !event.approximateTime || (!singleDay && range.contains(event.date)) {
            let index: Int
            if singleDay {
                index = calendar.component(.hour, from: event.date)
            } else {
                index = calendar.dateComponents([.day], from: calendar.startOfDay(for: range.start), to: calendar.startOfDay(for: event.date)).day ?? 0
            }
            if counts.indices.contains(index) { counts[index] += 1 }
        }
        return counts
    }

    /// Script runs as activity; the path is the script file (or the run's name for Shortcuts / commands).
    static func events(from runs: [ScriptRunRecord]) -> [ActivityEvent] {
        runs.map { run in
            ActivityEvent(id: run.id, date: run.started, kind: .script, path: run.scriptPath.isEmpty ? run.scriptName : run.scriptPath,
                          source: .wayfile, timelineEntry: run.timelineEntry, scriptRun: run.id)
        }
    }

    /// Wayfile operations (Timeline) as activity.
    static func events(from entries: [TimelineEntry]) -> [ActivityEvent] {
        entries.flatMap { entry -> [ActivityEvent] in
            guard let record = entry.record else { return [] }
            return events(from: record, date: entry.date, entry: entry.id, title: entry.undoTitle)
                .map { var event = $0; event.undone = entry.inverse != nil; return event }
        }
    }

    private static func events(from record: UndoRecord, date: Date, entry: UUID, title: String) -> [ActivityEvent] {
        switch record {
        case .created(let urls):
            let kind: ActivityKind = title.localizedCaseInsensitiveContains("copy") || title.localizedCaseInsensitiveContains("duplicate") ? .copied : .created
            return urls.map { ActivityEvent(date: date, kind: kind, path: $0.path, source: .wayfile, timelineEntry: entry) }
        case .trashed(let items):
            return items.map { ActivityEvent(date: date, kind: .deleted, path: $0.original.path, source: .wayfile, timelineEntry: entry) }
        case .moved(let items):
            return items.filter { !$0.to.lastPathComponent.hasPrefix(".wayfile-rename-") && !$0.from.lastPathComponent.hasPrefix(".wayfile-rename-") }.map {
                let sameFolder = $0.from.deletingLastPathComponent() == $0.to.deletingLastPathComponent()
                return ActivityEvent(date: date, kind: sameFolder ? .renamed : .moved, path: $0.to.path, fromPath: $0.from.path, source: .wayfile, timelineEntry: entry)
            }
        case .tagged, .permissions:
            return []
        case .group(let records):
            return records.flatMap { events(from: $0, date: date, entry: entry, title: title) }
        }
    }
}

// MARK: - Spotlight history

enum SpotlightActivity {
    /// Opens, creations and changes in the home folder, plus app launches, within a range.
    static func events(in range: DateInterval, limitPerKind: Int = 1500) async -> [ActivityEvent] {
        let home = NSHomeDirectory()
        let from = iso(range.start), to = iso(range.end)
        async let opened = paths("kMDItemLastUsedDate >= $time.iso(\(from)) && kMDItemLastUsedDate < $time.iso(\(to)) && kMDItemContentTypeTree != com.apple.application", in: [home])
        async let created = paths("kMDItemFSCreationDate >= $time.iso(\(from)) && kMDItemFSCreationDate < $time.iso(\(to)) && kMDItemContentType != public.folder", in: [home])
        async let modified = paths("kMDItemFSContentChangeDate >= $time.iso(\(from)) && kMDItemFSContentChangeDate < $time.iso(\(to)) && kMDItemContentType != public.folder", in: [home])
        async let apps = paths("kMDItemContentTypeTree == com.apple.application && kMDItemLastUsedDate >= $time.iso(\(from)) && kMDItemLastUsedDate < $time.iso(\(to))",
                               in: ["/Applications", "/System/Applications", home + "/Applications"])
        let (o, c, m, a) = await (opened, created, modified, apps)
        return await Task.detached {
            var events: [ActivityEvent] = []
            for path in o.prefix(limitPerKind) where !ActivityModel.isNoise(path) {
                events += openEvents(path, range: range)
            }
            var createdPaths = Set<String>()
            for path in c.prefix(limitPerKind) where !ActivityModel.isNoise(path) {
                if let date = date(path, kMDItemFSCreationDate), range.contains(date) {
                    events.append(ActivityEvent(date: date, kind: .created, path: path, source: .spotlight))
                    createdPaths.insert(path)
                }
            }
            for path in m.prefix(limitPerKind) where !ActivityModel.isNoise(path) {
                guard let date = date(path, kMDItemFSContentChangeDate), range.contains(date) else { continue }
                // A file created and saved once shows only as created.
                if createdPaths.contains(path), let created = Self.date(path, kMDItemFSCreationDate), abs(date.timeIntervalSince(created)) < 120 { continue }
                events.append(ActivityEvent(date: date, kind: .modified, path: path, source: .spotlight))
            }
            for path in a.prefix(300) {
                if let date = date(path, kMDItemLastUsedDate), range.contains(date) {
                    events.append(ActivityEvent(date: date, kind: .appLaunched, path: path, source: .spotlight))
                }
            }
            return events
        }.value
    }

    /// The last open with its exact time, plus earlier opens in the range by day.
    static func openEvents(_ path: String, range: DateInterval) -> [ActivityEvent] {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, URL(fileURLWithPath: path) as CFURL) else { return [] }
        var events: [ActivityEvent] = []
        let last = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        if let last, range.contains(last) { events.append(ActivityEvent(date: last, kind: .opened, path: path, source: .spotlight)) }
        let used = (MDItemCopyAttribute(item, "kMDItemUsedDates" as CFString) as? [Date]) ?? []
        let calendar = Calendar.current
        for day in used where range.contains(day) {
            if let last, calendar.isDate(day, inSameDayAs: last) { continue }
            let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
            events.append(ActivityEvent(date: noon, kind: .opened, path: path, source: .spotlight, approximateTime: true))
        }
        return events
    }

    static func date(_ path: String, _ attribute: CFString) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, URL(fileURLWithPath: path) as CFURL) else { return nil }
        return MDItemCopyAttribute(item, attribute) as? Date
    }

    private static func paths(_ query: String, in folders: [String]) async -> [String] {
        var all: [String] = []
        for folder in folders where FileManager.default.fileExists(atPath: folder) {
            let output = await Shell.run("/usr/bin/mdfind", ["-onlyin", folder, query])
            all += output.stdout.split(separator: "\n").map(String.init)
        }
        return all
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

// MARK: - Live recording

/// Records what happens in the home folder (creations, changes, moves, deletions) and app launches while
/// Wayfile runs — the things Spotlight doesn't remember. Kept for 90 days.
@MainActor
@Observable
final class ActivityRecorder {
    static let shared = ActivityRecorder(fileURL: ActivityRecorder.defaultURL)

    private(set) var events: [ActivityEvent] = []
    private let fileURL: URL
    private var stream: FSEventStreamRef?
    private var lastModified: [String: Date] = [:]
    private var saveScheduled = false
    static let retentionDays = 90
    static let limit = 30_000

    nonisolated static var defaultURL: URL {
        let name = Bundle.main.bundleIdentifier == nil ? "activity-dev.json" : "activity.json"
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Wayfile/\(name)")
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        events = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([ActivityEvent].self, from: $0) } ?? []
    }

    func start() {
        guard stream == nil else { return }
        prune()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let recorder = Unmanaged<ActivityRecorder>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let raw = (0..<min(count, list.count)).map { (list[$0], Int(flags[$0])) }
            MainActor.assumeIsolated { recorder.handle(raw) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        stream = FSEventStreamCreate(nil, callback, &context, [NSHomeDirectory()] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, let url = app.bundleURL else { return }
            MainActor.assumeIsolated { self?.add(ActivityEvent(date: Date(), kind: .appLaunched, path: url.path, source: .workspace)) }
        }
    }

    /// Turns raw FSEvents into activity (testable without a stream).
    func handle(_ raw: [(path: String, flags: Int)], now: Date = Date()) {
        let fm = FileManager.default
        let trash = NSHomeDirectory() + "/.Trash/"
        var pendingRename: String?
        for (path, flag) in raw {
            let exists = fm.fileExists(atPath: path)
            let isDir = flag & kFSEventStreamEventFlagItemIsDir != 0
            if flag & kFSEventStreamEventFlagItemRenamed != 0 {
                if !exists {
                    if let old = pendingRename, !ActivityModel.isNoise(old) { add(ActivityEvent(date: now, kind: .deleted, path: old, source: .watcher)) }
                    pendingRename = path
                    continue
                }
                if let old = pendingRename {
                    pendingRename = nil
                    if path.hasPrefix(trash) {
                        if !ActivityModel.isNoise(old) { add(ActivityEvent(date: now, kind: .deleted, path: old, source: .watcher)) }
                    } else if !ActivityModel.isNoise(path) {
                        let sameFolder = (old as NSString).deletingLastPathComponent == (path as NSString).deletingLastPathComponent
                        add(ActivityEvent(date: now, kind: sameFolder ? .renamed : .moved, path: path, fromPath: old, source: .watcher))
                    }
                } else if !ActivityModel.isNoise(path) && !path.hasPrefix(trash) && !isDir {
                    add(ActivityEvent(date: now, kind: .created, path: path, source: .watcher))   // moved in from elsewhere
                }
                continue
            }
            if ActivityModel.isNoise(path) || path.hasPrefix(trash) { continue }
            if flag & kFSEventStreamEventFlagItemRemoved != 0 && !exists {
                add(ActivityEvent(date: now, kind: .deleted, path: path, source: .watcher))
            } else if flag & kFSEventStreamEventFlagItemCreated != 0 && exists && !isDir {
                add(ActivityEvent(date: now, kind: .created, path: path, source: .watcher))
                lastModified[path] = now
            } else if flag & kFSEventStreamEventFlagItemModified != 0 && exists && !isDir {
                // Editors save many times; one "modified" per file per five minutes.
                if let last = lastModified[path], now.timeIntervalSince(last) < 300 { continue }
                lastModified[path] = now
                add(ActivityEvent(date: now, kind: .modified, path: path, source: .watcher))
            }
        }
        if let old = pendingRename, !ActivityModel.isNoise(old), !old.hasPrefix(trash) {
            add(ActivityEvent(date: now, kind: .deleted, path: old, source: .watcher))
        }
    }

    func add(_ event: ActivityEvent) {
        events.append(event)
        if events.count > Self.limit { events.removeFirst(events.count - Self.limit) }
        scheduleSave()
    }

    func clear() {
        events.removeAll()
        saveNow()
    }

    private func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        events.removeAll { $0.date < cutoff }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            MainActor.assumeIsolated {
                self?.saveScheduled = false
                self?.saveNow()
            }
        }
    }

    func saveNow() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(events) { try? data.write(to: fileURL, options: .atomic) }
    }
}
