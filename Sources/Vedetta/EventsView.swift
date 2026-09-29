import SwiftUI
import VedettaCore
import VedettaL10n

/// All detection events of a day across the NVR cameras.
struct EventsView: View {
    @Environment(AppModel.self) private var model
    @State private var index = RecordingIndex()
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var families: Set<EventType.Family> = Set(EventType.Family.allCases)
    @State private var channelFilter: String? = nil

    var body: some View {
        let channels = model.playbackChannels
        Group {
            if channels.isEmpty {
                EmptyStateView(symbol: "bell.slash", title: L("No recorder"),
                               message: L("Events (motion, people, vehicles…) are read from recorders that keep recordings (VIGI or ONVIF Profile G)."))
            } else {
                content(channels)
            }
        }
        .navigationTitle(L("Events"))
        .onAppear { model.newEventCount = 0 }
    }

    private func content(_ channels: [Channel]) -> some View {
        let all = index.allEvents(for: channels)
        let filtered = all.filter { families.contains($0.info.family) && (channelFilter == nil || $0.channelID == channelFilter) }
        let grouped = Dictionary(grouping: filtered) { Calendar.current.component(.hour, from: $0.start) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summary(all)
                if index.isLoadingDay && all.isEmpty {
                    HStack { ProgressView(); Text(L("Reading events from the recorder…")).foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity).padding(40)
                } else if filtered.isEmpty {
                    EmptyStateView(symbol: "checkmark.shield", title: L("No events"),
                                   message: L("There are no events for the chosen filters on this day."))
                }
                ForEach(grouped.keys.sorted(by: >), id: \.self) { hour in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: "%02d:00", hour)).font(.headline.monospacedDigit()).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                            ForEach(grouped[hour]!.sorted { $0.start > $1.start }) { e in EventCard(event: e) }
                        }
                    }
                }
            }
            .padding(20)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L("Events")).font(.headline)
                    Text(Format.dayLong.string(from: day).firstCapitalized).font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 6)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { day = Calendar.current.date(byAdding: .day, value: -1, to: day)! } label: { Label(L("Previous day"), systemImage: "chevron.left") }
                DatePicker("", selection: $day, in: ...Date(), displayedComponents: .date).labelsHidden().datePickerStyle(.field)
                Button { day = min(Calendar.current.startOfDay(for: Date()), Calendar.current.date(byAdding: .day, value: 1, to: day)!) } label: { Label(L("Next day"), systemImage: "chevron.right") }
                    .disabled(Calendar.current.isDateInToday(day))
                Button { Task { index.clearCache(); await load(channels, force: true) } } label: { Label(L("Refresh"), systemImage: "arrow.clockwise") }
            }
        }
        .task(id: "\(RecordingIndex.dayKey(day))-\(channels.map(\.id).joined())") { await load(channels, force: false) }
    }

    private func summary(_ all: [TimelineEvent]) -> some View {
        let counts = Dictionary(grouping: all, by: { $0.info.family }).mapValues(\.count)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ForEach(EventType.Family.allCases) { f in
                    let on = families.contains(f)
                    Button {
                        if on { families.remove(f) } else { families.insert(f) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Image(systemName: f.symbol).font(.title3).foregroundStyle(Theme.color(for: f))
                            Text("\(counts[f] ?? 0)").font(.title2.weight(.semibold).monospacedDigit())
                            Text(f.label).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .opacity(on ? 1 : 0.4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(on ? .regular.tint(Theme.color(for: f).opacity(0.15)).interactive() : .regular.interactive(), in: .rect(cornerRadius: 16))
                }
            }
            Picker(L("Camera"), selection: $channelFilter) {
                Text(L("All cameras")).tag(String?.none)
                ForEach(model.playbackChannels) { ch in Text(ch.name).tag(String?.some(ch.id)) }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 320)
        }
    }

    private func load(_ channels: [Channel], force: Bool) async {
        for d in model.devices where d.supportsPlayback {
            await index.loadDay(device: d, channels: d.visibleChannels, day: day, force: force)
        }
    }
}

struct EventCard: View {
    let event: TimelineEvent
    @Environment(AppModel.self) private var model
    var body: some View {
        let ch = model.channel(id: event.channelID)
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Theme.color(for: event.info.family).opacity(0.18)).frame(width: 42, height: 42)
                Image(systemName: event.info.family.symbol).foregroundStyle(Theme.color(for: event.info.family))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(event.info.name).font(.callout.weight(.semibold)).lineLimit(1)
                Text(ch?.name ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("\(Format.time.string(from: event.start)) · \(Format.duration(event.end.timeIntervalSince(event.start)))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                model.openPlayback(channelIDs: [event.channelID], at: event.start.addingTimeInterval(-3))
            } label: { Image(systemName: "play.fill") }
            .buttonStyle(.glass)
            .help(L("Review"))
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .contextMenu {
            Button(L("Review")) { model.openPlayback(channelIDs: [event.channelID], at: event.start.addingTimeInterval(-3)) }
            Button(L("Save this event on this Mac")) {
                if let ch, let d = model.device(for: ch) {
                    model.exports.enqueue(device: d, channel: ch, start: event.start.addingTimeInterval(-10), end: event.end.addingTimeInterval(10), folder: model.settings.exportsURL)
                    model.toast(.info, L("Export added"), "\(event.info.name) · \(ch.name)")
                }
            }
        }
    }
}
