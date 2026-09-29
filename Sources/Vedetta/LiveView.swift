import SwiftUI
import AppKit
import VedettaCore
import MediaKit
import VedettaL10n

struct LiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        GeometryReader { geo in
            let frames = model.layout.grid.frames
            let gap: CGFloat = 4
            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(Array(frames.enumerated()), id: \.offset) { i, f in
                    let rect = CGRect(x: f.minX * geo.size.width + gap / 2, y: f.minY * geo.size.height + gap / 2,
                                      width: f.width * geo.size.width - gap, height: f.height * geo.size.height - gap)
                    TileSlot(tile: i, size: rect.size)
                        .frame(width: max(1, rect.width), height: max(1, rect.height))
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
            .id(model.reloadToken)
        }
        .padding(4)
        .background(Color.black)
        .backgroundExtensionEffect()
        .navigationTitle(L("Live"))
        .toolbar { LiveToolbar() }
        .onKeyPress(characters: .decimalDigits) { press in
            guard let n = Int(press.characters), n >= 1, n <= model.layout.grid.capacity else { return .ignored }
            model.selectedTile = n - 1
            return .handled
        }
    }
}

struct LiveToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        @Bindable var model = model
        ToolbarItem(placement: .navigation) {
            VStack(alignment: .leading, spacing: 0) {
                Text(L("Live")).font(.headline)
                Text(L("%@ cameras · page %@ of %@", String(model.allChannels.count), String(model.currentPage + 1), String(model.pageCount)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.pageCount > 1 {
                Button { model.previousPage() } label: { Image(systemName: "chevron.left") }
                    .help(L("Previous page"))
                Button { model.nextPage() } label: { Image(systemName: "chevron.right") }
                    .help(L("Next page"))
            }
        }
        ToolbarSpacer(.fixed)
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker(L("Layout"), selection: Binding(get: { model.layout.grid }, set: { model.setGrid($0) })) {
                    ForEach(GridKind.allCases) { g in Label(g.label, systemImage: g.symbol).tag(g) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(L("Layout"), systemImage: model.layout.grid.symbol)
            }
            .help(L("Choose how many tiles to show"))

            Button { model.toggleTour() } label: {
                Label(L("Automatic tour"), systemImage: model.tourRunning ? "pause.circle.fill" : "arrow.triangle.2.circlepath.circle")
            }
            .help(model.tourRunning ? L("Stop the automatic page tour") : L("Scroll through pages automatically every %@ seconds", String(model.settings.tourIntervalSeconds)))
            .disabled(model.pageCount < 2 && !model.tourRunning)

            Menu {
                Picker(L("Video quality"), selection: $model.settings.liveQuality) {
                    ForEach(StreamQuality.allCases) { q in Text(q.label).tag(q) }
                }
                .pickerStyle(.inline)
                Toggle(L("Fill the tiles"), isOn: $model.settings.fillTiles)
                Toggle(L("Show video information"), isOn: $model.settings.showStreamInfo)
            } label: {
                Label(L("Quality"), systemImage: "slider.horizontal.3")
            }
            .help(L("Video quality and appearance"))
        }
        ToolbarSpacer(.fixed)
        ToolbarItem(placement: .primaryAction) {
            Button {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: { Label(L("Full screen"), systemImage: "arrow.up.left.and.arrow.down.right") }
            .help(L("Full screen"))
        }
    }
}

/// One cell of the grid: either an assigned channel or an empty drop target.
struct TileSlot: View {
    let tile: Int
    let size: CGSize
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false
    @State private var showPicker = false

    var body: some View {
        let chID = model.channelID(atTile: tile)
        ZStack {
            if let chID, let ch = model.channel(id: chID), let dev = model.device(for: ch), !ch.isHidden {
                VideoTile(channel: ch, device: dev, tile: tile, size: size)
                    .id(ch.id)
            } else {
                EmptyTile(showPicker: $showPicker, tile: tile)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isTargeted ? Theme.accent : (model.selectedTile == tile && model.layout.grid != .one ? Theme.accent.opacity(0.9) : .clear),
                              lineWidth: isTargeted ? 3 : 2)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first, model.channel(id: id) != nil else { return false }
            withAnimation(.snappy) { model.assign(channelID: id, toTile: tile) }
            return true
        } isTargeted: { isTargeted = $0 }
        .onTapGesture { model.selectedTile = tile }
    }
}

struct EmptyTile: View {
    @Binding var showPicker: Bool
    let tile: Int
    @Environment(AppModel.self) private var model
    @State private var hover = false

    var body: some View {
        ZStack {
            Color(white: 0.07)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(.white.opacity(hover ? 0.35 : 0.15))
                .padding(8)
            Button { showPicker = true } label: {
                VStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill").font(.system(size: 28)).symbolRenderingMode(.hierarchical)
                    Text(L("Add camera")).font(.callout.weight(.medium))
                    Text(L("or drag it here")).font(.caption).foregroundStyle(.secondary)
                }
                .foregroundStyle(.white.opacity(hover ? 0.9 : 0.55))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPicker) { ChannelPicker(tile: tile) }
        }
        .onHoverChange($hover)
    }
}

struct ChannelPicker: View {
    let tile: Int
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Choose the camera")).font(.headline).padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.devices) { d in
                        Text(d.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 8)
                        ForEach(d.visibleChannels) { ch in
                            Button {
                                model.assign(channelID: ch.id, toTile: tile)
                                dismiss()
                            } label: {
                                HStack {
                                    StatusDot(color: ch.isOnline ? .green : .gray)
                                    Text(ch.name)
                                    Spacer()
                                    if model.layout.slots.contains(ch.id) { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                                }
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .frame(width: 280, height: 360)
    }
}

/// Holds the stream subscription for a tile.
@MainActor
@Observable
final class TileController {
    let view = VideoDisplayView()
    private(set) var stream: LiveStream?
    @ObservationIgnored private weak var pool: StreamPool?

    func bind(pool: StreamPool, device: Device, channel: Channel, kind: StreamKind) {
        self.pool = pool
        guard let url = StreamURLs.live(device: device, channel: channel, kind: kind) else { return }
        let key = "\(device.id.uuidString)|\(channel.id)|\(kind == .main ? "main" : "sub")"
        if let s = stream, s.key == key, s.url == url { return }
        if let old = stream { old.detach(view); pool.release(old) }
        view.clear()
        let s = pool.acquire(key: key, url: url, credentials: device.credentials, title: channel.name)
        s.attach(view)
        stream = s
    }

    func unbind() {
        guard let s = stream else { return }
        s.detach(view)
        if s.status.audioEnabled { s.setAudio(enabled: false) }
        pool?.release(s)
        stream = nil
    }
}

struct VideoTile: View {
    let channel: Channel
    let device: Device
    let tile: Int
    let size: CGSize
    var allowsLayoutActions = true

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var controller = TileController()
    @State private var hover = false
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var pan: CGPoint = .zero
    @State private var dragStart: CGPoint = .zero
    @State private var showPTZ = false
    @State private var kind: StreamKind = .sub

    var body: some View {
        let status = controller.stream?.status
        ZStack {
            VideoSurface(view: controller.view)
            if let status, !status.isPlaying {
                statusOverlay(status)
            }
            overlays(status)
            if showPTZ, channel.hasPTZ {
                PTZPanel(device: device, channel: channel, isPresented: $showPTZ)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
        .background(Color.black)
        .contentShape(Rectangle())
        .onHoverChange($hover)
        .gesture(magnify)
        .simultaneousGesture(panGesture)
        .onTapGesture(count: 2) { if allowsLayoutActions { withAnimation(.snappy) { model.toggleSingle(tile: tile) } } }
        .onAppear { rebind() }
        .onDisappear { controller.unbind() }
        .onChange(of: size.width) { _, _ in rebind() }
        .onChange(of: model.settings.fillTiles, initial: true) { _, v in controller.view.fillsFrame = v }
        .contextMenu { contextMenu }
    }

    private func rebind() {
        let newKind = model.streamKind(forTileWidth: size.width)
        if controller.stream == nil || newKind != kind {
            kind = newKind
            controller.bind(pool: model.pool, device: device, channel: channel, kind: kind)
        }
    }

    // MARK: Overlays

    @ViewBuilder
    private func overlays(_ status: StreamStatus?) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                HStack(spacing: 6) {
                    StatusDot(color: dotColor(status), pulsing: status?.isRecording == true)
                    Text(channel.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if status?.isRecording == true {
                        RecordingBadge(start: status?.recordingStarted)
                    }
                    if zoom > 1.01 {
                        Text("\(String(format: "%.1f", zoom))×").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glassEffect(.clear, in: .capsule)
                .opacity(hover || size.width > 360 || status?.isRecording == true ? 1 : 0.0)

                Spacer(minLength: 8)

                if hover {
                    GlassEffectContainer(spacing: 6) {
                        HStack(spacing: 6) {
                            if status?.audioCodec != nil {
                                OverlayButton(symbol: status?.audioEnabled == true ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                              help: L("Audio"), active: status?.audioEnabled == true) {
                                    controller.stream?.setAudio(enabled: !(status?.audioEnabled ?? false))
                                }
                            }
                            OverlayButton(symbol: "camera.fill", help: L("Snapshot")) { snapshot() }
                            OverlayButton(symbol: status?.isRecording == true ? "stop.circle.fill" : "record.circle",
                                          help: status?.isRecording == true ? L("Stop recording") : L("Record on this Mac"),
                                          tint: Theme.recording, active: status?.isRecording == true) { toggleRecording() }
                            if channel.hasPTZ {
                                OverlayButton(symbol: "arrow.up.and.down.and.arrow.left.and.right", help: L("PTZ control"), active: showPTZ) {
                                    withAnimation(.snappy) { showPTZ.toggle() }
                                }
                            }
                            if allowsLayoutActions {
                                OverlayButton(symbol: model.layout.grid == .one ? "rectangle.split.2x2" : "arrow.up.left.and.arrow.down.right",
                                              help: model.layout.grid == .one ? L("Back to grid") : L("Enlarge")) {
                                    withAnimation(.snappy) { model.toggleSingle(tile: tile) }
                                }
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topTrailing)))
                }
            }
            Spacer()
            HStack {
                if model.settings.showStreamInfo, let s = status, s.isPlaying {
                    Text(streamInfo(s))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .glassEffect(.clear, in: .capsule)
                }
                Spacer()
                if zoom > 1.01 {
                    OverlayButton(symbol: "arrow.down.right.and.arrow.up.left", help: L("Reset zoom")) { resetZoom() }
                }
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private func statusOverlay(_ status: StreamStatus) -> some View {
        VStack(spacing: 10) {
            switch status.phase {
            case .failed(let msg):
                Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
                Text(msg).font(.callout).multilineTextAlignment(.center)
                Button(L("Retry")) { controller.unbind(); rebind() }.buttonStyle(.glass)
            case .reconnecting(let msg):
                ProgressView().controlSize(.small)
                Text(msg).font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
            case .idle, .connecting:
                ProgressView().controlSize(.small)
                Text(channel.isOnline ? L("Connecting to camera…") : L("Camera offline")).font(.caption).foregroundStyle(.secondary)
            case .playing:
                EmptyView()
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: min(320, size.width - 20))
    }

    private func dotColor(_ s: StreamStatus?) -> Color {
        guard let s else { return .gray }
        if s.isRecording { return Theme.recording }
        switch s.phase {
        case .playing: return .green
        case .failed: return .orange
        default: return .yellow
        }
    }

    private func streamInfo(_ s: StreamStatus) -> String {
        let res = s.resolution == .zero ? "" : "\(Int(s.resolution.width))×\(Int(s.resolution.height))"
        let rate = s.kbps >= 1000 ? String(format: "%.1f Mb/s", s.kbps / 1000) : String(format: "%.0f kb/s", s.kbps)
        return [s.codec, res, String(format: "%.0f fps", s.fps), rate, kind == .main ? "HD" : "SD"].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: Actions

    private func snapshot() {
        if let img = controller.view.currentImage() {
            model.saveSnapshot(img, channel: channel)
            return
        }
        controller.stream?.snapshot { img in
            DispatchQueue.main.async { model.saveSnapshot(img, channel: channel) }
        }
    }

    private func toggleRecording() {
        guard let s = controller.stream else { return }
        if s.status.isRecording {
            s.stopRecording { url, err in
                DispatchQueue.main.async {
                    if let url { model.toast(.success, L("Recording saved"), channel.name, file: url) }
                    else if let err { model.toast(.error, L("Recording not saved"), err.localizedDescription) }
                }
            }
        } else {
            let url = model.recordingURL(for: channel)
            s.startRecording(to: url) { err in
                DispatchQueue.main.async {
                    if let err { model.toast(.error, L("Cannot record"), err.localizedDescription) }
                    else { model.toast(.info, L("Recording started"), L("%@ — the file is being saved on this Mac", channel.name)) }
                }
            }
        }
    }

    // MARK: Digital zoom

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                zoom = min(8, max(1, baseZoom * v.magnification))
                controller.view.zoom = zoom
            }
            .onEnded { _ in
                baseZoom = zoom
                if zoom <= 1.01 { resetZoom() }
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                guard zoom > 1.01 else { return }
                let nx = dragStart.x - v.translation.width / max(1, size.width) * 2 / (zoom - 1)
                let ny = dragStart.y - v.translation.height / max(1, size.height) * 2 / (zoom - 1)
                pan = CGPoint(x: min(1, max(-1, nx)), y: min(1, max(-1, ny)))
                controller.view.pan = pan
            }
            .onEnded { _ in dragStart = pan }
    }

    private func resetZoom() {
        zoom = 1; baseZoom = 1; pan = .zero; dragStart = .zero
        controller.view.zoom = 1
        controller.view.pan = .zero
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button(L("Snapshot")) { snapshot() }
        Button(controller.stream?.status.isRecording == true ? L("Stop recording") : L("Record on this Mac")) { toggleRecording() }
        if channel.supportsPlayback {
            Button(L("Review the last hour")) { model.openPlayback(channelIDs: [channel.id], at: Date().addingTimeInterval(-3600)) }
        }
        Button(L("Open in a new window")) { openWindow(id: "channel", value: channel.id) }
        if allowsLayoutActions {
            Divider()
            Button(L("Remove from tile")) { model.assign(channelID: nil, toTile: tile) }
        }
    }
}

struct RecordingBadge: View {
    var start: Date?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text("REC \(Format.duration(ctx.date.timeIntervalSince(start ?? ctx.date)))")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.recording, in: Capsule())
                .foregroundStyle(.white)
        }
    }
}

struct VideoSurface: NSViewRepresentable {
    let view: VideoDisplayView
    func makeNSView(context: Context) -> VideoDisplayView { view }
    func updateNSView(_ nsView: VideoDisplayView, context: Context) {}
}

/// A channel in its own window (e.g. on a second monitor).
struct DetachedChannelWindow: View {
    let channelID: String
    @Environment(AppModel.self) private var model
    var body: some View {
        GeometryReader { geo in
            if let ch = model.channel(id: channelID), let d = model.device(for: ch) {
                VideoTile(channel: ch, device: d, tile: -1, size: geo.size, allowsLayoutActions: false)
                    .navigationTitle(ch.name)
            } else {
                EmptyStateView(symbol: "video.slash", title: L("Camera not found"), message: L("The camera has been removed."))
            }
        }
        .background(Color.black)
        .background(WindowObserver())
    }
}
