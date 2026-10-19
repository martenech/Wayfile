// File-operation self tests. Run with scripts/selftest.sh (works with Command Line Tools only,
// where `swift test` can't discover swift-testing tests).
import AppKit
import Foundation
import SwiftUI

var failures = 0
var checks = 0

func check(_ condition: @autoclosure () throws -> Bool, _ message: String, line: Int = #line) {
    checks += 1
    do {
        if try !condition() {
            failures += 1
            print("  ✗ line \(line): \(message)")
        }
    } catch {
        failures += 1
        print("  ✗ line \(line): \(message) — threw \(error)")
    }
}

/// For values that need `await` (check's autoclosure can't contain it); also prints what it got.
func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: Int = #line) {
    check(actual == expected, "\(message) (got \(actual))", line: line)
}

@MainActor
func checkThrowsAsync(_ message: String, line: Int = #line, _ body: () async throws -> Void) async {
    checks += 1
    do {
        try await body()
        failures += 1
        print("  ✗ line \(line): \(message) — did not throw")
    } catch {}
}

struct UnwrapError: Error { let what: String }

extension Optional {
    func unwrap(_ what: String) throws -> Wrapped {
        guard let self else { throw UnwrapError(what: what) }
        return self
    }
}

func checkThrows<E: Error>(_ type: E.Type, _ message: String, line: Int = #line, _ body: () throws -> Void) {
    checks += 1
    do {
        try body()
        failures += 1
        print("  ✗ line \(line): \(message) — did not throw")
    } catch is E {
    } catch {
        failures += 1
        print("  ✗ line \(line): \(message) — threw unexpected \(error)")
    }
}

struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wayfile-selftest-\(UUID().uuidString)")
    var src: URL { root.appendingPathComponent("src") }
    var dst: URL { root.appendingPathComponent("dst") }

    init() throws {
        try FileManager.default.createDirectory(at: src.appendingPathComponent("folder/sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        try "hello".write(to: src.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try Data(count: 3_000_000).write(to: src.appendingPathComponent("folder/sub/big.bin"))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

func test(_ name: String, _ body: (Fixture) throws -> Void) {
    print("• \(name)")
    do {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try body(fixture)
    } catch {
        failures += 1
        print("  ✗ threw \(error)")
    }
}

test("copy reports progress, undo and redo") { f in
    let progress = OperationProgress()
    let result = try FileOps.transfer([f.src.appendingPathComponent("a.txt"), f.src.appendingPathComponent("folder")],
                                      to: f.dst, mode: .copy, policy: .keepBoth, progress: progress)
    check(result.map(\.lastPathComponent) == ["a.txt", "folder"], "copied names")
    check(exists(f.dst.appendingPathComponent("folder/sub/big.bin")), "nested file copied")
    let s = progress.snapshot
    check(s.completedItems == 2, "2 items completed (got \(s.completedItems))")
    check(s.totalBytes == 3_000_005, "total bytes (got \(s.totalBytes))")
    check(s.completedBytes == s.totalBytes, "completed bytes == total (got \(s.completedBytes))")

    let inverse = try UndoRecord.combine(progress.records)!.revert()
    check(!exists(f.dst.appendingPathComponent("a.txt")) && !exists(f.dst.appendingPathComponent("folder")), "undo removed copies")
    check(exists(f.src.appendingPathComponent("a.txt")), "source untouched")
    _ = try inverse.revert()
    check(try read(f.dst.appendingPathComponent("a.txt")) == "hello", "redo restored copy")
}

test("move and undo") { f in
    let file = f.src.appendingPathComponent("a.txt")
    let progress = OperationProgress()
    _ = try FileOps.transfer([file], to: f.dst, mode: .move, policy: .keepBoth, progress: progress)
    check(!exists(file) && exists(f.dst.appendingPathComponent("a.txt")), "moved")
    _ = try UndoRecord.combine(progress.records)!.revert()
    check(exists(file) && !exists(f.dst.appendingPathComponent("a.txt")), "undo moved back")
}

test("conflict policies") { f in
    let file = f.src.appendingPathComponent("a.txt")
    let existing = f.dst.appendingPathComponent("a.txt")
    try "old".write(to: existing, atomically: true, encoding: .utf8)
    check(FileOps.conflicts([file], in: f.dst) == [file], "conflict detected")

    _ = try FileOps.transfer([file], to: f.dst, mode: .copy, policy: .skip, progress: OperationProgress())
    check(try read(existing) == "old", "skip keeps existing")

    let kept = try FileOps.transfer([file], to: f.dst, mode: .copy, policy: .keepBoth, progress: OperationProgress())
    check(kept.map(\.lastPathComponent) == ["a 2.txt"], "keep both → a 2.txt (got \(kept.map(\.lastPathComponent)))")

    let progress = OperationProgress()
    _ = try FileOps.transfer([file], to: f.dst, mode: .copy, policy: .replace, progress: progress)
    check(try read(existing) == "hello", "replace overwrote")
    _ = try UndoRecord.combine(progress.records)!.revert()
    check(try read(existing) == "old", "undo of replace restored the old file")
}

test("duplicate in same folder") { f in
    let file = f.src.appendingPathComponent("a.txt")
    check(FileOps.conflicts([file], in: f.src).isEmpty, "no conflict when duplicating in place")
    let result = try FileOps.transfer([file], to: f.src, mode: .copy, policy: .skip, progress: OperationProgress())
    check(result.map(\.lastPathComponent) == ["a 2.txt"], "duplicate named a 2.txt")
    let folder = try FileOps.transfer([f.src.appendingPathComponent("folder")], to: f.src, mode: .copy, policy: .skip, progress: OperationProgress())
    check(folder.map(\.lastPathComponent) == ["folder 2"], "folder duplicate named folder 2 (got \(folder.map(\.lastPathComponent)))")
}

test("refuse copying a folder into itself") { f in
    let folder = f.src.appendingPathComponent("folder")
    checkThrows(FileOpError.self, "copy into own subfolder") {
        _ = try FileOps.transfer([folder], to: folder.appendingPathComponent("sub"), mode: .copy, policy: .keepBoth, progress: OperationProgress())
    }
}

test("trash and undo") { f in
    let file = f.src.appendingPathComponent("a.txt")
    let progress = OperationProgress()
    _ = try FileOps.trash([file], progress: progress)
    check(!exists(file), "trashed")
    _ = try UndoRecord.combine(progress.records)!.revert()
    check(try read(file) == "hello", "restored from trash")
}

test("rename undo via moved record") { f in
    let file = f.src.appendingPathComponent("a.txt")
    let renamed = try FileOps.rename(file, to: "b.txt")
    _ = try UndoRecord.moved([MovedItem(from: file, to: renamed)]).revert()
    check(exists(file) && !exists(renamed), "rename undone")
}

test("tags and undo") { f in
    let file = f.src.appendingPathComponent("a.txt")
    try FileOps.setTags([FileTag(name: "Red", color: 6)], on: file)
    // Fresh URL each time: URL caches resource values, and tags are written straight to the xattr.
    let tags = { (try? URL(fileURLWithPath: file.path).resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? nil }
    check(tags() == ["Red"], "tag set")
    _ = try UndoRecord.tagged([TagChange(url: file, old: [], new: [FileTag(name: "Red", color: 6)])]).revert()
    check((tags() ?? []).isEmpty, "tag removed by undo")
}

test("cancellation") { f in
    let progress = OperationProgress()
    progress.cancel()
    checkThrows(CancellationError.self, "cancelled transfer throws") {
        _ = try FileOps.transfer([f.src.appendingPathComponent("folder")], to: f.dst, mode: .copy, policy: .keepBoth, progress: progress)
    }
    check(!exists(f.dst.appendingPathComponent("folder")), "nothing left behind")
}

test("grouping") { f in
    let fm = FileManager.default
    let dir = f.root.appendingPathComponent("grouping")
    try fm.createDirectory(at: dir.appendingPathComponent("Zeta"), withIntermediateDirectories: true)
    try Data(count: 10).write(to: dir.appendingPathComponent("apple.txt"))
    try Data(count: 2_000_000).write(to: dir.appendingPathComponent("banana.bin"))
    try Data().write(to: dir.appendingPathComponent("1-empty.txt"))
    let old = dir.appendingPathComponent("old.txt")
    try Data(count: 1).write(to: old)
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_500_000_000)], ofItemAtPath: old.path)

    let items = try FileSystem.list(dir).sorted { $0.name < $1.name }

    let bySize = Grouping.groups(items, by: .size, descending: false)
    check(bySize.map(\.title) == ["Folders", "Empty", "Tiny (< 16 KB)", "Medium (< 128 MB)"], "size groups ordered (got \(bySize.map(\.title)))")

    let byName = Grouping.groups(items, by: .name, descending: false)
    check(byName.first?.title == "#", "digits grouped under # first (got \(byName.map(\.title)))")
    check(byName.map(\.title).contains("Z"), "letters uppercased")

    let byDate = Grouping.groups(items, by: .modified, descending: false)
    check(byDate.first?.title == "Today", "newest bucket first (got \(byDate.map(\.title)))")
    check(byDate.last?.title == "2017", "old file in its year bucket")
    check(Grouping.groups(items, by: .modified, descending: true).first?.title == "2017", "descending reverses groups")

    let none = Grouping.groups(items, by: .none, descending: false)
    check(none.count == 1 && none[0].items.count == items.count, "no grouping → one group")
}

test("sort field round trip") { _ in
    for field in SortField.allCases {
        check(SortField(comparator: field.comparator(ascending: false)) == field, "\(field) survives comparator round trip")
    }
}

@MainActor
func testAsync(_ name: String, _ body: (Fixture) async throws -> Void) async {
    print("• \(name)")
    do {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try await body(fixture)
    } catch {
        failures += 1
        print("  ✗ threw \(error)")
    }
}

await testAsync("git status, commits, branches and sync") { f in
    let remote = f.root.appendingPathComponent("remote.git")
    let repo = f.root.appendingPathComponent("repo")
    try await Shell.check("/usr/bin/git", ["init", "--bare", "-b", "main", remote.path])
    try await Shell.check("/usr/bin/git", ["clone", remote.path, repo.path], environment: Git.environment)
    func git(_ args: String...) async throws { try await Git.check(["-c", "user.name=Tester", "-c", "user.email=t@example.com"] + args, in: repo) }
    func write(_ path: String, _ text: String) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    try write("README.md", "hi")
    try write("src/app.swift", "print(1)")
    try write("gone.txt", "bye")
    try await git("add", ".")
    try await git("commit", "-m", "Initial commit")
    try await git("push", "-u", "origin", "main")
    try write("src/app.swift", "print(2)")
    try await git("commit", "-am", "Change app")

    try write("README.md", "changed")       // modified
    try write("new.txt", "new")              // untracked file
    try write("fresh/a.txt", "a")            // untracked folder
    try FileManager.default.removeItem(at: repo.appendingPathComponent("gone.txt")) // deleted

    guard let info = await Git.info(for: repo) else { check(false, "repo detected"); return }
    check(info.branch == "main", "branch (got \(info.branch))")
    check(info.upstream == "origin/main", "upstream (got \(info.upstream ?? "nil"))")
    check(info.ahead == 1 && info.behind == 0, "ahead 1 / behind 0 (got \(info.ahead)/\(info.behind))")
    check(info.statuses["README.md"] == .modified, "README modified (got \(String(describing: info.statuses["README.md"])))")
    check(info.statuses["new.txt"] == .untracked, "new.txt untracked")
    check(info.statuses["fresh"] == .untracked, "untracked folder")
    check(info.statuses["gone.txt"] == .deleted, "deleted file")
    check(info.statuses["src"] == nil, "clean folder has no status")
    check(info.commits["src"]?.subject == "Change app", "folder gets its latest commit (got \(info.commits["src"]?.subject ?? "nil"))")
    check(info.commits["README.md"]?.subject == "Initial commit", "file commit subject")
    check(info.commits["README.md"]?.author == "Tester", "commit author")

    // Inside a subfolder, statuses are keyed by that folder's children.
    try write("src/app.swift", "print(3)")
    let sub = await Git.info(for: repo.appendingPathComponent("src"))
    check(sub?.statuses["app.swift"] == .modified, "nested file status relative to subfolder")
    let rootAgain = await Git.info(for: repo)
    check(rootAgain?.statuses["src"] == .modified, "folder with tracked change reads modified")

    // Branches: create, list, switch.
    try await git("switch", "-c", "feature/x")
    let branches = await Git.branches(in: repo)
    check(branches.contains { $0.name == "feature/x" && $0.isCurrent }, "new branch is current")
    check(branches.contains { $0.name == "origin/main" && $0.isRemote }, "remote branch listed")
    check(!branches.contains { $0.name.hasSuffix("/HEAD") }, "origin/HEAD hidden")
    try await git("switch", "main")

    // Push clears ahead count.
    try await git("push")
    let synced = await Git.info(for: repo)
    check(synced?.ahead == 0, "ahead 0 after push (got \(synced?.ahead ?? -1))")

    let outside = await Git.info(for: f.src)
    check(outside == nil, "non-repo folder has no git info")
}

test("git porcelain parsing") { _ in
    let output = "R  new name.txt\0old name.txt\0 M docs/guide.md\0?? docs/draft/\0UU conflict.txt\0"
    let root = Git.parseStatus(output, relativeTo: "")
    check(root["new name.txt"] == .renamed, "rename parsed, original path skipped")
    check(root["old name.txt"] == nil, "rename source not listed")
    check(root["docs"] == .modified, "folder mixing modified + untracked reads modified")
    check(root["conflict.txt"] == .conflicted, "conflict")
    let docs = Git.parseStatus(output, relativeTo: "docs")
    check(docs == ["guide.md": .modified, "draft": .untracked], "relative to subfolder (got \(docs))")

    let branch = Git.parseBranch("# branch.oid abcdef1234\n# branch.head (detached)\n")
    check(branch.head == "abcdef1" && branch.upstream == nil, "detached HEAD shows short hash")
}

await testAsync("hashes, sizes and permissions") { f in
    let file = f.root.appendingPathComponent("abc.txt")
    try "abc".write(to: file, atomically: true, encoding: .utf8)
    let hashes = try await Hashing.hashes(of: file) { _ in }
    check(hashes.md5 == "900150983cd24fb0d6963f7d28e17f72", "MD5 test vector")
    check(hashes.sha1 == "a9993e364706816aba3e25717850c26c9cd0d89d", "SHA-1 test vector")
    check(hashes.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 test vector")
    check(hashes.sha512.hasPrefix("ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"), "SHA-512 test vector")
    check(hashes.match("  BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD ") == "SHA-256", "compare is case/space-insensitive")
    check(hashes.match("deadbeef") == nil, "non-matching hash")

    var last = SizeSummary()
    for await summary in SizeCalculator.summarize([f.src]) { last = summary }
    check(last.isComplete, "size summary completes")
    check(last.bytes == 3_000_005, "recursive size (got \(last.bytes))")
    check(last.files == 2 && last.folders == 3, "counts files/folders incl. root (got \(last.files)/\(last.folders))")

    guard var perms = Permissions.read(file) else { check(false, "permissions readable"); return }
    perms.mode = 0o640
    try perms.apply(to: file)
    let reread = Permissions.read(file)
    check(reread?.octal == "640" && reread?.symbolic == "rw-r-----", "permissions applied (got \(reread?.symbolic ?? "nil"))")
    check(Permissions.bit(0, 0) == 0o400 && Permissions.bit(2, 2) == 0o001, "permission bit mapping")
}

test("cloud names and session restore") { f in
    check(CloudStore.displayName("GoogleDrive-me@example.com") == "Google Drive (me@example.com)", "google drive name")
    check(CloudStore.displayName("OneDrive-Personal") == "OneDrive Personal", "onedrive name")
    check(CloudStore.displayName("Dropbox") == "Dropbox", "dropbox name")

    let gone = f.root.appendingPathComponent("does-not-exist")
    let session = Session(tabs: [.init(panes: [.folderAt(f.src), .folderAt(gone)], activePane: 1),
                                 .init(panes: [.tag("Red")], activePane: 0)],
                          selectedTab: 1, showPreviewPane: false)
    let data = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(Session.self, from: data)
    check(decoded == session, "session round-trips through JSON")
    check(decoded.validated.tabs[0].panes == [.folderAt(f.src), .home], "missing folders fall back to Home")
}

await testAsync("keyboard shortcuts and theme colours") { _ in
    func key(_ chars: String, code: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }
    let cmdShiftN = KeyCombo(event: key("N", code: 45, [.command, .shift]))
    check(cmdShiftN == KeyCombo("n", KeyCombo.command | KeyCombo.shift), "⌘⇧N recorded (got \(String(describing: cmdShiftN)))")
    check(cmdShiftN?.display == "⇧⌘N", "display order follows macOS (got \(cmdShiftN?.display ?? "nil"))")
    check(KeyCombo(event: key("", code: 120, [])) == KeyCombo("f2", 0), "F2 alone is allowed")
    check(KeyCombo(event: key("a", code: 0, [])) == nil, "plain letters are rejected")
    check(KeyCombo(event: key("", code: 53, [.command])) == nil, "Esc is never recorded")
    check(KeyCombo(event: key("", code: 126, [.command]))?.display == "⌘↑", "arrow keys")
    check(KeyCombo("delete", KeyCombo.command | KeyCombo.option).keyboardShortcut != nil, "special keys map to KeyEquivalent")
    check(KeyCombo.none.keyboardShortcut == nil, "removed shortcut has no KeyEquivalent")

    let store = ShortcutStore.shared
    store.resetAll()
    check(store.display(.newTab) == "⌘T", "default shortcut")
    check(store.conflict(for: KeyCombo("t"), excluding: .refresh) == .newTab, "conflict detected")
    store.set(KeyCombo("y", KeyCombo.command | KeyCombo.shift), for: .newTab)
    check(store.display(.newTab) == "⇧⌘Y" && store.isCustomized(.newTab), "override applied")
    store.set(nil, for: .newTab)
    check(store.combo(for: .newTab) == nil && store.display(.newTab).isEmpty, "shortcut removed")
    store.set(KeyCombo("t"), for: .newTab)
    check(!store.isCustomized(.newTab), "setting the default clears the override")
    let defaults = ShortcutAction.allCases.compactMap(\.defaultCombo)
    check(Set(defaults).count == defaults.count, "no duplicate default shortcuts")
    store.resetAll()

    check(Color(hex: "88C0D0").hex == "88C0D0", "hex colour round trip")
    check(ThemePreset.all.map(\.id).count == Set(ThemePreset.all.map(\.id)).count, "unique theme ids")
}

test("new file templates") { f in
    for template in FileTemplate.builtIn {
        let created = try FileOps.createFile(named: template.fileName, in: f.dst, contents: try template.contents())
        check(created.lastPathComponent == template.fileName, "\(template.title): named \(template.fileName)")
    }
    let json = try Data(contentsOf: f.dst.appendingPathComponent("new.json"))
    check((try? JSONSerialization.jsonObject(with: json)) is [String: Any], "JSON template parses as an object")
    let rtf = try Data(contentsOf: f.dst.appendingPathComponent("New Document.rtf"))
    check((try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)) != nil, "RTF template opens as rich text")
    let html = try String(contentsOf: f.dst.appendingPathComponent("index.html"), encoding: .utf8)
    check(html.hasPrefix("<!doctype html>") && html.contains("</html>"), "HTML skeleton")
    check(try read(f.dst.appendingPathComponent("New Document.md")).hasPrefix("# "), "Markdown starts with a heading")
    check((try Data(contentsOf: f.dst.appendingPathComponent("untitled"))).isEmpty, "empty file is empty")
    let again = try FileOps.createFile(named: "new.json", in: f.dst, contents: Data())
    check(again.lastPathComponent == "new 2.json", "existing name gets a number (got \(again.lastPathComponent))")

    let folder = f.root.appendingPathComponent("templates")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "Dear …".write(to: folder.appendingPathComponent("Letter.txt"), atomically: true, encoding: .utf8)
    try "hidden".write(to: folder.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("Subfolder"), withIntermediateDirectories: true)
    let user = FileTemplate.userTemplates(in: folder)
    check(user.map(\.title) == ["Letter"], "user templates: files only, hidden skipped (got \(user.map(\.title)))")
    check(user.first?.fileName == "Letter.txt" && (try? user.first?.contents()) == Data("Dear …".utf8), "user template keeps name and contents")
}

test("batch rename rules") { _ in
    let date = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14
    func item(_ name: String, dir: Bool = false) -> BatchRenameItem {
        BatchRenameItem(url: URL(fileURLWithPath: "/tmp/batch/\(name)"), isDirectory: dir, modified: date, created: date)
    }
    func name(_ n: String, _ r: BatchRenameRules, index: Int = 0, dir: Bool = false) -> String {
        (try? BatchRename.newName(for: item(n, dir: dir), index: index, rules: r)) ?? "<error>"
    }
    var r = BatchRenameRules()
    check(name("Report.PDF", r) == "Report.PDF", "no rules → unchanged")

    r.find = "report"; r.replace = "Summary"
    check(name("Q1 Report.pdf", r) == "Q1 Summary.pdf", "plain replace is case-insensitive by default")
    r.caseSensitive = true
    check(name("Q1 Report.pdf", r) == "Q1 Report.pdf", "case-sensitive replace respects case")

    r = BatchRenameRules(); r.find = #"IMG_(\d+)"#; r.replace = "Photo $1"; r.useRegex = true
    check(name("IMG_0042.jpg", r) == "Photo 0042.jpg", "regex with capture group")
    r.find = "([unclosed"
    check((try? BatchRename.newName(for: item("a.txt"), index: 0, rules: r)) == nil, "invalid regex throws")

    r = BatchRenameRules(); r.find = "txt"; r.replace = "md"
    check(name("notes.txt", r) == "notes.txt", "extension untouched by default")
    r.includeExtension = true
    check(name("notes.txt", r) == "notes.md", "includeExtension changes it")

    r = BatchRenameRules(); r.trimWhitespace = true; r.caseChange = .title
    check(name("  my   holiday photo .jpg", r) == "My Holiday Photo.jpg", "trim + title case (got \(name("  my   holiday photo .jpg", r)))")
    r = BatchRenameRules(); r.caseChange = .lower; r.prefix = "2024 "; r.suffix = "_final"
    check(name("DRAFT.Docx", r) == "2024 draft_final.Docx", "prefix/suffix + lowercase keeps extension case")

    r = BatchRenameRules(); r.numbering = true; r.numberStart = 1; r.numberPadding = 3; r.numberSeparator = "-"
    check(name("scan.png", r, index: 0) == "scan-001.png" && name("scan.png", r, index: 11) == "scan-012.png", "numbering after, padded")
    r.numberPosition = .replace; r.numberStart = 10; r.numberStep = 5; r.numberPadding = 0
    check(name("whatever.png", r, index: 2) == "20.png", "numbering replaces name with start+step")

    r = BatchRenameRules(); r.addDate = true; r.dateFormat = "yyyy-MM-dd"
    check(name("Invoice.pdf", r) == "2023-11-14 Invoice.pdf", "date before name")

    r = BatchRenameRules(); r.suffix = " (old)"
    check(name("my.project", r, dir: true) == "my.project (old)", "folders never split a dotted name")
}

test("batch rename preview conflicts") { _ in
    let d = Date()
    let items = ["a.txt", "b.txt", "c.txt"].map {
        BatchRenameItem(url: URL(fileURLWithPath: "/tmp/batch/\($0)"), isDirectory: false, modified: d, created: d)
    }
    var r = BatchRenameRules(); r.find = #"[abc]"#; r.replace = "x"; r.useRegex = true
    let dupes = try BatchRename.preview(items, rules: r, existingNames: ["/tmp/batch": ["a.txt", "b.txt", "c.txt"]])
    check(dupes.allSatisfy { if case .conflict = $0.status { return true } else { return false } }, "duplicate new names conflict")

    r = BatchRenameRules(); r.suffix = "-1"
    let taken = try BatchRename.preview(items, rules: r, existingNames: ["/tmp/batch": ["a.txt", "b.txt", "c.txt", "A-1.TXT"]])
    check(taken[0].status == .conflict("An item with this name already exists"), "existing file conflicts (case-insensitive)")
    check(taken[1].status == .ok, "other rows fine")

    // Only changed rows matter; untouched ones are reported as unchanged.
    let rotate = [items[0], items[1]]
    r = BatchRenameRules(); r.find = "a"; r.replace = "TMP"
    let rows = try BatchRename.preview(rotate, rules: r, existingNames: ["/tmp/batch": ["a.txt", "b.txt"]])
    check(rows[0].newName == "TMP.txt" && rows[0].status == .ok && rows[1].status == .unchanged, "unchanged rows reported")

    r = BatchRenameRules(); r.find = "a.txt"; r.replace = ""; r.includeExtension = true
    check(try BatchRename.preview([items[0]], rules: r, existingNames: ["/tmp/batch": []])[0].status == .invalid("Empty name"), "empty name invalid")
    r.replace = "x/y"
    check(try BatchRename.preview([items[0]], rules: r, existingNames: ["/tmp/batch": []])[0].status == .invalid("Contains “/”"), "slash invalid")
}

test("batch rename on disk: swap, case-only, undo, rollback") { f in
    let dir = f.root.appendingPathComponent("rename")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try "A".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try "B".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
    try "P".write(to: dir.appendingPathComponent("photo.jpg"), atomically: true, encoding: .utf8)
    func items(_ names: [String]) -> [BatchRenameItem] {
        names.map { BatchRenameItem(FileItem(url: dir.appendingPathComponent($0))!) }
    }
    func listing() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }

    // Swap a↔b (no single rule does this, so build the rows directly — the shape the UI produces).
    let swapRows = [
        BatchRenameRow(url: dir.appendingPathComponent("a.txt"), oldName: "a.txt", newName: "b.txt", status: .ok),
        BatchRenameRow(url: dir.appendingPathComponent("b.txt"), oldName: "b.txt", newName: "a.txt", status: .ok),
    ]
    let progress = OperationProgress()
    _ = try BatchRename.apply(swapRows, progress: progress)
    let swappedA = try read(dir.appendingPathComponent("a.txt")), swappedB = try read(dir.appendingPathComponent("b.txt"))
    check(swappedA == "B" && swappedB == "A", "a↔b swapped")
    check(!listing().contains { $0.hasPrefix(".wayfile-rename") }, "no temporary files left")
    let redo = try UndoRecord.combine(progress.records)!.revert()
    check(try read(dir.appendingPathComponent("a.txt")) == "A", "undo restores the swap")
    _ = try redo.revert()
    check(try read(dir.appendingPathComponent("a.txt")) == "B", "redo swaps again")

    // Case-only rename on a case-insensitive volume.
    var r = BatchRenameRules(); r.caseChange = .title
    let caseRows = try BatchRename.preview(items(["photo.jpg"]), rules: r)
    check(caseRows[0].status == .ok, "case-only change is not a conflict")
    _ = try BatchRename.apply(caseRows, progress: OperationProgress())
    check(listing().contains("Photo.jpg"), "case-only rename applied (got \(listing()))")

    // A failure halfway rolls back what was already moved.
    let failing = [
        BatchRenameRow(url: dir.appendingPathComponent("Photo.jpg"), oldName: "Photo.jpg", newName: "Picture.jpg", status: .ok),
        BatchRenameRow(url: dir.appendingPathComponent("missing.txt"), oldName: "missing.txt", newName: "y.txt", status: .ok),
    ]
    let failProgress = OperationProgress()
    checkThrows(CocoaError.self, "missing file makes apply throw") { _ = try BatchRename.apply(failing, progress: failProgress) }
    check(listing().contains("Photo.jpg") && !listing().contains { $0.hasPrefix(".wayfile-rename") }, "rolled back after failure (got \(listing()))")
    check(failProgress.records.isEmpty, "nothing left to undo after a rollback")

    let conflicted = [BatchRenameRow(url: dir.appendingPathComponent("a.txt"), oldName: "a.txt", newName: "b.txt", status: .conflict("x"))]
    checkThrows(BatchRenameError.self, "apply refuses rows with conflicts") { _ = try BatchRename.apply(conflicted, progress: OperationProgress()) }
}

test("search: spotlight query and date ranges") { _ in
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    let now = ISO8601DateFormatter().date(from: "2026-10-09T12:00:00Z")!
    let (from7, to7) = SearchQuery.DateRange.last7Days.interval(now: now, calendar: cal)!
    check(ISO8601DateFormatter().string(from: from7) == "2026-10-03T00:00:00Z" && ISO8601DateFormatter().string(from: to7) == "2026-10-10T00:00:00Z",
          "last 7 days = today and the 6 days before")
    check(SearchQuery.DateRange.anyTime.interval(now: now) == nil, "any time has no bounds")

    var q = SearchQuery()
    q.text = #"say "hi""#
    check(SearchEngine.spotlightQuery(q) == #"kMDItemFSName == "*say \"hi\"*"cd"#, "name query escapes quotes (got \(SearchEngine.spotlightQuery(q)))")
    q.text = "invoice"; q.matchContent = true
    check(SearchEngine.spotlightQuery(q).contains("|| kMDItemTextContent == \"*invoice*\"cd"), "content search ORs text content")
    q = SearchQuery(); q.kinds = [.pdf]; q.minSize = 1024; q.tags = ["Red"]
    let pdfQuery = SearchEngine.spotlightQuery(q)
    check(pdfQuery == #"(kMDItemContentTypeTree == "com.adobe.pdf") && kMDItemFSSize >= 1024 && kMDItemUserTags == "Red""#, "kind + size + tag (got \(pdfQuery))")
    q = SearchQuery(); q.dateRange = .today
    check(SearchEngine.spotlightQuery(q, now: now).hasPrefix("kMDItemFSContentChangeDate >= $time.iso("), "date clause uses $time.iso")

    check(SearchQuery().isEmpty && !{ var e = SearchQuery(); e.kinds = [.image]; return e.isEmpty }(), "empty vs filter-only query")
    var saved = SearchQuery(); saved.text = "x"; saved.scope = .subfolders(URL(fileURLWithPath: "/tmp")); saved.dateRange = .between(now, now)
    let decoded = try JSONDecoder().decode(Location.self, from: JSONEncoder().encode(Location.search(saved)))
    check(decoded == .search(saved), "search location round-trips (sessions, saved searches)")
}

await testAsync("search: scan engine filters on real files") { f in
    let fm = FileManager.default
    let root = f.root.appendingPathComponent("search")
    let sub = root.appendingPathComponent("Sub")
    try fm.createDirectory(at: sub, withIntermediateDirectories: true)
    try "Invoice for October".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    try "let invoiceTotal = 42".write(to: sub.appendingPathComponent("billing.swift"), atomically: true, encoding: .utf8)
    try Data(count: 5_000_000).write(to: root.appendingPathComponent("big.bin"))
    try Data(count: 10).write(to: root.appendingPathComponent("photo.png"))
    let old = root.appendingPathComponent("old report.pdf")
    try Data(count: 10).write(to: old)
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_500_000_000)], ofItemAtPath: old.path)
    try FileOps.setTags([FileTag(name: "Red", color: 6)], on: root.appendingPathComponent("photo.png"))

    func names(_ configure: (inout SearchQuery) -> Void) async -> [String] {
        var q = SearchQuery(); q.engine = .scan; q.scope = .subfolders(root)
        configure(&q)
        return await SearchEngine.run(q).map(\.lastPathComponent).sorted()
    }
    checkEqual(await names { $0.text = "INVOICE" }, [], "name search doesn't look inside files")
    checkEqual(await names { $0.text = "invoice"; $0.matchContent = true }, ["billing.swift", "notes.txt"], "content search finds text and code")
    checkEqual(await names { $0.text = "invoice"; $0.matchContent = true; $0.scope = .folder(root) }, ["notes.txt"], "folder-only scope skips subfolders")
    checkEqual(await names { $0.kinds = [.image] }, ["photo.png"], "kind: images")
    checkEqual(await names { $0.kinds = [.text] }, ["billing.swift", "notes.txt"], "kind: text & code")
    checkEqual(await names { $0.kinds = [.folder] }, ["Sub"], "kind: folders")
    checkEqual(await names { $0.minSize = 1 << 20 }, ["big.bin"], "size: over 1 MB (folders excluded)")
    checkEqual(await names { $0.tags = ["Red"] }, ["photo.png"], "tag filter")
    checkEqual(await names { $0.text = "report"; $0.dateRange = .last30Days }, [], "date filter excludes old file")
    checkEqual(await names { $0.text = "report"; $0.dateRange = .between(Date(timeIntervalSince1970: 1_499_000_000), Date(timeIntervalSince1970: 1_501_000_000)) }, ["old report.pdf"], "custom date range")
    checkEqual(await names { _ in }, [], "empty query returns nothing")
}

test("tags keep their colours (Finder-compatible)") { f in
    let file = f.src.appendingPathComponent("a.txt")
    let tags = [FileTag(name: "Projekt X", color: 4), FileTag(name: "Červená", color: 6), FileTag(name: "Bez farby", color: 0)]
    try TagIO.write(tags, to: file)
    check(TagIO.read(file) == tags, "xattr round trip keeps names and colours")
    let names = (try? file.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    check(names == ["Projekt X", "Červená", "Bez farby"], "Foundation sees the same tag names (got \(names))")
    check(FileItem(url: file)?.fileTags == tags, "FileItem reads tags with colours")
    try TagIO.write([], to: file)
    check(TagIO.read(file).isEmpty && (FileItem(url: file)?.fileTags.isEmpty ?? false), "removing all tags")
    check(TagIO.parse("Work\n2") == FileTag(name: "Work", color: 2) && TagIO.parse("Plain") == FileTag(name: "Plain", color: 0), "entry parsing")
    // The red tag's name depends on the Mac's language ("Červená" in Slovak) — take it from Finder.
    let red = UserDefaults(suiteName: "com.apple.finder")?.stringArray(forKey: "FavoriteTagNames")?.dropFirst().first ?? "Red"
    let colors = TagIO.systemColors(for: [red, "Something Custom"])
    check(colors[red] == 6 && colors["Something Custom"] == 0, "system resolves the localized red tag (\(red)) (got \(colors))")
}

await testAsync("timeline: persistence, undo any entry, safety checks") { f in
    let fm = FileManager.default
    let store = TimelineStore(fileURL: f.root.appendingPathComponent("timeline.json"))
    func entry(_ title: String, _ record: UndoRecord?) -> TimelineEntry {
        TimelineEntry(title: title, undoTitle: title, status: .completed, record: record)
    }

    // Two real operations: move a.txt to dst, then create a file.
    let a = f.src.appendingPathComponent("a.txt"), moved = f.dst.appendingPathComponent("a.txt")
    try fm.moveItem(at: a, to: moved)
    let first = entry("Move", .moved([MovedItem(from: a, to: moved)]))
    store.add(first)
    let created = try FileOps.createFile(named: "new.txt", in: f.src)
    store.add(entry("New File", .created([created])))
    store.add(entry("Delete", nil))

    // Persistence: a fresh store reading the same file sees the same history.
    store.saveNow()
    let reloaded = TimelineStore(fileURL: f.root.appendingPathComponent("timeline.json"))
    check(reloaded.entries == store.entries && reloaded.entries.count == 3, "history survives a restart")
    check(reloaded.entries.first?.title == "Delete" && reloaded.entries.first?.canUndo == false, "non-undoable entries are logged too")

    // Undo the OLDER move while the newer file creation stays.
    try await reloaded.undo(first.id)
    check(exists(a) && !exists(moved), "older move undone")
    check(exists(created), "newer operation untouched")
    check(reloaded.entry(first.id)?.isUndone == true && reloaded.entry(first.id)?.canRedo == true, "entry marked undone")
    try await reloaded.redo(first.id)
    check(!exists(a) && exists(moved) && reloaded.entry(first.id)?.canUndo == true, "redo re-applies the move")

    // Safety: if the file was moved elsewhere meanwhile, undo refuses and changes nothing.
    let elsewhere = f.root.appendingPathComponent("elsewhere.txt")
    try fm.moveItem(at: moved, to: elsewhere)
    var refused = false
    do { try await reloaded.undo(first.id) } catch is TimelineError { refused = true }
    check(refused, "undo refused when the item is no longer where the operation left it")
    check(exists(elsewhere) && !exists(a), "nothing touched by a refused undo")
    check(reloaded.entry(first.id)?.canUndo == true, "entry still undoable once things are put back")

    // Safety: something new at the original place blocks moving back over it.
    try fm.moveItem(at: elsewhere, to: moved)
    try "intruder".write(to: a, atomically: true, encoding: .utf8)
    let problems = UndoRecord.moved([MovedItem(from: a, to: moved)]).problems()
    check(problems.count == 1 && problems[0].contains("already at"), "occupied original place reported (got \(problems))")

    // Records round-trip through JSON, including nested groups and tags.
    let record = UndoRecord.group([.trashed([TrashedItem(original: a, trashed: moved)]),
                                   .tagged([TagChange(url: a, old: [], new: [FileTag(name: "Red", color: 6)])]), .created([created])])
    check(try JSONDecoder().decode(UndoRecord.self, from: JSONEncoder().encode(record)) == record, "undo records encode/decode")

    // Batch rename's two passes show as old → new names.
    let tmp = f.src.appendingPathComponent(".wayfile-rename-X")
    let lines = UndoRecord.group([.moved([MovedItem(from: a, to: tmp)]), .moved([MovedItem(from: tmp, to: f.src.appendingPathComponent("b.txt"))])]).lines
    check(lines.map(\.text) == ["a.txt → b.txt"], "batch rename shown as a single rename (got \(lines.map(\.text)))")
}

await testAsync("transfer queue: pause, lanes, cancel while queued") { f in
    // Pause: a paused transfer copies nothing until resumed.
    let progress = OperationProgress()
    progress.setPaused(true)
    let src = f.src.appendingPathComponent("folder"), dst = f.dst
    let task = Task.detached { try FileOps.transfer([src], to: dst, mode: .copy, policy: .keepBoth, progress: progress) }
    try await Task.sleep(for: .milliseconds(400))
    check(!exists(dst.appendingPathComponent("folder")) && progress.snapshot.isPaused, "nothing copied while paused")
    progress.setPaused(false)
    _ = try await task.value
    check(exists(dst.appendingPathComponent("folder/sub/big.bin")), "copy completes after resume")

    // Lanes: two operations on the same lane run one after the other.
    let center = OperationCenter.shared
    var order: [String] = []
    async let first: [URL] = center.run("First", undoTitle: "Test", lane: "test-lane") { _ in
        await MainActor.run { order.append("first start") }
        try await Task.sleep(for: .milliseconds(400))
        await MainActor.run { order.append("first end") }
        return []
    }
    try await Task.sleep(for: .milliseconds(100))
    async let second: [URL] = center.run("Second", undoTitle: "Test", lane: "test-lane") { _ in
        await MainActor.run { order.append("second start") }
        return []
    }
    try await Task.sleep(for: .milliseconds(100))
    check(center.operations.first { $0.title == "Second" }?.status == .queued, "second operation waits in the queue")
    _ = try await (first, second)
    checkEqual(order, ["first start", "first end", "second start"], "same-lane operations run sequentially")

    // Cancelling a queued operation means its work never runs.
    var ranCancelled = false
    async let blocker: [URL] = center.run("Blocker", undoTitle: "Test", lane: "lane-2") { _ in
        try await Task.sleep(for: .milliseconds(300)); return []
    }
    try await Task.sleep(for: .milliseconds(50))
    let queued = Task { try await center.run("Queued", undoTitle: "Test", lane: "lane-2") { _ in
        await MainActor.run { ranCancelled = true }; return []
    } }
    try await Task.sleep(for: .milliseconds(50))
    center.operations.first { $0.title == "Queued" }?.cancel()
    _ = try await blocker
    let outcome = await queued.result
    check(!ranCancelled, "cancelled queued work never runs")
    check({ if case .failure(let e) = outcome { return e is CancellationError }; return false }(), "cancelled queued operation throws CancellationError")
}

test("per-item conflict choices") { f in
    for name in ["one.txt", "two.txt", "three.txt"] {
        try "new \(name)".write(to: f.src.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try "old \(name)".write(to: f.dst.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let sources = ["one.txt", "two.txt", "three.txt"].map { f.src.appendingPathComponent($0) }
    let overrides: [String: FileOps.ConflictPolicy] = [
        sources[0].standardizedFileURL.path: .replace,
        sources[1].standardizedFileURL.path: .skip,
    ]
    let result = try FileOps.transfer(sources, to: f.dst, mode: .copy, policy: .keepBoth, overrides: overrides, progress: OperationProgress())
    check(try read(f.dst.appendingPathComponent("one.txt")) == "new one.txt", "replace applied to one item")
    check(try read(f.dst.appendingPathComponent("two.txt")) == "old two.txt", "skip applied to another")
    check(try read(f.dst.appendingPathComponent("three 2.txt")) == "new three.txt", "default keep-both for the rest")
    checkEqual(result.map(\.lastPathComponent).sorted(), ["one.txt", "three 2.txt"], "returned items")
}

test("verify after copy") { f in
    let result = try FileOps.transfer([f.src.appendingPathComponent("folder"), f.src.appendingPathComponent("a.txt")],
                                      to: f.dst, mode: .copy, policy: .keepBoth, verify: true, progress: OperationProgress())
    check(result.count == 2, "verified copy succeeds")
    let tampered = f.dst.appendingPathComponent("folder/sub/big.bin")
    try Data(count: 10).write(to: tampered)
    let differences = try Hashing.differences(between: f.src.appendingPathComponent("folder"), and: f.dst.appendingPathComponent("folder"))
    checkEqual(differences, ["folder/sub/big.bin"], "a changed file inside a folder is detected")
    try "extra".write(to: f.dst.appendingPathComponent("folder/extra.txt"), atomically: true, encoding: .utf8)
    let more = try Hashing.differences(between: f.src.appendingPathComponent("folder"), and: f.dst.appendingPathComponent("folder"))
    check(more.contains("folder/extra.txt"), "an extra file is detected")
}

test("directory diff and sync") { f in
    let fm = FileManager.default
    let left = f.root.appendingPathComponent("L"), right = f.root.appendingPathComponent("R")
    try fm.createDirectory(at: left.appendingPathComponent("onlyleft/deep"), withIntermediateDirectories: true)
    try fm.createDirectory(at: right.appendingPathComponent("shared"), withIntermediateDirectories: true)
    try fm.createDirectory(at: left.appendingPathComponent("shared"), withIntermediateDirectories: true)
    let old = Date(timeIntervalSince1970: 1_600_000_000), new = Date(timeIntervalSince1970: 1_700_000_000)
    func put(_ root: URL, _ path: String, _ text: String, _ date: Date) throws {
        let url = root.appendingPathComponent(path)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
    try put(left, "same.txt", "same", old); try put(right, "same.txt", "same", old)
    try put(left, "shared/b.txt", "left version", new); try put(right, "shared/b.txt", "right v", old)
    try put(left, "c.txt", "only left", old)
    try put(left, "onlyleft/deep/x.txt", "x", old)
    try put(right, "d.txt", "only right", old)
    try put(left, "e.txt", "older", old); try put(right, "e.txt", "newer on right", new)

    var entries = try DirectoryDiff.compare(left: left, right: right)
    let status = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0.status) })
    checkEqual(status["shared/b.txt"], .leftNewer, "left newer")
    checkEqual(status["c.txt"], .leftOnly, "only left")
    checkEqual(status["onlyleft"], .leftOnly, "folder only on the left listed once")
    check(status["onlyleft/deep/x.txt"] == nil, "its contents are not listed separately")
    checkEqual(status["d.txt"], .rightOnly, "only right")
    checkEqual(status["e.txt"], .rightNewer, "right newer")
    check(status["same.txt"] == nil || status["same.txt"] == .same, "identical file is same")

    let update = DirectoryDiff.plan(entries, mode: .updateRight)
    checkEqual(Set(update.map(\.path)), ["shared/b.txt", "c.txt", "onlyleft"], "update-right copies new and newer from the left only")
    check(DirectoryDiff.plan(entries, mode: .twoWay).count == 5, "two-way copies both directions")
    check(!DirectoryDiff.plan(entries, mode: .twoWay).contains { if case .trash = $0.kind { return true }; return false }, "two-way never deletes")

    try DirectoryDiff.execute(update, left: left, right: right, progress: OperationProgress())
    check(try read(right.appendingPathComponent("shared/b.txt")) == "left version", "newer file copied")
    check(exists(right.appendingPathComponent("onlyleft/deep/x.txt")), "missing folder copied with contents")

    entries = try DirectoryDiff.compare(left: left, right: right)
    checkEqual(Set(entries.filter { $0.status != .same }.map(\.path)), ["d.txt", "e.txt"], "after update only right-side differences remain")

    let mirrorProgress = OperationProgress()
    try DirectoryDiff.execute(DirectoryDiff.plan(entries, mode: .mirrorToRight), left: left, right: right, progress: mirrorProgress)
    entries = try DirectoryDiff.compare(left: left, right: right)
    check(entries.allSatisfy { $0.status == .same }, "after mirroring both sides match (got \(entries.filter { $0.status != .same }.map(\.path)))")
    check(!exists(right.appendingPathComponent("d.txt")), "extra file removed (to the Trash) by mirror")

    _ = try UndoRecord.combine(mirrorProgress.records)!.revert()
    check(try read(right.appendingPathComponent("d.txt")) == "only right", "undo restores the removed file")
    check(try read(right.appendingPathComponent("e.txt")) == "newer on right", "undo restores the replaced file")
}

test("folder integrity baseline and check") { f in
    let store = f.root.appendingPathComponent("integrity.json")
    let folder = f.src
    let files = try Integrity.hashes(of: folder, progress: OperationProgress())
    check(files.keys.sorted() == ["a.txt", "folder/sub/big.bin"], "every file fingerprinted (got \(files.keys.sorted()))")
    try Integrity.save(Integrity.Baseline(folder: folder.standardizedFileURL.path, created: Date(), files: files), to: store)
    let baseline = Integrity.baseline(for: folder, from: store)
    check(baseline?.files == files, "baseline saved and loaded")
    check(Integrity.compare(baseline!, with: try Integrity.hashes(of: folder, progress: OperationProgress())).isClean, "unchanged folder is clean")

    try "edited".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try "new".write(to: folder.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: folder.appendingPathComponent("folder/sub/big.bin"))
    let report = Integrity.compare(baseline!, with: try Integrity.hashes(of: folder, progress: OperationProgress()))
    check(report.changed == ["a.txt"] && report.added == ["new.txt"] && report.removed == ["folder/sub/big.bin"],
          "changed / added / removed reported (got \(report.changed) \(report.added) \(report.removed))")
}

await testAsync("search: glob, regex, not opened, old saved searches") { f in
    let fm = FileManager.default
    let root = f.root.appendingPathComponent("patterns")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    for name in ["IMG_0001.jpg", "IMG_0002.jpg", "IMG_12.jpg", "notes.txt", "report-2024.pdf"] {
        try "content \(name)".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let stale = root.appendingPathComponent("report-2024.pdf")
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_500_000_000)], ofItemAtPath: stale.path)
    try "order 0001 shipped".write(to: root.appendingPathComponent("log1.log.txt"), atomically: true, encoding: .utf8)
    try "order 0002 pending".write(to: root.appendingPathComponent("log2.log.txt"), atomically: true, encoding: .utf8)
    var values = URLResourceValues(); values.contentAccessDate = Date(timeIntervalSince1970: 1_500_000_000)
    var staleURL = stale; try staleURL.setResourceValues(values)

    func names(_ configure: (inout SearchQuery) -> Void) async -> [String] {
        var q = SearchQuery(); q.engine = .scan; q.scope = .folder(root); configure(&q)
        return await SearchEngine.run(q).map(\.lastPathComponent).sorted()
    }
    checkEqual(await names { $0.text = "img_????.jpg"; $0.textMatch = .glob }, ["IMG_0001.jpg", "IMG_0002.jpg"], "glob with ? wildcards, case-insensitive")
    checkEqual(await names { $0.text = #"^IMG_\d{2}\.jpg$"#; $0.textMatch = .regex }, ["IMG_12.jpg"], "regex on names")
    checkEqual(await names { $0.text = #"order 000[12] (shipped|pending)"#; $0.textMatch = .regex; $0.matchContent = true }, ["log1.log.txt", "log2.log.txt"], "regex inside text file contents")
    checkEqual(await names { $0.text = "([bad"; $0.textMatch = .regex }, [], "invalid regex finds nothing (no crash)")
    checkEqual(await names { $0.notOpenedForDays = 90 }, ["report-2024.pdf"], "not opened for 90 days")

    var glob = SearchQuery(); glob.text = "*.pdf"; glob.textMatch = .glob
    checkEqual(SearchEngine.spotlightQuery(glob), #"kMDItemFSName == "*.pdf"cd"#, "glob passed to Spotlight as-is")
    var regex = SearchQuery(); regex.text = "^x"; regex.textMatch = .regex; regex.kinds = [.pdf]
    check(!SearchEngine.spotlightQuery(regex).contains("kMDItemFSName"), "regex names are filtered after Spotlight")

    let oldJSON = #"{"text":"invoice","matchContent":true,"kinds":["pdf"],"dateField":"modified","dateRange":{"anyTime":{}},"tags":[],"scope":{"everywhere":{}},"engine":"spotlight"}"#
    let decoded = try JSONDecoder().decode(SearchQuery.self, from: Data(oldJSON.utf8))
    check(decoded.text == "invoice" && decoded.textMatch == .plain && decoded.notOpenedForDays == nil && decoded.kinds == [.pdf],
          "searches saved by older versions still load")
}

test("duplicate finder and smart collections") { f in
    let fm = FileManager.default
    let root = f.root.appendingPathComponent("dups")
    try fm.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
    let photo = Data((0..<200_000).map { UInt8($0 % 251) })
    try photo.write(to: root.appendingPathComponent("photo.jpg"))
    try photo.write(to: root.appendingPathComponent("nested/photo copy.jpg"))
    try photo.write(to: root.appendingPathComponent("nested/renamed.jpg"))
    var sameHead = photo; sameHead[150_000] ^= 0xFF          // same size and first 64 KB, different later
    try sameHead.write(to: root.appendingPathComponent("almost.jpg"))
    try Data("tiny".utf8).write(to: root.appendingPathComponent("a.txt"))
    try Data("tiny".utf8).write(to: root.appendingPathComponent("b.txt"))
    try Data("diff".utf8).write(to: root.appendingPathComponent("c.txt"))   // same size, other content
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: root.appendingPathComponent("nested/renamed.jpg").path)

    let groups = try DuplicateFinder.find(in: root)
    let names = groups.map { $0.files.map(\.url.lastPathComponent).sorted() }
    check(names.contains(["photo copy.jpg", "photo.jpg", "renamed.jpg"]), "identical photos grouped regardless of name (got \(names))")
    check(names.contains(["a.txt", "b.txt"]), "identical small files grouped")
    check(!names.flatMap { $0 }.contains("almost.jpg") && !names.flatMap { $0 }.contains("c.txt"), "same size but different content is not a duplicate")
    check(groups.first?.wasted == 400_000, "biggest waste first")
    let photos = groups.first!
    let keepOldest = DuplicateFinder.autoMark([photos], keep: .oldest)
    check(keepOldest.count == 2 && !keepOldest.contains { $0.lastPathComponent == "renamed.jpg" }, "auto-mark keeps the oldest copy")
    check(try DuplicateFinder.find(in: root, minSize: 1 << 20).isEmpty, "minimum size filter")

    for collection in SmartCollection.allCases {
        check(!collection.query.isEmpty && collection.query.isValidPattern, "\(collection.title) is a valid query")
        check(SmartCollection.matching(collection.query) == collection, "\(collection.title) is recognised back from its query")
    }
}

await testAsync("workspaces") { f in
    let store = WorkspaceStore.shared
    for existing in store.workspaces { store.remove(existing) }
    let quad = Session(tabs: [.init(panes: [.folderAt(f.src), .folderAt(f.dst), .home, .timeline], activePane: 2)],
                       selectedTab: 0, showPreviewPane: true)
    store.save(Workspace(name: "Client A", session: quad, sidebarVisible: false))
    store.save(Workspace(name: "client a", session: Session(tabs: [.init(panes: [.home], activePane: 0)], selectedTab: 0, showPreviewPane: false), sidebarVisible: true))
    check(store.workspaces.count == 1, "saving under the same name (any case) updates instead of duplicating")
    check(store.workspaces[0].session.tabs[0].panes == [.home], "update replaced the layout")
    store.save(Workspace(name: "Photos", session: quad, sidebarVisible: false))
    store.rename(store.workspaces[1], to: "Photo Edit")
    check(store.workspaces.map(\.name) == ["client a", "Photo Edit"], "rename (got \(store.workspaces.map(\.name)))")
    let decoded = try JSONDecoder().decode([Workspace].self, from: JSONEncoder().encode(store.workspaces))
    check(decoded == store.workspaces && decoded[1].session.tabs[0].panes.count == 4, "workspaces with four panes round-trip")
    for existing in store.workspaces { store.remove(existing) }
    check(store.workspaces.isEmpty, "delete")
}

await testAsync("inspector viewers") { f in
    let html = MarkdownHTML.render("# Title\n\nSome **bold** and *it* with `code` and [link](https://x.dev).\n\n- one\n- [x] done\n\n1. first\n\n```\nlet a = 1 < 2\n```\n\n> quote")
    check(html.contains("<h1>Title</h1>"), "markdown heading")
    check(html.contains("<strong>bold</strong>") && html.contains("<em>it</em>") && html.contains("<code>code</code>"), "markdown emphasis and code")
    check(html.contains("<a href=\"https://x.dev\">link</a>"), "markdown link")
    check(html.contains("<ul>") && html.contains("<li>one</li>") && html.contains("☑︎ done") && html.contains("<ol>"), "markdown lists")
    check(html.contains("let a = 1 &lt; 2"), "code blocks are escaped")
    check(html.contains("<blockquote>quote</blockquote>"), "markdown quote")

    let highlighted = CodeHighlighter.highlight("let x = \"hi\" // note\nreturn 42", language: "swift")
    let colors = highlighted.runs.compactMap { run -> (String, Color)? in run.foregroundColor.map { (String(highlighted[run.range].characters), $0) } }
    check(colors.contains { $0.0 == "let" } && colors.contains { $0.0 == "return" }, "keywords coloured")
    check(colors.contains { $0.0 == "\"hi\"" } && colors.contains { $0.0 == "// note" } && colors.contains { $0.0 == "42" }, "strings, comments, numbers coloured")

    let node = JSONNode.parse(Data(#"{"name":"Wayfile","tags":["a","b"],"ok":true,"n":3,"x":null}"#.utf8))
    check(node?.children?.map(\.key) == ["n", "name", "ok", "tags", "x"], "json keys sorted")
    check(node?.children?.first { $0.key == "tags" }?.summary == "[ 2 ]" && node?.children?.first { $0.key == "ok" }?.summary == "true", "json summaries")
    check(JSONNode.parse(Data("{nope".utf8)) == nil, "invalid json rejected")

    let dump = HexDump.lines(Data("Hello, Wayfile app!".utf8))
    checkEqual(dump.first, "00000000  48 65 6c 6c 6f 2c 20 57  61 79 66 69 6c 65 20 61  |Hello, Wayfile a|", "hex dump line")
    check(dump.count == 2 && dump[1].hasSuffix("|pp!|"), "hex dump remainder")

    func kind(_ name: String, size: Int = 10) throws -> ViewerKind {
        let url = f.root.appendingPathComponent(name)
        try Data(count: size).write(to: url)
        return ViewerKind.of(FileItem(url: url)!)
    }
    check(try kind("readme.md") == .markdown && kind("data.json") == .json && kind("main.swift") == .code("swift"), "viewer kinds by extension")
    check(try kind("server.log") == .log && kind("page.html") == .web && kind("blob.bin") == .binary, "log, web, binary kinds")

    let zip = f.root.appendingPathComponent("archive.zip")
    try await Shell.check("/usr/bin/ditto", ["-c", "-k", "--keepParent", f.src.appendingPathComponent("folder").path, zip.path])
    let entries = await ArchiveListing.entries(of: zip) ?? []
    check(entries.contains { $0.hasSuffix("big.bin") }, "archive entries listed (got \(entries))")
    check(Metadata.codecName(0x61766331) == "H.264 (avc1)", "codec names")
}

await testAsync("context menu actions") { f in
    let base = URL(fileURLWithPath: "/Users/me/repo")
    let urls = [base.appendingPathComponent("src/main.swift"), URL(fileURLWithPath: "/tmp/it's here.txt")]
    checkEqual(PathFormat.relative.string(for: urls, relativeTo: base), "src/main.swift\n/tmp/it's here.txt", "relative paths (outside root stays absolute)")
    checkEqual(PathFormat.shell.string(for: urls, relativeTo: nil), "'/Users/me/repo/src/main.swift' '/tmp/it'\\''s here.txt'", "shell-escaped paths")
    checkEqual(PathFormat.fileURL.string(for: [urls[1]], relativeTo: nil), "file:///tmp/it's%20here.txt", "file URL")
    checkEqual(PathFormat.name.string(for: urls, relativeTo: nil), "main.swift\nit's here.txt", "names")
    let quoted = PathFormat.shellQuote("a b'$c")
    checkEqual(try await Shell.check("/bin/sh", ["-c", "printf %s \(quoted)"]), "a b'$c", "shell quoting round-trips through sh")

    let suite = UserDefaults(suiteName: "wayfile.selftest.contextmenu")!
    suite.removePersistentDomain(forName: "wayfile.selftest.contextmenu")
    let config = ContextMenuConfig(defaults: suite)
    checkEqual(config.order, ContextMenuSection.allCases, "default section order")
    config.setShown(.checksum, false)
    config.move(.info, by: -1)
    config.move(.open, by: -1)
    let reloaded = ContextMenuConfig(defaults: suite)
    check(!reloaded.shows(.checksum) && reloaded.shows(.tags), "hidden items persist")
    checkEqual(reloaded.order.suffix(2), [.info, .organize], "section order persists; moving past the start is ignored")
    checkEqual(reloaded.order.first, .open, "first section unchanged")
    reloaded.reset()
    check(reloaded.hidden.isEmpty && reloaded.order == ContextMenuSection.allCases, "reset")

    let image = f.root.appendingPathComponent("pic.png")
    try await Shell.check("/usr/bin/sips", ["-s", "format", "png", "-z", "20", "40", "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns", "--out", image.path])
    check(TypeActions.isImage(image) && !TypeActions.isImage(f.root.appendingPathComponent("a.svg")), "image detection")
    check(TypeActions.isEditableText(URL(fileURLWithPath: "x.swift")) && !TypeActions.isEditableText(image), "editable text detection")
    func size(_ url: URL) async throws -> String {
        let out = try await Shell.check("/usr/bin/sips", ["-g", "pixelWidth", "-g", "pixelHeight", url.path])
        let numbers = out.split(whereSeparator: \.isNewline).compactMap { $0.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } }.suffix(2)
        return numbers.joined(separator: "x")
    }
    checkEqual(try await size(image), "40x20", "fixture size")
    let rotate = OperationProgress()
    _ = try await TypeActions.rotate([image], degrees: 90, progress: rotate)
    checkEqual(try await size(image), "20x40", "rotated in place")
    _ = try UndoRecord.combine(rotate.records)!.revert()
    checkEqual(try await size(image), "40x20", "rotation undone from the Trash")
    let convert = OperationProgress()
    let converted = try await TypeActions.convert([image], to: .jpeg, progress: convert)
    checkEqual(converted.map(\.lastPathComponent), ["pic.jpg"], "converted copy named by format")
    check(FileManager.default.fileExists(atPath: image.path), "original kept")
}

await testAsync("scripts") { f in
    let dir = f.root.appendingPathComponent("Scripts")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func write(_ name: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    let shURL = try write("resize.sh", """
    #!/bin/sh
    # @name Resize for Web
    # @description Makes copies
    # @extensions .JPG, png
    # @count 1+
    # @permissions read, write, bogus
    # @trigger ~/Downloads
    # @schedule 15
    echo "count=$WAYFILE_COUNT dry=$WAYFILE_DRY_RUN folder=$WAYFILE_FOLDER"
    for p in "$@"; do echo "$p"; done
    echo oops >&2
    # @name ignored after code
    """)
    let sh = try Script.load(shURL).unwrap("sh script")
    checkEqual(sh.name, "Resize for Web", "header name")
    checkEqual(sh.extensions, ["jpg", "png"], "extensions normalized")
    checkEqual(sh.permissions, [.read, .write], "unknown permissions dropped")
    check(sh.count == Script.CountRange(min: 1, max: nil) && sh.scheduleMinutes == 15, "count and schedule")
    checkEqual(sh.triggerFolder?.path, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path, "trigger folder expands ~")
    checkEqual(Script.CountRange("2-5"), Script.CountRange(min: 2, max: 5), "count range")
    check(Script.CountRange("0")?.contains(0) == true && Script.CountRange("x") == nil, "count parsing")

    let jpg = f.root.appendingPathComponent("a.jpg"), txt = f.root.appendingPathComponent("b.txt")
    try Data().write(to: jpg); try Data("hello".utf8).write(to: txt)
    check(sh.applies(to: [jpg]) && !sh.applies(to: [txt]) && !sh.applies(to: []) && !sh.applies(to: [f.src]), "applies by extension and count")
    let anyScript = Script(url: dir.appendingPathComponent("x.py"), text: "# @count any")!
    check(anyScript.applies(to: []) && anyScript.applies(to: [txt, f.src]), "no filter applies to files and folders")
    let foldersOnly = Script(url: dir.appendingPathComponent("y.zsh"), text: "# @folders only")!
    check(foldersOnly.applies(to: [f.src]) && !foldersOnly.applies(to: [txt]), "folders only")
    check(Script(url: dir.appendingPathComponent("z.txt"), text: "") == nil, "unknown extension is not a script")

    final class Lines: @unchecked Sendable {
        let lock = NSLock(); var items: [ScriptOutputLine] = []
        func add(_ l: ScriptOutputLine) { lock.withLock { items.append(l) } }
        var text: [String] { lock.withLock { items.map(\.text) } }
        func of(_ s: ScriptOutputLine.Stream) -> [String] { lock.withLock { items.filter { $0.stream == s }.map(\.text) } }
    }
    var lines = Lines()
    let ctx = ScriptContext(selection: [jpg, txt], folder: f.root, otherFolder: nil)
    var result = try await ScriptRunner.run(sh, context: ctx, progress: OperationProgress(), output: lines.add)
    checkEqual(result.status, 0, "shell exit status")
    checkEqual(lines.of(.stdout).first, "count=2 dry=0 folder=\(f.root.path)", "environment variables")
    checkEqual(lines.of(.stderr), ["oops"], "stderr streamed")
    checkEqual(result.outputPaths.map(\.lastPathComponent), ["a.jpg", "b.txt"], "printed existing paths become output")

    let py = try Script.load(try write("upper.py", "import sys, os\n# @name Upper\nfor p in sys.argv[1:]:\n    print(os.path.basename(p).upper())\nsys.exit(3)\n")).unwrap("py")
    lines = Lines()
    result = try await ScriptRunner.run(py, context: ctx, progress: OperationProgress(), output: lines.add)
    check(result.status == 3 && lines.of(.stdout) == ["A.JPG", "B.TXT"], "python args and exit status (got \(lines.text))")

    let osa = try Script.load(try write("hello.applescript", "-- @name Hello\non run argv\n\treturn \"got \" & (count of argv)\nend run\n")).unwrap("osa")
    lines = Lines()
    result = try await ScriptRunner.run(osa, context: ctx, progress: OperationProgress(), output: lines.add)
    checkEqual(lines.of(.stdout), ["got 2"], "applescript argv")

    let sleeper = try Script.load(try write("sleep.sh", "sleep 30\n")).unwrap("sleep")
    let task = Task { try await ScriptRunner.run(sleeper, context: ctx, progress: OperationProgress(), output: { _ in }) }
    try await Task.sleep(nanoseconds: 300_000_000)
    let started = Date()
    task.cancel()
    let cancelled = (try? await task.value) == nil
    check(cancelled && Date().timeIntervalSince(started) < 5, "cancelling terminates the process")

    // JavaScript API
    let work = f.root.appendingPathComponent("js")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    for name in ["One.TXT", "two.txt", "pic.png"] { try Data(name.utf8).write(to: work.appendingPathComponent(name)) }
    let organize = try Script.load(try write("organize.js", """
    // @name Organize
    // @permissions read, write, delete
    const out = []
    for (const path of wayfile.list(wayfile.folder)) {
      if (wayfile.isDirectory(path)) continue
      const name = path.split('/').pop()
      if (name.endsWith('.png')) { out.push(wayfile.move(path, wayfile.folder + '/Images')) }
      else { out.push(wayfile.rename(path, name.toLowerCase().replace('.txt', '.md'))) }
    }
    wayfile.writeText('notes.txt', 'made by ' + wayfile.selection.length)
    wayfile.tag(out[0], 'Done')
    console.log('dry', wayfile.dryRun)
    out
    """)).unwrap("js")
    lines = Lines()
    var jsCtx = ScriptContext(selection: [jpg], folder: work, otherFolder: nil, dryRun: true)
    result = try await ScriptRunner.run(organize, context: jsCtx, progress: OperationProgress(), output: lines.add)
    check(result.status == 0 && lines.of(.info).count == 5 && lines.of(.stdout) == ["dry true"], "dry run describes changes (got \(lines.text))")
    checkEqual(try FileManager.default.contentsOfDirectory(atPath: work.path).sorted(), ["One.TXT", "pic.png", "two.txt"], "dry run changes nothing")

    lines = Lines()
    jsCtx.dryRun = false
    let progress = OperationProgress()
    result = try await ScriptRunner.run(organize, context: jsCtx, progress: progress, output: lines.add)
    checkEqual(result.status, 0, "js ran (\(lines.text))")
    checkEqual(try FileManager.default.contentsOfDirectory(atPath: work.path).sorted(), ["Images", "notes.txt", "one.md", "two.md"], "js changed files")
    checkEqual(result.outputPaths.map(\.lastPathComponent).sorted(), ["one.md", "pic.png", "two.md"], "returned array becomes output paths")
    checkEqual(try String(contentsOf: work.appendingPathComponent("notes.txt"), encoding: .utf8), "made by 1", "writeText with relative path")
    check(TagIO.read(result.outputPaths.first { $0.lastPathComponent == "one.md" }!).contains { $0.name == "Done" }, "tag applied")
    _ = try UndoRecord.combine(progress.records)!.revert()
    let afterUndo = try FileManager.default.contentsOfDirectory(atPath: work.path).filter { $0 != "Images" }.sorted()
    checkEqual(afterUndo, ["One.TXT", "pic.png", "two.txt"], "js changes undone")

    let sneaky = try Script.load(try write("sneaky.js", "// @permissions read\nwayfile.trash(wayfile.selection[0])\n")).unwrap("sneaky")
    lines = Lines()
    result = try await ScriptRunner.run(sneaky, context: ScriptContext(selection: [txt], folder: f.root), progress: OperationProgress(), output: lines.add)
    check(result.status == 1 && lines.of(.stderr).first?.contains("delete") == true && FileManager.default.fileExists(atPath: txt.path), "undeclared permission blocked (got \(lines.text))")
    lines = Lines()
    result = try await ScriptRunner.run(try Script.load(try write("bad.js", "syntax error here(")).unwrap("bad"), context: ctx, progress: OperationProgress(), output: lines.add)
    check(result.status == 1 && !lines.of(.stderr).isEmpty, "js syntax error reported")

    // Pipeline: JS returns paths, the shell step receives them.
    _ = try write("pick.js", "// @name Pick\nwayfile.selection.filter(p => p.endsWith('.txt'))\n")
    _ = try write("count.sh", "echo \"got $#: $(basename \"$1\")\"\n")
    let pipe = try Script.load(try write("flow.pipeline", "# @name Flow\npick.js\n\ncount.sh\n")).unwrap("pipeline")
    checkEqual(ScriptRunner.pipelineSteps("# c\npick.js\n\n  count.sh \n"), ["pick.js", "count.sh"], "pipeline steps parsed")
    lines = Lines()
    result = try await ScriptRunner.run(pipe, context: ctx, progress: OperationProgress(), output: lines.add)
    check(result.status == 0 && lines.of(.stdout).contains("got 1: b.txt"), "pipeline passes paths along (got \(lines.text))")
    let broken = try Script.load(try write("broken.pipeline", "missing.sh\n")).unwrap("broken")
    await checkThrowsAsync("missing pipeline step") { _ = try await ScriptRunner.run(broken, context: ctx, progress: OperationProgress(), output: { _ in }) }

    // Library
    let created = try ScriptLibrary.create(named: "New Script", language: .zsh, in: dir)
    let made = try Script.load(created).unwrap("skeleton")
    check(made.name == "New Script" && made.permissions == [.read] && made.count.min == 1, "skeleton header parses")
    check(FileManager.default.isExecutableFile(atPath: created.path), "shell skeleton executable")
    for language in Script.Language.allCases {
        let url = try ScriptLibrary.create(named: "S", language: language, in: dir)
        check(Script.load(url)?.name == "S", "\(language) skeleton parses")
    }
    check(ScriptLibrary.scripts(in: dir).count >= 10, "library lists scripts")
}

await testAsync("script examples") { f in
    for example in ScriptExamples.all {
        let script = example.script
        check(script != nil && !(script?.summary.isEmpty ?? true) && script?.name != example.fileName, "\(example.fileName) parses with name and description")
    }
    let dir = f.root.appendingPathComponent("lib")
    for example in ScriptExamples.all where example.fileName.hasSuffix(".js") {
        checkEqual(JSScriptHost.checkSyntax(example.text)?.message, nil, "example \(example.fileName) parses")
    }
    ScriptExamples.all.forEach { _ = try? ScriptExamples.install($0, in: dir) }
    check(ScriptExamples.all.allSatisfy { ScriptExamples.isInstalled($0, in: dir) }, "examples installed")
    check(FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent("Resize for Web.zsh").path), "shell examples executable")
    let pipeline = try String(contentsOf: dir.appendingPathComponent("Web Images.pipeline"), encoding: .utf8)
    check(ScriptRunner.pipelineSteps(pipeline).allSatisfy { Script.load(dir.appendingPathComponent($0)) != nil }, "pipeline example steps exist")

    let mess = f.root.appendingPathComponent("mess")
    try FileManager.default.createDirectory(at: mess, withIntermediateDirectories: true)
    for name in ["a.jpg", "b.pdf", "c.zip", "d.unknown"] { try Data().write(to: mess.appendingPathComponent(name)) }
    final class Lines: @unchecked Sendable { let lock = NSLock(); var items: [String] = []; func add(_ l: ScriptOutputLine) { lock.withLock { items.append(l.text) } } }
    let lines = Lines()
    let sort = try Script.load(dir.appendingPathComponent("Sort by Kind.js")).unwrap("sort")
    let result = try await ScriptRunner.run(sort, context: ScriptContext(selection: [], folder: mess, dryRun: true), progress: OperationProgress(), output: lines.add)
    check(result.status == 0 && lines.items.last == "Would move 3 files", "sort example dry run (got \(lines.items))")
    let zip = try Script.load(dir.appendingPathComponent("Dated Zip.zsh")).unwrap("zip")
    let zipLines = Lines()
    let zipped = try await ScriptRunner.run(zip, context: ScriptContext(selection: [mess.appendingPathComponent("a.jpg")], folder: mess), progress: OperationProgress(), output: zipLines.add)
    check(zipped.outputPaths.count == 1 && zipped.outputPaths[0].pathExtension == "zip", "zip example creates archive (got \(zipLines.items))")
}

test("rules") { f in
    let inbox = f.root.appendingPathComponent("inbox")
    let fm = FileManager.default
    try fm.createDirectory(at: inbox.appendingPathComponent("sub"), withIntermediateDirectories: true)
    let old = Date().addingTimeInterval(-40 * 86_400)
    for name in ["report.PDF", "photo.jpg", "notes.txt", "setup.dmg", "big.mov", "file.crdownload"] {
        try Data(count: name == "big.mov" ? 5000 : 10).write(to: inbox.appendingPathComponent(name))
    }
    try fm.setAttributes([.modificationDate: old], ofItemAtPath: inbox.appendingPathComponent("setup.dmg").path)

    var rule = Rule(folder: inbox)
    rule.pattern = "*.pdf"
    checkEqual(RuleEngine.matches(rule).map(\.lastPathComponent), ["report.PDF"], "glob, case-insensitive, folders and partial downloads skipped")
    rule.pattern = ""
    rule.kinds = [.image, .video]
    checkEqual(RuleEngine.matches(rule).map(\.lastPathComponent), ["big.mov", "photo.jpg"], "kind filter")
    rule.minSize = 1000
    checkEqual(RuleEngine.matches(rule).map(\.lastPathComponent), ["big.mov"], "size filter")
    var age = Rule(folder: inbox)
    age.olderThanDays = 30
    check(age.isAgeBased && RuleEngine.matches(age).map(\.lastPathComponent) == ["setup.dmg"], "age filter")
    rule.pattern = "^re"; rule.patternMode = .regex; rule.kinds = []; rule.minSize = nil
    checkEqual(RuleEngine.matches(rule).map(\.lastPathComponent), ["report.PDF"], "regex pattern")

    // Simulator + execution
    var sort = Rule(folder: inbox)
    sort.action = .sortByKind
    let plan = RuleEngine.plan(sort, files: RuleEngine.matches(sort))
    let dests = Dictionary(uniqueKeysWithValues: plan.map { ($0.url.lastPathComponent, $0.destination!.deletingLastPathComponent().lastPathComponent) })
    checkEqual(dests, ["report.PDF": "Documents", "photo.jpg": "Images", "notes.txt": "Text & Code", "setup.dmg": "Archives", "big.mov": "Videos"], "sort plan by kind")
    check(plan.allSatisfy { fm.fileExists(atPath: $0.url.path) } && !fm.fileExists(atPath: inbox.appendingPathComponent("Images").path), "plan changes nothing")
    let progress = OperationProgress()
    let moved = try RuleEngine.execute(plan, progress: progress)
    check(moved.count == 5 && fm.fileExists(atPath: inbox.appendingPathComponent("Images/photo.jpg").path), "sort executed")
    _ = try UndoRecord.combine(progress.records)!.revert()
    let back = try fm.contentsOfDirectory(atPath: inbox.path).sorted()
    checkEqual(back, ["big.mov", "file.crdownload", "notes.txt", "photo.jpg", "report.PDF", "setup.dmg", "sub"], "sort undone, created folders removed")

    var dated = Rule(folder: inbox)
    dated.action = .sortByDate
    let comps = Calendar.current.dateComponents([.year, .month], from: old)
    checkEqual(RuleEngine.destination(for: dated, inbox.appendingPathComponent("setup.dmg"))?.deletingLastPathComponent().path,
               inbox.appendingPathComponent("\(comps.year!)/\(String(format: "%02d", comps.month!))").path, "date folders")

    var tagRule = Rule(folder: inbox)
    tagRule.action = .tag("Inbox")
    let tagProgress = OperationProgress()
    _ = try RuleEngine.execute(RuleEngine.plan(tagRule, files: [inbox.appendingPathComponent("notes.txt")]), progress: tagProgress)
    check(TagIO.read(inbox.appendingPathComponent("notes.txt")).map(\.name) == ["Inbox"], "tag action")
    _ = try UndoRecord.combine(tagProgress.records)!.revert()
    check(TagIO.read(inbox.appendingPathComponent("notes.txt")).isEmpty, "tag undone")

    let encoded = try JSONEncoder().encode([dated, tagRule, rule])
    checkEqual(try JSONDecoder().decode([Rule].self, from: encoded), [dated, tagRule, rule], "rules round-trip JSON")
    check(rule.summary.contains("inbox") && tagRule.summary.hasSuffix("Tag “Inbox”"), "summary")
}

test("organize suggestions") { f in
    let messy = f.root.appendingPathComponent("messy")
    let fm = FileManager.default
    try fm.createDirectory(at: messy, withIntermediateDirectories: true)
    var names = (1...5).map { "Screenshot 2026-01-0\($0).png" } + (1...6).map { "img\($0).jpg" } + (1...4).map { "doc\($0).pdf" }
    names += ["Installer.dmg", "random.xyz", "a.txt"]
    for name in names { try Data().write(to: messy.appendingPathComponent(name)) }
    try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 86_400)], ofItemAtPath: messy.appendingPathComponent("Installer.dmg").path)
    let suggestions = OrganizeSuggestions.suggest(for: messy)
    checkEqual(suggestions.map(\.id), ["screenshots", "installers", "kind-Images", "kind-Documents"], "suggestions in order")
    checkEqual(suggestions.first { $0.id == "kind-Images" }?.files.count, 6, "screenshots not double-counted as images")
    let progress = OperationProgress()
    for suggestion in suggestions where suggestion.kind != .trash {
        _ = try OrganizeSuggestions.apply(suggestion, in: messy, progress: progress)
    }
    check(fm.fileExists(atPath: messy.appendingPathComponent("Screenshots/Screenshot 2026-01-01.png").path)
          && fm.fileExists(atPath: messy.appendingPathComponent("Documents/doc1.pdf").path), "suggestions applied")
    _ = try UndoRecord.combine(progress.records)!.revert()
    checkEqual(try fm.contentsOfDirectory(atPath: messy.path).count, names.count, "suggestions undone")
    check(OrganizeSuggestions.suggest(for: f.src).allSatisfy { $0.id != "kind-Images" }, "tidy folder gets no kind suggestions")
}

test("dev tools") { f in
    let old = "a\nb\nc\nd\ne\n"
    let new = "a\nB\nc\ne\nf\n"
    let rows = TextDiff.rows(old, new)
    checkEqual(rows.map(\.kind), [.same, .changed, .same, .removed, .same, .added], "diff rows")
    checkEqual(rows[1].left?.text, "b", "changed left"); checkEqual(rows[1].right?.text, "B", "changed right")
    checkEqual(rows[5].right?.number, 5, "added line number")
    checkEqual(TextDiff.stats(rows), TextDiff.Stats(added: 1, removed: 1, changed: 1), "diff stats")
    check(TextDiff.stats(TextDiff.rows("x\r\ny", "x\ny\n")).isIdentical, "CRLF and trailing newline ignored")
    check(TextDiff.stats(TextDiff.rows("if  x {", "if x {", ignoreWhitespace: true)).isIdentical, "ignore whitespace")
    let long = (1...30).map(String.init).joined(separator: "\n")
    let edited = long.replacingOccurrences(of: "\n15\n", with: "\nfifteen\n")
    let hunks = TextDiff.hunks(TextDiff.rows(long, edited))
    checkEqual(hunks.count, 9, "hunk: fold + 3 + change + 3 + fold")
    if case .fold(_, let count) = hunks.first { checkEqual(count, 11, "leading fold") } else { check(false, "leading fold") }
    checkEqual(TextDiff.hunks(TextDiff.rows("a", "a")).count, 1, "identical folds entirely")

    let proj = f.root.appendingPathComponent("proj")
    try FileManager.default.createDirectory(at: proj.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
    try #"let package = Package(\n    name: "Wayfile",\n)"#.write(to: proj.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try #"{"name":"web","version":"1.2.0","scripts":{"dev":"vite","build":"vite build"}}"#.write(to: proj.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    try "".write(to: proj.appendingPathComponent("pnpm-lock.yaml"), atomically: true, encoding: .utf8)
    try "[package]\nname = \"crab\"\nversion = \"0.3.1\"\n[dependencies]\nname = \"no\"\n".write(to: proj.appendingPathComponent("Cargo.toml"), atomically: true, encoding: .utf8)
    try "module example.com/tool\n\ngo 1.22\n".write(to: proj.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
    try "CC := cc\n.PHONY: build\nbuild test: deps\n\tcc\n%.o: %.c\n\tcc\ninstall:\n\tcp\n".write(to: proj.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
    try "FROM swift".write(to: proj.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
    let found = ProjectDetector.detect(in: proj)
    checkEqual(found.map(\.kind), [.swiftPackage, .xcode, .node, .rust, .go, .docker, .make], "project kinds")
    let byKind = Dictionary(uniqueKeysWithValues: found.map { ($0.kind, $0) })
    checkEqual(byKind[.swiftPackage]?.name, "Wayfile", "swift package name")
    checkEqual(byKind[.node]?.commands.map(\.command), ["pnpm install", "pnpm build", "pnpm dev"], "node runner from lockfile + scripts")
    check(byKind[.node]?.version == "1.2.0" && byKind[.rust]?.name == "crab" && byKind[.rust]?.version == "0.3.1", "versions and toml")
    checkEqual(byKind[.go]?.name, "example.com/tool", "go module")
    checkEqual(byKind[.make]?.commands.map(\.title), ["build", "test", "install"], "make targets (no variables, patterns, specials)")
    check(ProjectDetector.detect(in: f.src).isEmpty, "plain folder has no project")

    checkEqual(DevLinks.editorURI(URL(fileURLWithPath: "/Users/me/my app/x.swift")), "vscode://file/Users/me/my%20app/x.swift", "vscode uri")
    checkEqual(DevLinks.webURL(remote: "git@github.com:me/repo.git", branch: "main", relativePath: "Sources/a b.swift"),
               "https://github.com/me/repo/blob/main/Sources/a%20b.swift", "github ssh remote")
    checkEqual(DevLinks.webURL(remote: "https://user:tok@gitlab.com/g/p.git", branch: "dev", relativePath: "src", isDirectory: true),
               "https://gitlab.com/g/p/-/tree/dev/src", "gitlab https remote strips credentials")
    checkEqual(DevLinks.webURL(remote: "ssh://git@bitbucket.org/t/r.git", branch: "main", relativePath: "x"), "https://bitbucket.org/t/r/src/main/x", "bitbucket")
    check(DevLinks.webURL(remote: "/local/path", branch: "main", relativePath: "x") == nil, "local remote has no web url")
}

await testAsync("git changes") { f in
    let repo = f.root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    func git(_ args: String...) async throws { try await Shell.check("/usr/bin/git", ["-C", repo.path, "-c", "user.name=T", "-c", "user.email=t@t"] + args) }
    try await git("init", "-q", "-b", "main")
    try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try await Git.stage(["a.txt"], in: repo)
    var changes = try await Git.changes(in: repo)
    check(changes.count == 1 && changes[0].hasStaged && !changes[0].hasUnstaged, "staged new file")
    try await Git.unstage(["a.txt"], in: repo)
    changes = try await Git.changes(in: repo)
    check(changes.first?.isUntracked == true, "unstage before first commit")
    try await Git.stage(["a.txt"], in: repo)
    try await git("commit", "-q", "-m", "first")
    try "one\ntwo\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try "new\n".write(to: repo.appendingPathComponent("b file.txt"), atomically: true, encoding: .utf8)
    changes = try await Git.changes(in: repo)
    checkEqual(changes.map(\.path), ["a.txt", "b file.txt"], "changes listed (spaces kept)")
    check(changes[0].hasUnstaged && !changes[0].hasStaged && changes[0].status == .modified, "modified unstaged")
    checkEqual(await Git.show("a.txt", at: "HEAD", in: repo), "one\n", "HEAD version")
    try await Git.stage(["a.txt", "b file.txt"], in: repo)
    checkEqual(await Git.show("a.txt", at: "", in: repo), "one\ntwo\n", "index version")
    let absent = await Git.show("b file.txt", at: "HEAD", in: repo)
    check(absent == nil, "absent at HEAD")
    try await Shell.check("/usr/bin/git", ["-C", repo.path, "-c", "user.name=T", "-c", "user.email=t@t", "commit", "-q", "-m", "second\u{1f}x"])
    try await git("mv", "a.txt", "renamed.txt")
    try await git("commit", "-q", "-m", "rename")
    let history = try await Git.history(of: "renamed.txt", in: repo)
    checkEqual(history.map(\.subject), ["rename", "second\u{1f}x", "first"], "history follows renames")
    checkEqual(history.last?.path, "a.txt", "old path in history")
    checkEqual(try await Git.log(in: repo).count, 3, "repo log")
    checkEqual(try await Git.filesChanged(in: history[0].hash, root: repo), ["renamed.txt"], "files in commit (renames by new name)")

    try "x\n".write(to: repo.appendingPathComponent("renamed.txt"), atomically: true, encoding: .utf8)
    try await Git.discard(["renamed.txt"], in: repo)
    checkEqual(try String(contentsOf: repo.appendingPathComponent("renamed.txt"), encoding: .utf8), "one\ntwo\n", "discard restores")
    try await git("mv", "renamed.txt", "again.txt")
    changes = try await Git.changes(in: repo)
    check(changes.count == 1 && changes[0].path == "again.txt" && changes[0].originalPath == "renamed.txt", "rename parsed with original path")
    try await Git.commit(message: "via app", in: repo)
    checkEqual(try await Git.log(in: repo).first?.subject, "via app", "commit")
    let remote = await Git.remoteURL(in: repo)
    check(remote == nil, "no remote")
}

test("docker parsing") { _ in
    let ps = #"""
    {"ID":"e960ffac4745","Image":"sail-8.5/app","Labels":"com.docker.compose.depends_on=mysql:service_started:false,redis:service_started:false,com.docker.compose.project.working_dir=/Users/me/www/cms,com.docker.compose.project=cms,com.docker.compose.service=laravel.test,desktop.docker.io/binds/0/Source=/Users/me/www/cms,maintainer=Taylor Otwell","Names":"cms-laravel.test-1","Ports":"0.0.0.0:5200->5200/tcp, [::]:5200->5200/tcp, 0.0.0.0:8092->80/tcp","RunningFor":"4 days ago","Size":"111kB","State":"running","Status":"Up 8 hours"}
    {"ID":"aaa","Image":"redis","Labels":"","Names":"loose","Ports":"","RunningFor":"1 day ago","Size":"0B","State":"exited","Status":"Exited (0)"}
    """#
    let containers = Docker.parseContainers(ps)
    checkEqual(containers.map(\.name), ["cms-laravel.test-1", "loose"], "containers, compose projects first")
    let c = containers[0]
    check(c.isRunning && !containers[1].isRunning, "state")
    checkEqual(c.labels["com.docker.compose.depends_on"], "mysql:service_started:false,redis:service_started:false", "label values keep commas")
    checkEqual(c.labels["maintainer"], "Taylor Otwell", "plain label")
    check(c.composeProject == "cms" && c.composeService == "laravel.test" && c.projectFolder?.path == "/Users/me/www/cms", "compose info")
    checkEqual(c.bindSources.map(\.path), ["/Users/me/www/cms"], "bind mounts")
    checkEqual(c.localURLs.map(\.absoluteString), ["http://localhost:5200", "http://localhost:8092"], "published ports, deduplicated")
    let images = Docker.parseImages(#"{"Containers":"2","CreatedSince":"10 days ago","ID":"6ea9","Repository":"mysql","Size":"1.12GB","Tag":"8.4"}"#)
    check(images.first?.reference == "mysql:8.4" && images.first?.containers == 2, "images")
    let volumes = Docker.parseVolumes(#"{"Driver":"local","Labels":"com.docker.compose.project=shop","Mountpoint":"/var/lib/docker/volumes/x/_data","Name":"x"}"#)
    check(volumes.first?.composeProject == "shop" && volumes.first?.driver == "local", "volumes")
    check(Docker.parseContainers("not json\n").isEmpty, "garbage ignored")
}

await testAsync("servers") { _ in
    checkEqual(ServerAddress.normalize("nas.local")?.absoluteString, "smb://nas.local", "default scheme smb")
    checkEqual(ServerAddress.normalize("\\\\NAS\\Media")?.absoluteString, "smb://NAS/Media", "UNC path")
    checkEqual(ServerAddress.normalize(" https://dav.example.com/files ")?.absoluteString, "https://dav.example.com/files", "webdav kept")
    check(ServerAddress.normalize("") == nil && ServerAddress.normalize("gopher://x") == nil && ServerAddress.normalize("smb://") == nil, "invalid addresses")
    let url = URL(string: "smb://me:secret@nas.local/Media")!
    checkEqual(ServerAddress.stripCredentials(url).absoluteString, "smb://nas.local/Media", "credentials stripped")
    checkEqual(ServerAddress.displayName(URL(string: "smb://My%20Mac._smb._tcp.local")!), "My Mac", "bonjour display name")
    checkEqual(ServerAddress.displayName(url), "nas.local/Media", "display name with share")
    check(ServerAddress.kind(URL(string: "https://x")!) == "WebDAV" && ServerAddress.kind(url) == "SMB", "kinds")
    let found = ServerStore.DiscoveredServer(name: "My Mac", type: "_smb._tcp")
    checkEqual(found.url?.absoluteString, "smb://My%20Mac._smb._tcp.local", "discovered url")

    let host = "wayfile-selftest-\(UUID().uuidString).invalid"
    try Keychain.save(password: "s3cr3t", server: host, account: "me")
    checkEqual(Keychain.password(server: host, account: "me"), "s3cr3t", "keychain round-trip")
    try Keychain.save(password: "new", server: host, account: "me")
    checkEqual(Keychain.password(server: host, account: "me"), "new", "keychain replace")
    Keychain.delete(server: host, account: "me")
    check(Keychain.password(server: host, account: "me") == nil, "keychain delete")

    let suite = UserDefaults(suiteName: "wayfile.selftest.servers")!
    suite.removePersistentDomain(forName: "wayfile.selftest.servers")
    let store = await ServerStore(defaults: suite)
    await store.remember(url: url, username: "me", password: nil, savePassword: false)
    await store.remember(url: URL(string: "afp://old.local")!, username: nil, password: nil, savePassword: false)
    await store.remember(url: URL(string: "smb://nas.local/Media")!, username: "me", password: nil, savePassword: false)
    let reloaded = await ServerStore(defaults: suite)
    let names = await reloaded.servers.map(\.name)
    checkEqual(names, ["nas.local/Media", "old.local"], "servers deduplicated, most recent first, persisted")
    check(Mounter.existingMount(for: URL(string: "smb://nowhere.invalid/x")!) == nil, "no existing mount")
}

test("s3 signing") { _ in
    // Examples from the AWS Signature Version 4 documentation for S3.
    let account = S3Account(name: "AWS", endpoint: URL(string: "https://s3.amazonaws.com")!, region: "us-east-1",
                            accessKey: "AKIAIOSFODNN7EXAMPLE", pathStyle: false)
    let date = ISO8601DateFormatter().date(from: "2013-05-24T00:00:00Z")!
    let secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    func signed(_ path: String, query: [(String, String)], headers: [String: String] = [:]) -> URLRequest {
        var components = URLComponents(string: "https://examplebucket.s3.amazonaws.com")!
        components.percentEncodedPath = path
        var request = URLRequest(url: components.url!)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        SigV4.sign(&request, path: path, query: query, payloadHash: SigV4.emptyHash, accessKey: account.accessKey,
                   secret: secret, region: "us-east-1", date: date)
        return request
    }
    let get = signed("/test.txt", query: [], headers: ["Range": "bytes=0-9"])
    checkEqual(get.value(forHTTPHeaderField: "Authorization"),
               "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41",
               "AWS example: GET object")
    let list = signed("/", query: [("max-keys", "2"), ("prefix", "J")])
    check(list.value(forHTTPHeaderField: "Authorization")?.hasSuffix("Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7") == true,
          "AWS example: list objects (got \(list.value(forHTTPHeaderField: "Authorization") ?? ""))")
    let lifecycle = signed("/", query: [("lifecycle", "")])
    check(lifecycle.value(forHTTPHeaderField: "Authorization")?.hasSuffix("Signature=fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543") == true,
          "AWS example: bucket lifecycle")

    checkEqual(SigV4.encode("a b/č+~", keepSlash: true), "a%20b/%C4%8D%2B~", "path encoding")
    let client = S3Client(account: account, secret: secret)
    checkEqual(client.request("GET", bucket: "photos", key: "2026/My Trip.jpg").url?.absoluteString,
               "https://photos.s3.amazonaws.com/2026/My%20Trip.jpg", "virtual-hosted URL")
    var minio = account
    minio.endpoint = URL(string: "http://localhost:9000")!
    minio.pathStyle = true
    let pathReq = S3Client(account: minio, secret: secret).request("GET", bucket: "data", query: [("list-type", "2"), ("prefix", "a b/")])
    checkEqual(pathReq.url?.absoluteString, "http://localhost:9000/data/?list-type=2&prefix=a%20b%2F", "path-style URL with query")
    checkEqual(pathReq.value(forHTTPHeaderField: "Host"), "localhost:9000", "host keeps custom port")
    checkEqual(S3Client(account: account, secret: secret).request("GET", bucket: nil).url?.absoluteString, "https://s3.amazonaws.com/", "service root")

    let xml = Data(#"""
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult><Name>b</Name><Prefix>docs/</Prefix><IsTruncated>false</IsTruncated>
    <Contents><Key>docs/</Key><Size>0</Size></Contents>
    <Contents><Key>docs/a.pdf</Key><LastModified>2026-01-02T03:04:05.000Z</LastModified><Size>1234</Size></Contents>
    <CommonPrefixes><Prefix>docs/old/</Prefix></CommonPrefixes></ListBucketResult>
    """#.utf8)
    let parsed = S3XML.parse(xml)
    check(parsed.prefixes == ["docs/old/"] && parsed.contents.count == 2 && parsed.contents[1].size == 1234 && parsed.contents[1].modified != nil, "listing parsed")
    checkEqual(S3Object(key: "docs/old/", size: 0, modified: nil, isPrefix: true).name, "old", "prefix name")
    let error = S3XML.parse(Data("<Error><Code>AccessDenied</Code><Message>Nope</Message></Error>".utf8))
    checkEqual(S3Error(status: 403, code: error.first("Code"), message: error.first("Message")).errorDescription, "AccessDenied: Nope (HTTP 403)", "error parsed")
    checkEqual(S3XML.parse(Data("<ListAllMyBucketsResult><Buckets><Bucket><Name>a</Name></Bucket><Bucket><Name>b</Name></Bucket></Buckets></ListAllMyBucketsResult>".utf8)).all("Name"), ["a", "b"], "buckets parsed")
}

if let mock = ProcessInfo.processInfo.environment["S3_MOCK_URL"].flatMap(URL.init(string:)) {
    await testAsync("s3 round trip (mock server)") { f in
        let account = S3Account(name: "Mock", endpoint: mock, region: "us-east-1", accessKey: "AK", pathStyle: true)
        let client = S3Client(account: account, secret: "SECRET")
        checkEqual(try await client.buckets(), ["data"], "buckets")
        let file = f.root.appendingPathComponent("hello world.txt")
        try "hi there".write(to: file, atomically: true, encoding: .utf8)
        try await client.upload(file, bucket: "data", key: "docs/hello world.txt")
        try await client.createFolder(bucket: "data", key: "docs/empty")
        try await client.upload(file, bucket: "data", key: "top.txt")
        let root = try await client.list(bucket: "data", prefix: "")
        checkEqual(root.map(\.key), ["docs/", "top.txt"], "root listing: folder + file")
        let docs = try await client.list(bucket: "data", prefix: "docs/")
        checkEqual(docs.map(\.name), ["empty", "hello world.txt"], "folder listing with spaces")
        let target = f.root.appendingPathComponent("down.txt")
        try await client.download(bucket: "data", key: "docs/hello world.txt", to: target)
        checkEqual(try String(contentsOf: target, encoding: .utf8), "hi there", "download")
        do {
            try await client.download(bucket: "data", key: "missing", to: target)
            check(false, "missing key throws")
        } catch let error as S3Error {
            checkEqual(error.code, "NoSuchKey", "S3 error code surfaced")
        }
        try await client.deletePrefix(bucket: "data", prefix: "docs/")
        checkEqual(try await client.list(bucket: "data", prefix: "").map(\.key), ["top.txt"], "folder deleted recursively")
    }
}

await testAsync("disk tools") { f in
    // Treemap: areas proportional, inside the rect, no overlaps.
    let rect = CGRect(x: 0, y: 0, width: 600, height: 400)
    let values: [Double] = [6, 6, 4, 3, 2, 2, 1]
    let rects = DiskUsage.treemap(values, in: rect)
    let total = values.reduce(0, +)
    check(zip(values, rects).allSatisfy { abs(Double($1.width * $1.height) - $0 / total * 240_000) < 1 }, "treemap areas proportional")
    check(rects.allSatisfy { rect.insetBy(dx: -0.01, dy: -0.01).contains($0) }, "treemap inside bounds")
    check(!rects.indices.contains { i in rects.indices.contains { j in i < j && rects[i].insetBy(dx: 0.5, dy: 0.5).intersects(rects[j]) } }, "treemap has no overlaps")
    let aspect = rects.map { max($0.width / $0.height, $0.height / $0.width) }.max() ?? 0
    check(aspect < 4, "squarified (worst aspect \(aspect))")
    check(DiskUsage.treemap([], in: rect).isEmpty && DiskUsage.treemap([0, 0], in: rect).allSatisfy { $0 == .zero }, "treemap edge cases")

    let tree = f.root.appendingPathComponent("usage")
    try FileManager.default.createDirectory(at: tree.appendingPathComponent("big/deeper"), withIntermediateDirectories: true)
    try Data(count: 400_000).write(to: tree.appendingPathComponent("big/deeper/blob.bin"))
    try Data(count: 50_000).write(to: tree.appendingPathComponent("small.bin"))
    for i in 0..<(DiskUsage.keepPerFolder + 5) { try Data(count: 10).write(to: tree.appendingPathComponent("big/f\(i).txt")) }
    try FileManager.default.createSymbolicLink(at: tree.appendingPathComponent("loop"), withDestinationURL: tree)
    let node = DiskUsage.scan(tree)
    check(node.size >= 450_000 && node.children.first?.name == "big", "scan sizes, biggest first (\(node.size))")
    let big = node.children[0]
    checkEqual(big.children.count, DiskUsage.keepPerFolder + 1, "small items merged")
    check(big.children.last?.isAggregate == true && big.children.last?.fileCount ?? 0 > 0, "aggregate node")
    checkEqual(node.fileCount, DiskUsage.keepPerFolder + 5 + 3, "file count includes merged and symlink (not followed)")
    let blob = big.children.first { $0.name == "deeper" }!
    let before = node.size
    big.remove(blob)
    check(node.size == before - blob.size && blob.size >= 400_000, "remove updates totals up the tree")

    // Archives
    let listing = """
    drwxr-xr-x  0 me     staff       0 Jan  2 10:00 project/
    -rw-r--r--  0 me     staff    1234 Jan  2 10:00 project/a b.txt
    -rw-r--r--  0 me     staff      10 Feb 13  2024 project/src/main.swift
    lrwxr-xr-x  0 me     staff       0 Jan  2 10:00 project/link -> a b.txt
    -rw-r--r--  0 me     staff       5 Jan  2 10:00 __MACOSX/._x
    """
    let entries = ArchiveIndex.parse(listing)
    checkEqual(entries.map(\.path), ["project/", "project/a b.txt", "project/link", "project/src/", "project/src/main.swift"], "archive entries with implied folders")
    checkEqual(ArchiveIndex.children(of: "project/", in: entries).map(\.name), ["src", "a b.txt", "link"], "children, folders first")
    checkEqual(ArchiveIndex.size(of: "project/", in: entries), 1244, "folder size")
    let zipSource = f.root.appendingPathComponent("zipme")
    try FileManager.default.createDirectory(at: zipSource.appendingPathComponent("inner"), withIntermediateDirectories: true)
    try "x".write(to: zipSource.appendingPathComponent("inner/one.txt"), atomically: true, encoding: .utf8)
    try "y".write(to: zipSource.appendingPathComponent("two words.txt"), atomically: true, encoding: .utf8)
    let zip = f.root.appendingPathComponent("z.zip")
    try await Shell.check("/usr/bin/ditto", ["-c", "-k", "--keepParent", zipSource.path, zip.path])
    let real = try await ArchiveIndex.entries(of: zip)
    check(real.contains { $0.path == "zipme/inner/one.txt" } && real.contains { $0.path == "zipme/inner/" }, "real zip listed (\(real.map(\.path)))")
    let out = f.root.appendingPathComponent("extracted")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let picked = real.filter { $0.path == "zipme/inner/" || $0.path == "zipme/two words.txt" }
    let made = try await ArchiveIndex.extract(zip, entries: picked, base: "zipme/", to: out)
    checkEqual(made.map(\.lastPathComponent).sorted(), ["inner", "two words.txt"], "extract selected entries relative to the browsed folder")
    check(FileManager.default.fileExists(atPath: out.appendingPathComponent("inner/one.txt").path), "folder extracted with contents")

    // Compression
    for format in CompressOptions.Format.allCases {
        var options = CompressOptions()
        options.format = format
        options.name = "out-\(format.rawValue)"
        options.level = 9
        let archive = try await options.compress([zipSource])
        let names = try await ArchiveIndex.entries(of: archive).map(\.path)
        check(names.contains("zipme/inner/one.txt"), "\(format.title) archive round-trips")
    }
    var locked = CompressOptions()
    locked.password = "pw"
    locked.name = "secret"
    let secret = try await locked.compress([zipSource.appendingPathComponent("two words.txt")])
    let wrong = await Shell.run("/usr/bin/unzip", ["-P", "nope", "-p", secret.path])
    let right = await Shell.run("/usr/bin/unzip", ["-P", "pw", "-p", secret.path])
    check(wrong.status != 0 && right.stdout == "y", "zip password")

    // Links
    let target = zipSource.appendingPathComponent("two words.txt")
    let link = try Links.makeSymlink(to: target)
    let info = Links.info(link)
    check(info.isSymlink && !info.isBroken && info.symlinkTarget == "two words.txt", "relative symlink")
    let hard = try Links.makeHardLink(to: target)
    checkEqual(hard.lastPathComponent, "two words hardlink.txt", "hard link name")
    checkEqual(Links.info(target).hardLinkCount, 2, "hard link count")
    checkEqual(Links.relativePath(from: URL(fileURLWithPath: "/a/b/c"), to: URL(fileURLWithPath: "/a/x/y.txt")), "../../x/y.txt", "relative path")
    try FileManager.default.createSymbolicLink(atPath: zipSource.appendingPathComponent("inner/dead").path, withDestinationPath: "../missing")
    checkEqual(Links.broken(in: zipSource).map(\.lastPathComponent), ["dead"], "broken links found")

    // Custom metadata
    try CustomMetadata.write(["Project": "Atlas", "Client": "ACME"], to: target)
    checkEqual(CustomMetadata.read(target), ["Project": "Atlas", "Client": "ACME"], "metadata round-trip")
    check(CustomMetadata.matches(target, filter: "project=atl") && CustomMetadata.matches(target, filter: "client")
          && !CustomMetadata.matches(target, filter: "project=zeus") && !CustomMetadata.matches(target, filter: "owner"), "metadata filter")
    let copy = f.root.appendingPathComponent("copy.txt")
    try FileManager.default.copyItem(at: target, to: copy)
    checkEqual(CustomMetadata.read(copy)["Project"], "Atlas", "metadata travels with copies")
    try CustomMetadata.write([:], to: target)
    check(CustomMetadata.read(target).isEmpty, "metadata cleared")
}

await testAsync("search by custom metadata") { f in
    let dir = f.root.appendingPathComponent("meta")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, project) in [("a.txt", "Atlas"), ("b.txt", "Zeus"), ("c.txt", nil)] {
        let url = dir.appendingPathComponent(name)
        try Data().write(to: url)
        if let project { try CustomMetadata.write(["Project": project], to: url) }
    }
    var query = SearchQuery()
    query.scope = .subfolders(dir)
    query.metadata = "project=atl"
    check(!query.isEmpty, "metadata alone is a search")
    checkEqual(await SearchEngine.run(query).map(\.lastPathComponent), ["a.txt"], "metadata value filter (forces scan)")
    query.metadata = "project"
    checkEqual(await SearchEngine.run(query).map(\.lastPathComponent).sorted(), ["a.txt", "b.txt"], "has-field filter")
    let data = try JSONEncoder().encode(query)
    checkEqual(try JSONDecoder().decode(SearchQuery.self, from: data).metadata, "project", "metadata filter saved with searches")
}

await testAsync("clipboard history") { f in
    check(ClipboardHistory.looksLikePath("/Users/me/a.txt") && ClipboardHistory.looksLikePath("https://github.com/x/y/blob/main/a")
          && ClipboardHistory.looksLikePath("'/a b' '/c'") && ClipboardHistory.looksLikePath("src/main.swift"), "paths and links recorded")
    check(!ClipboardHistory.looksLikePath("my secret password 123") && !ClipboardHistory.looksLikePath("hello"), "plain text never recorded")
    let suite = UserDefaults(suiteName: "wayfile.selftest.clip")!
    suite.removePersistentDomain(forName: "wayfile.selftest.clip")
    let history = ClipboardHistory(defaults: suite)
    let board = NSPasteboard(name: NSPasteboard.Name("wayfile.selftest.\(UUID().uuidString)"))
    board.clearContents(); board.setString("/tmp/a", forType: .string)
    history.poll(pasteboard: board, appIsActive: false)
    check(history.entries.isEmpty, "copies while another app is active are ignored")
    board.clearContents(); board.writeObjects([f.src as NSURL])
    history.poll(pasteboard: board, appIsActive: true)
    board.clearContents(); board.setString("password123", forType: .string)
    history.poll(pasteboard: board, appIsActive: true)
    board.clearContents(); board.setString("/tmp/b", forType: .string)
    history.poll(pasteboard: board, appIsActive: true)
    history.poll(pasteboard: board, appIsActive: true)
    checkEqual(history.entries.map(\.title), ["/tmp/b", f.src.lastPathComponent], "files and paths, newest first, no duplicates for unchanged board")
    history.record(.files([f.src]))
    checkEqual(history.entries.count, 2, "re-copy moves entry to the top")
    checkEqual(ClipboardHistory(defaults: suite).entries.first?.title, f.src.lastPathComponent, "history persisted")
    history.restore(history.entries[1], to: board)
    checkEqual(board.string(forType: .string), "/tmp/b", "restore text")
    for i in 0..<40 { history.record(.text("/x/\(i)")) }
    checkEqual(history.entries.count, ClipboardHistory.limit, "limited")
}

await testAsync("security") { f in
    let file = f.root.appendingPathComponent("secure.txt")
    try "x".write(to: file, atomically: true, encoding: .utf8)
    try XAttr.set("dev.wayfile.test", Data("hello".utf8), on: file)
    let attrs = XAttr.list(file)
    check(attrs.contains { $0.name == "dev.wayfile.test" && $0.displayValue == "hello" && !$0.isSystem }, "xattr listed (\(attrs.map(\.name)))")
    try XAttr.remove("dev.wayfile.test", from: file)
    check(!XAttr.list(file).contains { $0.name == "dev.wayfile.test" }, "xattr removed")
    let plist = try PropertyListSerialization.data(fromPropertyList: ["a", "b"], format: .binary, options: 0)
    checkEqual(ExtendedAttribute(name: "p", data: plist).displayValue, "a, b", "binary plist decoded")
    checkEqual(ExtendedAttribute(name: "h", data: Data([0, 1, 255])).displayValue, "00 01 ff", "binary as hex")

    let q = Quarantine.parse("0083;65a1b2c3;Safari;8F1E-UUID")
    check(q?.agent == "Safari" && q?.date == Date(timeIntervalSince1970: 0x65a1b2c3) && q?.isApproved == false, "quarantine parsed")
    check(Quarantine.parse("00c3;65a1b2c3;Chrome;")?.isApproved == true, "approved bit")
    let app = f.root.appendingPathComponent("Fake.app/Contents")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try Data().write(to: app.appendingPathComponent("bin"))
    for url in [file, app.appendingPathComponent("bin"), app.deletingLastPathComponent()] {
        try XAttr.set(Quarantine.attribute, Data("0083;65a1b2c3;Safari;".utf8), on: url)
    }
    check(Quarantine.read(file)?.agent == "Safari", "quarantine read")
    checkEqual(try Quarantine.remove(from: [file, app.deletingLastPathComponent()]), 3, "quarantine removed recursively")
    check(Quarantine.read(app.appendingPathComponent("bin")) == nil, "nested flag gone")

    let aclOutput = """
    -rw-r--r--+ 1 me  staff  0 Jan  1 10:00 x
     0: user:admin allow read,write
     1: group:everyone inherited deny delete
    """
    let parsed = ACL.parse(aclOutput)
    checkEqual(parsed.map(\.principal), ["user:admin", "group:everyone"], "acl principals")
    check(parsed[0].allow && parsed[0].permissions == ["read", "write"] && parsed[1].inherited && !parsed[1].allow, "acl rules")
    let me = NSUserName()
    try await ACL.add(principal: "user:\(me)", allow: false, permissions: ["delete"], to: file)
    var live = await ACL.entries(of: file)
    check(live.count == 1 && live[0].principal == "user:\(me)" && !live[0].allow && live[0].permissions == ["delete"], "acl added (\(live))")
    try await ACL.remove(index: 0, from: file)
    live = await ACL.entries(of: file)
    check(live.isEmpty, "acl removed")

    checkEqual(PermissionPlan.parse("755"), .set(0o755), "octal mode")
    checkEqual(PermissionPlan.parse("go-w"), .adjust(add: 0, remove: 0o022), "symbolic remove")
    checkEqual(PermissionPlan.parse("+x"), .adjust(add: 0o111, remove: 0), "symbolic all")
    check(PermissionPlan.parse("999") == nil && PermissionPlan.parse("z+q") == nil, "invalid modes")
    let tree = f.root.appendingPathComponent("perms")
    try FileManager.default.createDirectory(at: tree.appendingPathComponent("sub"), withIntermediateDirectories: true)
    for name in ["a", "sub/b"] {
        try Data().write(to: tree.appendingPathComponent(name))
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: tree.appendingPathComponent(name).path)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: tree.appendingPathComponent("sub").path)
    let plan = PermissionPlan(files: .set(0o644), folders: .adjust(add: 0, remove: 0o022), recursive: true)
    let preview = plan.preview([tree])
    checkEqual(Set(preview.map(\.url.lastPathComponent)), ["a", "b", "sub", "perms"].filter { name in
        name != "perms" || ((try? FileManager.default.attributesOfItem(atPath: tree.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o022 != 0
    }.reduce(into: Set<String>()) { $0.insert($1) }, "preview lists only changes")
    let progress = OperationProgress()
    try PermissionPlan.apply(preview, progress: progress)
    let mode = { (p: String) in ((try? FileManager.default.attributesOfItem(atPath: tree.appendingPathComponent(p).path)[.posixPermissions]) as? NSNumber)?.intValue ?? 0 }
    check(mode("a") == 0o644 && mode("sub/b") == 0o644 && mode("sub") == 0o755, "permissions applied")
    check(UndoRecord.combine(progress.records)?.lines.first?.text.contains("→") == true, "timeline lines")
    _ = try UndoRecord.combine(progress.records)!.revert()
    check(mode("a") == 0o666 && mode("sub") == 0o777, "permissions undone")
    check(plan.preview([tree], limit: 1).count == 1, "preview limit")

    // Encrypted vault (small, temporary)
    let vault = try await Vaults.create(name: "PFTestVault", in: f.root, sizeGB: 1, password: "correct horse")
    check(FileManager.default.fileExists(atPath: vault.url.path), "vault created")
    do {
        _ = try await Vaults.unlock(vault, password: "wrong")
        check(false, "wrong password rejected")
    } catch {
        check(error.localizedDescription.lowercased().contains("password") || !error.localizedDescription.isEmpty, "wrong password error: \(error.localizedDescription)")
    }
    let mount = try await Vaults.unlock(vault, password: "correct horse")
    try "secret".write(to: mount.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
    check(Vaults.attachedImages()[vault.url.standardizedFileURL.path] == mount, "vault mount detected")
    try await Vaults.lock(mount)
    check(!FileManager.default.fileExists(atPath: mount.appendingPathComponent("note.txt").path), "vault locked")
    let raw = try FileManager.default.subpathsOfDirectory(atPath: vault.url.path).compactMap { try? Data(contentsOf: vault.url.appendingPathComponent($0)) }
    check(!raw.contains { $0.range(of: Data("secret".utf8)) != nil }, "contents encrypted at rest")
}

await testAsync("performance & recovery") { f in
    let big = f.root.appendingPathComponent("big")
    try FileManager.default.createDirectory(at: big.appendingPathComponent("nested"), withIntermediateDirectories: true)
    for i in 0..<2500 { FileManager.default.createFile(atPath: big.appendingPathComponent("f\(i)").path, contents: nil) }
    try Data().write(to: big.appendingPathComponent("doc.pdf"))
    try TagIO.write([FileTag(name: "Red", color: 6)], to: big.appendingPathComponent("doc.pdf"))
    var sizes: [Int] = [], detailCount = 0
    var quick: FileItem?, detailed: FileItem?
    for try await event in FileSystem.listProgressively(big, firstBatch: 300) {
        switch event {
        case .items(let batch):
            sizes.append(batch.count)
            quick = quick ?? batch.first { $0.name == "doc.pdf" }
        case .details(let batch):
            detailCount += batch.count
            detailed = detailed ?? batch.first { $0.name == "doc.pdf" }
        }
    }
    checkEqual(sizes, [300, 2202], "first batch, then the rest; folders included, not their contents")
    checkEqual(detailCount, 2502, "every item gets details (in one update)")
    check(quick?.detailsLoaded == false && quick?.fileTags.isEmpty == true, "quick pass skips tags")
    check(detailed?.fileTags.map(\.name) == ["Red"] && detailed?.kind.isEmpty == false && detailed?.detailsLoaded == true, "details pass adds tags and type")
    var mixed = (try FileSystem.list(big)).shuffled()
    FileSorting.sort(&mixed, by: [KeyPathComparator(\FileItem.name)])
    check(mixed.map(\.name) == mixed.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending } && mixed[3].name == "f2", "fast name sort (natural order)")
    FileSorting.sort(&mixed, by: [KeyPathComparator(\FileItem.sizeKey, order: .reverse)])
    check(zip(mixed, mixed.dropFirst()).allSatisfy { $0.sizeKey >= $1.sizeKey }, "fast size sort (descending)")
    var whole: [Int] = []
    for try await event in FileSystem.listProgressively(big) { if case .items(let b) = event { whole.append(b.count) } }
    checkEqual(whole, [2502], "by default all items arrive in one update")
    var failed = false
    do { for try await _ in FileSystem.listProgressively(big.appendingPathComponent("missing")) {} } catch { failed = true }
    check(failed, "missing folder reports an error")

    final class Counter: @unchecked Sendable { var direct = 0; var deep = 0 }
    let counter = Counter()
    let direct = FolderMonitor(big) { counter.direct += 1 }
    let deep = FolderMonitor(big, recursive: true) { counter.deep += 1 }
    try await Task.sleep(nanoseconds: 300_000_000)
    FileManager.default.createFile(atPath: big.appendingPathComponent("nested/inner.txt").path, contents: Data("x".utf8))
    try await Task.sleep(nanoseconds: 1_200_000_000)
    check(counter.direct == 0 && counter.deep > 0, "grandchild change: recursive only (direct \(counter.direct), deep \(counter.deep))")
    try Data("changed".utf8).write(to: big.appendingPathComponent("f1"))
    try await Task.sleep(nanoseconds: 1_200_000_000)
    check(counter.direct > 0, "child content change noticed (kqueue missed these)")
    _ = (direct, deep)

    // Transfer journal & resume plan
    let journal = TransferJournal(url: f.root.appendingPathComponent("journal.json"))
    let src = f.root.appendingPathComponent("srcset")
    let dst = f.root.appendingPathComponent("dstset")
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
    for name in ["done.bin", "partial.bin", "todo.bin"] { try Data(count: 5000).write(to: src.appendingPathComponent(name)) }
    try FileManager.default.copyItem(at: src.appendingPathComponent("done.bin"), to: dst.appendingPathComponent("done.bin"))
    try Data(count: 1200).write(to: dst.appendingPathComponent("partial.bin"))
    let job = TransferJob(sources: ["done.bin", "partial.bin", "todo.bin", "gone.bin"].map { src.appendingPathComponent($0) },
                          destination: dst, mode: .copy, started: Date())
    journal.begin(job)
    checkEqual(TransferJournal(url: f.root.appendingPathComponent("journal.json")).jobs.map(\.id), [job.id], "journal persisted")
    let plan = TransferJournal.resumePlan(for: job)
    checkEqual(plan.sources.map(\.lastPathComponent), ["done.bin", "partial.bin", "todo.bin"], "missing sources dropped")
    checkEqual(plan.overrides[src.appendingPathComponent("done.bin").standardizedFileURL.path], .skip, "complete copy skipped")
    checkEqual(plan.overrides[src.appendingPathComponent("partial.bin").standardizedFileURL.path], .replace, "partial copy redone")
    check(plan.overrides[src.appendingPathComponent("todo.bin").standardizedFileURL.path] == nil, "untouched item copied normally")
    let progress = OperationProgress()
    _ = try FileOps.transfer(plan.sources, to: dst, mode: .copy, policy: .keepBoth, overrides: plan.overrides, progress: progress)
    let sizesAfter = try ["done.bin", "partial.bin", "todo.bin"].map { try dst.appendingPathComponent($0).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
    checkEqual(sizesAfter, [5000, 5000, 5000], "resume completes the transfer")
    checkEqual(try FileManager.default.contentsOfDirectory(atPath: dst.path).count, 3, "no duplicates")
    journal.finish(job.id)
    check(journal.jobs.isEmpty && !FileManager.default.fileExists(atPath: f.root.appendingPathComponent("journal.json").path), "journal cleared")
    let folderA = src.appendingPathComponent("tree"), folderB = dst.appendingPathComponent("tree")
    try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
    try Data(count: 10).write(to: folderA.appendingPathComponent("a"))
    try FileManager.default.copyItem(at: folderA, to: folderB)
    check(TransferJournal.isComplete(folderA, copy: folderB), "identical folder complete")
    try Data(count: 10).write(to: folderA.appendingPathComponent("b"))
    check(!TransferJournal.isComplete(folderA, copy: folderB), "folder missing a file is partial")
}

await testAsync("personalization") { f in
    let suite = UserDefaults(suiteName: "wayfile.selftest.features")!
    suite.removePersistentDomain(forName: "wayfile.selftest.features")
    let features = Features(defaults: suite)
    checkEqual(features.mode, .power, "everything on by default")
    features.mode = .standard
    check(features.isOn(.compare) && !features.isOn(.automation) && !features.isOn(.security), "standard mode")
    features.set(.developer, true)
    checkEqual(features.mode, .custom, "custom after a manual change")
    checkEqual(Features(defaults: suite).enabled, [.compare, .developer], "modules persisted")
    check(ContextMenuItem.scripts.module == .automation && ContextMenuItem.copyPath.module == nil, "context items know their module")

    let sidebar = SidebarConfig(defaults: suite)
    checkEqual(sidebar.visibleSections, SidebarSection.allCases, "all sidebar sections by default")
    sidebar.setVisible(.cloud, false)
    sidebar.move(.tags, by: -1)
    let reloaded = SidebarConfig(defaults: suite)
    check(!reloaded.visibleSections.contains(.cloud) && reloaded.order.suffix(2) == [.tags, .savedSearches], "sidebar order & visibility persisted")
    reloaded.reset()
    checkEqual(reloaded.visibleSections, SidebarSection.allCases, "sidebar reset")

    let history = PaletteHistory(defaults: suite)
    for id in ["a", "b", "a", "c"] { history.record(id) }
    checkEqual(history.recent, ["c", "a", "b"], "palette history most recent first, no duplicates")
    for i in 0..<20 { history.record("x\(i)") }
    checkEqual(history.recent.count, PaletteHistory.limit, "palette history limited")
    checkEqual(FeatureModule.forPaletteAction("script./x.sh"), .automation, "palette script module")
    checkEqual(FeatureModule.forPaletteAction("vault.123"), .security, "palette vault module")
    check(FeatureModule.forPaletteAction("new.folder") == nil, "basic palette actions always shown")

    // Settings transfer
    let source = UserDefaults(suiteName: "wayfile.selftest.export")!
    source.removePersistentDomain(forName: "wayfile.selftest.export")
    source.set("nord", forKey: "theme.preset")
    source.set(["a", "b"], forKey: "features.enabled")
    source.set("{1,2}", forKey: "NSWindow Frame main")
    let support = f.root.appendingPathComponent("support")
    try FileManager.default.createDirectory(at: support.appendingPathComponent("Scripts"), withIntermediateDirectories: true)
    try "echo hi".write(to: support.appendingPathComponent("Scripts/hi.sh"), atomically: true, encoding: .utf8)
    try "[]".write(to: support.appendingPathComponent("rules.json"), atomically: true, encoding: .utf8)
    try "secret".write(to: support.appendingPathComponent("timeline.json"), atomically: true, encoding: .utf8)
    let data = try SettingsTransfer.export(defaults: source, domain: "wayfile.selftest.export", support: support)
    checkEqual(try SettingsTransfer.summary(of: data), SettingsTransfer.Summary(settings: 2, files: 2), "export: own keys and included files only")
    let target = UserDefaults(suiteName: "wayfile.selftest.import")!
    target.removePersistentDomain(forName: "wayfile.selftest.import")
    let other = f.root.appendingPathComponent("support2")
    _ = try SettingsTransfer.import(data, defaults: target, support: other)
    check(target.string(forKey: "theme.preset") == "nord" && target.object(forKey: "NSWindow Frame main") == nil, "import sets preferences")
    check(FileManager.default.isExecutableFile(atPath: other.appendingPathComponent("Scripts/hi.sh").path), "scripts imported executable")
    check(!FileManager.default.fileExists(atPath: other.appendingPathComponent("timeline.json").path), "history not exported")
    let evil = try PropertyListSerialization.data(fromPropertyList: ["format": 1, "defaults": [String: Any](), "files": ["Scripts/../../escape.txt": Data("x".utf8)]], format: .xml, options: 0)
    _ = try SettingsTransfer.import(evil, defaults: target, support: other)
    check(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("escape.txt").path), "paths outside the folder are refused")
    var refused = false
    do { _ = try SettingsTransfer.summary(of: Data("nope".utf8)) } catch { refused = true }
    check(refused, "non-settings file refused")
}

await testAsync("ai search") { _ in
    let home = URL(fileURLWithPath: "/Users/me")
    let places = NaturalSearch.Places(current: URL(fileURLWithPath: "/Users/me/Projects"), home: home)
    let tags = ["Červená", "Work"]
    let answer = "Sure! ```json\n{\"text\":\"beach\",\"kinds\":[\"image\",\"bogus\"],\"minSizeMB\":2.5,\"maxSizeMB\":null,\"date\":\"last30days\",\"dateField\":\"created\",\"tags\":[\"work\",\"Nope\"],\"folder\":\"desktop\",\"notOpenedDays\":null,\"content\":false}\n```"
    let r = NaturalSearch.query(fromModelJSON: answer, places: places, tagNames: tags)
    check(r?.query.text == "beach" && r?.query.kinds == [.image] && r?.query.minSize == Int64(2.5 * 1_000_000), "model JSON → filters")
    check(r?.query.tags == ["Work"] && r?.query.dateRange == .last30Days && r?.query.dateField == .created, "tags matched to existing, dates")
    checkEqual(r?.query.scope, .subfolders(home.appendingPathComponent("Desktop")), "folder")
    check(r?.summary.contains("on Desktop") == true && r?.summary.first == "Images", "summary")
    let year = NaturalSearch.query(fromModelJSON: #"{"text":"","kinds":["pdf"],"date":"2024","folder":"current","notOpenedDays":"90"}"#, places: places, tagNames: [])
    if case .between(let from, _) = year?.query.dateRange { checkEqual(Calendar.current.component(.year, from: from), 2024, "year range") } else { check(false, "year range") }
    check(year?.query.scope == .subfolders(places.current!) && year?.query.notOpenedForDays == 90, "current folder, numeric strings")
    check(NaturalSearch.query(fromModelJSON: "I can't help with that", places: places, tagNames: []) == nil, "prose ignored")
    check(NaturalSearch.query(fromModelJSON: #"{"text":"","kinds":[]}"#, places: places, tagNames: []) == nil, "empty filters rejected")

    // Request shapes per provider.
    func body(_ request: URLRequest) -> [String: Any] { (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:] }
    let ollama = try AIClient.makeRequest(system: "S", user: "U", json: true, configuration: AIConfiguration(kind: .ollama, endpoint: "http://localhost:11434/", model: "llama3.2"))
    check(ollama.url?.absoluteString == "http://localhost:11434/api/chat" && body(ollama)["format"] as? String == "json" && body(ollama)["stream"] as? Bool == false, "ollama request")
    let openai = try AIClient.makeRequest(system: "S", user: "U", json: true, configuration: AIConfiguration(kind: .openAI, endpoint: "https://api.openai.com/v1", model: "gpt-4o-mini", apiKey: "sk-1"))
    check(openai.url?.absoluteString == "https://api.openai.com/v1/chat/completions" && openai.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1"
          && body(openai)["response_format"] != nil, "openai request")
    let lmstudio = try AIClient.makeRequest(system: "S", user: "U", json: true, configuration: AIConfiguration(kind: .openAI, endpoint: "http://localhost:1234/v1", model: "x"))
    check(body(lmstudio)["response_format"] == nil && lmstudio.value(forHTTPHeaderField: "Authorization") == nil, "compatible server: no response_format, no key")
    let claude = try AIClient.makeRequest(system: "S", user: "U", json: true, configuration: AIConfiguration(kind: .anthropic, endpoint: "https://api.anthropic.com", model: "claude-haiku-4-5-20251001", apiKey: "ak"))
    check(claude.url?.path == "/v1/messages" && claude.value(forHTTPHeaderField: "x-api-key") == "ak" && claude.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01"
          && body(claude)["system"] as? String == "S", "anthropic request")
    let gemini = try AIClient.makeRequest(system: "S", user: "U", json: true, configuration: AIConfiguration(kind: .gemini, endpoint: "https://generativelanguage.googleapis.com", model: "gemini-2.5-flash", apiKey: "gk"))
    check(gemini.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent" && gemini.value(forHTTPHeaderField: "x-goog-api-key") == "gk", "gemini request (key in header, not URL)")

    // Response parsing per provider.
    checkEqual(try AIClient.parseResponse(Data(#"{"message":{"role":"assistant","content":"{}"}}"#.utf8), kind: .ollama), "{}", "ollama answer")
    checkEqual(try AIClient.parseResponse(Data(#"{"choices":[{"message":{"content":"hi"}}]}"#.utf8), kind: .openAI), "hi", "openai answer")
    checkEqual(try AIClient.parseResponse(Data(#"{"content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}"#.utf8), kind: .anthropic), "ab", "anthropic answer")
    checkEqual(try AIClient.parseResponse(Data(#"{"candidates":[{"content":{"parts":[{"text":"g"}]}}]}"#.utf8), kind: .gemini), "g", "gemini answer")
    checkThrows(AIError.self, "empty answer") { _ = try AIClient.parseResponse(Data(#"{"choices":[]}"#.utf8), kind: .openAI) }
    check(AIClient.errorMessage(Data(#"{"error":{"message":"Invalid key"}}"#.utf8), status: 401, kind: .openAI).contains("Invalid key"), "error message")
    await checkThrowsAsync("missing key is reported before any request") {
        _ = try await AIClient.complete(system: "S", user: "U", configuration: AIConfiguration(kind: .anthropic, endpoint: "https://api.anthropic.com", model: "m"))
    }
    // Subscription CLIs
    let ccArgs = SubscriptionCLI.arguments(for: .claudeCode, system: "SYS", user: "find pdfs", model: "haiku", outputFile: URL(fileURLWithPath: "/tmp/x"))
    check(ccArgs.starts(with: ["-p", "find pdfs"]) && ccArgs.contains("--system-prompt") && ccArgs.contains("haiku") && ccArgs.contains("--tools"), "claude code arguments (no tools)")
    let cxArgs = SubscriptionCLI.arguments(for: .codex, system: "SYS", user: "find pdfs", model: "", outputFile: URL(fileURLWithPath: "/tmp/x"))
    check(cxArgs.first == "exec" && cxArgs.contains("read-only") && cxArgs.contains("/tmp/x") && cxArgs.last?.contains("find pdfs") == true, "codex arguments (read-only)")
    checkEqual(try SubscriptionCLI.parse(kind: .claudeCode, stdout: #"{"type":"result","is_error":false,"result":"{\"kinds\":[\"pdf\"]}"}"#, stderr: "", status: 0, lastMessage: nil),
               #"{"kinds":["pdf"]}"#, "claude code result")
    checkThrows(AIError.self, "claude code error result") {
        _ = try SubscriptionCLI.parse(kind: .claudeCode, stdout: #"{"is_error":true,"result":"Credit balance is too low"}"#, stderr: "", status: 1, lastMessage: nil)
    }
    do {
        _ = try SubscriptionCLI.parse(kind: .claudeCode, stdout: "Invalid API key · Please run /login", stderr: "", status: 1, lastMessage: nil)
        check(false, "not signed in detected")
    } catch { check(error.localizedDescription.contains("Sign in"), "not signed in → sign-in hint") }
    checkEqual(try SubscriptionCLI.parse(kind: .codex, stdout: "noise", stderr: "progress", status: 0, lastMessage: "{\"ok\":true}\n"), "{\"ok\":true}\n", "codex last message")
    let loginOutput = "Opening browser to sign in…\nIf the browser didn't open, visit: \u{1B}]8;;https://claude.com/cai/oauth/authorize?code=true&client_id=abc&state=xyz\u{07}https://claude.com/cai/oauth/authorize?code=true&client_id=abc&state=xyz\u{1B}]8;;\u{07}\nPaste code here if prompted >"
    checkEqual(SubscriptionCLI.loginURL(in: loginOutput)?.absoluteString, "https://claude.com/cai/oauth/authorize?code=true&client_id=abc&state=xyz", "login link from hyperlinked output")
    checkEqual(SubscriptionCLI.loginURL(in: "visit https://auth.openai.com/oauth/authorize?x=1 to continue")?.host, "auth.openai.com", "plain login link")
    checkEqual(SubscriptionCLI.loginArguments(for: .claudeCode), ["auth", "login", "--claudeai"], "claude login uses the subscription")
}


test("ai context") { f in
    let dir = f.root.appendingPathComponent("aictx")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
    try "# Atlas\nA tool for maps.".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try "print(\"hi\")".write(to: dir.appendingPathComponent("src/main.py"), atomically: true, encoding: .utf8)
    try Data([0, 1, 2, 3, 255]).write(to: dir.appendingPathComponent("blob.bin"))
    let folder = AIContext.build(for: [dir])
    check(folder.text.contains("=== Folder:") && folder.text.contains("README.md") && folder.text.contains("main.py") && folder.text.contains("A tool for maps"),
          "folder listing with readme content")
    check(folder.included.first == "aictx/" && folder.included.contains("aictx/src/main.py"), "folder and its files counted")
    let files = AIContext.build(for: [dir.appendingPathComponent("src/main.py"), dir.appendingPathComponent("blob.bin")])
    check(files.text.contains("print(\"hi\")") && files.included == ["main.py"] && files.describedOnly == ["blob.bin"], "text vs binary")
    // PDF text
    let pdf = dir.appendingPathComponent("doc.pdf")
    let attributed = NSAttributedString(string: "Invoice 2026-0042 total 120 EUR")
    let printInfo = NSPrintInfo()
    let data = NSMutableData()
    let consumer = CGDataConsumer(data: data as CFMutableData)!
    var box = CGRect(x: 0, y: 0, width: 400, height: 200)
    let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed), CFRange(location: 0, length: 0), CGPath(rect: box, transform: nil), nil)
    CTFrameDraw(frame, ctx)
    ctx.endPDFPage(); ctx.closePDF()
    try (data as Data).write(to: pdf)
    _ = printInfo
    check(AIContext.build(for: [pdf]).text.contains("Invoice 2026-0042"), "pdf text extracted")
    // Budget
    try String(repeating: "x", count: 50_000).write(to: dir.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
    let small = AIContext.build(for: [dir.appendingPathComponent("big.txt")], budget: 1_000)
    check(small.truncated && small.text.count < 1_200, "budget respected")
    let prompt = AIContext.prompt(context: files, history: [("q1", "a1")], question: "q2")
    check(prompt.hasPrefix("CONTENT:") && prompt.contains("User: q1\nAssistant: a1") && prompt.hasSuffix("QUESTION: q2"), "prompt with history")
}

await testAsync("ai context: documents") { f in
    let dir = f.root.appendingPathComponent("docs")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // Word & RTF made by the system's own converter.
    let plain = dir.appendingPathComponent("letter.txt")
    try "Zmluva o dielo číslo 42, cena 1500 EUR.".write(to: plain, atomically: true, encoding: .utf8)
    try await Shell.check("/usr/bin/textutil", ["-convert", "docx", plain.path, "-output", dir.appendingPathComponent("letter.docx").path])
    try await Shell.check("/usr/bin/textutil", ["-convert", "rtf", plain.path, "-output", dir.appendingPathComponent("letter.rtf").path])
    try FileManager.default.removeItem(at: plain)
    check(AIContext.readText(dir.appendingPathComponent("letter.docx"), limit: 1000)?.contains("Zmluva o dielo číslo 42") == true, "docx text")
    let rtf = AIContext.readText(dir.appendingPathComponent("letter.rtf"), limit: 1000) ?? ""
    check(rtf.contains("1500 EUR") && !rtf.contains("\\rtf1"), "rtf text without markup")
    // Minimal xlsx and pptx built by hand.
    func zip(_ name: String, _ files: [String: String]) async throws -> URL {
        let staging = f.root.appendingPathComponent("stage-\(name)")
        for (path, content) in files {
            let url = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        let out = dir.appendingPathComponent(name)
        try await Shell.check("/usr/bin/zip", ["-qr", out.path, "."], cwd: staging)
        return out
    }
    let xlsx = try await zip("budget.xlsx", [
        "xl/sharedStrings.xml": #"<sst><si><t>Item</t></si><si><t>Cost</t></si><si><r><t>Ren</t></r><r><t>t</t></r></si></sst>"#,
        "xl/worksheets/sheet1.xml": #"<worksheet><sheetData><row><c t="s"><v>0</v></c><c t="s"><v>1</v></c></row><row><c t="s"><v>2</v></c><c><v>950</v></c></row></sheetData></worksheet>"#,
    ])
    checkEqual(AIContext.readText(xlsx, limit: 1000), "[sheet1]\nItem\tCost\nRent\t950\n", "xlsx rows with shared strings")
    let pptx = try await zip("talk.pptx", [
        "ppt/slides/slide1.xml": #"<p:sld xmlns:p="p" xmlns:a="a"><a:t>Quarterly</a:t><a:t>Review</a:t></p:sld>"#,
        "ppt/slides/slide2.xml": #"<p:sld xmlns:p="p" xmlns:a="a"><a:t>Thanks</a:t></p:sld>"#,
    ])
    checkEqual(AIContext.readText(pptx, limit: 1000), "[Slide 1]\nQuarterly Review\n[Slide 2]\nThanks\n", "pptx slides")
    // Image with text → OCR.
    let image = NSImage(size: NSSize(width: 900, height: 200), flipped: false) { rect in
        NSColor.white.setFill(); rect.fill()
        NSAttributedString(string: "INVOICE 7781 TOTAL 320", attributes: [.font: NSFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: NSColor.black])
            .draw(at: NSPoint(x: 20, y: 60))
        return true
    }
    let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    try png.write(to: dir.appendingPathComponent("scan.png"))
    let ocr = AIContext.readText(dir.appendingPathComponent("scan.png"), limit: 1000) ?? ""
    check(ocr.contains("7781") && ocr.uppercased().contains("INVOICE"), "OCR of image text (got \(ocr))")
    // Folder: listing plus the files' content.
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("node_modules/x"), withIntermediateDirectories: true)
    try "SHOULD NOT APPEAR".write(to: dir.appendingPathComponent("node_modules/x/index.js"), atomically: true, encoding: .utf8)
    let folder = AIContext.build(for: [dir])
    check(folder.text.contains("Zmluva o dielo") && folder.text.contains("Rent\t950") && folder.text.contains("Quarterly Review") && folder.text.contains("7781"),
          "folder includes document contents")
    check(!folder.text.contains("SHOULD NOT APPEAR"), "vendored folders skipped")
    check(AIContext.instructions.contains("Never say you can't open"), "model told it has the content")
}

test("two-way sync with deletions") { f in
    let fm = FileManager.default
    let A = f.root.appendingPathComponent("syncA"), B = f.root.appendingPathComponent("syncB")
    let state = f.root.appendingPathComponent("state")
    for dir in [A, B] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
    func write(_ root: URL, _ path: String, _ text: String, age: TimeInterval = 0) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
    }
    func read(_ root: URL, _ path: String) -> String? { try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
    func sync() throws -> TwoWaySync.Plan {
        let plan = try TwoWaySync.plan(left: A, right: B, folder: state)
        try DirectoryDiff.execute(plan.actions, left: A, right: B, progress: OperationProgress())
        try TwoWaySync.saveBase(left: A, right: B, folder: state)
        return plan
    }
    try write(A, "a.txt", "a", age: 100); try write(A, "docs/keep.txt", "k", age: 100); try write(A, "docs/old.txt", "o", age: 100)
    try write(B, "b.txt", "b", age: 100); try write(B, "photos/p.txt", "p", age: 100)
    var plan = try sync()
    check(plan.isFirstSync && plan.actions.allSatisfy { if case .copy = $0.kind { return true } else { return false } }, "first sync only copies")
    check(read(B, "a.txt") == "a" && read(A, "photos/p.txt") == "p" && read(B, "docs/old.txt") == "o", "first sync merges both sides")

    // Deletions on each side travel over.
    try fm.removeItem(at: A.appendingPathComponent("b.txt"))
    try fm.removeItem(at: B.appendingPathComponent("docs/old.txt"))
    try fm.removeItem(at: B.appendingPathComponent("photos"))
    try write(A, "new-left.txt", "n")
    plan = try sync()
    check(!plan.isFirstSync && plan.conflicts.isEmpty, "second sync knows the state")
    check(!fm.fileExists(atPath: B.appendingPathComponent("b.txt").path) && !fm.fileExists(atPath: A.appendingPathComponent("docs/old.txt").path),
          "file deletions propagated both ways")
    check(!fm.fileExists(atPath: A.appendingPathComponent("photos").path), "deleted folder propagated")
    check(read(B, "new-left.txt") == "n" && read(A, "docs/keep.txt") == "k", "new files still copied, untouched kept")

    // Conflicts: deleted on one side, changed on the other → kept; changed on both → newer wins.
    try fm.removeItem(at: A.appendingPathComponent("a.txt"))
    try write(B, "a.txt", "a changed on B")
    try write(A, "docs/keep.txt", "older edit", age: 50)
    try write(B, "docs/keep.txt", "newer edit", age: 5)
    plan = try sync()
    checkEqual(plan.conflicts.count, 2, "two conflicts reported")
    check(read(A, "a.txt") == "a changed on B", "changed copy survives a deletion on the other side")
    check(read(A, "docs/keep.txt") == "newer edit" && read(B, "docs/keep.txt") == "newer edit", "newer edit wins on both sides")

    // Nothing changed → nothing to do; undo of a sync restores trashed files.
    plan = try TwoWaySync.plan(left: A, right: B, folder: state)
    check(plan.actions.isEmpty, "in sync: nothing to do")
    try fm.removeItem(at: A.appendingPathComponent("new-left.txt"))
    plan = try TwoWaySync.plan(left: A, right: B, folder: state)
    let progress = OperationProgress()
    try DirectoryDiff.execute(plan.actions, left: A, right: B, progress: progress)
    check(!fm.fileExists(atPath: B.appendingPathComponent("new-left.txt").path), "deletion applied")
    _ = try UndoRecord.combine(progress.records)!.revert()
    check(read(B, "new-left.txt") == "n", "deletion undone from the Trash")
    checkEqual(TwoWaySync.stateURL(left: A, right: B, folder: state), TwoWaySync.stateURL(left: B, right: A, folder: state), "state shared regardless of side order")
    TwoWaySync.forget(left: A, right: B, folder: state)
    check(TwoWaySync.loadBase(left: A, right: B, folder: state) == nil, "state forgotten")
}

test("two-finger swipe decision") { _ in
    check(SwipeDecision.isHorizontalStart(dx: 8, dy: 1) && !SwipeDecision.isHorizontalStart(dx: 3, dy: 3) && !SwipeDecision.isHorizontalStart(dx: 0.2, dy: 0), "sideways only")
    check(SwipeDecision.navigates(dx: 5, room: nil), "no scroll view → navigate")
    check(SwipeDecision.navigates(dx: -5, room: .init(offset: 0, visibleWidth: 800, contentWidth: 800)), "nothing to scroll sideways → navigate")
    let wide = SwipeDecision.Room(offset: 0, visibleWidth: 800, contentWidth: 1400)
    check(SwipeDecision.navigates(dx: 5, room: wide) && !SwipeDecision.navigates(dx: -5, room: wide), "at left edge: back swipes, forward scrolls the table")
    let middle = SwipeDecision.Room(offset: 300, visibleWidth: 800, contentWidth: 1400)
    check(!SwipeDecision.navigates(dx: 5, room: middle) && !SwipeDecision.navigates(dx: -5, room: middle), "mid-scroll: the table scrolls")
    check(SwipeDecision.navigates(dx: -5, room: .init(offset: 600, visibleWidth: 800, contentWidth: 1400)), "at right edge: forward swipes")
}

await testAsync("home dashboard") { _ in
    let suite = UserDefaults(suiteName: "wayfile.selftest.home")!
    suite.removePersistentDomain(forName: "wayfile.selftest.home")
    let config = HomeConfig(defaults: suite)
    checkEqual(config.preset, .everyday, "Everyday by default")
    config.apply(.developer)
    check(config.isShown(.gitRepositories) && config.preset == .developer, "developer preset")
    config.setShown(.tags, true)
    checkEqual(config.preset, .custom, "changes make it custom")
    config.setShown(.drives, false)
    check(!config.isShown(.drives), "hide widget")
    config.move(.tags, before: .quickAccess)
    checkEqual(config.widgets.first, .tags, "drag before target")
    config.move(.tags, by: 2)
    checkEqual(config.widgets.firstIndex(of: .tags), 2, "move later")
    config.move(.tags, by: -10)
    checkEqual(config.widgets.first, .tags, "move clamps")
    config.pinProject(URL(fileURLWithPath: "/tmp/p/"))
    config.pinProject(URL(fileURLWithPath: "/tmp/p"))
    config.notes = "remember"
    let reloaded = HomeConfig(defaults: suite)
    check(reloaded.widgets == config.widgets && reloaded.projects.count == 1 && reloaded.notes == "remember", "persisted")
    reloaded.reset()
    checkEqual(reloaded.preset, .everyday, "reset")

    let widgets: [HomeWidget] = [.quickAccess, .recentFiles, .drives, .tags, .transferQueue]
    let columns = HomeConfig.columns(for: widgets, count: 2)
    checkEqual(columns.flatMap { $0 }.count, widgets.count, "every card placed")
    checkEqual(columns[0].first, .quickAccess, "first card top-left")
    checkEqual(columns[1].first, .recentFiles, "second card top-right")
    let heights = columns.map { $0.reduce(0) { $0 + $1.estimatedHeight } }
    check(abs(heights[0] - heights[1]) <= 300, "columns balanced (\(heights))")
    checkEqual(HomeConfig.columns(for: widgets, count: 1), [widgets], "single column keeps order")
    let calendar = Calendar(identifier: .gregorian)
    let at = { (h: Int) in calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: h))! }
    check(HomeConfig.greeting(at: at(9), calendar: calendar) == "Good morning" && HomeConfig.greeting(at: at(15), calendar: calendar) == "Good afternoon"
          && HomeConfig.greeting(at: at(20), calendar: calendar) == "Good evening" && HomeConfig.greeting(at: at(2), calendar: calendar) == "Good night", "greetings")
    checkEqual(HomeConfig.quote(for: at(9), calendar: calendar), HomeConfig.quote(for: at(20), calendar: calendar), "same quote all day")
}

await testAsync("activity timeline") { f in
    let home = NSHomeDirectory()
    check(ActivityModel.isNoise(home + "/Library/Caches/x") && ActivityModel.isNoise("/p/node_modules/a.js") && ActivityModel.isNoise("/p/.git/HEAD")
          && ActivityModel.isNoise("/p/x.crdownload") && !ActivityModel.isNoise(home + "/Documents/a.pdf"), "noise filter")
    let now = Date()
    let a = ActivityEvent(date: now, kind: .created, path: "/x/a.txt", source: .spotlight)
    let b = ActivityEvent(date: now.addingTimeInterval(30), kind: .created, path: "/x/a.txt", source: .watcher)
    let c = ActivityEvent(date: now.addingTimeInterval(60), kind: .deleted, path: "/x/b.txt", source: .wayfile, timelineEntry: UUID())
    let d = ActivityEvent(date: now.addingTimeInterval(65), kind: .deleted, path: "/x/b.txt", source: .watcher)
    let merged = ActivityModel.merge([a, b, c, d])
    checkEqual(merged.count, 2, "duplicates across sources merged")
    check(merged.contains { $0.kind == .deleted && $0.timelineEntry != nil }, "Wayfile's undoable record wins")
    checkEqual(ActivityModel.filter(merged, by: .deleted, search: "").count, 1, "filter by kind")
    checkEqual(ActivityModel.filter(merged, by: .all, search: "a.txt").count, 1, "search")
    let calendar = Calendar.current
    let today = ActivityRange.today.interval(now: now)
    let at = { (h: Int) in calendar.date(bySettingHour: h, minute: 10, second: 0, of: now)! }
    let hist = ActivityModel.histogram([ActivityEvent(date: at(9), kind: .opened, path: "/1", source: .spotlight),
                                        ActivityEvent(date: at(9), kind: .opened, path: "/2", source: .spotlight),
                                        ActivityEvent(date: at(14), kind: .opened, path: "/3", source: .spotlight)], range: today)
    check(hist.count == 24 && hist[9] == 2 && hist[14] == 1, "hourly histogram")
    checkEqual(ActivityModel.histogram([], range: ActivityRange.last7Days.interval(now: now)).count, 7, "daily buckets for a week")
    let days = ActivityModel.days([a, ActivityEvent(date: now.addingTimeInterval(-86_400), kind: .opened, path: "/y", source: .spotlight)])
    check(days.count == 2 && days[0].date > days[1].date, "grouped by day, newest first")

    // Wayfile operations → events
    let entry = TimelineEntry(title: "Move", undoTitle: "Move", status: .completed,
                              record: .group([.moved([MovedItem(from: URL(fileURLWithPath: "/a/x.txt"), to: URL(fileURLWithPath: "/b/x.txt"))]),
                                              .moved([MovedItem(from: URL(fileURLWithPath: "/a/y.txt"), to: URL(fileURLWithPath: "/a/z.txt"))]),
                                              .trashed([TrashedItem(original: URL(fileURLWithPath: "/a/old.txt"), trashed: URL(fileURLWithPath: "/t/old.txt"))])]))
    let ops = ActivityModel.events(from: [entry])
    checkEqual(ops.map(\.kind), [.moved, .renamed, .deleted], "operations mapped (move, rename, trash)")
    check(ops.allSatisfy { $0.timelineEntry == entry.id }, "operations keep their undo entry")

    // Live recorder: raw FSEvents → activity
    let recorder = ActivityRecorder(fileURL: f.root.appendingPathComponent("activity.json"))
    let dir = f.root.appendingPathComponent("watched")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("doc.txt"), renamed = dir.appendingPathComponent("doc2.txt")
    try Data().write(to: file)
    let created = Int(kFSEventStreamEventFlagItemCreated), modified = Int(kFSEventStreamEventFlagItemModified)
    let removed = Int(kFSEventStreamEventFlagItemRemoved), renamedFlag = Int(kFSEventStreamEventFlagItemRenamed)
    recorder.handle([(file.path, created)], now: now)
    recorder.handle([(file.path, modified)], now: now.addingTimeInterval(10))
    recorder.handle([(file.path, modified)], now: now.addingTimeInterval(400))
    try FileManager.default.moveItem(at: file, to: renamed)
    recorder.handle([(file.path, renamedFlag), (renamed.path, renamedFlag)], now: now.addingTimeInterval(500))
    try FileManager.default.removeItem(at: renamed)
    recorder.handle([(renamed.path, removed)], now: now.addingTimeInterval(600))
    recorder.handle([(dir.appendingPathComponent(".DS_Store").path, created)], now: now)
    checkEqual(recorder.events.map(\.kind), [.created, .modified, .renamed, .deleted], "created, one modified per 5 min, renamed, deleted; noise ignored")
    checkEqual(recorder.events[2].fromPath, file.path, "rename keeps the old path")
    recorder.saveNow()
    checkEqual(ActivityRecorder(fileURL: f.root.appendingPathComponent("activity.json")).events.count, 4, "recorded activity persisted")
}

await testAsync("sidebar hiding") { _ in
    let suite = UserDefaults(suiteName: "wayfile.selftest.sidebar.hide")!
    suite.removePersistentDomain(forName: "wayfile.selftest.sidebar.hide")
    let config = SidebarConfig(defaults: suite)
    config.setItemHidden("smart:largeFiles", true)
    config.setItemHidden("vol:/Volumes/Backup", true)
    config.setVisible(.cloud, false)
    check(!config.lists("smart:largeFiles") && config.lists("smart:screenshots"), "hidden item not listed")
    check(!config.visibleSections.contains(.cloud), "hidden section not listed")
    checkEqual(config.hiddenCount, 3, "hidden count for the button")
    check(config.listsAny(["smart:largeFiles", "smart:screenshots"]) && !config.listsAny(["smart:largeFiles"]) && !config.listsAny([]), "section with every row hidden is not shown")
    config.revealHidden = true
    check(config.lists("smart:largeFiles") && config.isHidden("smart:largeFiles") && config.visibleSections.contains(.cloud), "revealing lists hidden ones (still marked hidden)")
    config.setItemHidden("smart:largeFiles", false)
    config.revealHidden = false
    check(config.lists("smart:largeFiles"), "shown again")
    let reloaded = SidebarConfig(defaults: suite)
    check(reloaded.isHidden("vol:/Volumes/Backup") && !reloaded.isHidden("smart:largeFiles") && !reloaded.revealHidden, "hidden items persisted, reveal is not")
    reloaded.reset()
    checkEqual(reloaded.hiddenCount, 0, "reset clears hidden items")
}

await testAsync("javascript api v1") { f in
    final class Lines: @unchecked Sendable {
        let lock = NSLock(); var items: [ScriptOutputLine] = []
        func add(_ l: ScriptOutputLine) { lock.withLock { items.append(l) } }
        var text: [String] { lock.withLock { items.map(\.text) } }
        func of(_ s: ScriptOutputLine.Stream) -> [String] { lock.withLock { items.filter { $0.stream == s }.map(\.text) } }
    }
    final class Calls: @unchecked Sendable { let lock = NSLock(); var items: [String] = []; func add(_ s: String) { lock.withLock { items.append(s) } } }
    let fm = FileManager.default
    let dir = f.root.appendingPathComponent("api")
    try fm.createDirectory(at: dir.appendingPathComponent("out"), withIntermediateDirectories: true)
    let abc = dir.appendingPathComponent("abc.txt")
    try Data("abc".utf8).write(to: abc)
    try Data("x".utf8).write(to: dir.appendingPathComponent("out/abc.txt"))
    // A real 3×2 PNG for image metadata.
    let png = dir.appendingPathComponent("dot.png")
    let ctx = CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let destination = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
    _ = CGImageDestinationFinalize(destination)

    func run(_ source: String, permissions: String = "read, write", selection: [URL] = [], dryRun: Bool = false, ui: ScriptUI? = nil) async throws -> (ScriptResult, Lines) {
        let url = f.root.appendingPathComponent("t-\(UUID().uuidString).js")
        try "// @permissions \(permissions)\n\(source)".write(to: url, atomically: true, encoding: .utf8)
        let lines = Lines()
        let script = try Script.load(url).unwrap("script")
        let result = try await ScriptRunner.run(script, context: ScriptContext(selection: selection, folder: dir, dryRun: dryRun, ui: ui), progress: OperationProgress(), output: lines.add)
        return (result, lines)
    }

    var (result, lines) = try await run("console.log(wayfile.version, wayfile.count, wayfile.items[0].name, wayfile.items[0].size, wayfile.items[0].isDirectory)", selection: [abc])
    checkEqual(lines.of(.stdout), ["\(ScriptAPI.version) 1 abc.txt 3 false"], "selection items with attributes")
    (result, lines) = try await run("console.log(wayfile.checksum('abc.txt'), wayfile.checksum('abc.txt', 'md5'))")
    checkEqual(lines.of(.stdout), ["ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad 900150983cd24fb0d6963f7d28e17f72"], "checksums")
    (result, lines) = try await run("const m = wayfile.metadata('dot.png'); console.log(m.image.width, m.image.height, m.uti, Array.isArray(m.tags))", permissions: "metadata")
    checkEqual(lines.of(.stdout), ["3 2 public.png true"], "image metadata (\(lines.text))")
    (result, lines) = try await run("wayfile.metadata('abc.txt')", permissions: "write")
    check(result.status == 1 && lines.of(.stderr).first?.contains("metadata") == true, "metadata needs its permission")
    (result, lines) = try await run("console.log({a: 1, b: [2]})")
    checkEqual(lines.of(.stdout), [#"{"a":1,"b":[2]}"#], "objects logged as JSON")

    // transfer through the copy engine: conflict policies, dry run shows clashes
    (result, lines) = try await run("wayfile.transfer(['abc.txt', 'dot.png'], 'out', {mode: 'copy', conflict: 'skip'})", dryRun: true)
    check(lines.of(.info).contains { $0.contains("skip abc.txt") } && lines.of(.info).contains { $0.contains("copy dot.png") }, "dry run reports the clash (\(lines.text))")
    check(!fm.fileExists(atPath: dir.appendingPathComponent("out/dot.png").path), "dry run copies nothing")
    var plan = lines.items.compactMap(\.plan)
    checkEqual(plan.map(\.action), [.skip, .copy], "dry run plan steps")
    check(plan[0].conflict != nil && plan[1].conflict == nil, "plan marks the clash")
    (result, lines) = try await run("wayfile.rename('abc.txt', 'dot.png'); wayfile.writeText('abc.txt', 'x'); wayfile.writeText('new.txt', 'y'); wayfile.trash('dot.png'); wayfile.tag('abc.txt', 'Red')", permissions: "write, delete", dryRun: true)
    plan = lines.items.compactMap(\.plan)
    checkEqual(plan.map(\.action), [.rename, .write, .create, .trash, .tag], "plan covers each kind of change")
    check(plan[0].conflict?.contains("already exists") == true && plan[1].conflict != nil && plan[2].conflict == nil, "rename clash and overwrite flagged")
    check(ScriptPlanStep.summary(plan).map { "\($0.action.rawValue)\($0.count)" } == ["create1", "write1", "rename1", "tag1", "trash1"], "plan summary")
    checkEqual(plan[0].sentence, "Would rename abc.txt → dot.png (“dot.png” already exists)", "plan sentence for the console")
    checkEqual(try String(contentsOf: abc, encoding: .utf8), "abc", "dry run touched nothing")
    (result, lines) = try await run("wayfile.transfer(['abc.txt', 'dot.png'], 'out', {mode: 'copy', conflict: 'skip'})")
    checkEqual(try String(contentsOf: dir.appendingPathComponent("out/abc.txt"), encoding: .utf8), "x", "skip kept the existing file")
    check(fm.fileExists(atPath: dir.appendingPathComponent("out/dot.png").path), "transfer copied")
    (result, lines) = try await run("wayfile.transfer('abc.txt', 'out', {conflict: 'replace'})")
    check(result.status == 1 && lines.of(.stderr).first?.contains("delete") == true, "replace needs the delete permission (\(lines.text))")

    // errors carry their line; async scripts and their results
    (result, lines) = try await run("const a = 1\nnull.x\n")
    check(result.errorLine == 3 && lines.of(.stderr).first?.hasPrefix("Line 3:") == true, "error line reported (got \(String(describing: result.errorLine)) \(lines.text))")
    (result, lines) = try await run("async function main() { wayfile.sleep(5); return ['/tmp'] }\nmain()")
    check(result.status == 0 && result.outputPaths.map(\.path) == ["/tmp"], "async script result (\(lines.text))")
    (result, lines) = try await run("async function main() { throw new Error('nope') }\nmain()")
    check(result.status == 1 && lines.of(.stderr).first?.contains("nope") == true, "async rejection is an error")

    // dialogs / panel need a window; with one, calls reach it
    (result, lines) = try await run("wayfile.dialogs.confirm('Sure?')")
    check(result.status == 1 && lines.of(.stderr).first?.contains("needs a window") == true, "dialogs refused in automatic runs")
    let calls = Calls()
    let ui = ScriptUI(open: { calls.add("open " + $0.lastPathComponent) }, refresh: { calls.add("refresh") }, select: { calls.add("select \($0.count)") },
                      workspaces: { ["Work"] }, openWorkspace: { calls.add("ws " + $0); return $0 == "Work" })
    (result, lines) = try await run("wayfile.panel.open('out'); wayfile.panel.select(['out/dot.png']); wayfile.panel.refresh(); console.log(wayfile.workspaces.list().join(), wayfile.workspaces.open('Work'))", ui: ui)
    checkEqual(calls.items, ["open out", "select 1", "refresh", "ws Work"], "panel and workspace calls reach the window (\(lines.text))")
    checkEqual(lines.of(.stdout), ["Work true"], "workspace results")
    (result, lines) = try await run("wayfile.fetch('https://example.com')")
    check(result.status == 1 && lines.of(.stderr).first?.contains("network") == true, "fetch needs the network permission")

    // syntax check and completion
    checkEqual(JSScriptHost.checkSyntax("let ok = 1")?.message, nil, "valid syntax")
    checkEqual(JSScriptHost.checkSyntax("let x = 1\nlet y = (")?.line, 2, "syntax error line")
    checkEqual(ScriptAPI.completions(for: "wayfile.dia").map(\.insertion), ["dialogs."], "namespace completion")
    checkEqual(Set(ScriptAPI.completions(for: "wayfile.dialogs.c").map(\.insertion)), ["confirm(", "chooseFile("], "member completion")
    check(ScriptAPI.completions(for: "wayfile.").contains { $0.name == "selection" } && ScriptAPI.completions(for: "wayfile.").contains { $0.name == "panel" }, "top-level completion")
    let docs = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../docs/Scripting.md"), encoding: .utf8)) ?? ""
    let undocumented = ScriptAPI.members.filter { !docs.contains("`\($0.name)") }.map(\.name)
    checkEqual(undocumented, [], "every API member is in docs/Scripting.md (run scripts/gen-scripting-docs.py)")
}

await testAsync("code editor: highlighting, indent, syntax check") { _ in
    func kinds(_ text: String, _ language: Script.Language) -> [String] {
        SyntaxHighlighter.tokens(text, language: language).map { "\($0.kind):\((text as NSString).substring(with: $0.range))" }
    }
    checkEqual(kinds("// @name X\nconst a = 'hi' // c\nwayfile.dialogs.confirm(2)", .javascript),
               ["comment:// @name X", "annotation:@name", "keyword:const", "string:'hi'", "comment:// c", "api:wayfile.dialogs.confirm", "number:2"], "javascript tokens")
    checkEqual(kinds("echo \"$# ${HOME}\" # done\nfor f in \"$@\"; do", .zsh),
               ["keyword:echo", "string:\"$# ${HOME}\"", "comment:# done", "keyword:for", "keyword:in", "string:\"$@\"", "keyword:do"], "shell tokens; $# is not a comment")
    checkEqual(kinds("x = $HOME", .bash), ["api:$HOME"], "shell variable")
    checkEqual(kinds("def f():\n    return \"\"\"a\nb\"\"\"", .python), ["keyword:def", "keyword:return", "string:\"\"\"a\nb\"\"\""], "python tokens with a triple-quoted string")
    checkEqual(kinds("obj.const", .javascript), [], "a property named like a keyword isn't one")
    checkEqual(kinds("/* a\nb */ 1", .javascript), ["comment:/* a\nb */", "number:1"], "block comment")

    checkEqual(CodeIndent.indent(after: "  if (x) {", language: .javascript), "    ", "indent after {")
    checkEqual(CodeIndent.indent(after: "  x = 1", language: .javascript), "  ", "keep indent")
    checkEqual(CodeIndent.indent(after: "def f():", language: .python), "    ", "python block")
    checkEqual(CodeIndent.indent(after: "for f in \"$@\"; do", language: .zsh), "  ", "shell do")
    checkEqual(CodeIndent.indent(after: "tell application \"Finder\"", language: .applescript), "\t", "applescript tell")

    checkEqual(ScriptLinter.parse("bash: -c: line 3: syntax error near unexpected token `fi'", language: .bash), ScriptLinter.Problem(message: "syntax error near unexpected token `fi'", line: 3), "bash error line")
    checkEqual(ScriptLinter.parse("zsh:4: parse error near `done'", language: .zsh)?.line, 4, "zsh error line")
    checkEqual(ScriptLinter.parse("2:invalid syntax", language: .python), ScriptLinter.Problem(message: "invalid syntax", line: 2), "python error line")
    checkEqual(ScriptLinter.line(fromConsole: "Line 12: TypeError: x"), 12, "runtime error line from the console")
    let zsh = await ScriptLinter.check("for f in a; do\n  echo $f\n", language: .zsh)
    check(zsh?.line != nil, "zsh -n finds the missing done (\(String(describing: zsh)))")
    let fine = await ScriptLinter.check("echo ok\n", language: .bash)
    checkEqual(fine, nil, "valid shell passes")
    let py = await ScriptLinter.check("x = 1\ndef (:\n", language: .python)
    checkEqual(py?.line, 2, "python syntax error line")
    let js = await ScriptLinter.check("let a = 1\nlet = ;", language: .javascript)
    checkEqual(js?.line, 2, "javascript syntax error line")
}

test("script versions") { f in
    let script = f.root.appendingPathComponent("v.js")
    try "// @version 1.0\none".write(to: script, atomically: true, encoding: .utf8)
    checkEqual(Script.load(script)?.version, "1.0", "@version parsed")
    try ScriptVersions.save("two", to: script)
    try ScriptVersions.save("two", to: script)
    checkEqual(ScriptVersions.list(for: script).count, 1, "saving the same text keeps no extra version")
    try ScriptVersions.save("three", to: script)
    let versions = ScriptVersions.list(for: script)
    checkEqual(versions.compactMap { try? String(contentsOf: $0.url, encoding: .utf8) }, ["two", "// @version 1.0\none"], "versions newest first")
    try ScriptVersions.restore(versions[1], to: script)
    checkEqual(try String(contentsOf: script, encoding: .utf8), "// @version 1.0\none", "restored")
    checkEqual(try String(contentsOf: ScriptVersions.list(for: script)[0].url, encoding: .utf8), "three", "restoring keeps the replaced text")
    checkEqual(ScriptLibrary.scripts(in: f.root).map(\.name), ["v"], "versions folder isn't listed as scripts")
    for i in 0..<(ScriptVersions.limit + 3) { try ScriptVersions.keep("text \(i)", for: script, now: Date().addingTimeInterval(Double(i))) }
    checkEqual(ScriptVersions.list(for: script).count, ScriptVersions.limit, "old versions pruned")
}

test("script shortcuts, pinning and @after") { f in
    checkEqual(ScriptShortcut("cmd+shift+L")?.display, "⇧⌘L", "shortcut parsed")
    checkEqual(ScriptShortcut("⌃⌥f5"), ScriptShortcut(key: "f5", modifiers: [.control, .option]), "symbols and function keys")
    checkEqual(ScriptShortcut("shift+L"), nil, "needs ⌘ or ⌃")
    checkEqual(ScriptShortcut("cmd+hyper+L"), nil, "unknown modifier")
    checkEqual(ScriptShortcut("cmd+LL"), nil, "one key only")
    let shortcut = ScriptShortcut("cmd+shift+l")!
    check(shortcut.matches(characters: "L", keyCode: 37, modifiers: [.command, .shift]), "matches the key press")
    check(!shortcut.matches(characters: "l", keyCode: 37, modifiers: [.command]), "modifiers must match exactly")
    check(ScriptShortcut("ctrl+f5")!.matches(characters: nil, keyCode: 96, modifiers: [.control]), "function key by key code")

    let script = try Script(url: f.root.appendingPathComponent("p.js"), text: "// @menu pin\n// @shortcut cmd+shift+P\n// @after copy, move, bogus\n// @extensions jpg\nx").unwrap("script")
    check(script.pinned && script.showInMenu, "@menu pin")
    checkEqual(script.after, [.copy, .move], "@after parsed (unknown ignored)")
    checkEqual(script.shortcut?.display, "⇧⌘P", "@shortcut parsed")
    let jpg = f.root.appendingPathComponent("a.jpg"), txt = f.root.appendingPathComponent("b.txt")
    try Data().write(to: jpg)
    try Data().write(to: txt)
    let events = [ActivityEvent(date: Date(), kind: .copied, path: jpg.path, source: .wayfile),
                  ActivityEvent(date: Date(), kind: .copied, path: txt.path, source: .wayfile),
                  ActivityEvent(date: Date(), kind: .deleted, path: "/gone/c.jpg", source: .wayfile)]
    checkEqual(script.afterInput(events).map(\.lastPathComponent), ["a.jpg"], "@after takes matching kinds and types")
    var trash = script
    trash.after = [.trash]
    checkEqual(trash.afterInput(events).map(\.path), ["/gone/c.jpg"], "trashed items by original path")
    trash.after = [.rename]
    checkEqual(trash.afterInput(events), [], "nothing for other operations")
}

test("script packages") { f in
    let src = f.root.appendingPathComponent("Tidy Up.js")
    let text = "// @name Tidy Up\n// @version 1.3\n// @description Sorts things\n// @permissions read, write\n// @extensions pdf\n// @after copy\n// @trigger ~/Downloads\nwayfile.log(1)\n"
    try text.write(to: src, atomically: true, encoding: .utf8)
    let data = try ScriptPackage.export(try Script.load(src).unwrap("script"))
    let (package, script) = try ScriptPackage.read(data)
    checkEqual(package.manifest.name, "Tidy Up", "manifest name")
    checkEqual(package.manifest.version, "1.3", "manifest version")
    checkEqual(package.manifest.permissions, ["read", "write"], "manifest permissions")
    checkEqual(package.manifest.triggers, ["New files in ~/Downloads", "After copy"], "triggers listed with a home-relative path")
    checkEqual(package.source, text, "source kept verbatim")
    checkEqual(script.after, [.copy], "script parsed from the source")

    let folder = f.root.appendingPathComponent("lib")
    let first = try ScriptPackage.install(package, language: .javascript, in: folder)
    let second = try ScriptPackage.install(package, language: .javascript, in: folder)
    check(first != second && first.lastPathComponent == "Tidy Up.js", "install keeps existing scripts (\(second.lastPathComponent))")

    // Tampering and bad input
    var tampered = package
    tampered.manifest.permissions = ["read"]
    checkThrows(ScriptPackage.PackageError.self, "manifest hiding a permission") { _ = try ScriptPackage.read(try JSONEncoder().encode(tampered)) }
    var newer = package
    newer.format = ScriptPackage.format + 1
    checkThrows(ScriptPackage.PackageError.self, "newer format refused") { _ = try ScriptPackage.read(try JSONEncoder().encode(newer)) }
    var future = package
    future.manifest.minAPIVersion = "9.0"
    checkThrows(ScriptPackage.PackageError.self, "needs a newer API") { _ = try ScriptPackage.read(try JSONEncoder().encode(future)) }
    checkThrows(ScriptPackage.PackageError.self, "garbage refused") { _ = try ScriptPackage.read(Data("nope".utf8)) }
    checkEqual(ScriptPackage.safeFileName("../../.ssh/evil.sh", language: .zsh), "evil.zsh", "file name stays inside the Scripts folder")
    checkEqual(ScriptPackage.safeFileName("...", language: .javascript), "Imported Script.js", "empty name replaced")
    checkEqual(ScriptPackage.compare("1.10", "1.2"), .orderedDescending, "numeric version compare")
    checkEqual(ScriptPackage.compare("1.0", "1"), .orderedSame, "missing parts are zero")
}

await testAsync("javascript isolation") { f in
    let fm = FileManager.default
    func script(_ body: String, permissions: String = "read") throws -> Script {
        let url = f.root.appendingPathComponent("iso-\(UUID().uuidString).js")
        try "// @permissions \(permissions)\n\(body)".write(to: url, atomically: true, encoding: .utf8)
        return try Script.load(url).unwrap("script")
    }
    final class Lines: @unchecked Sendable { let lock = NSLock(); var items: [ScriptOutputLine] = []; func add(_ l: ScriptOutputLine) { lock.withLock { items.append(l) } }
        var text: [String] { lock.withLock { items.map(\.text) } } }
    check(JSScriptHost.isIsolated, "tests run through the sandboxed runner")

    // Stop ends even an endless loop (the runner process is terminated).
    let progress = OperationProgress()
    let loop = try script("while (true) {}")
    let started = Date()
    let task = Task { try await ScriptRunner.run(loop, context: ScriptContext(selection: [], folder: f.root), progress: progress, output: { _ in }) }
    try await Task.sleep(for: .milliseconds(400))
    progress.cancel()
    let stopped: Bool
    do { _ = try await task.value; stopped = false } catch is CancellationError { stopped = true } catch { stopped = false }
    check(stopped && Date().timeIntervalSince(started) < 3, "endless loop stopped (\(Date().timeIntervalSince(started)) s)")

    // Stop in the console cancels the caller's task; it must reach scripts running inside an operation.
    for (name, body) in [("js loop", "while (true) {}"), ("shell sleep", "")] {
        let target: Script
        if body.isEmpty {
            let url = f.root.appendingPathComponent("sleepy.sh")
            try "#!/bin/sh\nsleep 30\n".write(to: url, atomically: true, encoding: .utf8)
            target = try Script.load(url).unwrap("sh")
        } else {
            target = try script(body)
        }
        let begin = Date()
        let op = Task { @MainActor in
            try await OperationCenter.shared.run("Script: test", undoTitle: "Script") { progress in
                _ = try await ScriptRunner.run(target, context: ScriptContext(selection: [], folder: f.root), progress: progress, output: { _ in })
                return []
            }
        }
        try await Task.sleep(for: .milliseconds(500))
        op.cancel()
        _ = try? await op.value
        check(Date().timeIntervalSince(begin) < 3, "Stop reaches the \(name) inside an operation (\(Date().timeIntervalSince(begin)) s)")
    }

    // The bridge isn't reachable from scripts; only wayfile / console are.
    var lines = Lines()
    var result = try await ScriptRunner.run(try script("console.log(typeof __call, typeof __log, typeof wayfile.copy, typeof require, typeof process)"),
                                            context: ScriptContext(selection: [], folder: f.root), progress: OperationProgress(), output: lines.add)
    checkEqual(lines.text, ["undefined undefined function undefined undefined"], "bridge hidden (\(result.status))")

    // Unknown API names are refused by the host.
    lines = Lines()
    result = try await ScriptRunner.run(try script("wayfile.copy.call(null); "), context: ScriptContext(selection: [], folder: f.root), progress: OperationProgress(), output: lines.add)
    check(result.status == 1, "API errors surface as script errors (\(lines.text))")

    // Same script in-process gives the same result.
    let file = f.root.appendingPathComponent("iso.txt")
    try Data("hello".utf8).write(to: file)
    let read = try script("wayfile.log(wayfile.readText('iso.txt').toUpperCase()); ['iso.txt']")
    lines = Lines()
    result = try await ScriptRunner.run(read, context: ScriptContext(selection: [], folder: f.root), progress: OperationProgress(), output: lines.add)
    let isolated = (lines.text, result.outputPaths.map(\.lastPathComponent))
    setenv("WAYFILE_SCRIPT_RUNNER", "none", 1)
    check(!JSScriptHost.isIsolated, "runner can be switched off")
    lines = Lines()
    result = try await ScriptRunner.run(read, context: ScriptContext(selection: [], folder: f.root), progress: OperationProgress(), output: lines.add)
    let inProcess = (lines.text, result.outputPaths.map(\.lastPathComponent))
    check(isolated == inProcess && isolated.0 == ["HELLO"], "isolated and in-process agree (\(isolated) / \(inProcess))")
    // A missing runner is reported, not hung on.
    setenv("WAYFILE_SCRIPT_RUNNER", f.root.appendingPathComponent("missing-runner").path, 1)
    await checkThrowsAsync("missing runner throws") { _ = try await ScriptRunner.run(read, context: ScriptContext(selection: [], folder: f.root), progress: OperationProgress(), output: { _ in }) }
    if let runner = ProcessInfo.processInfo.environment["WAYFILE_SELFTEST_RUNNER"] { setenv("WAYFILE_SCRIPT_RUNNER", runner, 1) }
    _ = fm
}

await testAsync("plugins with an interface") { f in
    let fm = FileManager.default
    let dir = f.root.appendingPathComponent("plug")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, size) in [("a.jpg", 3000), ("b.jpg", 1000), ("c.txt", 500)] { try Data(count: size).write(to: dir.appendingPathComponent(name)) }
    let scripts = f.root.appendingPathComponent("pluginlib")
    for example in ScriptExamples.all where example.text.contains("@panel") { try ScriptExamples.install(example, in: scripts) }
    let insights = try Script.load(scripts.appendingPathComponent("Selection Insights.js")).unwrap("insights")
    let studio = try Script.load(scripts.appendingPathComponent("Rename Studio.js")).unwrap("studio")
    checkEqual(insights.panel, .inspector, "@panel inspector")
    checkEqual(studio.panel, .window, "@panel window")
    checkEqual(Script(url: URL(fileURLWithPath: "/x.sh"), text: "# @panel window\n")?.panel, nil, "only JavaScript can be a plugin")

    final class Lines: @unchecked Sendable { let lock = NSLock(); var items: [String] = []; func add(_ l: ScriptOutputLine) { lock.withLock { items.append(l.text) } } }
    func texts(_ node: PluginNode) -> [String] { [node.string("text"), node.string("title"), node.string("label")].compactMap { $0 } + node.children.flatMap(texts) }

    for mode in ["runner", "in-process"] {
        if mode == "in-process" { setenv("WAYFILE_SCRIPT_RUNNER", "none", 1) }
        let lines = Lines()
        let session = ScriptSession(script: insights)
        let context = ScriptContext(selection: [dir], folder: f.root)
        let loaded = try await session.start(context: context, output: lines.add)
        if case .failure(let message, _) = loaded { check(false, "\(mode): plugin loads (\(message))") }
        let ctx = JSScriptHost.engineContext(for: context)["values"] as? [String: Any] ?? [:]
        var outcome = try await session.invoke("render", args: [ctx], context: context, progress: OperationProgress(), output: lines.add)
        guard case .success(let value) = outcome, let node = PluginNode(value) else { check(false, "\(mode): render returns a node (\(outcome))"); continue }
        check(texts(node).contains("3 files") && texts(node).contains("JPG"), "\(mode): rendered from the folder (\(texts(node)))")
        var form = PluginFormState()
        form.adopt(node)
        checkEqual(form.text("tag"), "Review", "\(mode): text field value from render")
        // A button: action changes files (recorded for undo) and the plugin's own state, shown by the next render.
        form.set("tag", "Checked")
        let progress = OperationProgress()
        outcome = try await session.invoke("action", args: ["tag", form.values, ctx], context: context, progress: progress, output: lines.add)
        if case .failure(let message, _) = outcome { check(false, "\(mode): action ran (\(message))") }
        check(TagIO.read(dir).contains { $0.name == "Checked" } && UndoRecord.combine(progress.records) != nil, "\(mode): action tagged, undoable")
        outcome = try await session.invoke("render", args: [ctx], context: context, progress: OperationProgress(), output: lines.add)
        if case .success(let value) = outcome, let again = PluginNode(value) {
            check(texts(again).contains { $0.contains("Tagged 1 item") }, "\(mode): plugin state kept between calls")
        }
        outcome = try await session.invoke("missing", args: [], context: context, progress: OperationProgress(), output: lines.add)
        if case .failure(let message, _) = outcome { check(message.contains("doesn't define missing()"), "\(mode): missing function reported") }
        session.close()
        try TagIO.write([], to: dir)
    }
    if let runner = ProcessInfo.processInfo.environment["WAYFILE_SELFTEST_RUNNER"] { setenv("WAYFILE_SCRIPT_RUNNER", runner, 1) }

    // Node parsing and form state
    let tree: [String: Any] = ["type": "vstack", "children": [["type": "textField", "id": "q", "value": "a"], ["type": "toggle", "id": "t", "title": "T", "value": true],
                                                              ["type": "picker", "id": "p", "title": "P", "options": ["x", "y"]], ["type": "wat"]]]
    let node = try PluginNode(tree).unwrap("node")
    checkEqual(node.children.map(\.id), ["0.0", "0.1", "0.2", "0.3"], "positional ids")
    check(node.children[3].kind == nil, "unknown element kept (shown as a note)")
    var form = PluginFormState()
    form.adopt(node)
    check(form.text("q") == "a" && form.flag("t") && form.text("p") == "x", "form starts from rendered values")
    form.set("q", "typed")
    form.adopt(node)
    checkEqual(form.text("q"), "typed", "typing survives a re-render")
    let changed = try PluginNode(["type": "textField", "id": "q", "value": ""] as [String: Any]).unwrap("n")
    form.adopt(changed)
    checkEqual(form.text("q"), "", "a new value from the plugin replaces it")
    checkEqual(JSScriptHost.checkSyntax(ScriptLibrary.pluginSkeleton(name: "P", panel: .window))?.message, nil, "plugin template parses")
}

await testAsync("javascript api 1.1 and more plugins") { f in
    let fm = FileManager.default
    setenv("WAYFILE_SCRIPT_DATA_DIR", f.root.appendingPathComponent("data").path, 1)
    let dir = f.root.appendingPathComponent("api11")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    func png(_ name: String, _ w: Int, _ h: Int, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
        _ = CGImageDestinationFinalize(destination)
        return url
    }
    final class Lines: @unchecked Sendable { let lock = NSLock(); var items: [ScriptOutputLine] = []; func add(_ l: ScriptOutputLine) { lock.withLock { items.append(l) } }
        var text: [String] { lock.withLock { items.map(\.text) } } }
    func run(_ source: String, permissions: String = "read, write", name: String = UUID().uuidString, dryRun: Bool = false) async throws -> (ScriptResult, Lines) {
        let url = f.root.appendingPathComponent("\(name).js")
        try "// @permissions \(permissions)\n\(source)".write(to: url, atomically: true, encoding: .utf8)
        let lines = Lines()
        let result = try await ScriptRunner.run(try Script.load(url).unwrap("s"), context: ScriptContext(selection: [], folder: dir, dryRun: dryRun), progress: OperationProgress(), output: lines.add)
        return (result, lines)
    }

    // storage: per script, survives runs
    var (result, lines) = try await run("wayfile.storage.set('n', {a: [1, 2]}); wayfile.storage.set('x', 1); wayfile.storage.remove('x')", name: "keeper")
    (result, lines) = try await run("console.log(JSON.stringify(wayfile.storage.get('n')), wayfile.storage.keys().join(), wayfile.storage.get('missing'))", name: "keeper")
    checkEqual(lines.text, [#"{"a":[1,2]} n null"#], "storage kept between runs (\(result.status))")
    (result, lines) = try await run("console.log(wayfile.storage.keys().length)", name: "other")
    checkEqual(lines.text, ["0"], "storage is per script")
    (result, lines) = try await run("wayfile.storage.set('big', 'x'.repeat(1100000))", name: "keeper")
    check(result.status == 1 && lines.text.first?.contains("full") == true, "storage limit")

    // images
    let photo = try png("photo.png", 300, 200, in: dir)
    (result, lines) = try await run("console.log(wayfile.images.formats().join())")
    check(lines.text.first?.contains("jpeg") == true && lines.text.first?.contains("png") == true, "writable formats (\(lines.text))")
    (result, lines) = try await run("wayfile.images.convert('photo.png', {format: 'jpg', maxSize: 120, toFolder: 'out'})", dryRun: true)
    check(lines.items.compactMap(\.plan).first?.action == .create && !fm.fileExists(atPath: dir.appendingPathComponent("out").path), "convert dry run plans only")
    (result, lines) = try await run("wayfile.images.convert(['photo.png'], {format: 'jpeg', maxSize: 120, quality: 0.6, toFolder: 'out'})")
    let jpg = dir.appendingPathComponent("out/photo-120.jpg")
    let made = CGImageSourceCreateWithURL(jpg as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
    check(result.status == 0 && made?[kCGImagePropertyPixelWidth] as? Int == 120 && made?[kCGImagePropertyPixelHeight] as? Int == 80, "resized copy (\(lines.text))")
    check(fm.fileExists(atPath: photo.path), "original kept")
    (result, lines) = try await run("wayfile.images.convert('photo.png', {format: 'bmp'})")
    check(result.status == 1, "unknown format refused")
    (result, lines) = try await run("wayfile.images.convert('photo.png', {format: 'png'})", permissions: "read")
    check(result.status == 1 && lines.text.first?.contains("write") == true, "convert needs write")

    // git (read-only)
    let repo = f.root.appendingPathComponent("repo")
    try fm.createDirectory(at: repo, withIntermediateDirectories: true)
    _ = await Shell.run("/usr/bin/git", ["-C", repo.path, "init", "-q", "-b", "main"])
    try "x".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
    (result, lines) = try await run("const s = wayfile.git.status('\(repo.path)'); console.log(s.branch, s.changes.map(c => c.path + ':' + c.status).join())")
    checkEqual(lines.text, ["main new.txt:untracked"], "git status (\(lines.text))")
    (result, lines) = try await run("console.log(wayfile.git.status('\(f.root.path)'))")
    checkEqual(lines.text, ["null"], "git status outside a repository")
    (result, lines) = try await run("wayfile.open('https://example.com')")
    check(result.status == 1 && lines.text.first?.contains("needs a window") == true, "open needs a window")

    // The new example plugins
    let lib = f.root.appendingPathComponent("lib11")
    for example in ScriptExamples.all where example.text.contains("@panel") { try ScriptExamples.install(example, in: lib) }
    func node(_ name: String, _ context: ScriptContext, action: String? = nil, values: [String: Any] = [:]) async throws -> PluginNode? {
        let session = ScriptSession(script: try Script.load(lib.appendingPathComponent(name)).unwrap(name))
        defer { session.close() }
        _ = try await session.start(context: context, output: { _ in })
        var ctx = JSScriptHost.engineContext(for: context)["values"] as? [String: Any] ?? [:]
        ctx["values"] = values
        if let action {
            let progress = OperationProgress()
            let outcome = try await session.invoke("action", args: [action, values, ctx], context: context, progress: progress, output: { _ in })
            if case .failure(let message, _) = outcome { check(false, "\(name) action failed: \(message)") }
        }
        let outcome = try await session.invoke("render", args: [ctx], context: context, progress: OperationProgress(), output: { _ in })
        if case .failure(let message, let line) = outcome { check(false, "\(name) render failed: \(message) line \(line ?? 0)"); return nil }
        if case .success(let value) = outcome { return PluginNode(value) }
        return nil
    }
    func texts(_ node: PluginNode?) -> String {
        guard let node else { return "" }
        return ([node.string("text"), node.string("title"), node.string("label"), node.string("value")].compactMap { $0 }
            + node.listItems.map(\.title) + node.children.map(texts)).joined(separator: " | ")
    }
    let photoInfo = try await node("Photo Info.js", ScriptContext(selection: [photo], folder: dir))
    check(texts(photoInfo).contains("No camera data") && texts(photoInfo).contains("300 × 200"), "Photo Info renders (\(texts(photoInfo)))")

    let dupes = f.root.appendingPathComponent("dupes")
    try fm.createDirectory(at: dupes, withIntermediateDirectories: true)
    for name in ["a.txt", "copy of a.txt", "b.txt"] { try (name == "b.txt" ? "different" : "same text").write(to: dupes.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    let dupeContext = ScriptContext(selection: [dupes], folder: f.root)
    let before = try await node("Duplicate Check.js", dupeContext)
    check(texts(before).contains("3 files"), "Duplicate Check summary (\(texts(before)))")
    let scanned = try await node("Duplicate Check.js", dupeContext, action: "scan")
    check(texts(scanned).contains("1 set of duplicates") && texts(scanned).contains("Move 1 Extra Copy to Trash"), "Duplicate Check finds the copy (\(texts(scanned)))")

    let cluttered = f.root.appendingPathComponent("cluttered")
    try fm.createDirectory(at: cluttered, withIntermediateDirectories: true)
    try Data().write(to: cluttered.appendingPathComponent("Setup.dmg"))
    try Data().write(to: cluttered.appendingPathComponent("fresh.txt"))
    let cleanup = try await node("Folder Cleanup.js", ScriptContext(selection: [], folder: cluttered))
    check(texts(cleanup).contains("Setup.dmg") && !texts(cleanup).contains("fresh.txt") && texts(cleanup).contains("Move 1 to Trash"), "Folder Cleanup lists the installer (\(texts(cleanup)))")
    _ = try await node("Folder Cleanup.js", ScriptContext(selection: [], folder: cluttered), action: "settings", values: ["installers": false, "age": "1 year"])
    let remembered = try await node("Folder Cleanup.js", ScriptContext(selection: [], folder: cluttered))
    check(!texts(remembered).contains("Setup.dmg"), "Folder Cleanup remembers its settings")

    let converted = try await node("Image Converter.js", ScriptContext(selection: [photo], folder: dir), action: "convert", values: ["format": "png", "size": "800", "subfolder": true])
    check(fm.fileExists(atPath: dir.appendingPathComponent("Converted/photo-800.png").path) && texts(converted).contains("Made 1"), "Image Converter converts (\(texts(converted)))")
    unsetenv("WAYFILE_SCRIPT_DATA_DIR")
}

test("script run log") { f in
    let url = f.root.appendingPathComponent("runs.json")
    let log = ScriptRunLog(fileURL: url)
    let a = ScriptRunRecord(scriptName: "Resize", scriptPath: "/s/resize.js", language: "JavaScript", trigger: "Manual", dryRun: false)
    let b = ScriptRunRecord(scriptName: "Resize", scriptPath: "/s/resize.js", language: "JavaScript", trigger: "Manual", dryRun: true)
    log.start(a)
    log.start(b)
    log.finish(b.id, outcome: .succeeded, output: [ScriptOutputLine(stream: .stdout, text: "ok"), ScriptOutputLine(stream: .stderr, text: "warn")],
               changedPaths: ["/tmp/x.jpg"])
    checkEqual(log.record(b.id)?.output ?? [], ["ok", "! warn"], "stderr marked in the stored output")
    checkEqual(log.record(b.id)?.statusTitle, "Simulated", "a successful dry run shows as simulated")
    log.saveNow()
    // `a` never finished — as if Wayfile crashed meanwhile.
    let reloaded = ScriptRunLog(fileURL: url)
    checkEqual(reloaded.record(a.id)?.outcome, .interrupted, "unfinished run is interrupted after relaunch")
    check(reloaded.record(a.id)?.finished != nil, "interrupted run gets an end time")
    checkEqual(reloaded.runs(of: "/s/resize.js").count, 2, "runs per script")
    let long = Array(repeating: String(repeating: "x", count: 900), count: 300)
    let capped = ScriptRunLog.capped(long)
    check(capped.count == ScriptRunLog.outputLines && capped[0].count == ScriptRunLog.lineLength + 1, "output tail capped in lines and length")

    // Timeline: each run is its own event (no merging), with a Scripts filter.
    let events = ActivityModel.events(from: reloaded.records)
    let merged = ActivityModel.merge(events + [ActivityEvent(date: Date(), kind: .created, path: "/tmp/x.jpg", source: .wayfile)])
    checkEqual(merged.filter { $0.kind == .script }.count, 2, "two runs of one script in a minute both listed")
    checkEqual(ActivityModel.filter(merged, by: .scripts, search: "").count, 2, "Scripts filter shows only runs")
    check(events.allSatisfy { $0.scriptRun != nil }, "events link to their run")
}

print(failures == 0 ? "\n✓ all \(checks) checks passed" : "\n✗ \(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
