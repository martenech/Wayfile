import SwiftUI

/// Filters for the active search: text, name/content, kind, size, date, tags, scope, engine.
struct SearchFilterBar: View {
    let state: WindowState
    let pane: PaneState
    let query: SearchQuery

    @State private var text = ""
    @State private var showCustomSize = false
    @State private var showCustomDate = false
    @State private var minMB = ""
    @State private var maxMB = ""
    @State private var fromDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var toDate = Date()
    @State private var showMetadata = false
    @State private var metadataText = ""

    private static let sizePresets: [(String, Int64?, Int64?)] = [
        ("Any size", nil, nil),
        ("Under 1 MB", nil, 1 << 20),
        ("1 – 100 MB", 1 << 20, 100 << 20),
        ("Over 100 MB", 100 << 20, nil),
        ("Over 1 GB", 1 << 30, nil),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                bar
                ScrollView(.horizontal, showsIndicators: false) { bar }
            }
            .frame(height: 36)
            if let summary = state.aiSummary, !summary.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(Color.themeAccent)
                    (Text("AI understood: ") + Text(verbatim: summary.joined(separator: " · "))).lineLimit(1).truncationMode(.tail)
                    Spacer()
                    Button { state.aiSummary = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Hide")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
        }
        .onAppear { text = query.text }
        .onChange(of: query.text) { _, newText in if newText != text { text = newText } }
        // Debounce typing so Spotlight isn't queried on every keystroke.
        .task(id: text) {
            guard text != query.text else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            update { $0.text = text }
        }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $text)
                    .textFieldStyle(.plain)
                    .frame(width: 140)
                    .onSubmit { update { $0.text = text } }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.themeSurface))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(query.isValidPattern ? Color.primary.opacity(0.1) : Color.red))
            .help(query.isValidPattern ? "" : String(localized: "Invalid regular expression"))
            .fixedSize()

            Button {
                if text.trimmingCharacters(in: .whitespaces).isEmpty { state.showAskAI = true } else { state.askAI(text) }
            } label: {
                if state.aiBusy {
                    ProgressView().controlSize(.mini).frame(width: 16)
                } else {
                    Image(systemName: "sparkles")
                }
            }
            .buttonStyle(.borderless)
            .disabled(state.aiBusy)
            .help("Ask AI: describe what you're looking for in your own words — e.g. “PDFs over 5 MB from last week in Downloads” (model: Settings → AI)")
            .accessibilityLabel("Ask AI")

            Menu {
                Picker("Match", selection: binding(\.textMatch)) {
                    ForEach(SearchQuery.TextMatch.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                filterLabel(query.textMatch == .plain ? "Aa" : query.textMatch == .glob ? "*.?" : ".*", active: query.textMatch != .plain)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Text, glob pattern (*.pdf, IMG_????) or regular expression")

            Picker("Match", selection: binding(\.matchContent)) {
                Text("Name").tag(false)
                Text("Name & Content").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            kindMenu
            sizeMenu
            dateMenu
            tagMenu
            metadataButton
            scopeMenu

            Menu {
                Picker("Engine", selection: binding(\.engine)) {
                    ForEach(SearchQuery.Engine.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                filterLabel(query.engine.title, active: query.engine == .scan, symbol: query.engine == .scan ? "doc.text.magnifyingglass" : "bolt")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Spotlight is instant but skips unindexed folders; Scan Files reads the folder directly")

            Spacer(minLength: 8)

            if pane.isLoading {
                ProgressView().controlSize(.small)
            } else if !query.isEmpty {
                (pane.items.count >= SearchEngine.resultLimit ? Text("\(pane.items.count)+ results") : Text("\(pane.items.count) results"))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if SavedSearchStore.shared.search(matching: query) == nil {
                Button("Save…") { state.beginNew(.saveSearch(query)) }
                    .disabled(query.isEmpty)
            } else {
                Label("Saved", systemImage: "checkmark").foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
    }

    // MARK: Menus

    private var kindMenu: some View {
        Menu {
            ForEach(SearchQuery.Kind.allCases) { kind in
                Toggle(isOn: Binding(
                    get: { query.kinds.contains(kind) },
                    set: { on in update { if on { $0.kinds.insert(kind) } else { $0.kinds.remove(kind) } } }
                )) { Label(kind.title, systemImage: kind.symbol) }
            }
            Divider()
            Button("Any Kind") { update { $0.kinds = [] } }
        } label: {
            filterLabel(query.kinds.isEmpty ? "Kind" : query.kinds.count == 1 ? query.kinds.first!.title : "\(query.kinds.count) kinds",
                        active: !query.kinds.isEmpty)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var sizeMenu: some View {
        let current = Self.sizePresets.first { $0.1 == query.minSize && $0.2 == query.maxSize }?.0 ?? "Custom size"
        return Menu {
            ForEach(Self.sizePresets, id: \.0) { preset in
                Button(preset.0) { update { $0.minSize = preset.1; $0.maxSize = preset.2 } }
            }
            Divider()
            Button("Custom…") {
                minMB = query.minSize.map { String($0 / 1_048_576) } ?? ""
                maxMB = query.maxSize.map { String($0 / 1_048_576) } ?? ""
                showCustomSize = true
            }
        } label: {
            filterLabel(query.minSize == nil && query.maxSize == nil ? "Size" : current, active: query.minSize != nil || query.maxSize != nil)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .popover(isPresented: $showCustomSize) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Size in MB").font(.headline)
                HStack {
                    TextField("Min", text: $minMB).frame(width: 80)
                    Text("–")
                    TextField("Max", text: $maxMB).frame(width: 80)
                }
                .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Apply") {
                        update {
                            $0.minSize = Double(minMB.replacingOccurrences(of: ",", with: ".")).map { Int64($0 * 1_048_576) }
                            $0.maxSize = Double(maxMB.replacingOccurrences(of: ",", with: ".")).map { Int64($0 * 1_048_576) }
                        }
                        showCustomSize = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
        }
    }

    private var dateMenu: some View {
        Menu {
            Picker("Date", selection: binding(\.dateField)) {
                ForEach(SearchQuery.DateField.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            ForEach(SearchQuery.DateRange.presets, id: \.self) { range in
                Button(range.title) { update { $0.dateRange = range } }
            }
            Divider()
            Button("Custom Range…") { showCustomDate = true }
            Divider()
            Menu("Not Opened For") {
                Button("Any time") { update { $0.notOpenedForDays = nil } }
                ForEach([30, 90, 180, 365], id: \.self) { days in
                    Button("\(days) days") { update { $0.notOpenedForDays = days } }
                }
            }
        } label: {
            filterLabel(dateTitle, active: query.dateRange != .anyTime || query.notOpenedForDays != nil)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .popover(isPresented: $showCustomDate) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(query.dateField.title) between").font(.headline)
                DatePicker("From", selection: $fromDate, displayedComponents: .date)
                DatePicker("To", selection: $toDate, displayedComponents: .date)
                HStack {
                    Spacer()
                    Button("Apply") {
                        update { $0.dateRange = .between(min(fromDate, toDate), max(fromDate, toDate)) }
                        showCustomDate = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(width: 260)
        }
    }

    private var dateTitle: String {
        var parts: [String] = []
        if query.dateRange != .anyTime { parts.append("\(query.dateField.title): \(query.dateRange.title)") }
        if let days = query.notOpenedForDays { parts.append("not opened \(days)d") }
        return parts.isEmpty ? "Date" : parts.joined(separator: ", ")
    }

    private var metadataButton: some View {
        Button {
            metadataText = query.metadata ?? ""
            showMetadata = true
        } label: {
            filterLabel((query.metadata ?? "").isEmpty ? "Metadata" : query.metadata!, active: !(query.metadata ?? "").isEmpty)
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .popover(isPresented: $showMetadata) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Custom metadata").font(.headline)
                TextField("key=value or key", text: $metadataText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit(applyMetadata)
                Text("Fields you add in the inspector (Details → Custom Metadata). Searches by scanning files.")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 220, alignment: .leading)
                HStack {
                    Button("Clear") { metadataText = ""; applyMetadata() }
                    Spacer()
                    Button("Apply", action: applyMetadata).keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
        }
    }

    private func applyMetadata() {
        let value = metadataText.trimmingCharacters(in: .whitespaces)
        update { $0.metadata = value.isEmpty ? nil : value }
        showMetadata = false
    }

    private var tagMenu: some View {
        Menu {
            ForEach(TagStore.shared.menuTags) { tag in
                Toggle(tag.name, isOn: Binding(
                    get: { query.tags.contains(tag.name) },
                    set: { on in update { if on { $0.tags.insert(tag.name) } else { $0.tags.remove(tag.name) } } }
                ))
            }
        } label: {
            filterLabel(query.tags.isEmpty ? "Tags" : query.tags.sorted().joined(separator: ", "), active: !query.tags.isEmpty)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var scopeMenu: some View {
        // The folder the search started from, kept even while "Entire Mac" is selected.
        let root = query.scope.root ?? pane.backStack.last?.folderURL ?? FileManager.default.homeDirectoryForCurrentUser
        let title: String = {
            switch query.scope {
            case .folder(let url): return "Only \(url.displayName)"
            case .subfolders(let url): return url.displayName
            case .everywhere: return "Entire Mac"
            }
        }()
        return Menu {
            Button("Only “\(root.displayName)”") { update { $0.scope = .folder(root) } }
            Button("“\(root.displayName)” and subfolders") { update { $0.scope = .subfolders(root) } }
            Button("Entire Mac") { update { $0.scope = .everywhere } }
        } label: {
            filterLabel(title, active: false, symbol: "scope")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func filterLabel(_ title: String, active: Bool, symbol: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(key: title).lineLimit(1)
        }
        .foregroundStyle(active ? Color.themeAccent : Color.primary)
    }

    // MARK: Helpers

    private func update(_ change: (inout SearchQuery) -> Void) {
        var updated = query
        change(&updated)
        guard updated != query else { return }
        state.aiSummary = nil
        pane.updateSearch(updated)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<SearchQuery, Value>) -> Binding<Value> {
        Binding(get: { query[keyPath: keyPath] }, set: { value in update { $0[keyPath: keyPath] = value } })
    }
}
