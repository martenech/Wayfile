import SwiftUI

/// "Select Matching…": select items in the current folder by name pattern, kind, size, date or tag.
struct SelectMatchingView: View {
    let state: WindowState

    @AppStorage("selectMatching.pattern") private var pattern = ""
    @State private var rule = SearchQuery()
    @State private var minMB = ""
    @State private var maxMB = ""
    @Environment(\.dismiss) private var dismiss

    private var effective: SearchQuery {
        var q = rule
        q.text = pattern
        q.minSize = Double(minMB.replacingOccurrences(of: ",", with: ".")).map { Int64($0 * 1_048_576) }
        q.maxSize = Double(maxMB.replacingOccurrences(of: ",", with: ".")).map { Int64($0 * 1_048_576) }
        return q
    }

    var body: some View {
        let rule = effective
        let count = rule.isValidPattern ? state.items(matching: rule).count : 0
        VStack(alignment: .leading, spacing: 14) {
            Text("Select Matching Items").font(.title3.weight(.semibold))
            Form {
                HStack {
                    TextField("Name", text: $pattern, prompt: Text(placeholder))
                    Picker("", selection: $rule.textMatch) {
                        ForEach(SearchQuery.TextMatch.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if !rule.isValidPattern {
                    Text("Invalid regular expression").foregroundStyle(.red).font(.caption)
                }
                LabeledContent("Kind") {
                    Menu(self.rule.kinds.isEmpty ? String(localized: "Any") : self.rule.kinds.map(\.title).sorted().joined(separator: ", ")) {
                        ForEach(SearchQuery.Kind.allCases) { kind in
                            Toggle(kind.title, isOn: Binding(
                                get: { self.rule.kinds.contains(kind) },
                                set: { if $0 { self.rule.kinds.insert(kind) } else { self.rule.kinds.remove(kind) } }
                            ))
                        }
                    }
                    .fixedSize()
                }
                LabeledContent("Size (MB)") {
                    HStack {
                        TextField("min", text: $minMB).frame(width: 70)
                        Text("–")
                        TextField("max", text: $maxMB).frame(width: 70)
                    }
                }
                Picker("Modified", selection: $rule.dateRange) {
                    ForEach(SearchQuery.DateRange.presets, id: \.self) { Text($0.title).tag($0) }
                }
            }
            .formStyle(.grouped)

            HStack {
                Text("\(count) matching items").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add to Selection") { state.select(matching: rule, adding: true); dismiss() }
                    .disabled(count == 0)
                Button("Select") { state.select(matching: rule, adding: false); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(count == 0)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var placeholder: String {
        switch rule.textMatch {
        case .plain: return String(localized: "contains…")
        case .glob: return String(localized: "*.jpg, IMG_????")
        case .regex: return String(localized: "^report-\\d{4}")
        }
    }
}
