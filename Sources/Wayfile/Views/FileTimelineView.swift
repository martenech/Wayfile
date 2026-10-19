import AppKit
import Charts
import CoreServices
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Timeline: files, apps and actions in chronological order (Spotlight history + live recording + Wayfile's operations).
struct FileTimelineView: View {
    let state: WindowState
    let pane: PaneState

    @AppStorage("timeline.range") private var rangeRaw = ActivityRange.today.rawValue
    @State private var filter: ActivityFilter = .all
    @State private var search = ""
    @State private var spotlight: [ActivityEvent] = []
    @State private var loading = false
    @State private var selected: ActivityEvent?
    @State private var limit = 300

    private var range: ActivityRange { ActivityRange(rawValue: rangeRaw) ?? .today }

    /// Everything in the range, merged across sources.
    private var allEvents: [ActivityEvent] {
        let interval = range.interval()
        let recorded = ActivityRecorder.shared.events.filter { interval.contains($0.date) }
        let operations = ActivityModel.events(from: TimelineStore.shared.entries).filter { interval.contains($0.date) }
        let scripts = ActivityModel.events(from: ScriptRunLog.shared.records).filter { interval.contains($0.date) }
        return ActivityModel.merge(spotlight + recorded + operations + scripts)
    }

    var body: some View {
        let events = allEvents
        let shown = ActivityModel.filter(events, by: filter, search: search)
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                header
                filterBar(events)
                histogram(shown)
                if loading && events.isEmpty {
                    ProgressView("Reading your activity…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if shown.isEmpty {
                    ContentUnavailableView("Nothing here", systemImage: "clock",
                                           description: !search.isEmpty ? Text("Nothing matches “\(search)”.")
                                               : filter == .all ? Text("No activity in this period.") : Text("No \(filter.title.lowercased()) activity in this period."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list(shown)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()
            TimelineDetail(event: selected, events: events, state: state, pane: pane)
                .frame(width: 300)
        }
        .themedContentBackground()
        .task(id: rangeRaw) { await load() }
        .onChange(of: filter) { limit = 300 }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "clock").font(.system(size: 30)).foregroundStyle(Color.themeAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Timeline").font(.title.weight(.bold)).fixedSize()
                Text("Files, apps and actions in chronological order.").foregroundStyle(.secondary).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search timeline…", text: $search).textFieldStyle(.plain).frame(minWidth: 100, maxWidth: 180)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.themeSurface))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.1)))
            Picker("", selection: $rangeRaw) {
                ForEach(ActivityRange.allCases) { Label($0.title, systemImage: "calendar").tag($0.rawValue) }
            }
            .labelsHidden()
            .fixedSize()
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh").accessibilityLabel("Refresh")
        }
    }

    private func filterBar(_ events: [ActivityEvent]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) { filterButtons(events) }
            .fixedSize(horizontal: false, vertical: true)
    }

    private func filterButtons(_ events: [ActivityEvent]) -> some View {
        HStack(spacing: 4) {
            ForEach(ActivityFilter.allCases) { item in
                let count = events.filter { item.includes($0.kind) }.count
                Button { filter = item } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.symbol)
                        Text(item.title).lineLimit(1).fixedSize()
                        if item != .all && count > 0 { Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(filter == item ? .white.opacity(0.8) : .secondary) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .foregroundStyle(filter == item ? .white : .primary)
                    .background(RoundedRectangle(cornerRadius: 7).fill(filter == item ? Color.themeAccent : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.themeSurface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func histogram(_ events: [ActivityEvent]) -> some View {
        let interval = range.interval()
        let counts = ActivityModel.histogram(events, range: interval)
        let singleDay = counts.count == 24
        return Chart(Array(counts.enumerated()), id: \.offset) { index, count in
            BarMark(x: .value("Time", index), y: .value("Activity", count), width: .fixed(singleDay ? 9 : 7))
                .foregroundStyle(Color.themeAccent.gradient)
                .cornerRadius(2)
        }
        .chartXScale(domain: -0.5...(Double(counts.count) - 0.5))
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: Array(stride(from: 0, to: counts.count, by: singleDay ? 3 : max(1, counts.count / 7)))) { value in
                AxisValueLabel {
                    if let index = value.as(Int.self) {
                        Text(singleDay ? String(format: "%02d:00", index)
                             : Calendar.current.date(byAdding: .day, value: index, to: interval.start)!.formatted(.dateTime.day().month(.abbreviated)))
                    }
                }
            }
        }
        .frame(height: 70)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.themeSurface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }

    // MARK: List

    private func list(_ events: [ActivityEvent]) -> some View {
        let days = ActivityModel.days(Array(events.prefix(limit)))
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                ForEach(days) { day in
                    Section {
                        VStack(spacing: 0) {
                            ForEach(day.events) { event in
                                TimelineRow(event: event, selected: selected?.id == event.id, state: state, pane: pane)
                                    .onTapGesture { selected = event }
                                    .onTapGesture(count: 2) { open(event) }
                                if event.id != day.events.last?.id { Divider().padding(.leading, 60) }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.themeSurface))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
                    } header: {
                        dayHeader(day, total: events.filter { Calendar.current.isDate($0.date, inSameDayAs: day.date) }.count)
                    }
                }
                if events.count > limit {
                    Button("Show more (\(events.count - limit))") { limit += 300 }.frame(maxWidth: .infinity).padding(.vertical, 6)
                }
            }
            .padding(.bottom, 16)
        }
    }

    private func dayHeader(_ day: ActivityModel.Day, total: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge").foregroundStyle(Color.themeAccent)
            Text(dayName(day.date)).font(.title3.weight(.semibold))
            Text(day.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())).foregroundStyle(.secondary)
            Text("\(total) activities")
                .font(.caption).padding(.horizontal, 8).padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            Spacer()
        }
        .padding(.vertical, 6)
        .background((ThemeStore.shared.preset.content ?? Color(nsColor: .windowBackgroundColor)).opacity(0.97))
    }

    private func dayName(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        return date.formatted(.dateTime.weekday(.wide))
    }

    private func open(_ event: ActivityEvent) {
        if event.kind == .script { NotificationCenter.default.post(name: .openAutomation, object: nil); return }
        guard FileManager.default.fileExists(atPath: event.path) else { return }
        if event.kind == .appLaunched || !FileSystem.isDirectory(event.url) || FileSystem.isPackage(event.url) {
            NSWorkspace.shared.open(event.url)
        } else {
            pane.navigate(to: .folderAt(event.url))
        }
    }

    private func load() async {
        loading = true
        spotlight = await SpotlightActivity.events(in: range.interval())
        loading = false
        if selected == nil { selected = ActivityModel.filter(allEvents, by: filter, search: search).first }
    }
}

// MARK: - Row

private struct TimelineRow: View {
    let event: ActivityEvent
    let selected: Bool
    let state: WindowState
    let pane: PaneState

    private var exists: Bool { event.kind == .script || FileManager.default.fileExists(atPath: event.path) }
    private var run: ScriptRunRecord? { event.scriptRun.flatMap { ScriptRunLog.shared.record($0) } }

    var body: some View {
        if let run {
            ScriptRunRow(run: run, selected: selected)
        } else {
            fileRow
        }
    }

    private var fileRow: some View {
        HStack(spacing: 12) {
            Text(event.approximateTime ? "—" : event.date.formatted(date: .omitted, time: .shortened))
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                .help(event.approximateTime ? String(localized: "Opened that day (Spotlight keeps only the day for earlier opens)") : "")
            Image(systemName: event.kind.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Self.color(event.kind))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Self.color(event.kind).opacity(0.15)))
            FileThumb(url: event.url, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.kind == .appLaunched ? event.url.deletingPathExtension().lastPathComponent : event.name)
                    .fontWeight(.medium).lineLimit(1).strikethrough(!exists && event.kind != .deleted, color: .secondary)
                Text(detailLine).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
            Label(event.undone ? String(localized: "\(event.kind.title) · Undone") : event.kind.title, systemImage: event.undone ? "arrow.uturn.backward" : event.kind.symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(Self.color(event.kind))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(Self.color(event.kind).opacity(0.12)))
                .overlay(Capsule().strokeBorder(Self.color(event.kind).opacity(0.35)))
                .frame(width: 118, alignment: .leading)
            ViewThatFits(in: .horizontal) {
                AppLabel(event: event).frame(width: 150, alignment: .leading)
                Color.clear.frame(width: 0)
            }
            Menu {
                if exists {
                    Button("Open") { NSWorkspace.shared.open(event.url) }
                    Button("Show in Wayfile") { reveal() }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([event.url]) }
                }
                if let entry = event.timelineEntry {
                    if event.undone {
                        Button("Redo This Action") { redo(entry) }
                    } else {
                        Button("Undo This Action") { undo(entry) }
                    }
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(event.path, forType: .string)
                }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Actions for \(event.name)")
            Button { reveal() } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless)
                .help("Show the enclosing folder")
                .accessibilityLabel("Show enclosing folder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.themeAccent.opacity(0.12) : .clear))
        .contentShape(Rectangle())
        .opacity(!exists && event.kind != .deleted ? 0.7 : 1)
    }

    private var detailLine: String {
        let folder = { (path: String) in ((path as NSString).deletingLastPathComponent).replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        if let from = event.fromPath, event.kind == .moved { return folder(from) + " → " + folder(event.path) }
        if let from = event.fromPath, event.kind == .renamed { return "was " + (from as NSString).lastPathComponent }
        return folder(event.path)
    }

    private func reveal() {
        let folder = event.url.deletingLastPathComponent()
        pane.navigate(to: .folderAt(folder))
        let target = event.url
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            pane.selection = [target]
        }
    }

    private func redo(_ entry: UUID) {
        Task {
            do {
                try await TimelineStore.shared.redo(entry)
                OperationCenter.shared.timelineDidRedo(entry)
                state.reloadAll()
            } catch {
                state.errorMessage = error.localizedDescription
            }
        }
    }

    private func undo(_ entry: UUID) {
        Task {
            do {
                try await TimelineStore.shared.undo(entry)
                OperationCenter.shared.timelineDidUndo(entry)
                state.reloadAll()
            } catch {
                state.errorMessage = error.localizedDescription
            }
        }
    }

    static func color(_ kind: ActivityKind) -> Color {
        switch kind {
        case .opened: return .blue
        case .created, .copied: return .green
        case .modified, .renamed: return .orange
        case .moved: return .purple
        case .deleted: return .red
        case .appLaunched: return .teal
        case .script: return .indigo
        }
    }
}

/// The app that opens the file (macOS doesn't record which app actually opened it), or the app itself.
private struct AppLabel: View {
    let event: ActivityEvent

    var body: some View {
        if event.kind == .appLaunched {
            Text("Application").font(.callout).foregroundStyle(.secondary)
        } else if event.source == .wayfile || event.kind == .moved || event.kind == .deleted || event.kind == .renamed {
            HStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 18, height: 18)
                Text(event.source == .wayfile ? String(localized: "Wayfile") : String(localized: "Finder / other")).font(.callout).lineLimit(1)
            }
        } else if let app = NSWorkspace.shared.urlForApplication(toOpen: event.url) {
            HStack(spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 18, height: 18)
                Text(app.deletingPathExtension().lastPathComponent).font(.callout).lineLimit(1)
            }
            .help("Opens with \(app.deletingPathExtension().lastPathComponent)")
        }
    }
}

/// Quick Look thumbnail for existing files, the type's icon for gone ones.
struct FileThumb: View {
    let url: URL
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(nsImage: fallbackIcon).resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .task(id: url) {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size * 2, height: size * 2), scale: 2, representationTypes: .thumbnail)
            if let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                image = thumbnail.nsImage
            }
        }
    }

    private var fallbackIcon: NSImage {
        if FileManager.default.fileExists(atPath: url.path) { return IconCache.icon(for: url) }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data)
    }
}

// MARK: - Script runs

/// Colour of a run's outcome badge.
enum ScriptRunStyle {
    static func color(_ run: ScriptRunRecord) -> Color {
        if run.dryRun && run.outcome == .succeeded { return .blue }
        switch run.outcome {
        case .running: return .secondary
        case .succeeded: return .green
        case .exited, .failed: return .red
        case .cancelled: return .gray
        case .interrupted: return .orange
        }
    }

    static func duration(_ run: ScriptRunRecord) -> String? {
        guard let seconds = run.duration else { return nil }
        if seconds < 1 { return "\(Int(seconds * 1000)) ms" }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        return "\(Int(seconds) / 60) min \(Int(seconds) % 60) s"
    }

    static func summary(_ run: ScriptRunRecord) -> String {
        var parts = [run.trigger]
        if let duration = duration(run) { parts.append(duration) }
        if !run.changedPaths.isEmpty { parts.append(String(localized: "\(run.changedPaths.count) files changed")) }
        if case .failed(let message) = run.outcome { parts.append(message) }
        return parts.joined(separator: " · ")
    }
}

private struct ScriptRunRow: View {
    let run: ScriptRunRecord
    let selected: Bool

    var body: some View {
        let color = ScriptRunStyle.color(run)
        HStack(spacing: 12) {
            Text(run.started.formatted(date: .omitted, time: .shortened))
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            Image(systemName: "curlybraces")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.indigo)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.indigo.opacity(0.15)))
            Image(systemName: run.scriptPath.isEmpty ? (run.language == "Shortcut" ? "square.2.layers.3d" : "terminal") : "doc.text")
                .font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text((run.dryRun ? "Dry run: " : "") + run.scriptName).fontWeight(.medium).lineLimit(1)
                Text(ScriptRunStyle.summary(run)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
            Label(run.statusTitle, systemImage: run.dryRun && run.outcome == .succeeded ? "eye" : run.outcome.symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(color.opacity(0.12)))
                .overlay(Capsule().strokeBorder(color.opacity(0.35)))
                .frame(width: 118, alignment: .leading)
            ViewThatFits(in: .horizontal) {
                Text(run.language).font(.callout).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                Color.clear.frame(width: 0)
            }
            Button { NotificationCenter.default.post(name: .openAutomation, object: nil) } label: { Image(systemName: "terminal") }
                .buttonStyle(.borderless)
                .help("Open Scripts & Automation")
                .accessibilityLabel("Open Scripts and Automation")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.themeAccent.opacity(0.12) : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Detail panel for a run: outcome, timing, changed files (undoable) and the output tail.
private struct ScriptRunDetail: View {
    let run: ScriptRunRecord
    let state: WindowState
    let pane: PaneState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(spacing: 6) {
                    Image(systemName: run.dryRun && run.outcome == .succeeded ? "eye" : run.outcome.symbol)
                        .font(.system(size: 40)).foregroundStyle(ScriptRunStyle.color(run))
                    Text(run.scriptName).font(.headline).multilineTextAlignment(.center)
                    Text("\(run.language) · \(run.statusTitle)").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    row("bolt", "Trigger", run.trigger)
                    row("clock", "Started", run.started.formatted(date: .abbreviated, time: .standard))
                    if let duration = ScriptRunStyle.duration(run) { row("timer", "Duration", duration) }
                    if run.dryRun { row("eye", "Mode", "Dry run — nothing was changed") }
                    if case .failed(let message) = run.outcome { row("xmark.octagon", "Error", message) }
                    if case .interrupted = run.outcome { row("exclamationmark.triangle", "Note", "Wayfile quit while the script was running") }
                    if !run.scriptPath.isEmpty { row("doc", "Script", run.scriptPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")) }
                }
                if !run.changedPaths.isEmpty {
                    Divider()
                    HStack {
                        Text("Changed files").font(.headline)
                        Spacer()
                        if let entry = run.timelineEntry, let timeline = TimelineStore.shared.entry(entry) {
                            if timeline.canUndo {
                                Button("Undo All") { undo(entry) }.controlSize(.small)
                            } else if timeline.canRedo {
                                Button("Redo All") { redo(entry) }.controlSize(.small)
                            }
                        }
                    }
                    ForEach(run.changedPaths.prefix(30), id: \.self) { path in
                        Button {
                            pane.navigate(to: .folderAt(URL(fileURLWithPath: path).deletingLastPathComponent()))
                        } label: {
                            Label((path as NSString).lastPathComponent, systemImage: "doc").lineLimit(1).truncationMode(.middle)
                        }
                        .buttonStyle(.link)
                        .help(path)
                    }
                    if run.changedPaths.count > 30 { Text("and \(run.changedPaths.count - 30) more").font(.caption).foregroundStyle(.secondary) }
                }
                if !run.output.isEmpty {
                    Divider()
                    Text("Output").font(.headline)
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(run.output.suffix(60).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.hasPrefix("! ") ? Color.red : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                }
                Button("Open Scripts & Automation") { NotificationCenter.default.post(name: .openAutomation, object: nil) }
                    .controlSize(.small)
            }
            .padding(16)
        }
    }

    private func row(_ symbol: String, _ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(key: label, systemImage: symbol).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(value).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
        }
        .font(.callout)
    }

    private func undo(_ entry: UUID) {
        Task {
            do {
                try await TimelineStore.shared.undo(entry)
                OperationCenter.shared.timelineDidUndo(entry)
                state.reloadAll()
            } catch { state.errorMessage = error.localizedDescription }
        }
    }

    private func redo(_ entry: UUID) {
        Task {
            do {
                try await TimelineStore.shared.redo(entry)
                OperationCenter.shared.timelineDidRedo(entry)
                state.reloadAll()
            } catch { state.errorMessage = error.localizedDescription }
        }
    }
}

// MARK: - Detail panel

private struct TimelineDetail: View {
    let event: ActivityEvent?
    let events: [ActivityEvent]
    let state: WindowState
    let pane: PaneState
    @State private var tab = 0
    @State private var showAll = false

    var body: some View {
        if let event, let run = event.scriptRun.flatMap({ ScriptRunLog.shared.record($0) }) {
            ScriptRunDetail(run: run, state: state, pane: pane)
        } else if let event {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("", selection: $tab) {
                        Text("Details").tag(0)
                        Text("Preview").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if tab == 1, FileManager.default.fileExists(atPath: event.path) {
                        QuickLookView(url: event.url).frame(height: 360).clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        FileThumb(url: event.url, size: 200).frame(maxWidth: .infinity)
                    }
                    VStack(spacing: 2) {
                        Text(event.name).font(.headline).multilineTextAlignment(.center)
                        Text(kindLine(event)).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 8) {
                        if let last = lastOpened(event) { info("clock", "Last opened", last.formatted(date: .abbreviated, time: .shortened)) }
                        if let app = NSWorkspace.shared.urlForApplication(toOpen: event.url), event.kind != .appLaunched {
                            info("app", "Opens with", app.deletingPathExtension().lastPathComponent)
                        }
                        info("folder", "Path", (event.url.deletingLastPathComponent().path).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        if let size = (try? event.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                            info("doc", "Size", "\(size.formatted()) bytes")
                        }
                        if let dimensions = dimensions(event.url) { info("aspectratio", "Dimensions", dimensions) }
                        if !FileManager.default.fileExists(atPath: event.path) {
                            Label("No longer at this location", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    let history = events.filter { $0.path == event.path || $0.fromPath == event.path }
                    if !history.isEmpty {
                        Divider()
                        Text("Recent actions").font(.headline)
                        ForEach(history.prefix(showAll ? 50 : 4)) { item in
                            HStack {
                                Image(systemName: item.kind.symbol).foregroundStyle(TimelineRowColor.color(item.kind)).frame(width: 18)
                                Text(item.kind.title)
                                Spacer()
                                Text(item.approximateTime ? item.date.formatted(date: .abbreviated, time: .omitted) : item.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if history.count > 4 {
                            Button(showAll ? String(localized: "Show less") : String(localized: "Show more")) { showAll.toggle() }.buttonStyle(.link).font(.caption)
                        }
                    }
                    if FileManager.default.fileExists(atPath: event.path) {
                        HStack {
                            Button("Open") { NSWorkspace.shared.open(event.url) }
                            Button("Show in Folder") { pane.navigate(to: .folderAt(event.url.deletingLastPathComponent())) }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView("Select an item", systemImage: "cursorarrow.click", description: Text("Details and its history appear here."))
        }
    }

    private func info(_ symbol: String, _ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(key: label, systemImage: symbol).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            Text(value).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
        .font(.callout)
    }

    private func kindLine(_ event: ActivityEvent) -> String {
        let v = try? event.url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .fileSizeKey])
        return [v?.localizedTypeDescription, v?.fileSize.map { Formatters.size(Int64($0)) }].compactMap { $0 }.joined(separator: " – ")
    }

    private func lastOpened(_ event: ActivityEvent) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, event.url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    private func dimensions(_ url: URL) -> String? {
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return "\(w) × \(h)"
    }
}

private enum TimelineRowColor {
    static func color(_ kind: ActivityKind) -> Color {
        switch kind {
        case .opened: return .blue
        case .created, .copied: return .green
        case .modified, .renamed: return .orange
        case .moved: return .purple
        case .deleted: return .red
        case .appLaunched: return .teal
        case .script: return .indigo
        }
    }
}
