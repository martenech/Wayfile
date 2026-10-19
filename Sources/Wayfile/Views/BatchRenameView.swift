import SwiftUI

struct BatchRenameRequest: Identifiable {
    let id = UUID()
    let items: [FileItem]
}

/// Rename many items with find/replace (regex), case, prefix/suffix, numbering and dates, with a live preview.
struct BatchRenameView: View {
    let state: WindowState
    let request: BatchRenameRequest

    @State private var rules = BatchRenameView.savedRules
    @Environment(\.dismiss) private var dismiss

    private let items: [BatchRenameItem]
    /// Folder listings read once, so typing doesn't hit the disk on every keystroke.
    private let existingNames: [String: Set<String>]

    init(state: WindowState, request: BatchRenameRequest) {
        self.state = state
        self.request = request
        items = request.items.map(BatchRenameItem.init)
        var names: [String: Set<String>] = [:]
        for folder in Set(request.items.map { $0.url.deletingLastPathComponent().path }) {
            names[folder] = Set((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
        }
        existingNames = names
    }

    private var preview: Result<[BatchRenameRow], Error> {
        Result { try BatchRename.preview(items, rules: rules, existingNames: existingNames) }
    }

    var body: some View {
        let preview = self.preview
        let rows = (try? preview.get()) ?? []
        let changed = rows.filter { $0.status == .ok }.count
        let problems = rows.filter(\.status.isProblem).count

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                controls
                    .frame(width: 340)
                Divider()
                previewTable(rows, error: preview.failureMessage)
            }
            Divider()
            HStack {
                Button("Reset") { rules = BatchRenameRules() }
                    .disabled(rules.isEmpty)
                Spacer()
                Group {
                    if let error = preview.failureMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else if problems > 0 {
                        Label("\(problems) conflicts to fix", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Text(changed == 0 ? String(localized: "Nothing to rename yet") : String(localized: "\(changed) of \(rows.count) will be renamed"))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename \(changed) Items") {
                    Self.savedRules = rules
                    state.applyBatchRename(rows)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(changed == 0 || problems > 0 || preview.failureMessage != nil)
            }
            .padding(12)
        }
        .frame(width: 900, height: 600)
    }

    // MARK: Controls

    private var controls: some View {
        Form {
            Section("Find & Replace") {
                TextField("Find", text: $rules.find)
                TextField("Replace with", text: $rules.replace)
                Toggle("Regular expression", isOn: $rules.useRegex)
                    .help("Use $1, $2… in the replacement for captured groups")
                Toggle("Case sensitive", isOn: $rules.caseSensitive)
            }
            Section("Name") {
                Picker("Case", selection: $rules.caseChange) {
                    ForEach(BatchRenameRules.CaseChange.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Trim extra spaces", isOn: $rules.trimWhitespace)
                TextField("Prefix", text: $rules.prefix)
                TextField("Suffix", text: $rules.suffix)
                Toggle("Also change extensions", isOn: $rules.includeExtension)
            }
            Section {
                Toggle("Add number", isOn: $rules.numbering)
                if rules.numbering {
                    Stepper("Start at \(rules.numberStart)", value: $rules.numberStart, in: 0...100_000)
                    Stepper("Step \(rules.numberStep)", value: $rules.numberStep, in: 1...1000)
                    Stepper("Digits \(rules.numberPadding)", value: $rules.numberPadding, in: 0...8)
                    Picker("Position", selection: $rules.numberPosition) {
                        ForEach(BatchRenameRules.Position.allCases) { Text($0.title).tag($0) }
                    }
                    if rules.numberPosition != .replace {
                        TextField("Separator", text: $rules.numberSeparator)
                    }
                }
            } header: { Text("Numbering") } footer: {
                if rules.numbering { Text("Numbers follow the order of the current view.").font(.caption) }
            }
            Section {
                Toggle("Add date", isOn: $rules.addDate)
                if rules.addDate {
                    Picker("From", selection: $rules.dateSource) {
                        ForEach(BatchRenameRules.DateSource.allCases) { Text($0.title).tag($0) }
                    }
                    TextField("Format", text: $rules.dateFormat)
                    Picker("Position", selection: $rules.datePosition) {
                        ForEach(BatchRenameRules.Position.allCases) { Text($0.title).tag($0) }
                    }
                    if rules.datePosition != .replace {
                        TextField("Separator", text: $rules.dateSeparator)
                    }
                }
            } header: { Text("Date") } footer: {
                if rules.addDate { Text("e.g. yyyy-MM-dd, yyyyMMdd_HHmm, dd.MM.yyyy").font(.caption) }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Preview

    private func previewTable(_ rows: [BatchRenameRow], error: String?) -> some View {
        Table(rows) {
            TableColumn("Original") { row in
                Text(row.oldName).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }
            TableColumn("New name") { row in
                Text(row.newName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .fontWeight(row.status == .ok ? .medium : .regular)
                    .foregroundStyle(row.status == .unchanged ? Color.secondary : Color.primary)
            }
            TableColumn("") { row in
                statusIcon(row.status)
            }
            .width(min: 24, ideal: 24, max: 24)
        }
        .overlay {
            if let error {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
                    .background(.background)
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: BatchRenameRow.Status) -> some View {
        switch status {
        case .unchanged:
            Image(systemName: "minus").foregroundStyle(.tertiary)
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .conflict(let reason), .invalid(let reason):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(reason)
        }
    }

    // MARK: Persistence

    private static let rulesKey = "batchRenameRules"

    static var savedRules: BatchRenameRules {
        get {
            UserDefaults.standard.data(forKey: rulesKey)
                .flatMap { try? JSONDecoder().decode(BatchRenameRules.self, from: $0) } ?? BatchRenameRules()
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: rulesKey) }
    }
}

private extension Result {
    var failureMessage: String? {
        if case .failure(let error) = self { return error.localizedDescription }
        return nil
    }
}
