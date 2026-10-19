import SwiftUI
import PDFKit
import WebKit
import QuickLook

struct MainView: View {
    @State private var state = WindowState(location: MainView.initialLocation)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    /// Read once per window; saving during a drag must not re-render the window.
    @State private var sidebarIdealWidth = RememberedWidth.sidebar.saved
    @State private var previewWidth = RememberedWidth.preview.saved
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @State private var input: WindowInputController?
    #if DEBUG
    static var debugPreviewWidth: CGFloat = -1
    #endif

    /// Only the first window of a launch restores the previous session; later windows start fresh.
    private static var didRestoreSession = false

    private static var initialLocation: Location {
        #if DEBUG
        // Dev aid: WAYFILE_START=/some/path opens the first window there.
        if let path = ProcessInfo.processInfo.environment["WAYFILE_START"] {
            return .folderAt(URL(fileURLWithPath: path))
        }
        #endif
        let settings = AppSettings.shared
        if settings.startup == .folder, let folder = settings.startupFolder, FileSystem.isDirectory(folder) {
            return .folderAt(folder)
        }
        return .home
    }

    private func restoreSessionIfNeeded() {
        defer { Self.didRestoreSession = true }
        guard !Self.didRestoreSession, AppSettings.shared.startup == .restore else { return }
        #if DEBUG
        if ProcessInfo.processInfo.environment["WAYFILE_START"] != nil { return }
        #endif
        if let session = Session.load() { state.restore(session) }
    }

    #if DEBUG
    /// Dev aid for screenshots: WAYFILE_LAYOUT=columns, WAYFILE_NAVIGATE=/path, WAYFILE_PALETTE=1, WAYFILE_GROUP=kind, WAYFILE_PROPERTIES=/path, WAYFILE_THEME=nord, WAYFILE_SHORTCUT_TEST=1, WAYFILE_SIDEBAR_TEST=[width], WAYFILE_PREVIEW_TEST=[width], WAYFILE_F5_TEST=1, WAYFILE_DUAL=1, WAYFILE_ENTER_TEST=open|rename, WAYFILE_NEWFILE_TEST=1, WAYFILE_BATCH_TEST=1, WAYFILE_SEARCH_TEST=1, WAYFILE_CHROME_TEST=1, WAYFILE_SELECT=name, WAYFILE_INSPECTOR_TAB=Details, WAYFILE_ZOOM_TEST=1, WAYFILE_RESIZE_TEST=1, WAYFILE_SETTINGS=contextMenu.
    private func applyDebugEnvironment() {
        let env = ProcessInfo.processInfo.environment
        if let layout = env["WAYFILE_LAYOUT"].flatMap(LayoutMode.init(rawValue:)) { state.activePane.layout = layout }
        if env["WAYFILE_SIDEBAR_HIDE_TEST"] != nil {
            setvbuf(stdout, nil, _IOLBF, 0)
            let config = SidebarConfig.shared
            config.setItemHidden("smart:largeFiles", true)
            config.setItemHidden("smart:downloadsThisWeek", true)
            let wide = env["WAYFILE_SIDEBAR_HIDE_TEST"] == "hold"
            let extra = ["trash", "connect", "sftp", "fav:" + FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path, "vol:/"]
            if wide { extra.forEach { config.setItemHidden($0, true) }; config.setVisible(.cloud, false) }
            config.setVisible(.tags, false)
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                config.revealHidden = true
                // "hold" keeps them revealed long enough for a screenshot.
                try? await Task.sleep(for: .seconds(env["WAYFILE_SIDEBAR_HIDE_TEST"] == "hold" ? 6 : 1))
                config.revealHidden = false
                config.setItemHidden("smart:largeFiles", false)
                config.setItemHidden("smart:downloadsThisWeek", false)
                if wide { extra.forEach { config.setItemHidden($0, false) }; config.setVisible(.cloud, true) }
                config.setVisible(.tags, true)
                try? await Task.sleep(for: .seconds(0.5))
                print("SIDEBAR hide/reveal/show OK hidden=\(config.hiddenCount)")
            }
        }
        if let image = env["WAYFILE_HOME_BACKGROUND"] { HomeConfig.shared.backgroundImage = URL(fileURLWithPath: image) }
        if let preset = env["WAYFILE_HOME_PRESET"].flatMap(HomePreset.init(rawValue:)) {
            HomeConfig.shared.apply(preset)
            HomeConfig.shared.pinProject(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        }
        if let path = env["WAYFILE_NAVIGATE"] {
            state.activePane.navigate(to: path == "home" ? .home : path == "timeline" ? .timeline : path == "activity" ? .activity : .folderAt(URL(fileURLWithPath: path)))
        }
        if env["WAYFILE_PALETTE"] != nil { state.showCommandPalette = true }
        if let group = env["WAYFILE_GROUP"].flatMap(GroupBy.init(rawValue:)) { state.activePane.groupBy = group }
        if let path = env["WAYFILE_PROPERTIES"] { state.showProperties([URL(fileURLWithPath: path)]) }
        if let theme = env["WAYFILE_THEME"] { ThemeStore.shared.presetID = theme }
        if env["WAYFILE_AUTOMATION_TEST"] != nil {
            setvbuf(stdout, nil, _IOLBF, 0)
            // Scripts dir comes from WAYFILE_SCRIPTS_DIR; files to work on from WAYFILE_NAVIGATE.
            let center = AutomationCenter.shared
            let fm = FileManager.default
            guard let folder = env["WAYFILE_NAVIGATE"].map({ URL(fileURLWithPath: $0) }) else { return }
            ScriptExamples.all.forEach { try? ScriptExamples.install($0, in: center.folder) }
            let inbox = folder.appendingPathComponent("Inbox")
            try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
            try? """
            #!/bin/sh
            # @name Inbox Logger
            # @extensions txt
            # @menu no
            # @trigger \(inbox.path)
            for f in "$@"; do echo "seen $(basename "$f")" >> "\(folder.path)/trigger.log"; done
            """.write(to: center.folder.appendingPathComponent("inbox.sh"), atomically: true, encoding: .utf8)
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                center.reload()
                guard let lower = center.scripts.first(where: { $0.name == "Lowercase Names" }),
                      let logger = center.scripts.first(where: { $0.name == "Inbox Logger" }) else { print("AUTOMATION FAIL: scripts not loaded \(center.scripts.map(\.name))"); return }
                center.approve(lower)
                center.approve(logger)
                let picks = state.activePane.displayedItems.filter { $0.name.hasPrefix("UPPER") }.map(\.url)
                state.activePane.selection = Set(picks)
                let menuNames = center.scripts(for: picks).map(\.name)
                print("AUTOMATION menu for \(picks.count) items: \(menuNames)")
                center.request(lower, context: state.scriptContext(for: picks))
                try? "x".write(to: inbox.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
                try? "x".write(to: inbox.appendingPathComponent("skip.png"), atomically: true, encoding: .utf8)
                try? await Task.sleep(for: .seconds(5))
                let names = (try? fm.contentsOfDirectory(atPath: folder.path).sorted()) ?? []
                let log = (try? String(contentsOf: folder.appendingPathComponent("trigger.log"), encoding: .utf8)) ?? "none"
                print("AUTOMATION files: \(names)")
                print("AUTOMATION trigger log: \(log.replacingOccurrences(of: "\n", with: " | "))")
                print("AUTOMATION runs: \(center.runs.map { "\($0.title) [\($0.trigger)] \($0.status) lines=\($0.lines.count)" })")
                print("AUTOMATION timeline: \(TimelineStore.shared.entries.prefix(2).map(\.title))")
                print("AUTOMATION run log: \(ScriptRunLog.shared.records.prefix(3).map { "\($0.scriptName) [\($0.trigger)] \($0.statusTitle) changed=\($0.changedPaths.count) out=\($0.output.count) entry=\($0.timelineEntry != nil)" })")
                let scriptEvents = ActivityModel.filter(ActivityModel.events(from: ScriptRunLog.shared.records), by: .scripts, search: "")
                print("AUTOMATION timeline script events: \(scriptEvents.count)")
                // API v1: panel control from a script started in this window.
                try? "// @name Go Inbox\n// @permissions metadata\nwayfile.panel.open('Inbox'); wayfile.panel.select(['Inbox/hello.txt']); console.log(wayfile.metadata('Inbox/hello.txt').uti)\n"
                    .write(to: center.folder.appendingPathComponent("go.js"), atomically: true, encoding: .utf8)
                center.reload()
                if let go = center.scripts.first(where: { $0.name == "Go Inbox" }) {
                    center.approve(go)
                    let run = center.run(go, context: state.scriptContext(for: []), trigger: "Test")
                    try? await Task.sleep(for: .seconds(2))
                    print("AUTOMATION api: pane=\(state.activePane.location.folderURL?.lastPathComponent ?? "-") selected=\(state.activePane.selection.map(\.lastPathComponent)) out=\(run.lines.map(\.text)) status=\(run.status)")
                }
                // @after: a copy made in Wayfile runs the script on the copies; a disabled one stays quiet.
                let copies = folder.appendingPathComponent("Copies")
                try? fm.createDirectory(at: copies, withIntermediateDirectories: true)
                for (file, name) in [("after.sh", "After Copy"), ("off.sh", "Disabled After")] {
                    try? "#!/bin/sh\n# @name \(name)\n# @after copy\n# @menu no\nfor f in \"$@\"; do echo \"\(name): $(basename \"$f\")\" >> \"\(folder.path)/after.log\"; done\n"
                        .write(to: center.folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
                }
                center.reload()
                for script in center.scripts where script.name.contains("After") { center.approve(script) }
                if let off = center.scripts.first(where: { $0.name == "Disabled After" }) { center.setEnabled(off, false) }
                state.transfer([folder.appendingPathComponent("upper_a.txt")], to: copies, mode: .copy)
                try? await Task.sleep(for: .seconds(2))
                let afterLog = (try? String(contentsOf: folder.appendingPathComponent("after.log"), encoding: .utf8)) ?? "none"
                print("AUTOMATION after log: \(afterLog.replacingOccurrences(of: "\n", with: " | ")) runs=\(center.runs.prefix(2).map { "\($0.title) [\($0.trigger)]" })")
                if let off = center.scripts.first(where: { $0.name == "Disabled After" }) { center.setEnabled(off, true) }
                // Dry-run plan shown in the console.
                let fresh = ["REPORT.TXT", "NOTES.MD"].map { folder.appendingPathComponent($0) }
                fresh.forEach { fm.createFile(atPath: $0.path, contents: Data()) }
                center.run(lower, context: ScriptContext(selection: fresh, folder: folder, dryRun: true), trigger: "Test")
                try? await Task.sleep(for: .seconds(1))
                print("AUTOMATION plan: \(center.runs.first?.plan.map(\.sentence) ?? [])")
                openWindow(id: "automation")
            }
        }
        if let tab = env["WAYFILE_SETTINGS"] {
            UserDefaults.standard.set(tab, forKey: "settings.tab")
            openSettings()
        }
        if env["WAYFILE_TIMELINE_TEST"] != nil {
            // Real operations through the app (move, rename, trash), then undo the OLDEST from the Timeline.
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("wayfile-timeline-\(UUID().uuidString)")
            let inbox = root.appendingPathComponent("Inbox"), archive = root.appendingPathComponent("Archive")
            try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
            try? fm.createDirectory(at: archive, withIntermediateDirectories: true)
            for name in ["invoice.pdf", "notes.txt", "draft.md"] { fm.createFile(atPath: inbox.appendingPathComponent(name).path, contents: Data(name.utf8)) }
            func log(_ text: String) { FileHandle.standardError.write("TIMELINE \(text)\n".data(using: .utf8)!) }
            func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
            TimelineStore.shared.clear()
            state.activePane.navigate(to: .folderAt(inbox))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                state.transfer([inbox.appendingPathComponent("invoice.pdf")], to: archive, mode: .move)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    state.activePane.selection = Set(state.activePane.items.filter { $0.name == "notes.txt" }.map(\.url))
                    state.beginRename(); state.promptText = "meeting notes.txt"; state.commitPrompt()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        state.activePane.selection = Set(state.activePane.items.filter { $0.name == "draft.md" }.map(\.url))
                        state.trashSelection()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            let entries = TimelineStore.shared.entries
                            log("entries (newest first): \(entries.map { "\($0.undoTitle): \($0.record?.lines.map(\.text) ?? [])" })")
                            state.activePane.navigate(to: .timeline)
                            guard let oldest = entries.last else { return }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                Task {
                                    try? await TimelineStore.shared.undo(oldest.id)
                                    OperationCenter.shared.timelineDidUndo(oldest.id)
                                    log("undid oldest (\(oldest.undoTitle)): invoice back in Inbox=\(exists(inbox.appendingPathComponent("invoice.pdf"))), rename kept=\(exists(inbox.appendingPathComponent("meeting notes.txt"))), draft still trashed=\(!exists(inbox.appendingPathComponent("draft.md")))")
                                    log("⌘Z would now undo: \(OperationCenter.shared.undoTitle ?? "nothing")")
                                    // Leave the draft in the Trash restored to keep things tidy.
                                    try? await OperationCenter.shared.undo()
                                    log("after ⌘Z: draft restored=\(exists(inbox.appendingPathComponent("draft.md")))")
                                    let undone = ActivityModel.events(from: TimelineStore.shared.entries).filter(\.undone)
                                    log("timeline shows undone: \(undone.map { ($0.path as NSString).lastPathComponent })")
                                    try? await TimelineStore.shared.redo(oldest.id)
                                    OperationCenter.shared.timelineDidRedo(oldest.id)
                                    log("redid oldest: invoice in Archive=\(exists(archive.appendingPathComponent("invoice.pdf"))), undone now=\(ActivityModel.events(from: TimelineStore.shared.entries).filter(\.undone).count)")
                                    TimelineStore.shared.saveNow()
                                }
                            }
                        }
                    }
                }
            }
        }
        if env["WAYFILE_TAGS_TEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let store = TagStore.shared
                let line = { (tags: [FileTag]) in tags.map { "\($0.name)(color \($0.color), \(store.usage[$0.name] ?? 0) files)" }.joined(separator: ", ") }
                FileHandle.standardError.write("TAGS finder favourites: \(store.favorites.count)\nTAGS sidebar (in use): \(line(store.sidebarTags))\n".data(using: .utf8)!)
            }
        }
        if let pair = env["WAYFILE_COMPARE"]?.split(separator: "|"), pair.count == 2 {
            state.compareRequest = CompareTarget(left: URL(fileURLWithPath: String(pair[0])), right: URL(fileURLWithPath: String(pair[1])))
        }
        if env["WAYFILE_DROPSTACK_TEST"] != nil {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("wayfile-stack-\(UUID().uuidString)")
            let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B"), target = root.appendingPathComponent("Target")
            for dir in [a, b, target] { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            fm.createFile(atPath: a.appendingPathComponent("report.pdf").path, contents: Data("r".utf8))
            fm.createFile(atPath: b.appendingPathComponent("photo.png").path, contents: Data("p".utf8))
            func log(_ text: String) { FileHandle.standardError.write("STACK \(text)\n".data(using: .utf8)!) }
            DropStackStore.shared.clear()
            DropStackStore.shared.add([a.appendingPathComponent("report.pdf"), b.appendingPathComponent("photo.png")])
            state.activePane.navigate(to: .folderAt(target))
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                let moving = DropStackStore.shared.items
                state.transfer(moving, to: target, mode: .move) { DropStackStore.shared.remove(moving) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let names = ((try? fm.contentsOfDirectory(atPath: target.path)) ?? []).sorted()
                    log("after Move Here: target=\(names) stack=\(DropStackStore.shared.items.count) originals gone=\(!fm.fileExists(atPath: a.appendingPathComponent("report.pdf").path))")
                    DropStackStore.shared.isVisible = false
                    try? fm.removeItem(at: root)
                }
            }
        }
        if env["WAYFILE_SELECT_TEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                func log(_ text: String) { FileHandle.standardError.write("SELECT \(text)\n".data(using: .utf8)!) }
                var rule = SearchQuery(); rule.text = "*.html"; rule.textMatch = .glob
                state.select(matching: rule, adding: false)
                log("glob *.html selected \(state.activePane.selection.count) of \(state.activePane.displayedItems.count)")
                state.invertSelection()
                log("inverted: \(state.activePane.selectedItems.map(\.name).sorted())")
                state.activePane.selection = Set(state.activePane.items.filter { $0.name == "photo.png" }.map(\.url))
                state.selectSameKind()
                log("same kind as photo.png: \(state.activePane.selectedItems.map(\.name).sorted())")
            }
        }
        if let folder = env["WAYFILE_DUPLICATES"] { state.duplicatesRequest = URL(fileURLWithPath: folder) }
        if let tool = env["WAYFILE_TOOL"] { openWindow(id: tool) }
        if env["WAYFILE_DUMP_MENU"] != nil {
            // Prints the menu bar (for checking translations).
            setvbuf(stdout, nil, _IOLBF, 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                func dump(_ menu: NSMenu, _ depth: Int) {
                    for item in menu.items where !item.isSeparatorItem {
                        print("MENU " + String(repeating: "  ", count: depth) + item.title)
                        if let sub = item.submenu { dump(sub, depth + 1) }
                    }
                }
                if let main = NSApp.mainMenu { dump(main, 0) }
            }
        }
        if env["WAYFILE_SORT_TEST"] != nil {
            // Sorting a smart collection: how long the window is busy after each change.
            setvbuf(stdout, nil, _IOLBF, 0)
            let pane = state.activePane
            pane.navigate(to: .search(SmartCollection.recentDocuments.query))
            Task {
                for _ in 0..<60 where pane.items.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
                try? await Task.sleep(for: .seconds(2))
                print("SORT items=\(pane.items.count) unique=\(Set(pane.items.map(\.id)).count) layout=\(pane.layout)")
                for field in [SortField.modified, .size, .kind, .name, .created, .name] {
                    let start = Date()
                    pane.sortOrder = [field.comparator(ascending: true)]
                    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
                    let busy = Date().timeIntervalSince(start)
                    try? await Task.sleep(for: .milliseconds(300))
                    print("SORT \(field) main busy \(Int(busy * 1000)) ms")
                }
            }
        }
        if let plugin = env["WAYFILE_OPEN_PLUGIN"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { openWindow(id: "plugin", value: plugin) }
        }
        if env["WAYFILE_CONNECT"] != nil { state.showConnect = true }
        if let spec = env["WAYFILE_SFTP_TEST"]?.split(separator: "|").map(String.init), spec.count == 5 {
            setvbuf(stdout, nil, _IOLBF, 0)
            Task {
                let server = SFTPServer(name: "Test", host: spec[0], port: Int(spec[1]) ?? 22, username: spec[2], auth: .key, keyPath: spec[3])
                let remote = spec[4]
                SFTPKnownHosts.forget(host: server.host, port: server.port)
                do {
                    let c = try await SFTPConnection.connect(server, password: nil)
                    print("SFTP connected home=\(c.home) knownKey=\(SFTPKnownHosts.known(server.host, port: server.port) != nil)")
                    print("SFTP list \(try await c.list(remote).map(\.name))")
                    let local = FileManager.default.temporaryDirectory.appendingPathComponent("pf-sftp-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: local.appendingPathComponent("up/sub"), withIntermediateDirectories: true)
                    try Data(repeating: 65, count: 700_000).write(to: local.appendingPathComponent("up/big.bin"))
                    try "nested".write(to: local.appendingPathComponent("up/sub/n.txt"), atomically: true, encoding: .utf8)
                    try await c.upload(local.appendingPathComponent("up"), to: remote, progress: OperationProgress())
                    print("SFTP after upload \(try await c.list(remote + "/up").map { "\($0.name):\($0.size)" })")
                    let readme = try await c.list(remote).first { $0.name == "readme.txt" }!
                    let down = try await c.download(readme, to: local, progress: OperationProgress())
                    print("SFTP downloaded \(try String(contentsOf: down, encoding: .utf8).trimmingCharacters(in: .newlines))")
                    let folder = try await c.list(remote).first { $0.name == "up" }!
                    let back = try await c.download(folder, to: local.appendingPathComponent("back"), progress: OperationProgress())
                    print("SFTP folder round trip size=\((try? back.appendingPathComponent("big.bin").resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1) nested=\((try? String(contentsOf: back.appendingPathComponent("sub/n.txt"), encoding: .utf8)) ?? "-")")
                    try await c.rename(readme, to: "renamed.txt")
                    try await c.makeFolder(remote + "/made")
                    try await c.delete(folder)
                    print("SFTP after rename/mkdir/delete \(try await c.list(remote).map(\.name))")
                    await c.close()
                    SFTPKnownHosts.remember("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl", host: server.host, port: server.port)
                    do { _ = try await SFTPConnection.connect(server, password: nil); print("SFTP tampered key ACCEPTED (bad)") }
                    catch { print("SFTP tampered key rejected: \(error.localizedDescription.prefix(60))") }
                    SFTPKnownHosts.forget(host: server.host, port: server.port)
                } catch {
                    print("SFTP error \(error.localizedDescription)")
                }
            }
        }
        if let second = env["WAYFILE_TERMINAL_TEST"] {
            setvbuf(stdout, nil, _IOLBF, 0)
            Task {
                try? await Task.sleep(for: .seconds(1))
                state.terminal.followsFolder = true
                state.terminal.toggle(folder: state.activePane.location.folderURL)
                try? await Task.sleep(for: .seconds(2.5))
                let session = state.terminal.selected
                print("TERM start idle=\(session?.isIdle ?? false) cwd=\(session?.currentDirectory?.path ?? "-")")
                session?.type("echo hello-from-wayfile\r")
                try? await Task.sleep(for: .seconds(1))
                state.activePane.navigate(to: .folderAt(URL(fileURLWithPath: second)))
                try? await Task.sleep(for: .seconds(1.5))
                print("TERM after follow cwd=\(session?.currentDirectory?.path ?? "-")")
                session?.type("sleep 3\r")
                try? await Task.sleep(for: .milliseconds(600))
                print("TERM while running idle=\(session?.isIdle ?? true)")
                state.activePane.navigate(to: .folderAt(URL(fileURLWithPath: NSHomeDirectory())))
                try? await Task.sleep(for: .seconds(1))
                print("TERM no cd while busy cwd=\(session?.currentDirectory?.path ?? "-")")
            }
        }
        if let provider = env["WAYFILE_AI_PROVIDER"].flatMap(AIProviderKind.init(rawValue:)) { AISettings.shared.provider = provider }
        if let path = env["WAYFILE_ASKAI_ABOUT"] { state.askAIRequest = AskAITarget(urls: [URL(fileURLWithPath: path)]) }
        if let request = env["WAYFILE_ASK_AI"] {
            setvbuf(stdout, nil, _IOLBF, 0)
            Task {
                try? await Task.sleep(for: .seconds(1))
                let started = Date()
                state.askAI(request)
                while state.aiBusy { try? await Task.sleep(for: .milliseconds(100)) }
                print("ASKAI \(String(format: "%.1f", Date().timeIntervalSince(started)))s summary=\(state.aiSummary ?? []) error=\(state.errorMessage ?? "-")")
                if case .search(let q) = state.activePane.location { print("ASKAI query kinds=\(q.kinds) min=\(q.minSize ?? -1) date=\(q.dateRange) scope=\(q.scope)") }
            }
        }
        if let path = env["WAYFILE_DISKUSAGE"] { state.diskUsageRequest = URL(fileURLWithPath: path) }
        if env["WAYFILE_LOAD_TEST"] != nil {
            setvbuf(stdout, nil, _IOLBF, 0)
            let started = Date()
            Task {
                var last = "", worstLag = 0.0
                while Date().timeIntervalSince(started) < 25 {
                    let tick = Date()
                    try? await Task.sleep(for: .milliseconds(20))
                    worstLag = max(worstLag, Date().timeIntervalSince(tick) - 0.02)
                    let now = "items=\(state.activePane.items.count) loading=\(state.activePane.isLoading)"
                    if now != last {
                        print("LOAD \(String(format: "%.2f", Date().timeIntervalSince(started)))s \(now) worst main-thread stall so far \(String(format: "%.2f", worstLag))s")
                        last = now
                    }
                }
                print("LOAD done, worst stall \(String(format: "%.2f", worstLag))s")
            }
        }
        if let path = env["WAYFILE_PERMISSIONS"] { state.permissionsRequest = .init(urls: [URL(fileURLWithPath: path)]) }
        if let path = env["WAYFILE_ARCHIVE"] { state.archiveRequest = URL(fileURLWithPath: path) }
        if let root = env["WAYFILE_GIT"] { state.gitRequest = GitTarget(root: URL(fileURLWithPath: root)) }
        if let pair = env["WAYFILE_DIFF"]?.split(separator: "|"), pair.count == 2 {
            state.textDiffRequest = DiffTarget(left: .file(URL(fileURLWithPath: String(pair[0]))), right: .file(URL(fileURLWithPath: String(pair[1]))))
        }
        if let folder = env["WAYFILE_ORGANIZE"] { state.organizeRequest = .init(folder: URL(fileURLWithPath: folder)) }
        if let path = env["WAYFILE_RULES_TEST"] {
            setvbuf(stdout, nil, _IOLBF, 0)
            let inbox = URL(fileURLWithPath: path)
            let store = RulesStore.shared
            var sort = Rule(folder: inbox)
            sort.name = "Sort images"
            sort.kinds = [.image]
            sort.action = .sortByKind
            sort.requiresApproval = false
            var tag = Rule(folder: inbox)
            tag.name = "Tag notes"
            tag.pattern = "*.txt"
            tag.action = .tag("Red")
            store.rules = [sort, tag]
            Task {
                try? await Task.sleep(for: .seconds(1))
                for name in ["a.jpg", "b.png", "note.txt", "x.bin"] { try? Data().write(to: inbox.appendingPathComponent(name)) }
                try? await Task.sleep(for: .seconds(5))
                let fm = FileManager.default
                print("RULES files: \((try? fm.contentsOfDirectory(atPath: inbox.path).sorted()) ?? [])")
                print("RULES images: \((try? fm.contentsOfDirectory(atPath: inbox.appendingPathComponent("Images").path).sorted()) ?? [])")
                print("RULES pending: \(store.pending.map(\.description))")
                store.approve(store.pending)
                try? await Task.sleep(for: .seconds(2))
                print("RULES tags after approve: \(TagIO.read(inbox.appendingPathComponent("note.txt")).map(\.name))")
                print("RULES timeline: \(TimelineStore.shared.entries.prefix(2).map(\.title))")
                store.rules = []
            }
        }
        if env["WAYFILE_TREE_TEST"] != nil {
            setvbuf(stdout, nil, _IOLBF, 0)
            UserDefaults.standard.set("tree", forKey: "sidebarMode")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let home = FileManager.default.homeDirectoryForCurrentUser.normalizedDirectory
                let allRoots = [home] + VolumeStore.shared.volumes.map(\.url)
                let everything = FolderTreeStore.shared.visibleRows(roots: allRoots)
                let homeCopies = everything.filter { $0.url.standardizedFileURL.path == home.standardizedFileURL.path }.count
                print("TREE home rows=\(homeCopies) total rows=\(everything.count)")
                let rows = FolderTreeStore.shared.visibleRows(roots: [home])
                let target = state.activePane.location.folderURL?.standardizedFileURL.path ?? ""
                let index = rows.firstIndex { $0.url.standardizedFileURL.path == target }
                let chain = rows.filter { target.hasPrefix($0.url.standardizedFileURL.path) }.map { "\(String(repeating: "  ", count: $0.depth))\($0.url.lastPathComponent)" }
                FileHandle.standardError.write("TREE rows=\(rows.count) current at row \(index.map(String.init) ?? "missing")\nTREE path:\n\(chain.joined(separator: "\n"))\n".data(using: .utf8)!)
                UserDefaults.standard.set("places", forKey: "sidebarMode")
            }
        }
        if env["WAYFILE_SYNC_TEST"] != nil {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("wayfile-sync-\(UUID().uuidString)")
            for side in ["Original", "Copy"] { try? fm.createDirectory(at: root.appendingPathComponent("\(side)/src/views"), withIntermediateDirectories: true) }
            func log(_ text: String) { FileHandle.standardError.write("SYNC \(text)\n".data(using: .utf8)!) }
            let tab = state.selectedTab
            tab.setPaneCount(2)
            tab.panes[0].navigate(to: .folderAt(root.appendingPathComponent("Original")))
            tab.panes[1].navigate(to: .folderAt(root.appendingPathComponent("Copy")))
            tab.isSynced = true
            tab.activePaneID = tab.panes[0].id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let where_ = { tab.panes.map { $0.location.folderURL.map { $0.pathComponents.suffix(3).joined(separator: "/") } ?? "-" } }
                tab.panes[0].navigate(to: .folderAt(root.appendingPathComponent("Original/src")))
                log("into src: \(where_())")
                tab.panes[0].navigate(to: .folderAt(root.appendingPathComponent("Original/src/views")))
                log("into views: \(where_())")
                tab.panes[0].goUp()
                log("up: \(where_())")
                tab.isSynced = false
                tab.panes[0].goUp()
                log("up with sync off: \(where_())")
                tab.setPaneCount(4)
                log("quad: panes=\(tab.panes.count) partner of pane 3 is pane \(tab.panes.firstIndex { $0.id == { tab.activePaneID = tab.panes[3].id; return tab.inactivePane!.id }() } ?? -1)")
                tab.activePaneID = tab.panes[0].id
            }
        }
        if env["WAYFILE_VIM_TEST"] != nil {
            AppSettings.shared.vimMode = true
            func log(_ text: String) { FileHandle.standardError.write("VIM \(text)\n".data(using: .utf8)!) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NSApp.activate(ignoringOtherApps: true)
                guard let window = NSApp.windows.first(where: \.isVisible) else { return }
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(nil)
                func press(_ keys: String) {
                    for char in keys {
                        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: char.isUppercase ? [.shift] : [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                                     characters: String(char), charactersIgnoringModifiers: String(char), isARepeat: false, keyCode: 0)!
                        NSApp.sendEvent(event)
                    }
                }
                let pane = state.activePane
                let selected = { pane.selectedItems.map(\.name).joined(separator: ",") }
                press("jj"); log("jj → \(selected())")
                press("G"); log("G → \(selected()) (last is \(pane.displayedItems.last?.name ?? "-"))")
                press("gg"); log("gg → \(selected())")
                press("l"); log("l on folder → now in \(pane.location.folderURL?.lastPathComponent ?? "-")")
                press("h"); log("h → back in \(pane.location.folderURL?.lastPathComponent ?? "-")")
                // Typing in a text field must not trigger Vim actions.
                state.focusSearchField = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let before = pane.items.count
                    press("dd")
                    log("dd typed in the filter field: items \(before) → \(pane.items.count), filter='\(pane.filterText)'")
                    pane.filterText = ""
                    window.makeFirstResponder(nil)
                    AppSettings.shared.vimMode = false
                }
            }
        }
        if env["WAYFILE_DUAL"] != nil, !state.selectedTab.isDualPane { state.selectedTab.toggleDualPane() }
        if env["WAYFILE_PANES_TEST"] != nil {
            // Cycles 1 → 2 → 4 → 1 → 2 → 1 panes (dual → single used to crash).
            setvbuf(stdout, nil, _IOLBF, 0)
            Task {
                for count in [2, 4, 1, 2, 1, 4, 2, 1] {
                    try? await Task.sleep(for: .milliseconds(400))
                    state.selectedTab.setPaneCount(count)
                }
                try? await Task.sleep(for: .milliseconds(500))
                print("PANES OK \(state.selectedTab.panes.count)")
            }
        }
        if let name = env["WAYFILE_SELECT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                state.activePane.selection = Set(state.activePane.items.filter { $0.name == name }.map(\.url))
            }
        }
        if let tab = env["WAYFILE_INSPECTOR_TAB"] { UserDefaults.standard.set(tab, forKey: "inspectorTab") }
        if env["WAYFILE_RESIZE_TEST"] != nil {
            // Drag the inspector's divider 120 pt to the left with real mouse events.
            func log(_ text: String) { FileHandle.standardError.write("RESIZE \(text)\n".data(using: .utf8)!) }
            func handle(in view: NSView?) -> ResizeHandleNSView? {
                guard let view else { return nil }
                if let match = view as? ResizeHandleNSView { return match }
                return view.subviews.lazy.compactMap(handle).first
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let window = NSApp.windows.first(where: \.isVisible), let divider = handle(in: window.contentView) else { log("no handle"); return }
                let start = divider.convert(NSPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil)
                let hit = window.contentView?.superview?.hitTest(start)
                log("before: inspector=\(Int(MainView.debugPreviewWidth)) handle hit-tests to itself=\(hit === divider)")
                var chain: [String] = []
                var current: NSView? = hit
                while let view = current, chain.count < 6 {
                    chain.append("\(Swift.type(of: view)) x=\(Int(view.convert(view.bounds, to: nil).minX))…\(Int(view.convert(view.bounds, to: nil).maxX))")
                    current = view.superview
                }
                log("hit at x=\(Int(start.x)): " + chain.joined(separator: " ← "))
                log("handle frame in window: \(divider.convert(divider.bounds, to: nil))")
                func allHandles(_ view: NSView) -> [ResizeHandleNSView] {
                    ((view as? ResizeHandleNSView).map { [$0] } ?? []) + view.subviews.flatMap(allHandles)
                }
                for each in allHandles(window.contentView!) {
                    let center = each.convert(NSPoint(x: each.bounds.midX, y: each.bounds.midY), to: nil)
                    log("handle at x=\(Int(center.x)) receives clicks: \(window.contentView?.superview?.hitTest(center) === each)")
                }
                func send(_ type: NSEvent.EventType, x: CGFloat) {
                    window.sendEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: start.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
                }
                send(.leftMouseDown, x: start.x)
                for step in 1...6 { send(.leftMouseDragged, x: start.x - CGFloat(step) * 20) }
                send(.leftMouseUp, x: start.x - 120)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    log("after dragging 120 pt left: inspector=\(Int(MainView.debugPreviewWidth)) saved=\(UserDefaults.standard.double(forKey: "previewWidth"))")
                }
            }
        }
        if env["WAYFILE_ZOOM_TEST"] != nil {
            // Inspect the live preview views: does changing zoom actually change what's rendered?
            func log(_ text: String) { FileHandle.standardError.write("ZOOM \(text)\n".data(using: .utf8)!) }
            func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
                guard let view else { return nil }
                if let match = view as? T { return match }
                return view.subviews.lazy.compactMap { find(type, in: $0) }.first
            }
            // Set zoom the way the slider does (through the preview's state), then read what was rendered.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let root = NSApp.windows.first(where: \.isVisible)?.contentView
                func describe() -> String {
                    if let web = find(WKWebView.self, in: root) { return "web pageZoom=\(String(format: "%.2f", web.pageZoom))" }
                    if let scroll = find(FitImageScrollView.self, in: root) {
                        return "image magnification=\(String(format: "%.2f", scroll.magnification)) docWidth=\(Int(scroll.documentView?.frame.width ?? 0)) visibleWidth=\(Int(scroll.contentView.bounds.width))"
                    }
                    if let pdf = find(PDFView.self, in: root) {
                        return "pdf scale=\(String(format: "%.2f", pdf.scaleFactor)) fit=\(String(format: "%.2f", pdf.scaleFactorForSizeToFit))"
                    }
                    return "Quick Look (no zoom controls)"
                }
                log("zoom 1: \(describe())")
                NotificationCenter.default.post(name: .init("WayfileDebugZoom"), object: 2.0)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    log("zoom 2: \(describe())")
                    NotificationCenter.default.post(name: .init("WayfileDebugZoom"), object: 1.0)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { log("back to 1: \(describe())") }
                }
            }
        }
        if env["WAYFILE_CHROME_TEST"] != nil {
            // Hit-test the hidden title bar: tabs, "+" and the sidebar button must land in our SwiftUI
            // content, not in AppKit's title bar view (which would swallow the clicks).
            func log(_ text: String) { FileHandle.standardError.write("CHROME \(text)\n".data(using: .utf8)!) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let window = NSApp.windows.first(where: \.isVisible), let frameView = window.contentView?.superview else { return }
                func splitView(_ view: NSView) -> NSSplitView? {
                    if let split = view as? NSSplitView { return split }
                    return view.subviews.lazy.compactMap(splitView).first
                }
                let sidebarWidth = splitView(frameView)?.arrangedSubviews.first?.frame.width ?? 0
                let top = window.frame.height - TitleBar.height / 2
                let points: [(String, CGFloat)] = [
                    ("sidebar button", sidebarWidth + 22), ("tab chip", sidebarWidth + 100),
                    ("+ button", sidebarWidth + 285), ("empty title bar", window.frame.width - 200),
                ]
                for (name, x) in points {
                    let hit = frameView.hitTest(NSPoint(x: x, y: top))
                    let typeName = hit.map { String(describing: Swift.type(of: $0)) } ?? "nil"
                    log("\(name) at x=\(Int(x)): \(typeName.hasPrefix("NSHostingView") ? "SwiftUI content" : typeName)")
                }
            }
        }
        if env["WAYFILE_SEARCH_TEST"] != nil {
            // Search via the real search field path, add a filter, compare engines, save the search.
            func log(_ text: String) { FileHandle.standardError.write("SEARCH \(text)\n".data(using: .utf8)!) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                state.search("View")
                guard case .search(var query) = state.activePane.location else { log("not searching"); return }
                query.kinds = [.text]
                state.activePane.updateSearch(query)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let spotlight = state.activePane.items.map(\.name).sorted()
                    log("spotlight: \(spotlight.count) results, e.g. \(spotlight.prefix(4))")
                    query.engine = .scan
                    state.activePane.updateSearch(query)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        let scan = state.activePane.items.map(\.name).sorted()
                        log("scan: \(scan.count) results; only in scan: \(Set(scan).subtracting(spotlight).sorted().prefix(5))")
                        query.engine = .spotlight
                        state.activePane.updateSearch(query)
                        SavedSearchStore.shared.add("Swift views", query: query)
                        log("saved: \(SavedSearchStore.shared.searches.map(\.name)) title=\(state.activePane.location.title)")
                    }
                }
            }
        }
        if env["WAYFILE_BATCH_TEST"] != nil {
            // Open the batch rename sheet on three photos (one rename collides), then rename for real and undo.
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("wayfile-batch-\(UUID().uuidString)")
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            for name in ["IMG_0001.jpg", "IMG_0002.jpg", "IMG_0003.jpg", "Holiday 02.jpg"] {
                fm.createFile(atPath: root.appendingPathComponent(name).path, contents: Data(name.utf8))
            }
            var rules = BatchRenameRules()
            rules.find = #"IMG_\d+"#; rules.useRegex = true; rules.replace = "Holiday"
            rules.numbering = true; rules.numberPadding = 2
            BatchRenameView.savedRules = rules
            state.activePane.navigate(to: .folderAt(root))
            func log(_ text: String) { FileHandle.standardError.write("BATCH \(text)\n".data(using: .utf8)!) }
            func listing() -> [String] { ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let pane = state.activePane
                pane.selection = Set(pane.items.filter { $0.name.hasPrefix("IMG_") }.map(\.url))
                state.beginRename()
                log("sheet presented=\(state.batchRenameRequest != nil) items=\(state.batchRenameRequest?.items.count ?? 0)")
                // Leave the sheet up for the snapshot, then do what the Rename button does.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    let items = state.batchRenameRequest?.items.map(BatchRenameItem.init) ?? []
                    let blocked = (try? BatchRename.preview(items, rules: rules)) ?? []
                    log("with collision: \(blocked.map { "\($0.newName)=\($0.status.isProblem ? "conflict" : "ok")" })")
                    try? fm.removeItem(at: root.appendingPathComponent("Holiday 02.jpg"))
                    let rows = (try? BatchRename.preview(items, rules: rules)) ?? []
                    state.batchRenameRequest = nil
                    state.applyBatchRename(rows)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        log("renamed: \(listing()) selected=\(state.activePane.selection.count)")
                        state.undo()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            log("after undo: \(listing())")
                            BatchRenameView.savedRules = BatchRenameRules()
                            try? fm.removeItem(at: root)
                        }
                    }
                }
            }
        }
        if env["WAYFILE_NEWFILE_TEST"] != nil {
            // Create a Markdown file through the real prompt flow, check it, then undo it.
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("wayfile-new-\(UUID().uuidString)")
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            state.activePane.navigate(to: .folderAt(root))
            func log(_ text: String) { FileHandle.standardError.write("NEWFILE \(text)\n".data(using: .utf8)!) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let markdown = FileTemplate.builtIn.first { $0.id == "md" }!
                state.beginNew(.newFile(markdown))
                log("prompt='\(state.prompt?.title ?? "none")' suggested='\(state.promptText)'")
                state.promptText = "Notes.md"
                state.commitPrompt()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let file = root.appendingPathComponent("Notes.md")
                    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? "<missing>"
                    let selected = state.activePane.selectedItems.map(\.name)
                    log("created=\(fm.fileExists(atPath: file.path)) contents=\(text.debugDescription) selected=\(selected)")
                    state.undo()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        log("after undo: exists=\(fm.fileExists(atPath: file.path))")
                        try? fm.removeItem(at: root)
                    }
                }
            }
        }
        if env["WAYFILE_ENTER_TEST"] != nil {
            // Press a real Return key on a selected folder and report what happened (open vs rename).
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("wayfile-enter-\(UUID().uuidString)")
            try? fm.createDirectory(at: root.appendingPathComponent("Sub"), withIntermediateDirectories: true)
            state.activePane.navigate(to: .folderAt(root))
            func log(_ text: String) { FileHandle.standardError.write("ENTERTEST \(text)\n".data(using: .utf8)!) }
            func firstResponderTarget(_ view: NSView?) -> NSView? {
                guard let view else { return nil }
                // The sidebar is an outline view too; it's the one flush with the window's left edge.
                if view is NSTableView, view.convert(view.bounds, to: nil).minX > 100 { return view }
                for sub in view.subviews { if let found = firstResponderTarget(sub) { return found } }
                return nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NSApp.activate(ignoringOtherApps: true)
                guard let window = NSApp.windows.first(where: \.isVisible) else { return }
                window.makeKeyAndOrderFront(nil)
                let pane = state.activePane
                if let layout = env["WAYFILE_LAYOUT"].flatMap(LayoutMode.init(rawValue:)) { pane.layout = layout }
                AppSettings.shared.returnKeyRenames = env["WAYFILE_ENTER_TEST"] == "rename"
                pane.selection = Set(pane.items.filter { $0.name == "Sub" }.map(\.url))
                // Let a layout switch render (SwiftUI layouts focus their file area on appear).
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                if [.details, .columns].contains(pane.layout), let target = firstResponderTarget(window.contentView) {
                    window.makeFirstResponder(target)
                }
                log("layout=\(pane.layout.rawValue) firstResponder=\(type(of: window.firstResponder!)) selected=\(pane.selection.count)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                     charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
                        NSApp.sendEvent(event)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        let entered = state.activePane.location.folderURL?.lastPathComponent == "Sub"
                        log("after Return: opened=\(entered) renamePrompt=\(state.prompt != nil) backStack=\(state.activePane.backStack.count)")
                        state.prompt = nil
                        AppSettings.shared.returnKeyRenames = false
                        try? fm.removeItem(at: root)
                    }
                }
            }
        }
        if env["WAYFILE_F5_TEST"] != nil {
            // End-to-end F5/F6: two temp folders in dual pane, trigger the real menu items by key equivalent.
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("wayfile-f5-\(UUID().uuidString)")
            let left = root.appendingPathComponent("Left"), right = root.appendingPathComponent("Right")
            try? fm.createDirectory(at: left, withIntermediateDirectories: true)
            try? fm.createDirectory(at: right, withIntermediateDirectories: true)
            try? "copy me".write(to: left.appendingPathComponent("copy.txt"), atomically: true, encoding: .utf8)
            try? "move me".write(to: left.appendingPathComponent("move.txt"), atomically: true, encoding: .utf8)
            func log(_ text: String) { FileHandle.standardError.write("F5TEST \(text)\n".data(using: .utf8)!) }
            func select(_ name: String) {
                let pane = state.activePane
                pane.selection = Set(pane.items.filter { $0.name == name }.map(\.url))
            }
            func pressMenu(_ titlePrefix: String) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.isVisible }?.makeKeyAndOrderFront(nil)
                for menu in NSApp.mainMenu?.items.compactMap(\.submenu) ?? [] { menu.delegate?.menuNeedsUpdate?(menu); menu.update() }
                let items = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] } ?? []
                guard let item = items.first(where: { $0.title.hasPrefix(titlePrefix) }), let menu = item.menu else { log("menu item '\(titlePrefix)' missing"); return }
                let key = item.keyEquivalent.unicodeScalars.first.map { $0.value == 0xF708 ? "F5" : $0.value == 0xF709 ? "F6" : String($0) } ?? "none"
                log("menu '\(item.title)' key=\(key) enabled=\(item.isEnabled)")
                menu.performActionForItem(at: menu.index(of: item))
            }
            state.activePane.navigate(to: .folderAt(left))
            state.selectedTab.otherPane().navigate(to: .folderAt(right))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                select("copy.txt")
                // A person needs at least a moment between selecting and pressing F5; give the menu that too.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { pressMenu("Copy to") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    log("after F5: left/copy.txt=\(fm.fileExists(atPath: left.appendingPathComponent("copy.txt").path)) right/copy.txt=\(fm.fileExists(atPath: right.appendingPathComponent("copy.txt").path))")
                    select("move.txt")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { pressMenu("Move to") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        log("after F6: left/move.txt=\(fm.fileExists(atPath: left.appendingPathComponent("move.txt").path)) right/move.txt=\(fm.fileExists(atPath: right.appendingPathComponent("move.txt").path))")
                        log("right pane shows: \(state.selectedTab.inactivePane?.items.map(\.name).sorted() ?? [])")
                        try? fm.removeItem(at: root)
                    }
                }
            }
        }
        if env["WAYFILE_SIDEBAR_TEST"] != nil || env["WAYFILE_PREVIEW_TEST"] != nil {
            // Report panel widths; with a value, drag that divider there first (as a user would).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                func splits(_ view: NSView?) -> [NSSplitView] {
                    guard let view else { return [] }
                    return ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(splits)
                }
                guard let sidebar = splits(NSApp.windows.first { $0.isVisible }?.contentView).first else { return }
                func report(_ label: String) {
                    let ud = UserDefaults.standard
                    FileHandle.standardError.write(("WIDTHS \(label): sidebar=\(Int(sidebar.arrangedSubviews.first?.frame.width ?? -1)) "
                        + "preview=\(Int(MainView.debugPreviewWidth)) "
                        + "saved=\(ud.double(forKey: "sidebarWidth"))/\(ud.double(forKey: "previewWidth"))\n").data(using: .utf8)!)
                }
                report("launch")
                if let target = Double(env["WAYFILE_SIDEBAR_TEST"] ?? ""), target > 0 {
                    sidebar.setPosition(target, ofDividerAt: 0)
                }
                if let target = Double(env["WAYFILE_PREVIEW_TEST"] ?? ""), target > 0 {
                    // Same effect as releasing a drag of the preview handle.
                    previewWidth = target
                    RememberedWidth.preview.save(target)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { report("after drag") }
            }
        }
        if env["WAYFILE_SHORTCUT_TEST"] != nil {
            // Remap New Tab, then read the real menu item to confirm the change reached AppKit.
            func dump(_ label: String) {
                // AppKit refreshes menus right before matching a key equivalent; do the same here.
                for menu in NSApp.mainMenu?.items.compactMap(\.submenu) ?? [] {
                    menu.delegate?.menuNeedsUpdate?(menu)
                    menu.update()
                }
                let items = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] } ?? []
                let item = items.first { $0.title == "New Tab" }
                FileHandle.standardError.write("SHORTCUT \(label): key=\(item?.keyEquivalent ?? "nil") mods=\(item?.keyEquivalentModifierMask.rawValue ?? 0)\n".data(using: .utf8)!)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.isVisible }?.makeKeyAndOrderFront(nil)
                FileHandle.standardError.write("SHORTCUT active=\(NSApp.isActive) key=\(NSApp.keyWindow?.title ?? "none")\n".data(using: .utf8)!)
                dump("before")
                ShortcutStore.shared.set(KeyCombo("y", KeyCombo.command | KeyCombo.shift), for: .newTab)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    dump("after")
                    ShortcutStore.shared.reset(.newTab)
                }
            }
        }
    }
    #endif

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { sidebarVisible ? .all : .detailOnly },
            set: { sidebarVisible = $0 != .detailOnly }
        )) {
            SidebarView(state: state)
                .toolbar(removing: .sidebarToggle)
                // The column width modifier must stay outermost or SwiftUI ignores `ideal` at launch.
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { RememberedWidth.sidebar.save($0) }
                .navigationSplitViewColumnWidth(
                    min: RememberedWidth.sidebar.min, ideal: sidebarIdealWidth, max: RememberedWidth.sidebar.max
                )
        } detail: {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    TabBarView(state: state, sidebarVisible: $sidebarVisible)
                    Divider()
                    NavigationBar(state: state, sidebarVisible: $sidebarVisible)
                    Divider()
                    CommandBar(state: state)
                    if case .search(let query) = state.activePane.location {
                        Divider()
                        SearchFilterBar(state: state, pane: state.activePane, query: query)
                    }
                }
                .themedChrome()
                .zIndex(1)
                Divider()
                // Not an HSplitView: it ignores the preferred width at launch and jumps the preview to its maximum.
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        PanesView(state: state, tab: state.selectedTab)
                            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                        if state.terminal.isVisible {
                            TerminalPanel(state: state, panel: state.terminal)
                        }
                    }
                    // Home is a dashboard: nothing to preview there.
                    if state.showPreviewPane && ![.home, .timeline, .activity].contains(state.activePane.location) {
                        PanelResizeHandle(width: $previewWidth, range: RememberedWidth.preview.min...RememberedWidth.preview.max) {
                            RememberedWidth.preview.save($0)
                        }
                        .zIndex(1)
                        // Leading-aligned and clipped: content wider than the panel must never spill left over the handle.
                        InspectorView(state: state, pane: state.activePane)
                            .frame(width: previewWidth, alignment: .leading)
                            .clipped()
                            .frame(maxHeight: .infinity)
                            #if DEBUG
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { MainView.debugPreviewWidth = $0 }
                            #endif
                    }
                }
                if DropStackStore.shared.isVisible {
                    Divider()
                    DropStackBar(state: state)
                        .themedChrome()
                }
                Divider()
                StatusBar(state: state, pane: state.activePane)
                    .themedChrome()
            }
            .background(ThemedWindowBackground())
            // The tab bar sits in the (hidden) title bar.
            .ignoresSafeArea(.container, edges: .top)
        }
        .tint(Color.themeAccent)
        .overlay(alignment: .top) {
            if state.showCommandPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.08)
                        .ignoresSafeArea()
                        .onTapGesture { state.showCommandPalette = false }
                    CommandPalette(state: state)
                        .padding(.top, 70)
                }
            }
        }
        .navigationTitle(state.selectedTab.title)
        .onAppear { restoreSessionIfNeeded() }
        .background(WindowAccessor { window in
            if input == nil { input = WindowInputController(state: state) }
            input?.attach(to: window)
        })
        .onChange(of: state.session) { _, session in session.save() }
        .onChange(of: state.activePane.location.folderURL) { _, folder in state.terminal.paneMoved(to: folder) }
        .onDisappear { state.terminal.closeAll() }
        .modifier(WindowRequests(state: state))
        .sheet(isPresented: $state.showSelectMatching) {
            SelectMatchingView(state: state)
        }
        .sheet(item: $state.permissionsRequest) { target in
            PermissionsSheet(state: state, urls: target.urls)
        }
        .sheet(isPresented: $state.showNewVault) {
            NewVaultSheet(state: state)
        }
        .sheet(item: $state.compressRequest) { target in
            CompressSheet(state: state, urls: target.urls)
        }
        .sheet(item: $state.brokenLinksRequest) { target in
            BrokenLinksView(folder: target.folder)
        }
        .sheet(isPresented: $state.showAskAI, onDismiss: { state.aiSearchFolder = nil }) {
            AskAISheet(state: state, folder: state.aiSearchFolder)
        }
        .sheet(isPresented: $state.showConnect) {
            ConnectView(state: state)
        }
        .sheet(item: $state.organizeRequest) { target in
            OrganizeView(folder: target.folder)
        }
        .sheet(item: $state.integrityReport) { result in
            IntegrityReportView(result: result)
        }
        .sheet(item: $state.batchRenameRequest) { request in
            BatchRenameView(state: state, request: request)
        }
        #if DEBUG
        .onAppear { applyDebugEnvironment() }
        #endif
        .focusedSceneValue(\.windowState, state)
        .quickLookPreview($state.quickLookURL, in: state.activePane.selectedItems.map(\.url))
        // Alert bindings only read: every button resolves explicitly, so a dismissal can't race the action.
        .alert(state.prompt?.title ?? "", isPresented: .constant(state.prompt != nil)) {
            TextField("Name", text: $state.promptText)
            Button(state.prompt?.confirmTitle ?? String(localized: "OK")) { state.commitPrompt() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { state.cancelPrompt() }
        }
        .sheet(item: Binding(get: { state.conflictPrompt }, set: { if $0 == nil { state.resolveConflicts(nil) } })) { prompt in
            ConflictResolutionView(prompt: prompt) { state.resolveConflicts($0) }
        }
        .alert("Delete permanently?", isPresented: .constant(state.pendingPermanentDelete != nil)) {
            Button("Delete", role: .destructive) { state.confirmPermanentDelete() }
            Button("Cancel", role: .cancel) { state.pendingPermanentDelete = nil }
        } message: {
            Text("\(WindowState.describe(state.pendingPermanentDelete ?? [])) will be deleted immediately. This can’t be undone.")
        }
        .alert("Something went wrong", isPresented: .constant(state.errorMessage != nil)) {
            Button("OK", role: .cancel) { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }
}

enum TitleBar {
    /// Height of the title-bar row, aligned with the window's traffic lights.
    static let height: CGFloat = 40
    /// Space the traffic lights need when the tab bar starts at the window's left edge.
    static let trafficLightsWidth: CGFloat = 78
}

struct SidebarToggleButton: View {
    @Binding var isVisible: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isVisible.toggle() }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(isVisible ? String(localized: "Hide Sidebar (⌃⌘S)") : String(localized: "Show Sidebar (⌃⌘S)"))
    }
}

/// A panel width the user can drag, remembered across launches.
struct RememberedWidth {
    let key: String
    let min: CGFloat
    let max: CGFloat
    let standard: CGFloat

    static let sidebar = RememberedWidth(key: "sidebarWidth", min: 180, max: 320, standard: 220)
    static let preview = RememberedWidth(key: "previewWidth", min: 180, max: 520, standard: 240)

    var saved: CGFloat {
        let value = UserDefaults.standard.double(forKey: key)
        return value > 0 ? Swift.min(Swift.max(value, min), max) : standard
    }

    func save(_ width: CGFloat) {
        // Collapsing or animating panels report out-of-range widths; don't remember those.
        guard width >= min, width <= max else { return }
        UserDefaults.standard.set(Double(width.rounded()), forKey: key)
    }
}

/// Draggable divider that resizes the panel to its right. AppKit-backed: a real cursor rect and
/// mouse tracking are more reliable than a SwiftUI drag gesture on a hairline.
struct PanelResizeHandle: NSViewRepresentable {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    let onEnd: (CGFloat) -> Void

    /// Hit area; only a 1 pt line in the middle is drawn.
    static let thickness: CGFloat = 7

    func makeNSView(context: Context) -> ResizeHandleNSView {
        let view = ResizeHandleNSView()
        configure(view)
        return view
    }

    func updateNSView(_ view: ResizeHandleNSView, context: Context) {
        configure(view)
    }

    private func configure(_ view: ResizeHandleNSView) {
        let range = self.range
        view.currentWidth = { width }
        view.onDrag = { width = min(max($0, range.lowerBound), range.upperBound) }
        view.onEnd = { onEnd(width) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ResizeHandleNSView, context: Context) -> CGSize? {
        CGSize(width: Self.thickness, height: proposal.height ?? 100)
    }
}

final class ResizeHandleNSView: NSView {
    var currentWidth: () -> CGFloat = { 0 }
    var onDrag: (CGFloat) -> Void = { _ in }
    var onEnd: () -> Void = {}

    private var dragStart: (mouseX: CGFloat, width: CGFloat)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: (bounds.width - 1) / 2, y: 0, width: 1, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = (event.locationInWindow.x, currentWidth())
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        // Dragging left widens the panel on the right.
        onDrag(start.width - (event.locationInWindow.x - start.mouseX))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        onEnd()
    }
}

/// One pane, or two side by side in dual-pane mode.
struct PanesView: View {
    let state: WindowState
    let tab: TabState

    /// Share of the width given to the left pane; the divider between panes is draggable.
    @State private var leftFraction: CGFloat = 0.5

    var body: some View {
        if tab.panes.count >= 2 {
            // Explicit widths instead of HSplitView: tables would otherwise demand the width of all
            // their columns and push the layout past the window edge.
            GeometryReader { geo in
                let total = geo.size.width
                // The reader's content can run once more after panes were removed (dual → single),
                // so it reads its own snapshot instead of trusting the outer count check.
                let panes = tab.panes
                VStack(spacing: 0) {
                    if panes.count >= 2 {
                        row(panes[0], panes[1], total: total)
                    }
                    if panes.count == 4 {
                        Divider()
                        row(panes[2], panes[3], total: total)
                    }
                }
            }
        } else {
            PaneView(state: state, tab: tab, pane: tab.activePane)
        }
    }

    private func row(_ left: PaneState, _ right: PaneState, total: CGFloat) -> some View {
        HStack(spacing: 0) {
            pane(left)
                .frame(width: max(total * leftFraction - 0.5, 0))
            PanelResizeHandle(
                width: Binding(
                    get: { total * (1 - leftFraction) },
                    set: { leftFraction = 1 - $0 / max(total, 1) }
                ),
                range: (total * 0.2)...(total * 0.8)
            ) { _ in }
            .zIndex(1)
            pane(right)
                .frame(maxWidth: .infinity)
        }
    }

    private func pane(_ pane: PaneState) -> some View {
        PaneView(state: state, tab: tab, pane: pane)
            .frame(maxHeight: .infinity)
            .clipped()
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(pane.id == tab.activePaneID ? Color.themeAccent : .clear)
                    .frame(height: 2)
            }
    }
}

/// Opens the tool windows other code asks for through WindowState (log, diff, git, compare…).
private struct WindowRequests: ViewModifier {
    @Bindable var state: WindowState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .openAutomation)) { _ in
                // Every window receives it; only the active one opens the (single) Automation window.
                if WindowState.lastActive === state { openWindow(id: "automation") }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openTerminalSettings)) { _ in
                if WindowState.lastActive === state { openSettings() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openToolWindow)) { note in
                if WindowState.lastActive === state, let id = note.object as? String { openWindow(id: id) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openPlugin)) { note in
                if WindowState.lastActive === state, let path = note.object as? String { openWindow(id: "plugin", value: path) }
            }
            .onChange(of: state.logViewerRequest) { _, url in
                guard let url else { return }
                openWindow(id: "log", value: url)
                state.logViewerRequest = nil
            }
            .onChange(of: state.textDiffRequest) { _, target in
                guard let target else { return }
                openWindow(id: "textdiff", value: target)
                state.textDiffRequest = nil
            }
            .onChange(of: state.diskUsageRequest) { _, url in
                guard let url else { return }
                openWindow(id: "diskusage", value: url)
                state.diskUsageRequest = nil
            }
            .onChange(of: state.archiveRequest) { _, url in
                guard let url else { return }
                openWindow(id: "archive", value: url)
                state.archiveRequest = nil
            }
            .onChange(of: state.askAIRequest) { _, target in
                guard let target else { return }
                openWindow(id: "askai", value: target)
                state.askAIRequest = nil
            }
            .onChange(of: state.gitRequest) { _, target in
                guard let target else { return }
                openWindow(id: "git", value: target)
                state.gitRequest = nil
            }
            .onChange(of: state.duplicatesRequest) { _, folder in
                guard let folder else { return }
                openWindow(id: "duplicates", value: folder)
                state.duplicatesRequest = nil
            }
            .onChange(of: state.compareRequest) { _, request in
                guard let request else { return }
                openWindow(id: "compare", value: request)
                state.compareRequest = nil
            }
            .onChange(of: state.propertiesRequest) { _, request in
                guard let request else { return }
                openWindow(id: "properties", value: request)
                state.propertiesRequest = nil
            }
    }
}
