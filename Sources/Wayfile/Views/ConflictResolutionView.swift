import SwiftUI

/// Per-item choices for name collisions, with size/date comparison and bulk shortcuts.
struct ConflictResolutionView: View {
    let prompt: WindowState.ConflictPrompt
    let onDone: ([String: FileOps.ConflictPolicy]?) -> Void

    @State private var choices: [String: FileOps.ConflictPolicy] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                (prompt.items.count == 1 ? Text("“\(prompt.items[0].name)” already exists") : Text("\(prompt.items.count) items already exist"))
                    .font(.title3.weight(.semibold))
                Text("in “\(prompt.destination)”. Replaced items go to the Trash and can be restored with Undo.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text("All:").foregroundStyle(.secondary)
                Button("Replace") { setAll(.replace) }
                Button("Keep Both") { setAll(.keepBoth) }
                Button("Skip") { setAll(.skip) }
                Button("Replace Older") {
                    for item in prompt.items { choices[item.id] = item.sourceIsNewer ? .replace : .skip }
                }
                .help("Replace only where the item you're copying is newer; skip the rest")
            }
            .controlSize(.small)

            List(prompt.items) { item in
                HStack(spacing: 10) {
                    Image(nsImage: IconCache.icon(for: item.source)).resizable().frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                        versionLine("Copying", size: item.sourceSize, date: item.sourceDate,
                                    newer: item.sourceIsNewer, larger: (item.sourceSize ?? 0) > (item.existingSize ?? 0))
                        versionLine("Existing", size: item.existingSize, date: item.existingDate,
                                    newer: !item.sourceIsNewer && item.sourceDate != item.existingDate,
                                    larger: (item.existingSize ?? 0) > (item.sourceSize ?? 0))
                    }
                    Spacer()
                    Picker("", selection: Binding(get: { choices[item.id] ?? .keepBoth }, set: { choices[item.id] = $0 })) {
                        Text("Replace").tag(FileOps.ConflictPolicy.replace)
                        Text("Keep Both").tag(FileOps.ConflictPolicy.keepBoth)
                        Text("Skip").tag(FileOps.ConflictPolicy.skip)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 120, maxHeight: 320)

            HStack {
                summary
                Spacer()
                Button("Cancel", role: .cancel) { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") { onDone(prompt.items.reduce(into: [:]) { $0[$1.id] = choices[$1.id] ?? .keepBoth }) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
    }

    private var summary: some View {
        let values = prompt.items.map { choices[$0.id] ?? .keepBoth }
        let replace = values.filter { $0 == .replace }.count
        let keep = values.filter { $0 == .keepBoth }.count
        let skip = values.filter { $0 == .skip }.count
        return Text([replace > 0 ? "\(replace) replace" : nil, keep > 0 ? "\(keep) keep both" : nil, skip > 0 ? "\(skip) skip" : nil]
            .compactMap { $0 }.joined(separator: " · "))
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func versionLine(_ label: String, size: Int64?, date: Date?, newer: Bool, larger: Bool) -> some View {
        HStack(spacing: 6) {
            Text(key: label).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            Text([size.map(Formatters.size), date.map(Formatters.date)].compactMap { $0 }.joined(separator: " · "))
            if newer { badge("newer", .green) }
            if larger { badge("larger", .blue) }
        }
        .font(.caption)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(key: text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    private func setAll(_ policy: FileOps.ConflictPolicy) {
        for item in prompt.items { choices[item.id] = policy }
    }
}
