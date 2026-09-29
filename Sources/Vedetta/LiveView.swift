import SwiftUI
import AppKit
import VedettaCore
import NetKit
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
            let grid = LiveGridGeometry(size: geo.size, frames: frames, gap: gap)
            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(Array(frames.enumerated()), id: \.offset) { i, _ in
                    let rect = grid.rect(i)
                    TileSlot(tile: i, size: rect.size)
                        .frame(width: max(1, rect.width), height: max(1, rect.height))
                        .offset(x: rect.minX, y: rect.minY)
                }
                if let drag = model.tileDrag { dragOverlay(drag, grid: grid) }
            }
            .coordinateSpace(.named(LiveGridGeometry.space))
            .environment(\.liveGrid, grid)
            .id(model.reloadToken)
        }
        .padding(4)
        .background(Color.black)
        // No background extension: the grid must stay entirely below the toolbar (top labels and buttons visible).
        .navigationTitle(L("Live"))
        .toolbar { LiveToolbar() }
        .onKeyPress(characters: .decimalDigits) { press in
            guard let n = Int(press.characters), n >= 1, n <= model.layout.grid.capacity else { return .ignored }
            model.selectedTile = n - 1
            return .handled
        }
    }
}

extension LiveView {
    /// Where a dragged tile will land: highlighted target and the camera name following the pointer.
    @ViewBuilder
    func dragOverlay(_ drag: AppModel.TileDrag, grid: LiveGridGeometry) -> some View {
        if let target = grid.index(at: drag.location), target != drag.from {
            let r = grid.rect(target)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 3)
                .background(Theme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
                .allowsHitTesting(false)
        }
        Label(drag.name, systemImage: "video.fill")
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .glassEffect(.regular.tint(Theme.accent.opacity(0.4)), in: .capsule)
            .fixedSize()
            .position(x: drag.location.x, y: drag.location.y - 24)
            .allowsHitTesting(false)
    }
}

/// Tile rectangles of the live grid (shared by the grid and the tiles, for drag and drop between tiles).
struct LiveGridGeometry: Equatable {
    static let space = "liveGrid"
    var size: CGSize = .zero
    var frames: [CGRect] = []
    var gap: CGFloat = 4

    func rect(_ i: Int) -> CGRect {
        let f = frames[i]
        return CGRect(x: f.minX * size.width + gap / 2, y: f.minY * size.height + gap / 2,
                      width: f.width * size.width - gap, height: f.height * size.height - gap)
    }

    func index(at p: CGPoint) -> Int? {
        frames.indices.first { rect($0).insetBy(dx: -gap, dy: -gap).contains(p) }
    }
}

private struct LiveGridKey: EnvironmentKey { static let defaultValue: LiveGridGeometry? = nil }
extension EnvironmentValues {
    var liveGrid: LiveGridGeometry? {
        get { self[LiveGridKey.self] }
        set { self[LiveGridKey.self] = newValue }
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
                Picker(L("Picture in the tiles"), selection: $model.settings.tileFit) {
                    ForEach(TileFit.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                Picker(L("Camera names"), selection: $model.settings.tileLabels) {
                    ForEach(TileLabelMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
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
        let s = pool.acquire(key: key, url: url, credentials: device.credentials, title: channel.name,
                             accessGuard: DeviceClients.shared.accessGuard(for: device))
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
    @Environment(\.liveGrid) private var grid
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
            if model.accessState(device).needsUser {
                blockedOverlay(model.accessState(device))
            } else if let status, !status.isPlaying {
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
        .simultaneousGesture(moveGesture)
        .opacity(model.tileDrag?.from == tile && allowsLayoutActions ? 0.45 : 1)
        .onTapGesture(count: 2) { if allowsLayoutActions { withAnimation(.snappy) { model.toggleSingle(tile: tile) } } }
        .onAppear { rebind() }
        .onDisappear { controller.unbind() }
        .onChange(of: size.width) { _, _ in rebind() }
        .onChange(of: model.accessState(device).needsUser) { _, _ in rebind() }
        .onChange(of: model.settings.tileFit, initial: true) { _, v in
            switch v {
            case .fit: controller.view.gravity = .resizeAspect
            case .fill: controller.view.gravity = .resizeAspectFill
            case .stretch: controller.view.gravity = .resize
            }
        }
        .contextMenu { contextMenu }
    }

    private func rebind() {
        // Waiting for the user (refused, locked, signed out): no stream with credentials that do not work.
        guard !model.accessState(device).needsUser else { controller.unbind(); return }
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
                    StatusDot(color: dotColor(status), pulsing: recording != nil)
                    Text(channel.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if let recording {
                        RecordingBadge(start: recording.started)
                    }
                    if zoom > 1.01 {
                        Text("\(String(format: "%.1f", zoom))×").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glassEffect(.clear, in: .capsule)
                .opacity(labelVisible ? 1 : 0)

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
                            OverlayButton(symbol: recording != nil ? "stop.circle.fill" : "record.circle",
                                          help: recording != nil ? L("Stop recording") : L("Record on this Mac (full quality)"),
                                          tint: Theme.recording, active: recording != nil) { toggleRecording() }
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
                if model.accessState(device).needsUser {
                    Button(L("Sign In…")) { model.signIn = AppModel.SignInRequest(deviceID: device.id) }.buttonStyle(.glass)
                } else {
                    Button(L("Retry")) { controller.stream?.retryNow() }.buttonStyle(.glass)
                }
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

    private func blockedOverlay(_ state: AccessState) -> some View {
        VStack(spacing: 10) {
            Image(systemName: state == .signedOut ? "rectangle.portrait.and.arrow.right" : "lock.trianglebadge.exclamationmark")
                .font(.title2).foregroundStyle(.orange)
            Text(state.message).font(.callout).multilineTextAlignment(.center)
            Button(L("Sign In…")) { model.signIn = AppModel.SignInRequest(deviceID: device.id) }.buttonStyle(.glass)
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: min(320, size.width - 20))
    }

    private var recording: AppModel.LiveRecording? { model.liveRecordings[channel.id] }

    private var labelVisible: Bool {
        if recording != nil { return true }
        switch model.settings.tileLabels {
        case .always: return true
        case .hover: return hover
        case .never: return false
        }
    }

    private func dotColor(_ s: StreamStatus?) -> Color {
        guard let s else { return .gray }
        if recording != nil { return Theme.recording }
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

    /// Always at the camera's full resolution (main stream), even when the tile shows the light stream.
    private func snapshot() {
        let current = controller.view.currentImage()
        model.saveFullQualitySnapshot(channel: channel, device: device, current: current, currentIsMain: kind == .main)
    }

    /// Records the main (full quality) stream, whatever quality the tile is showing.
    private func toggleRecording() {
        model.toggleLiveRecording(channel: channel, device: device)
    }

    /// Drag a tile onto another one to swap the two cameras (or move it to an empty tile).
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .named(LiveGridGeometry.space))
            .onChanged { v in
                guard allowsLayoutActions, tile >= 0, grid != nil, zoom <= 1.01 else { return }
                model.tileDrag = AppModel.TileDrag(from: tile, channelID: channel.id, name: channel.name, location: v.location)
            }
            .onEnded { v in
                defer { model.tileDrag = nil }
                guard model.tileDrag != nil, let target = grid?.index(at: v.location), target != tile else { return }
                withAnimation(.snappy) { model.assign(channelID: channel.id, toTile: target) }
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
        Button(recording != nil ? L("Stop recording") : L("Record on this Mac (full quality)")) { toggleRecording() }
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
