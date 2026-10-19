import SwiftUI

struct IntegrityReportView: View {
    let result: WindowState.IntegrityResult

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let report = result.report
        VStack(alignment: .leading, spacing: 12) {
            Label(report.isClean ? String(localized: "No changes") : String(localized: "Changes found"),
                  systemImage: report.isClean ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(report.isClean ? Color.green : Color.orange)
            Text("“\(result.folder.lastPathComponent)” compared with its baseline from \(report.baselineDate.formatted(date: .abbreviated, time: .shortened)).")
                .foregroundStyle(.secondary)
            if !report.isClean {
                List {
                    section("Changed", report.changed, "pencil", .orange)
                    section("Added", report.added, "plus", .green)
                    section("Removed", report.removed, "minus", .red)
                }
                .frame(minHeight: 180, maxHeight: 360)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder
    private func section(_ title: String, _ paths: [String], _ symbol: String, _ color: Color) -> some View {
        if !paths.isEmpty {
            Section {
                ForEach(paths, id: \.self) { path in
                    Label(path, systemImage: symbol).foregroundStyle(color).lineLimit(1).truncationMode(.middle)
                }
            } header: {
                Text(key: title) + Text(verbatim: " (\(paths.count))")
            }
        }
    }
}
