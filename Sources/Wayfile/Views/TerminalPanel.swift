import AppKit
import Darwin
import SwiftTerm
import SwiftUI

/// A shell profile for the integrated terminal.
struct TerminalProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var shell: String
    /// Typed once the shell starts (e.g. "source venv/bin/activate").
    var startupCommand = ""
    var fontSize: Double = 12

    static var systemDefault: TerminalProfile {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return TerminalProfile(name: (shell as NSString).lastPathComponent, shell: shell)
    }
}

@MainActor
@Observable
final class TerminalProfiles {
    static let shared = TerminalProfiles()
    var profiles: [TerminalProfile] { didSet { save() } }

    private init() {
        profiles = UserDefaults.standard.data(forKey: "terminal.profiles").flatMap { try? JSONDecoder().decode([TerminalProfile].self, from: $0) } ?? []
        if profiles.isEmpty { profiles = [.systemDefault] }
    }

    var defaultProfile: TerminalProfile { profiles.first ?? .systemDefault }

    /// Shells installed on this Mac (for new profiles).
    static var availableShells: [String] {
        let listed = ((try? String(contentsOfFile: "/etc/shells", encoding: .utf8)) ?? "").split(separator: "\n")
            .map(String.init).filter { $0.hasPrefix("/") }
        let extra = ["/opt/homebrew/bin/fish", "/opt/homebrew/bin/nu", "/opt/homebrew/bin/bash", "/usr/local/bin/fish"]
        return Array(Set(listed + extra)).filter { FileManager.default.isExecutableFile(atPath: $0) }.sorted()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: "terminal.profiles") }
    }
}

/// One running shell. Its view lives as long as the session, so switching tabs keeps the scrollback.
@MainActor
final class TerminalSession: NSObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let profile: TerminalProfile
    let view: LocalProcessTerminalView
    private(set) var title: String
    private(set) var exited = false
    var onChange: (() -> Void)?

    init(profile: TerminalProfile, folder: URL?) {
        self.profile = profile
        title = profile.name
        view = ThemedTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        super.init()
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: profile.fontSize, weight: .regular)
        (view as? ThemedTerminalView)?.applyColors()
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Wayfile"
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        let shellName = (profile.shell as NSString).lastPathComponent
        // A leading "-" in argv[0] makes it a login shell, like Terminal.app.
        view.startProcess(executable: profile.shell, args: [], environment: environment.map { "\($0.key)=\($0.value)" },
                          execName: "-" + shellName, currentDirectory: folder?.path ?? NSHomeDirectory())
        if !profile.startupCommand.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.view.send(txt: profile.startupCommand + "\r") }
        }
    }

    /// The shell is at its prompt (no program running in the foreground), so typing is safe.
    var isIdle: Bool {
        let process = view.process!
        guard process.running, process.childfd >= 0 else { return false }
        return tcgetpgrp(process.childfd) == process.shellPid
    }

    /// The shell's current folder (read from the process, works with any shell).
    var currentDirectory: URL? {
        let pid = view.process.shellPid
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in String(cString: raw.bindMemory(to: CChar.self).baseAddress!) }
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    /// cd into a folder if the shell is idle. Returns false when a program is running.
    @discardableResult
    func changeDirectory(to folder: URL) -> Bool {
        guard isIdle, currentDirectory?.standardizedFileURL.path != folder.standardizedFileURL.path else { return false }
        // Clear the line first (Ctrl-U) so a half-typed command isn't mixed in.
        view.send(txt: "\u{15}cd " + Admin.shellQuote(folder.path) + "\r")
        return true
    }

    func type(_ text: String) { view.send(txt: text) }

    func terminate() { if !exited { view.terminate() } }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { MainActor.assumeIsolated {
            self.title = title.isEmpty ? self.profile.name : title
            self.onChange?()
        } }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { MainActor.assumeIsolated {
            self.exited = true
            self.title = String(localized: "\(self.profile.name) — exited")
            self.onChange?()
        } }
    }
}

/// Terminal panel state for one window.
@MainActor
@Observable
final class TerminalPanelState {
    var isVisible = false
    private(set) var sessions: [TerminalSession] = []
    var selectedID: UUID?
    /// Follow the active pane: cd when it changes folder (only when the shell is idle).
    var followsFolder: Bool = UserDefaults.standard.object(forKey: "terminal.follows") as? Bool ?? true {
        didSet { UserDefaults.standard.set(followsFolder, forKey: "terminal.follows") }
    }
    var height: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "terminal.height") as? Double ?? 240) {
        didSet { UserDefaults.standard.set(Double(height), forKey: "terminal.height") }
    }
    /// Bumped when a session's title or state changes.
    private(set) var revision = 0

    var selected: TerminalSession? { sessions.first { $0.id == selectedID } ?? sessions.last }

    func newSession(profile: TerminalProfile? = nil, in folder: URL?) {
        let session = TerminalSession(profile: profile ?? TerminalProfiles.shared.defaultProfile, folder: folder)
        session.onChange = { [weak self] in self?.revision += 1 }
        sessions.append(session)
        selectedID = session.id
        isVisible = true
    }

    func close(_ session: TerminalSession) {
        session.terminate()
        sessions.removeAll { $0.id == session.id }
        if selectedID == session.id { selectedID = sessions.last?.id }
        if sessions.isEmpty { isVisible = false }
    }

    func toggle(folder: URL?) {
        if isVisible { isVisible = false; return }
        if sessions.isEmpty { newSession(in: folder) } else { isVisible = true }
    }

    /// Shows the panel and runs a folder in a fresh tab, or cds the current one.
    func open(_ folder: URL) {
        if let selected, !selected.exited, selected.changeDirectory(to: folder) {
            isVisible = true
        } else {
            newSession(in: folder)
        }
    }

    func paneMoved(to folder: URL?) {
        guard followsFolder, isVisible, let folder, let selected, !selected.exited else { return }
        selected.changeDirectory(to: folder)
    }

    func closeAll() { sessions.forEach { $0.terminate() }; sessions.removeAll() }
}

// MARK: - Views

struct TerminalPanel: View {
    let state: WindowState
    @Bindable var panel: TerminalPanelState

    var body: some View {
        VStack(spacing: 0) {
            ResizeBar(height: $panel.height)
            HStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(panel.sessions) { session in
                            tab(session)
                        }
                    }
                }
                Menu {
                    ForEach(TerminalProfiles.shared.profiles) { profile in
                        Button(profile.name) { panel.newSession(profile: profile, in: state.activePane.location.folderURL) }
                    }
                    Divider()
                    Button("Edit Profiles…") {
                        UserDefaults.standard.set("terminal", forKey: "settings.tab")
                        NotificationCenter.default.post(name: .openTerminalSettings, object: nil)
                    }
                } label: {
                    Image(systemName: "plus")
                } primaryAction: {
                    panel.newSession(in: state.activePane.location.folderURL)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("New terminal tab (click and hold for profiles)")
                Spacer()
                Toggle(isOn: $panel.followsFolder) { Label("Follow folder", systemImage: "arrow.triangle.pull") }
                    .toggleStyle(.button)
                    .help("Change the terminal's folder when the active pane changes folder (only while the shell waits for a command)")
                Button {
                    if let folder = panel.selected?.currentDirectory { state.activePane.navigate(to: .folderAt(folder)) }
                } label: { Image(systemName: "folder") }
                    .help("Show the terminal's current folder in the pane")
                    .accessibilityLabel("Show terminal folder")
                Button { panel.isVisible = false } label: { Image(systemName: "chevron.down") }
                    .help("Hide terminal (⌃`)")
                    .accessibilityLabel("Hide terminal")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()
            if let session = panel.selected {
                TerminalHost(session: session).id(session.id)
            }
        }
        .frame(height: panel.height)
        .background(Color(nsColor: .textBackgroundColor))
        .id(panel.revision)
    }

    private func tab(_ session: TerminalSession) -> some View {
        let selected = panel.selected?.id == session.id
        return HStack(spacing: 4) {
            Image(systemName: "terminal").font(.caption)
            Text(session.title).lineLimit(1).frame(maxWidth: 180)
            Button { panel.close(session) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close terminal tab")
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.themeAccent.opacity(0.18) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { panel.selectedID = session.id }
    }
}

/// Embeds the session's AppKit terminal view and gives it keyboard focus.
private struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if session.view.superview !== container { attach(to: container) }
        // Reading the theme here makes SwiftUI call this again when the theme changes.
        _ = ThemeStore.shared.preset.id
        (session.view as? ThemedTerminalView)?.applyColors()
    }

    private func attach(to container: NSView) {
        session.view.removeFromSuperview()
        session.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(session.view)
        NSLayoutConstraint.activate([
            session.view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            session.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            session.view.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            session.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        DispatchQueue.main.async { session.view.window?.makeFirstResponder(session.view) }
    }
}

/// Drag the top edge to resize the panel.
private struct ResizeBar: View {
    @Binding var height: CGFloat
    @State private var start: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .overlay(Color.clear.frame(height: 7).contentShape(Rectangle()))
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if start == nil { start = height }
                    height = min(max((start ?? height) - value.translation.height, 120), 700)
                }
                .onEnded { _ in start = nil })
    }
}

extension Notification.Name {
    static let openTerminalSettings = Notification.Name("WayfileOpenTerminalSettings")
}

/// Settings → Terminal: shell profiles (first one is the default).
struct TerminalSettingsView: View {
    @Bindable private var store = TerminalProfiles.shared
    @State private var selection: TerminalProfile.ID?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                List(selection: $selection) {
                    ForEach(store.profiles) { profile in
                        HStack {
                            Text(profile.name)
                            if profile.id == store.profiles.first?.id { Text("default").font(.caption).foregroundStyle(.secondary) }
                        }
                        .tag(profile.id)
                    }
                    .onMove { store.profiles.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(width: 200, height: 260)
                HStack {
                    Button { add() } label: { Image(systemName: "plus") }.accessibilityLabel("Add profile")
                    Button { remove() } label: { Image(systemName: "minus") }
                        .disabled(selection == nil || store.profiles.count < 2)
                        .accessibilityLabel("Remove profile")
                    Spacer()
                    Button("Make Default") { makeDefault() }.disabled(selection == nil || selection == store.profiles.first?.id)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            if let index = store.profiles.firstIndex(where: { $0.id == selection }) {
                Form {
                    TextField("Name", text: $store.profiles[index].name)
                    Picker("Shell", selection: $store.profiles[index].shell) {
                        ForEach(Array(Set(TerminalProfiles.availableShells + [store.profiles[index].shell])).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Run at start", text: $store.profiles[index].startupCommand, prompt: Text("optional, e.g. source .venv/bin/activate"))
                    Stepper("Font size: \(Int(store.profiles[index].fontSize))", value: $store.profiles[index].fontSize, in: 9...24)
                    Text("Changes apply to new terminal tabs. Toggle the terminal with ⌃` (Settings → Keyboard).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .formStyle(.grouped)
            } else {
                Text("Select a profile").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { selection = selection ?? store.profiles.first?.id }
        .frame(minHeight: 320)
    }

    private func add() {
        var profile = TerminalProfile.systemDefault
        profile.name = "New Profile"
        store.profiles.append(profile)
        selection = profile.id
    }

    private func remove() {
        store.profiles.removeAll { $0.id == selection }
        selection = store.profiles.first?.id
    }

    private func makeDefault() {
        guard let index = store.profiles.firstIndex(where: { $0.id == selection }) else { return }
        let profile = store.profiles.remove(at: index)
        store.profiles.insert(profile, at: 0)
    }
}

/// The terminal keeps fixed colours (it converts what it's given once), so system colours like
/// `textBackgroundColor` would freeze in whatever appearance applied at creation — often the wrong one.
/// This view resolves the theme's colours for its own appearance and again whenever that changes.
final class ThemedTerminalView: LocalProcessTerminalView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    func applyColors() {
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        var background = NSColor.textBackgroundColor, foreground = NSColor.textColor
        appearance.performAsCurrentDrawingAppearance {
            let theme = MainActor.assumeIsolated { ThemeStore.shared.preset.content }
            background = (theme.map { NSColor($0) } ?? .textBackgroundColor).usingColorSpace(.sRGB) ?? .black
            foreground = NSColor.textColor.usingColorSpace(.sRGB) ?? .white
        }
        // A theme background decides light or dark text on its own (a dark theme in a light system appearance).
        if let theme = ThemeStore.shared.preset.content.map({ NSColor($0).usingColorSpace(.sRGB) }), let theme {
            let luminance = 0.2126 * theme.redComponent + 0.7152 * theme.greenComponent + 0.0722 * theme.blueComponent
            foreground = luminance < 0.5 ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.1, alpha: 1)
        }
        if nativeBackgroundColor != background { nativeBackgroundColor = background }
        if nativeForegroundColor != foreground { nativeForegroundColor = foreground }
        caretColor = foreground.withAlphaComponent(0.7)
        needsDisplay = true
    }
}
