import SwiftUI
import AppKit
import VedettaCore
import VedettaL10n

struct ExportSheet: View {
    let channels: [Channel]
    let initialRange: ClosedRange<Date>
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var start = Date()
    @State private var end = Date()
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down.on.square.fill")
                    .font(.system(size: 28)).foregroundStyle(Theme.accent.gradient)
                VStack(alignment: .leading) {
                    Text(L("Save recordings on this Mac")).font(.title3.weight(.semibold))
                    Text(L("Videos are copied from the recorder with no quality loss (MP4)."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    DatePicker(L("From"), selection: $start, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    DatePicker(L("To"), selection: $end, in: start...Date(), displayedComponents: [.date, .hourAndMinute])
                    HStack {
                        Text(L("Duration")).foregroundStyle(.secondary)
                        Spacer()
                        Text(Format.duration(end.timeIntervalSince(start))).monospacedDigit()
                    }
                    HStack(spacing: 6) {
                        ForEach([(L("5 min"), 300.0), (L("15 min"), 900.0), (L("1 hour"), 3600.0)], id: \.1) { label, secs in
                            Button(label) { end = min(Date(), start.addingTimeInterval(secs)) }
                                .buttonStyle(.glass).controlSize(.small)
                        }
                    }
                }
            }
            if channels.count > 1 {
                GlassCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Cameras")).font(.headline)
                        ForEach(channels) { ch in
                            Toggle(ch.name, isOn: Binding(get: { selected.contains(ch.id) },
                                                          set: { if $0 { selected.insert(ch.id) } else { selected.remove(ch.id) } }))
                        }
                    }
                }
            }
            HStack {
                Label(model.settings.exportsURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), systemImage: "folder")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(L("Cancel")) { dismiss() }.buttonStyle(.glass)
                Button(L("Save")) { save() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(end.timeIntervalSince(start) < 2 || selected.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            start = initialRange.lowerBound
            end = min(Date(), initialRange.upperBound)
            selected = Set(channels.map(\.id))
        }
    }

    private func save() {
        for ch in channels where selected.contains(ch.id) {
            guard let d = model.device(for: ch) else { continue }
            model.exports.enqueue(device: d, channel: ch, start: start, end: end, folder: model.settings.exportsURL)
        }
        model.toast(.info, L("Export started"), L("Follow the progress in the Exports section."))
        dismiss()
    }
}

struct ExportsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let jobs = model.exports.jobs
        Group {
            if jobs.isEmpty {
                EmptyStateView(symbol: "square.and.arrow.down.on.square", title: L("No exports"),
                               message: L("In Recordings, select a range and press “Save on this Mac”: the videos will be downloaded here."),
                               action: (L("Go to recordings"), { model.section = .playback }))
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(jobs) { job in ExportRow(job: job) }
                    }
                    .padding(20)
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle(L("Exports"))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text(L("Exports")).font(.headline).padding(.horizontal, 6)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    NSWorkspace.shared.open(model.settings.exportsURL)
                } label: { Label(L("Open folder"), systemImage: "folder") }
                Button {
                    model.exports.clearFinished()
                } label: { Label(L("Clear list"), systemImage: "trash") }
                .disabled(!jobs.contains { $0.state == .completed || $0.state == .cancelled })
            }
        }
        .onAppear { try? FileManager.default.createDirectory(at: model.settings.exportsURL, withIntermediateDirectories: true) }
    }
}

struct ExportRow: View {
    let job: ExportRecord
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(color.opacity(0.18)).frame(width: 40, height: 40)
                Image(systemName: icon).foregroundStyle(color).font(.title3)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title).font(.headline).lineLimit(1)
                Text("\(Format.dayShort.string(from: job.start).firstCapitalized) · \(Format.time.string(from: job.start)) – \(Format.time.string(from: job.end)) · \(Format.duration(job.end.timeIntervalSince(job.start)))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if job.state == .running {
                    ProgressView(value: job.progress).tint(Theme.accent)
                    Text(job.message ?? "\(Int(job.progress * 100))% · \(Format.bytes(job.bytes))")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                } else if let m = job.message, job.state == .failed || job.state == .queued {
                    Text(m).font(.caption).foregroundStyle(job.state == .failed ? .red : .secondary)
                } else if job.state == .queued {
                    Text(L("Queued")).font(.caption).foregroundStyle(.secondary)
                } else if job.state == .completed {
                    Text(job.fileURL.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                switch job.state {
                case .completed:
                    Button { NSWorkspace.shared.open(job.fileURL) } label: { Image(systemName: "play.fill") }.help(L("Open"))
                    Button { NSWorkspace.shared.activateFileViewerSelecting([job.fileURL]) } label: { Image(systemName: "magnifyingglass") }.help(L("Show in Finder"))
                case .running, .queued:
                    Button { model.exports.cancel(job.id) } label: { Image(systemName: "stop.fill") }.help(L("Cancel"))
                case .failed, .cancelled:
                    Button { model.exports.retry(job.id) } label: { Image(systemName: "arrow.clockwise") }.help(L("Retry"))
                }
                Button { model.exports.remove(job.id) } label: { Image(systemName: "xmark") }.help(L("Remove from list"))
            }
            .buttonStyle(.glass)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var icon: String {
        switch job.state {
        case .queued: return "clock"
        case .running: return "arrow.down"
        case .completed: return "checkmark"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark"
        }
    }
    private var color: Color {
        switch job.state {
        case .completed: return .green
        case .failed: return .orange
        case .cancelled: return .secondary
        default: return Theme.accent
        }
    }
}
