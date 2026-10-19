import SwiftUI

/// Command bar button: shows aggregate progress while operations run, opens the Status Center.
struct StatusCenterButton: View {
    @Bindable var state: WindowState

    private var center: OperationCenter { .shared }

    var body: some View {
        let running = center.running
        Button {
            state.showStatusCenter.toggle()
        } label: {
            ZStack {
                if running.isEmpty {
                    Image(systemName: "arrow.up.arrow.down.circle")
                } else {
                    ProgressRing(fraction: Self.aggregateFraction(running))
                        .frame(width: 16, height: 16)
                }
            }
            .frame(width: 28, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(running.isEmpty ? String(localized: "Status Center") : String(localized: "\(running.count) operations in progress"))
        .popover(isPresented: $state.showStatusCenter, arrowEdge: .bottom) {
            StatusCenterView()
        }
        .onChange(of: center.operations.first?.id) { _, _ in
            // Surface the panel when a new long-running operation starts.
            guard let newest = center.operations.first, newest.isRunning else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if newest.isRunning { state.showStatusCenter = true }
            }
        }
    }

    @MainActor
    static func aggregateFraction(_ operations: [FileOperation]) -> Double? {
        let fractions = operations.compactMap(\.snapshot.fraction)
        guard !fractions.isEmpty else { return nil }
        return fractions.reduce(0, +) / Double(fractions.count)
    }
}

private struct ProgressRing: View {
    let fraction: Double?

    var body: some View {
        if let fraction {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(fraction, 0.02))
                    .stroke(Color.themeAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        } else {
            ProgressView().controlSize(.mini)
        }
    }
}

struct StatusCenterView: View {
    private var center: OperationCenter { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Status Center").font(.headline)
                Spacer()
                Button("Clear") { center.clearFinished() }
                    .buttonStyle(.borderless)
                    .disabled(center.operations.allSatisfy(\.isRunning))
            }
            .padding(12)

            Divider()

            if center.operations.isEmpty {
                Text("No recent operations")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(center.operations) { operation in
                            OperationRow(operation: operation)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 380)
    }
}

private struct OperationRow: View {
    let operation: FileOperation

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(operation.title)
                    .lineLimit(2)
                if operation.status == .running {
                    if let fraction = operation.snapshot.fraction {
                        ProgressView(value: fraction)
                            .tint(operation.isPaused ? .secondary : nil)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if operation.status == .running {
                    Button {
                        operation.isPaused ? operation.resume() : operation.pause()
                    } label: {
                        Image(systemName: operation.isPaused ? "play.circle.fill" : "pause.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(operation.isPaused ? String(localized: "Resume") : String(localized: "Pause"))
                }
                if operation.isRunning {
                    Button {
                        operation.cancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel")
                }
                if let retry = operation.retry, operation.status == .cancelled || { if case .failed = operation.status { return true }; return false }() {
                    Button("Retry") { retry() }
                        .controlSize(.small)
                        .help("Run it again — you'll be asked what to do with items that were already copied")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch operation.status {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running:
            if operation.isPaused {
                Image(systemName: "pause.circle").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .cancelled: Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var detail: String {
        let s = operation.snapshot
        switch operation.status {
        case .failed(let message):
            return message
        case .cancelled:
            return "Cancelled"
        case .queued:
            return "Waiting for the previous transfer to this disk"
        case .completed:
            let time = operation.startedAt.formatted(date: .omitted, time: .shortened)
            return s.totalBytes > 0 ? "\(Formatters.size(s.totalBytes)) · \(time)" : "Done · \(time)"
        case .running:
            var parts: [String] = []
            if s.totalBytes > 0 {
                parts.append("\(Formatters.size(s.completedBytes)) of \(Formatters.size(s.totalBytes))")
                let elapsed = Date().timeIntervalSince(operation.startedAt)
                if elapsed > 2, s.completedBytes > 0 {
                    let rate = Double(s.completedBytes) / elapsed
                    let remaining = Double(s.totalBytes - s.completedBytes) / rate
                    parts.append("\(Formatters.size(Int64(rate)))/s")
                    parts.append(Duration.seconds(remaining).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)) + " left")
                }
            }
            if s.totalItems > 1 { parts.append("\(min(s.completedItems + 1, s.totalItems)) of \(s.totalItems)") }
            if !s.currentName.isEmpty { parts.append(s.currentName) }
            if s.isPaused { parts.insert("Paused", at: 0) }
            return parts.joined(separator: " · ")
        }
    }
}

/// Compact progress line for the status bar while something is running.
struct StatusBarProgress: View {
    private var center: OperationCenter { .shared }

    var body: some View {
        let running = center.running
        if let first = running.first {
            HStack(spacing: 6) {
                if let fraction = StatusCenterButton.aggregateFraction(running) {
                    ProgressView(value: fraction).frame(width: 80)
                    Text("\(Int(fraction * 100)) %")
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text(running.count > 1 ? String(localized: "\(running.count) operations") : first.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .leading)
            }
        }
    }
}
