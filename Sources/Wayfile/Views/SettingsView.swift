import AppKit
import SwiftUI

struct SettingsView: View {
    /// Last shown section, so Settings reopens where the user left it.
    @AppStorage("settings.tab") private var tab = "general"
    @State private var search = ""

    /// Sections in sidebar order; keywords make the search find settings by what's inside.
    struct Section: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let color: Color
        let group: String
        let keywords: String
    }

    static let sections: [Section] = [
        .init(id: "general", title: "General", symbol: "gearshape", color: .gray, group: "Wayfile",
              keywords: "launch startup hidden files tags verify copies density status bar vim timeline history return key"),
        .init(id: "views", title: "Views", symbol: "rectangle.3.group", color: .blue, group: "Wayfile",
              keywords: "layout details grid columns sort group folder default size"),
        .init(id: "appearance", title: "Appearance", symbol: "paintpalette", color: .pink, group: "Wayfile",
              keywords: "theme dark light accent colour color background glass nord navy"),
        .init(id: "layout", title: "Layout", symbol: "sidebar.squares.left", color: .indigo, group: "Wayfile",
              keywords: "sidebar sections inspector panes"),
        .init(id: "keyboard", title: "Keyboard", symbol: "keyboard", color: .orange, group: "Customize",
              keywords: "shortcuts keys remap"),
        .init(id: "toolbar", title: "Toolbar", symbol: "menubar.rectangle", color: .teal, group: "Customize",
              keywords: "buttons toolbar items"),
        .init(id: "contextMenu", title: "Context Menu", symbol: "contextualmenu.and.cursorarrow", color: .purple, group: "Customize",
              keywords: "right click menu items"),
        .init(id: "features", title: "Features", symbol: "square.stack.3d.up", color: .green, group: "Customize",
              keywords: "modules automation developer remote security disk tools compare"),
        .init(id: "ai", title: "AI", symbol: "sparkles", color: .purple, group: "Integrations",
              keywords: "anthropic claude openai codex ollama api key subscription model ask search"),
        .init(id: "terminal", title: "Terminal", symbol: "apple.terminal", color: .black, group: "Integrations",
              keywords: "shell profiles font follow folder"),
    ]

    static func groupTitle(_ group: String) -> String {
        switch group {
        case "Customize": return String(localized: "Customize")
        case "Integrations": return String(localized: "Integrations")
        default: return group
        }
    }

    /// Panes built as a Form.
    static let formSections: Set<String> = ["general", "views", "appearance", "features", "ai"]

    private var shown: [Section] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Self.sections }
        return Self.sections.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.keywords.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { tab }, set: { if let value = $0 { tab = value } })) {
                ForEach(["Wayfile", "Customize", "Integrations"], id: \.self) { group in
                    let items = shown.filter { $0.group == group }
                    if !items.isEmpty {
                        SwiftUI.Section(Self.groupTitle(group)) {
                            ForEach(items) { section in
                                Label {
                                    Text(key: section.title)
                                } icon: {
                                    Image(systemName: section.symbol)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 20, height: 20)
                                        .background(RoundedRectangle(cornerRadius: 5).fill(section.color.gradient))
                                }
                                .tag(section.id)
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .onChange(of: search) {
                // Jump to the first match so typing then looking works.
                if let first = shown.first, !shown.contains(where: { $0.id == tab }) { tab = first.id }
            }
        } detail: {
            Group {
                if Self.formSections.contains(tab) {
                    // Column-style forms don't scroll by themselves, so they sit in a scroll view.
                    ScrollView {
                        pane.formStyle(.columns)
                            .frame(maxWidth: 640, alignment: .topLeading)
                            .padding(24)
                            .frame(maxWidth: .infinity, alignment: .top)
                    }
                } else {
                    pane.padding(20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(LocalizedStringKey(Self.sections.first { $0.id == tab }?.title ?? "Settings"))
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 620)
    }

    @ViewBuilder
    private var pane: some View {
        switch tab {
        case "views": ViewSettingsPane()
        case "appearance": AppearanceSettings()
        case "keyboard": KeyboardSettings()
        case "toolbar": ToolbarSettings()
        case "contextMenu": ContextMenuSettings()
        case "layout": LayoutSettings()
        case "features": FeatureSettings()
        case "ai": AISettingsView()
        case "terminal": TerminalSettingsView()
        default: GeneralSettings()
        }
    }
}

private struct GeneralSettings: View {
    @Bindable private var settings = AppSettings.shared
    @State private var language = AppLanguage.current
    private let launchLanguage = AppLanguage.current

    var body: some View {
        Form {
            Picker("Language", selection: $language) {
                ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: language) { AppLanguage.current = language }
            if language != launchLanguage {
                HStack {
                    Text("Wayfile switches the language after a restart.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart Now") { AppLanguage.relaunch() }.controlSize(.small)
                }
            }
            Picker("On launch", selection: $settings.startup) {
                ForEach(StartupBehavior.allCases) { Text($0.title).tag($0) }
            }
            if settings.startup == .folder {
                LabeledContent("Folder") {
                    HStack {
                        Text(settings.startupFolder?.path ?? String(localized: "None")).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { chooseFolder() }
                    }
                }
            }
            Toggle("Show hidden files in new windows", isOn: $settings.showHiddenByDefault)
            Toggle("Sidebar: show only tags in use", isOn: $settings.sidebarShowsUsedTagsOnly)
            Toggle("Verify copies (compare checksums after copying)", isOn: $settings.verifyCopies)
            Picker("Row density", selection: $settings.rowDensity) {
                ForEach(RowDensity.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Compact status bar", isOn: $settings.compactStatusBar)
            Toggle("Vim keys in file lists (j/k, h/l, gg/G, dd, yy, p, /)", isOn: $settings.vimMode)
            Picker("Keep Timeline history", selection: Binding(
                get: { TimelineStore.retentionDays },
                set: { TimelineStore.retentionDays = $0; TimelineStore.shared.prune() }
            )) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("1 year").tag(365)
                Text("Forever").tag(0)
            }
            Picker("Return key", selection: $settings.returnKeyRenames) {
                Text("Opens the selection (Windows, Files)").tag(false)
                Text("Renames the selection (Finder)").tag(true)
            }
            Text("Double-click and ⌘↓ always open; F2 always renames.")
                .font(.caption).foregroundStyle(.secondary)
            Section("Settings file") {
                HStack {
                    Button("Export Settings…") { exportSettings() }
                    Button("Import Settings…") { importSettings() }
                }
                Text("Preferences, rules, scripts and templates. Passwords and secret keys stay in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Wayfile Settings.\(SettingsTransfer.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SettingsTransfer.export().write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: SettingsTransfer.fileExtension) ?? .propertyList, .propertyList, .xml]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let summary = try SettingsTransfer.summary(of: data)
            let alert = NSAlert()
            alert.messageText = String(localized: "Import \(summary.settings) settings and \(summary.files) files?")
            alert.informativeText = String(localized: "Matching preferences, rules, scripts and templates are replaced. Wayfile quits afterwards so everything reloads; open it again.")
            alert.addButton(withTitle: String(localized: "Import and Quit"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            _ = try SettingsTransfer.import(data)
            UserDefaults.standard.synchronize()
            NSApp.terminate(nil)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.startupFolder = url
        }
    }
}

private struct ViewSettingsPane: View {
    @Bindable private var store = ViewSettingsStore.shared

    var body: some View {
        Form {
            Toggle("Use the same view for all folders", isOn: $store.syncAcrossFolders)
            LabeledContent("Default view") {
                (store.defaults.groupBy == .none
                    ? Text("\(store.defaults.layout.title), sorted by \(store.defaults.sortField.title.lowercased())")
                    : Text("\(store.defaults.layout.title), sorted by \(store.defaults.sortField.title.lowercased()), grouped by \(store.defaults.groupBy.title.lowercased())"))
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Folders with their own view") {
                HStack {
                    Text("\(store.customFolderCount)")
                    Button("Reset All") { store.resetAllFolders() }
                        .disabled(store.customFolderCount == 0)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @Bindable private var theme = ThemeStore.shared

    var body: some View {
        Form {
            ForEach([(String(localized: "Theme"), nil), (String(localized: "Dark themes"), AppearanceMode.dark),
                     (String(localized: "Light themes"), AppearanceMode.light)], id: \.0) { title, mode in
                Section(title) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                        ForEach(ThemePreset.all.filter { $0.appearance == mode }) { preset in
                            ThemeSwatch(preset: preset, isSelected: preset.id == theme.presetID)
                                .onTapGesture { theme.presetID = preset.id }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Section {
                Picker("Appearance", selection: $theme.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(theme.preset.appearance != nil)
                if let forced = theme.preset.appearance {
                    (forced == .dark ? Text("\(theme.preset.name) is a dark theme.") : Text("\(theme.preset.name) is a light theme."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Accent colour") {
                    HStack {
                        ColorPicker("", selection: Binding(
                            get: { theme.accent },
                            set: { theme.customAccent = $0 }
                        ), supportsOpacity: false)
                        .labelsHidden()
                        Button("Use Theme Colour") { theme.customAccent = nil }
                            .disabled(theme.customAccent == nil)
                    }
                }
            }
            Section("Background image") {
                LabeledContent("Image") {
                    HStack {
                        Text(theme.backgroundImage?.lastPathComponent ?? String(localized: "None"))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { chooseImage() }
                        if theme.backgroundImage != nil {
                            Button("Remove") { theme.backgroundImage = nil }
                        }
                    }
                }
                if theme.backgroundImage != nil {
                    LabeledContent("Opacity") {
                        Slider(value: $theme.backgroundOpacity, in: 0.05...1)
                            .frame(width: 200)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 520)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { theme.backgroundImage = url }
    }
}

private struct ThemeSwatch: View {
    let preset: ThemePreset
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(preset.content ?? (preset.translucent ? Color.gray.opacity(0.25) : Color(nsColor: .controlBackgroundColor)))
                VStack(spacing: 0) {
                    (preset.chrome ?? Color(nsColor: .windowBackgroundColor)).frame(height: 14)
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(preset.accent ?? .accentColor).frame(width: 30, height: 6)
                        RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.4)).frame(width: 40, height: 6)
                    }
                    .padding(8)
                    Spacer(minLength: 0)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                if preset.translucent {
                    Image(systemName: "sparkles").foregroundStyle(.secondary).padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .frame(height: 64)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.themeAccent : Color.primary.opacity(0.15), lineWidth: isSelected ? 2.5 : 1))
            Text(preset.name).font(.callout)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Keyboard

private struct KeyboardSettings: View {
    @State private var query = ""
    @State private var recording: ShortcutAction?
    @State private var message: String?

    private var store: ShortcutStore { .shared }

    private var categories: [(String, [ShortcutAction])] {
        let filtered = ShortcutAction.allCases.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || store.display($0).localizedCaseInsensitiveContains(query)
        }
        return ["File", "Edit", "View", "Go", "Tools"].compactMap { category in
            let actions = filtered.filter { $0.category == category }
            return actions.isEmpty ? nil : (category, actions)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search actions or shortcuts", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button("Reset All") { store.resetAll(); message = nil }
                    .disabled(store.overrides.isEmpty)
            }
            if let message {
                Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            List {
                ForEach(categories, id: \.0) { category, actions in
                    Section(LocalizedStringKey(category)) {
                        ForEach(actions) { action in
                            HStack {
                                Text(action.title)
                                Spacer()
                                ShortcutRecorder(action: action, recording: $recording) { combo in assign(combo, to: action) }
                                Button { store.set(nil, for: action) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.borderless)
                                .help("Remove shortcut")
                                .opacity(store.combo(for: action) == nil ? 0 : 1)
                                Button { store.reset(action) } label: {
                                    Image(systemName: "arrow.counterclockwise")
                                }
                                .buttonStyle(.borderless)
                                .help("Reset to \(action.defaultCombo?.display ?? "none")")
                                .opacity(store.isCustomized(action) ? 1 : 0)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 420)
            Text("Click a shortcut, then press the new keys. Esc cancels. Letters need ⌘, ⌃ or ⌥.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Assigning a shortcut that's taken moves it: the other action loses it.
    private func assign(_ combo: KeyCombo, to action: ShortcutAction) {
        if let other = store.conflict(for: combo, excluding: action) {
            store.set(nil, for: other)
            message = "\(combo.display) was removed from “\(other.title)”."
        } else {
            message = nil
        }
        store.set(combo, for: action)
    }
}

private struct ShortcutRecorder: View {
    let action: ShortcutAction
    @Binding var recording: ShortcutAction?
    let onRecord: (KeyCombo) -> Void

    @State private var monitor: Any?

    private var isRecording: Bool { recording == action }

    var body: some View {
        Button {
            isRecording ? stop() : start()
        } label: {
            Text(isRecording ? String(localized: "Type shortcut…") : (ShortcutStore.shared.display(action).isEmpty ? "—" : ShortcutStore.shared.display(action)))
                .font(.body.monospaced())
                .frame(minWidth: 110)
                .padding(.vertical, 2)
        }
        .buttonStyle(.bordered)
        .tint(isRecording ? Color.themeAccent : nil)
        .onChange(of: recording) { _, current in if current != action { removeMonitor() } }
        .onDisappear { stop() }
    }

    private func start() {
        recording = action
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                stop()
                return nil
            }
            if let combo = KeyCombo(event: event) {
                onRecord(combo)
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        removeMonitor()
        if recording == action { recording = nil }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Toolbar

private struct FeatureSettings: View {
    @Bindable private var features = Features.shared

    var body: some View {
        Form {
            Picker("Mode", selection: Binding(get: { features.mode }, set: { features.mode = $0 })) {
                Text("Standard — everyday file management").tag(Features.Mode.standard)
                Text("Power — every tool").tag(Features.Mode.power)
                if features.mode == .custom { Text("Custom").tag(Features.Mode.custom) }
            }
            .pickerStyle(.radioGroup)
            Section("Tools") {
                ForEach(FeatureModule.allCases) { module in
                    Toggle(isOn: Binding(get: { features.isOn(module) }, set: { features.set(module, $0) })) {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(module.title)
                                Text(module.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: module.symbol)
                        }
                    }
                }
            }
            Text("Turned-off tools disappear from menus, the command palette and the inspector; their background work (folder triggers, schedules, rules) pauses. Nothing is deleted.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct LayoutSettings: View {
    @Bindable private var sidebar = SidebarConfig.shared
    @Bindable private var inspector = InspectorConfig.shared

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sidebar").font(.headline)
                List {
                    ForEach(Array(sidebar.order.enumerated()), id: \.element) { index, section in
                        HStack {
                            Toggle(section.title, isOn: Binding(get: { !sidebar.hidden.contains(section) }, set: { sidebar.setVisible(section, $0) }))
                            Spacer()
                            Button { sidebar.move(section, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0).accessibilityLabel("Move \(section.title) up")
                            Button { sidebar.move(section, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(index == sidebar.order.count - 1).accessibilityLabel("Move \(section.title) down")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .frame(minHeight: 300)
                Button("Restore Defaults") { sidebar.reset() }.controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Inspector sections").font(.headline)
                List {
                    ForEach(InspectorConfig.sections, id: \.self) { title in
                        Toggle(LocalizedStringKey(title), isOn: Binding(get: { inspector.isShown(title) }, set: { inspector.setShown(title, $0) }))
                    }
                }
                .frame(minHeight: 300)
            }
        }
        .frame(minHeight: 380)
    }
}

private struct ContextMenuSettings: View {
    @Bindable private var config = ContextMenuConfig.shared
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose what the right-click menu for files shows and in which order its groups appear. Open, Rename, Move to Trash, Cut, Copy and Get Info always stay.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(Array(config.order.enumerated()), id: \.element) { index, section in
                    Section {
                        ForEach(section.items) { item in
                            Toggle(item.title, isOn: Binding(get: { config.shows(item) }, set: { config.setShown(item, $0) }))
                        }
                        if section.items.isEmpty {
                            Text("Always shown").foregroundStyle(.secondary)
                        }
                    } header: {
                        HStack {
                            Text(section.title)
                            Spacer()
                            Button { config.move(section, by: -1) } label: { Image(systemName: "chevron.up") }
                                .accessibilityLabel("Move \(section.title) up")
                                .disabled(index == 0)
                            Button { config.move(section, by: 1) } label: { Image(systemName: "chevron.down") }
                                .accessibilityLabel("Move \(section.title) down")
                                .disabled(index == config.order.count - 1)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 340)
            Toggle("Quick actions on hover (Quick Look, Copy Path, Move to Trash)", isOn: $settings.hoverActions)
            HStack {
                Spacer()
                Button("Restore Defaults") { config.reset() }
            }
        }
        .frame(minHeight: 440)
    }
}

private struct ToolbarSettings: View {
    @Bindable private var config = CommandBarConfig.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Drag to reorder. Items on the left start at the left edge, items on the right are right-aligned.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                column("Left", items: $config.left)
                column("Right", items: $config.right)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Available").font(.headline)
                    List(config.available) { item in
                        HStack {
                            Label(item.title, systemImage: item.symbol).lineLimit(1)
                            Spacer()
                            Button("Left") { config.left.append(item) }.controlSize(.small)
                            Button("Right") { config.right.append(item) }.controlSize(.small)
                        }
                    }
                    .frame(minHeight: 300)
                }
            }
            HStack {
                Spacer()
                Button("Restore Defaults") { config.reset() }
            }
        }
        .frame(minHeight: 400)
    }

    private func column(_ title: String, items: Binding<[CommandBarItem]>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(key: title).font(.headline)
            List {
                ForEach(Array(items.wrappedValue.enumerated()), id: \.offset) { index, item in
                    HStack {
                        Label(item.title, systemImage: item.symbol).lineLimit(1)
                        Spacer()
                        Button { items.wrappedValue.remove(at: index) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.borderless)
                            .help("Remove from the bar")
                            .accessibilityLabel("Remove from the bar")
                    }
                }
                .onMove { items.wrappedValue.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: 300)
        }
    }
}

/// The app's own language, independent of the system's (System = follow macOS).
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, sk

    var id: String { rawValue }

    /// Language names stay in their own language so anyone can find theirs.
    var title: String {
        switch self {
        case .system: return String(localized: "Same as macOS")
        case .en: return String(localized: "English")
        case .sk: return String(localized: "Slovenčina")
        }
    }

    /// Stored as this app's `AppleLanguages`, which Foundation reads at launch.
    static var current: AppLanguage {
        get {
            let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
            let chosen = (domain?["AppleLanguages"] as? [String])?.first
            return chosen.flatMap { code in allCases.first { $0 != .system && code.hasPrefix($0.rawValue) } } ?? .system
        }
        set {
            if newValue == .system {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([newValue.rawValue], forKey: "AppleLanguages")
            }
        }
    }

    /// Quits and opens again a moment later (after this copy saved its session, so windows come back).
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}
