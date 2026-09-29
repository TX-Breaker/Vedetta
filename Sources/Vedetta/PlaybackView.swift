import SwiftUI
import AppKit
import VedettaCore
import MediaKit
import VedettaL10n

struct PlaybackView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedIDs: [String] = []
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var month = Date()
    @State private var session: PlaybackSession?
    @State private var span: TimeInterval = 86400
    @State private var center = Calendar.current.startOfDay(for: Date()).addingTimeInterval(43200)
    @State private var clipMode = false
    @State private var clip: ClosedRange<Date>?
    @State private var families: Set<EventType.Family> = Set(EventType.Family.allCases)
    @State private var viewCache = ViewCache()
    @State private var showExport = false
    @State private var pendingStart: Date?
    @State private var showKeys = false
    @State private var keyMonitor: Any?
    @State private var hostWindow = WeakWindow()

    var body: some View {
        let channels = model.playbackChannels
        if channels.isEmpty {
            EmptyStateView(symbol: "clock.arrow.circlepath", title: L("No recorder"),
                           message: L("Add a recorder (VIGI, Hikvision, Dahua or any ONVIF NVR with recordings) to review recorded video here."),
                           action: (L("Add recorder"), { model.showAddDevice = true }))
            .navigationTitle(L("Recordings"))
        } else {
            HStack(spacing: 0) {
                sidePanel
                    .frame(width: 290)
                    .padding(12)
                VStack(spacing: 10) {
                    videoArea
                    controlBar
                }
                .padding([.vertical, .trailing], 12)
            }
            .navigationTitle(L("Recordings"))
            .toolbar { toolbar }
            .onAppear(perform: setup)
            .onDisappear { session?.stop() }
            .onChange(of: model.playbackRequest) { _, _ in applyRequest() }
            .onChange(of: selectedIDs) { _, _ in reloadDay(restart: true) }
            .onChange(of: day) { _, _ in reloadDay(restart: true) }
            .task(id: monthKey) { await loadMonth() }
            .sheet(isPresented: $showExport) {
                ExportSheet(channels: selectedChannels, initialRange: clip ?? defaultExportRange)
            }
            .onAppear { installKeys() }
            .onDisappear { removeKeys() }
            .background(WindowReader { hostWindow.window = $0 })
        }
    }

    // MARK: Derived

    private var selectedChannels: [Channel] { selectedIDs.compactMap { model.channel(id: $0) } }
    private var currentDevice: Device? { selectedChannels.first.flatMap { model.device(for: $0) } }
    private var monthKey: String { "\(RecordingIndex.dayKey(month).prefix(6))-\(selectedIDs.joined())" }
    private var visibleEvents: [TimelineEvent] {
        model.index.allEvents(for: selectedChannels).filter { families.contains($0.info.family) }
    }
    private var defaultExportRange: ClosedRange<Date> {
        let t = session?.currentTime ?? Date()
        return t.addingTimeInterval(-60)...t.addingTimeInterval(240)
    }

    // MARK: Side panel

    private var sidePanel: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let err = model.index.error {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("Cannot read the list of recordings")).font(.callout.weight(.semibold))
                            Text(err).font(.caption).foregroundStyle(.secondary)
                            Button(L("Retry")) {
                                model.index.clearCache()
                                reloadDay(restart: false)
                                Task { await loadMonth() }
                            }
                            .buttonStyle(.glass).controlSize(.small)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .rect(cornerRadius: 16))
                }
                GlassCard {
                    CalendarCard(selectedDay: $day, displayedMonth: $month,
                                 recordedDays: model.index.recordedDays, isLoading: model.index.isLoadingMonth,
                                 daysUnknown: model.index.daysUnknown)
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SectionHeader(title: L("Cameras"), subtitle: L("Up to 4 at once, synchronized"))
                            Spacer()
                        }
                        ForEach(model.devices.filter(\.supportsPlayback)) { d in
                            if model.devices.filter(\.supportsPlayback).count > 1 {
                                Text(d.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            ForEach(d.visibleChannels.filter(\.supportsPlayback)) { ch in channelRow(ch, device: d) }
                        }
                    }
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: L("Events of the day"))
                        eventFilter
                        let list = visibleEvents
                        if model.index.isLoadingDay {
                            HStack { ProgressView().controlSize(.small); Text(L("Loading…")).font(.caption).foregroundStyle(.secondary) }
                        } else if list.isEmpty {
                            Text(L("No events detected")).font(.caption).foregroundStyle(.secondary)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(list.suffix(200).reversed()) { e in eventRow(e) }
                            }
                        }
                    }
                }
            }
        }
        .scrollIndicators(.never)
    }

    private func channelRow(_ ch: Channel, device: Device) -> some View {
        let idx = selectedIDs.firstIndex(of: ch.id)
        let otherDevice = currentDevice.map { $0.id != device.id } ?? false
        return Button {
            toggle(ch)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.5), lineWidth: 1.2).frame(width: 18, height: 18)
                    if let idx {
                        RoundedRectangle(cornerRadius: 5).fill(Theme.channelColors[idx % 4]).frame(width: 18, height: 18)
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    }
                }
                Text(ch.name).lineLimit(1)
                Spacer()
                if !ch.isOnline { Text(L("offline")).font(.caption2).foregroundStyle(.secondary) }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .disabled(idx == nil && (selectedIDs.count >= 4 || otherDevice))
        .opacity(idx == nil && (selectedIDs.count >= 4 || otherDevice) ? 0.45 : 1)
    }

    private var eventFilter: some View {
        let counts = Dictionary(grouping: model.index.allEvents(for: selectedChannels), by: { $0.info.family }).mapValues(\.count)
        return FlowLayout(spacing: 6) {
            ForEach(EventType.Family.allCases) { f in
                let on = families.contains(f)
                Button {
                    if on { families.remove(f) } else { families.insert(f) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: f.symbol).font(.caption2)
                        Text(f.label).font(.caption)
                        if let c = counts[f] { Text("\(c)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .foregroundStyle(on ? Theme.color(for: f) : .secondary)
                    .background(on ? Theme.color(for: f).opacity(0.15) : Color.clear, in: Capsule())
                    .overlay(Capsule().strokeBorder(on ? Theme.color(for: f).opacity(0.5) : .secondary.opacity(0.3)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func eventRow(_ e: TimelineEvent) -> some View {
        Button {
            session?.seek(to: e.start.addingTimeInterval(-3))
        } label: {
            HStack(spacing: 8) {
                Image(systemName: e.info.family.symbol)
                    .font(.caption)
                    .foregroundStyle(Theme.color(for: e.info.family))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(e.info.name).font(.callout).lineLimit(1)
                    if selectedIDs.count > 1, let ch = model.channel(id: e.channelID) {
                        Text(ch.name).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(Format.time.string(from: e.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(L("Play")) { session?.seek(to: e.start.addingTimeInterval(-3)) }
            Button(L("Export this event")) {
                if let ch = model.channel(id: e.channelID), let d = model.device(for: ch) {
                    model.exports.enqueue(device: d, channel: ch, start: e.start.addingTimeInterval(-10),
                                          end: e.end.addingTimeInterval(10), folder: model.settings.exportsURL,
                                          includeAudio: model.settings.exportAudio)
                    model.toast(.info, L("Export added"), "\(e.info.name) · \(ch.name)")
                }
            }
        }
    }

    // MARK: Video area

    private var videoArea: some View {
        GeometryReader { geo in
            let chans = selectedChannels
            let cols = chans.count <= 1 ? 1 : 2
            let rows = chans.count <= 2 ? 1 : 2
            let gap: CGFloat = 4
            let w = (geo.size.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let h = (geo.size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            ZStack(alignment: .topLeading) {
                Color.black
                if chans.isEmpty {
                    EmptyStateView(symbol: "hand.point.left.fill", title: L("Choose a camera"),
                                   message: L("Select one or more cameras on the left to review their recordings."))
                        .foregroundStyle(.white)
                }
                ForEach(Array(chans.enumerated()), id: \.element.id) { i, ch in
                    PlaybackTile(channel: ch, color: Theme.channelColors[i % 4], view: view(for: ch), session: session,
                                 ended: session?.endedChannels.contains(ch.id) == true,
                                 hasRecordings: !(model.index.segments[ch.id] ?? []).isEmpty || model.index.isLoadingDay || model.index.unindexed.contains(ch.id))
                        .frame(width: w, height: h)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .offset(x: CGFloat(i % cols) * (w + gap), y: CGFloat(i / cols) * (h + gap))
                }
                if let notice = session?.notice {
                    Text(notice)
                        .font(.callout)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 16)
                        .transition(.opacity)
                }
                if session?.isBuffering == true {
                    ProgressView().controlSize(.large).tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func view(for ch: Channel) -> VideoDisplayView { viewCache.view(for: ch.id) }

    // MARK: Control bar

    private var controlBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                PlaybackClock(session: session, day: day)
                    .frame(width: 190, alignment: .leading)

                Spacer()

                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        transportButton("backward.end.fill", L("Previous event")) { jumpEvent(forward: false) }
                        transportButton("gobackward.10", L("Back 10 seconds")) { session?.jump(by: -10) }
                        Button { session?.togglePlay() } label: {
                            Image(systemName: session?.isPlaying == true ? "pause.fill" : "play.fill")
                                .font(.system(size: 20, weight: .bold))
                                .frame(width: 52, height: 52)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.tint(Theme.accent).interactive(), in: .circle)
                        .help(L("Play / Pause (space bar)"))
                        transportButton("goforward.10", L("Forward 10 seconds")) { session?.jump(by: 10) }
                        transportButton("forward.end.fill", L("Next event")) { jumpEvent(forward: true) }
                        transportButton("forward.frame.fill", L("Next frame")) { session?.stepForward() }
                    }
                }
                .disabled(selectedIDs.isEmpty)

                Spacer()

                HStack(spacing: 8) {
                    Menu {
                        ForEach([0.5, 1, 2, 4, 8, 16], id: \.self) { s in
                            Button { session?.setSpeed(s) } label: {
                                if session?.speed == s { Label(PlaybackSession.speedLabel(s), systemImage: "checkmark") }
                                else { Text(PlaybackSession.speedLabel(s)) }
                            }
                        }
                    } label: {
                        Text(PlaybackSession.speedLabel(session?.speed ?? 1)).font(.callout.weight(.semibold).monospacedDigit())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .fixedSize()
                    .help(L("Playback speed"))

                    Button { snapshot() } label: { Image(systemName: "camera.fill") }
                        .buttonStyle(.glass).help(L("Snapshot"))
                    Button {
                        withAnimation(.snappy) {
                            clipMode.toggle()
                            if clipMode, clip == nil, let t = session?.currentTime {
                                clip = t...min(t.addingTimeInterval(max(60, span / 20)), day.addingTimeInterval(86400))
                            }
                            if !clipMode { clip = nil }
                        }
                    } label: { Image(systemName: "scissors") }
                        .buttonStyle(.glass)
                        .tint(clipMode ? Theme.accent : nil)
                        .help(L("Select a range on the timeline to save"))
                    Button {
                        showExport = true
                    } label: {
                        Label(clip != nil ? L("Save selection") : L("Save on this Mac"), systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(selectedIDs.isEmpty)
                }
            }

            HStack(spacing: 10) {
                TimelineHost(session: session, day: day, lanes: lanes, events: visibleEvents,
                             span: $span, center: $center, clip: $clip, clipMode: clipMode,
                             wheelZooms: model.settings.timelineWheel == .zoom)
                .padding(.top, 16)
                zoomPicker
            }
            timelineControls
            if selectedChannels.contains(where: { model.index.unindexed.contains($0.id) }) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(L("This recorder does not list its recordings: click a time on the timeline to play it."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            if clipMode, let clip {
                HStack {
                    Button(L("Start here")) { setClipStart() }.buttonStyle(.glass).controlSize(.small)
                        .help(L("Selection starts at the current time (I)"))
                    Button(L("End here")) { setClipEnd() }.buttonStyle(.glass).controlSize(.small)
                        .help(L("Selection ends at the current time (O)"))
                    Image(systemName: "scissors").foregroundStyle(Theme.accent)
                    Text(L("Selection: %@ – %@ · %@", Format.time.string(from: clip.lowerBound), Format.time.string(from: clip.upperBound), Format.duration(clip.upperBound.timeIntervalSince(clip.lowerBound))))
                        .font(.caption.monospacedDigit())
                    Text(L("Drag on the timeline to change it")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private var lanes: [TimelineLane] {
        selectedChannels.enumerated().map { i, ch in
            TimelineLane(channel: ch, color: Theme.channelColors[i % 4], segments: model.index.segments[ch.id] ?? [])
        }
    }

    /// Buttons for everything the wheel and the keyboard do (mouse only, one hand).
    private var timelineControls: some View {
        HStack(spacing: 8) {
            Group {
                smallButton("minus.magnifyingglass", L("Zoom out the timeline (–)")) { zoomTimeline(by: 2) }
                smallButton("plus.magnifyingglass", L("Zoom in the timeline (+)")) { zoomTimeline(by: 0.5) }
                smallButton("chevron.left", L("Move the timeline back")) { panTimeline(-1) }
                smallButton("chevron.right", L("Move the timeline forward")) { panTimeline(1) }
                smallButton("scope", L("Center on the playhead (C)")) { centerTimeline() }
            }
            Text(model.settings.timelineWheel == .zoom ? L("Mouse wheel: zoom · Shift + wheel: scroll") : L("Mouse wheel: scroll · ⌘ + wheel: zoom"))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button { showKeys.toggle() } label: { Label(L("Keyboard shortcuts"), systemImage: "keyboard") }
                .buttonStyle(.glass).controlSize(.small)
                .popover(isPresented: $showKeys) { PlaybackShortcutsHelp() }
        }
    }

    private func smallButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 18, height: 14) }
            .buttonStyle(.glass).controlSize(.small)
            .help(help)
            .accessibilityLabel(help)
    }

    private func zoomTimeline(by factor: Double) {
        withAnimation(.snappy) {
            span = min(86400, max(60, span * factor))
            centerTimeline(animated: false)
        }
    }

    private func panTimeline(_ direction: Double) {
        withAnimation(.snappy) {
            let half = span / 2
            center = min(max(center.addingTimeInterval(direction * span * 0.4), day.addingTimeInterval(half)), day.addingTimeInterval(86400 - half))
        }
    }

    private func centerTimeline(animated: Bool = true) {
        let half = span / 2
        let t = session?.currentTime ?? center
        let c = min(max(t, day.addingTimeInterval(half)), day.addingTimeInterval(86400 - half))
        if animated { withAnimation(.snappy) { center = c } } else { center = c }
    }

    private func setClipStart() {
        guard let t = session?.currentTime else { return }
        withAnimation(.snappy) {
            clipMode = true
            let end = clip.map { max($0.upperBound, t.addingTimeInterval(1)) } ?? t.addingTimeInterval(max(60, span / 20))
            clip = t...end
        }
    }

    private func setClipEnd() {
        guard let t = session?.currentTime else { return }
        withAnimation(.snappy) {
            clipMode = true
            let start = clip.map { min($0.lowerBound, t.addingTimeInterval(-1)) } ?? t.addingTimeInterval(-max(60, span / 20))
            clip = start...t
        }
    }

    // MARK: Keyboard

    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKey(event) ? nil : event
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Single keys, no chords (usable with one hand); ignored while typing or in another window/sheet.
    func handleKey(_ event: NSEvent) -> Bool {
        // Key events go to the key window: only those addressed to the window showing Recordings count.
        guard model.section == .playback, !selectedIDs.isEmpty, let w = event.window, w === hostWindow.window,
              w.attachedSheet == nil, !(w.firstResponder is NSText) else { return false }
        let mods = event.modifierFlags.intersection([.command, .control])
        guard mods.isEmpty else { return false }
        let shift = event.modifierFlags.contains(.shift)
        let option = event.modifierFlags.contains(.option)
        switch event.keyCode {
        case 49: session?.togglePlay(); return true                                            // space
        case 123: session?.jump(by: shift ? -60 : (option ? -1 : -10)); return true             // ←
        case 124: session?.jump(by: shift ? 60 : (option ? 1 : 10)); return true                // →
        case 126: jumpEvent(forward: false); return true                                        // ↑
        case 125: jumpEvent(forward: true); return true                                         // ↓
        case 53: if clipMode { withAnimation(.snappy) { clipMode = false; clip = nil } }; return clipMode   // esc
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() ?? "" {
        case "k": session?.togglePlay()
        case "+", "=": zoomTimeline(by: 0.5)
        case "-": zoomTimeline(by: 2)
        case "0": withAnimation(.snappy) { span = 86400; center = day.addingTimeInterval(43200) }
        case "c": centerTimeline()
        case ".": session?.stepForward()
        case "i": setClipStart()
        case "o": setClipEnd()
        case "s": snapshot()
        case "e": showExport = true
        case "1": session?.setSpeed(1)
        case "2": session?.setSpeed(2)
        case "4": session?.setSpeed(4)
        case "8": session?.setSpeed(8)
        case "h", "?": showKeys.toggle()
        default: return false
        }
        return true
    }

    private var zoomPicker: some View {
        VStack(spacing: 4) {
            ForEach([(86400.0, "24h"), (21600.0, "6h"), (3600.0, "1h"), (600.0, "10m")], id: \.0) { value, label in
                Button {
                    withAnimation(.snappy) {
                        span = value
                        center = (session?.currentTime ?? center)
                        let half = span / 2
                        center = min(max(center, day.addingTimeInterval(half)), day.addingTimeInterval(86400 - half))
                    }
                } label: {
                    Text(label).font(.caption2.weight(.semibold)).frame(width: 34, height: 18)
                }
                .buttonStyle(.plain)
                .foregroundStyle(span == value ? .white : .secondary)
                .background(span == value ? Theme.accent : Color.clear, in: Capsule())
            }
        }
    }

    private func transportButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(help)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            VStack(alignment: .leading, spacing: 0) {
                Text(L("Recordings")).font(.headline)
                Text(Format.dayLong.string(from: day).firstCapitalized).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                day = Calendar.current.date(byAdding: .day, value: -1, to: day)!
                month = day
            } label: { Label(L("Previous day"), systemImage: "chevron.left") }
            Button {
                let next = Calendar.current.date(byAdding: .day, value: 1, to: day)!
                if next <= Date() { day = next; month = day }
            } label: { Label(L("Next day"), systemImage: "chevron.right") }
            .disabled(Calendar.current.isDateInToday(day))
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.index.clearCache()
                reloadDay(restart: false)
                Task { await loadMonth() }
            } label: { Label(L("Refresh"), systemImage: "arrow.clockwise") }
            .help(L("Reload the list of recordings"))
        }
    }

    // MARK: Logic

    private func setup() {
        if model.playbackRequest != nil { applyRequest(); return }
        if selectedIDs.isEmpty, let first = model.playbackChannels.first(where: \.isOnline) ?? model.playbackChannels.first {
            selectedIDs = [first.id]
        } else {
            reloadDay(restart: true)
        }
    }

    private func applyRequest() {
        guard let req = model.playbackRequest else { return }
        model.playbackRequest = nil
        let ids = req.channelIDs.filter { model.channel(id: $0) != nil }
        pendingStart = req.time
        let d = Calendar.current.startOfDay(for: req.time)
        let changedDay = d != day
        let changedSel = ids != selectedIDs
        if changedDay { day = d; month = d }
        if changedSel { selectedIDs = ids }
        if !changedDay && !changedSel { reloadDay(restart: true) }
    }

    private func toggle(_ ch: Channel) {
        withAnimation(.snappy) {
            if let i = selectedIDs.firstIndex(of: ch.id) { selectedIDs.remove(at: i) }
            else if selectedIDs.count < 4 { selectedIDs.append(ch.id) }
        }
    }

    private func ensureSession() -> PlaybackSession? {
        guard let device = currentDevice else { session?.stop(); session = nil; return nil }
        if let s = session, s.device.id == device.id { s.updateDevice(device); model.activePlayback = s; return s }
        session?.stop()
        let s = PlaybackSession(device: device, start: day)
        s.segmentsProvider = { [index = model.index] ch in index.intervals(for: ch) }
        s.onDeviceUpdated = { [weak model] d in model?.updateDevice(d) }
        session = s
        model.activePlayback = s
        return s
    }

    private func reloadDay(restart: Bool) {
        let chans = selectedChannels
        guard let s = ensureSession() else { return }
        let prevTime = s.currentTime
        s.setChannels(chans)
        for id in viewCache.ids where !selectedIDs.contains(id) { s.detach(channelID: id) }
        for ch in chans { s.attach(view(for: ch), for: ch.id) }
        guard let device = currentDevice else { return }
        let targetDay = day
        Task {
            await model.index.loadDay(device: device, channels: chans, day: targetDay)
            guard restart, targetDay == day else { return }
            let start: Date
            if let p = pendingStart { start = p; pendingStart = nil }
            else if Calendar.current.isDate(prevTime, inSameDayAs: targetDay), s.channels.count > 0, prevTime > targetDay, !chans.isEmpty,
                    s.isPlaying || s.currentTime != targetDay {
                start = prevTime
            } else {
                start = defaultStart(for: targetDay, channels: chans)
            }
            center = start
            span = min(span, 86400)
            if chans.isEmpty { s.stop() } else { s.play(from: start) }
        }
    }

    private func defaultStart(for d: Date, channels: [Channel]) -> Date {
        let segs = channels.flatMap { model.index.segments[$0.id] ?? [] }.sorted { $0.start < $1.start }
        if Calendar.current.isDateInToday(d) {
            let target = Date().addingTimeInterval(-300)
            if let s = segs.last(where: { $0.start <= target }) { return min(target, max(s.start, target)) }
            return target
        }
        return segs.first?.start ?? d.addingTimeInterval(8 * 3600)
    }

    private func loadMonth() async {
        guard let d = currentDevice else { return }
        await model.index.loadMonth(device: d, channels: selectedChannels, month: month)
    }

    private func jumpEvent(forward: Bool) {
        guard let s = session else { return }
        let t = s.currentTime
        let list = visibleEvents
        if forward, let e = list.first(where: { $0.start > t.addingTimeInterval(1) }) { s.seek(to: e.start.addingTimeInterval(-2)) }
        else if !forward, let e = list.last(where: { $0.start < t.addingTimeInterval(-5) }) { s.seek(to: e.start.addingTimeInterval(-2)) }
        else { model.toast(.info, forward ? L("No next event") : L("No previous event")) }
    }

    private func snapshot() {
        guard let s = session else { return }
        for ch in selectedChannels {
            let v = viewCache.view(for: ch.id)
            let img = s.withFrozenClock { v.currentImage() }
            model.saveSnapshot(img, channel: ch)
        }
    }
}

/// Only these small views observe the playback clock, so the rest of the screen is not redrawn 5×/s.
struct PlaybackClock: View {
    let session: PlaybackSession?
    let day: Date
    var body: some View {
        let t = session?.currentTime ?? day
        VStack(alignment: .leading, spacing: 0) {
            Text(Format.dayLong.string(from: t).firstCapitalized)
                .font(.caption).foregroundStyle(.secondary)
            Text(Format.time.string(from: t))
                .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
        }
    }
}

struct TimelineHost: View {
    let session: PlaybackSession?
    let day: Date
    let lanes: [TimelineLane]
    let events: [TimelineEvent]
    @Binding var span: TimeInterval
    @Binding var center: Date
    @Binding var clip: ClosedRange<Date>?
    let clipMode: Bool
    var wheelZooms = true
    var body: some View {
        RecordingTimeline(dayStart: day, lanes: lanes, events: events,
                          current: session?.currentTime ?? day, span: $span, center: $center,
                          clip: $clip, clipMode: clipMode, wheelZooms: wheelZooms) { t in
            session?.seek(to: t)
        }
    }
}

final class WeakWindow { weak var window: NSWindow? }

/// Reports the window hosting a view.
struct WindowReader: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView { Reader(onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}
    final class Reader: NSView {
        let onWindow: (NSWindow?) -> Void
        init(_ f: @escaping (NSWindow?) -> Void) { onWindow = f; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onWindow(window) }
    }
}

/// List of the Recordings keyboard shortcuts (all single keys: usable with one hand).
struct PlaybackShortcutsHelp: View {
    var body: some View {
        let rows: [(String, String)] = [
            (L("Space or K"), L("Play / Pause")),
            ("← →", L("Back / forward 10 seconds")),
            ("⇧ ← →", L("Back / forward 1 minute")),
            ("⌥ ← →", L("Back / forward 1 second")),
            ("↑ ↓", L("Previous / next event")),
            (".", L("Next frame")),
            ("+ –", L("Zoom the timeline in / out")),
            ("0", L("Whole day")),
            ("C", L("Center the timeline on the playhead")),
            ("I  O", L("Selection start / end at the current time")),
            ("E", L("Save on this Mac")),
            ("S", L("Snapshot")),
            ("1 2 4 8", L("Playback speed")),
            ("Esc", L("Cancel the selection")),
        ]
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Keyboard shortcuts")).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(rows, id: \.0) { key, action in
                    GridRow {
                        Text(key).font(.system(.callout, design: .monospaced).weight(.semibold))
                        Text(action).font(.callout)
                    }
                }
            }
            Divider()
            Text(L("With the mouse only: the wheel over the timeline zooms around the pointer (Shift + wheel scrolls), a click jumps to that time, and the buttons under the timeline zoom, scroll and set the selection."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 420)
    }
}

/// Keeps one display view per channel across SwiftUI updates.
final class ViewCache {
    private var views: [String: VideoDisplayView] = [:]
    var ids: [String] { Array(views.keys) }
    @MainActor func view(for id: String) -> VideoDisplayView {
        if let v = views[id] { return v }
        let v = VideoDisplayView()
        views[id] = v
        return v
    }
}

struct PlaybackTile: View {
    let channel: Channel
    let color: Color
    let view: VideoDisplayView
    let session: PlaybackSession?
    var ended: Bool
    var hasRecordings: Bool
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            VideoSurface(view: view)
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(channel.name).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glassEffect(.clear, in: .capsule)
            .padding(8)
            if !hasRecordings {
                VStack(spacing: 6) {
                    Image(systemName: "film.stack").font(.title2)
                    Text(L("No recordings on this day")).font(.callout)
                }
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
    }
}

/// Simple wrapping layout for filter chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: maxW, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
