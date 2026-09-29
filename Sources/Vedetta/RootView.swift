import SwiftUI
import AppKit
import LocalAuthentication
import VedettaCore
import NetKit
import VedettaL10n

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack {
            if !model.hasDevices {
                WelcomeView()
                    .transition(.opacity)
            } else if !model.credentialsReady {
                KeychainWaitView()
                    .transition(.opacity)
            } else if model.everyDeviceNeedsSignIn {
                // Refused/locked/signed out and nothing else to show: straight to the sign-in screen.
                SignInScreen()
                    .transition(.opacity)
            } else {
                MainView()
                    .transition(.opacity)
            }
            ToastStack()
            if model.isLocked { LockView().transition(.opacity) }
        }
        .animation(.easeInOut(duration: 0.35), value: model.hasDevices)
        .animation(.easeInOut(duration: 0.35), value: model.everyDeviceNeedsSignIn)
        .background(WindowObserver())
        .sheet(isPresented: $model.showAddDevice) { AddDeviceSheet() }
        .sheet(item: Binding(get: { model.everyDeviceNeedsSignIn ? nil : model.signIn }, set: { model.signIn = $0 })) { req in
            SignInView(deviceID: req.deviceID, clearUser: req.clearUser, inSheet: true)
        }
        .tint(Theme.accent)
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            Group {
                switch model.section {
                case .live: LiveView()
                case .playback: PlaybackView()
                case .events: EventsView()
                case .exports: ExportsView()
                case .album: AlbumView()
                case .devices: DevicesView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) { AccessBanner() }
            .animation(.snappy, value: model.access)
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var renaming: Channel?
    @State private var newName = ""

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })) {
            Section {
                ForEach([AppSection.live, .playback, .events, .exports, .album]) { s in
                    Label(s.title, systemImage: s.symbol)
                        .badge(badge(for: s))
                        .tag(s)
                }
            } header: {
                SidebarHeader()
            }

            Section(L("Cameras")) {
                ForEach(model.devices) { device in
                    DisclosureGroup {
                        ForEach(device.visibleChannels) { ch in
                            ChannelRow(channel: ch)
                                .draggable(ch.id)
                                .contextMenu {
                                    Button(L("Show live")) { model.showChannelLive(ch.id) }
                                    Button(L("Open in a new window")) { openWindow(id: "channel", value: ch.id) }
                                    if ch.supportsPlayback {
                                        Button(L("Review recordings")) { model.openPlayback(channelIDs: [ch.id], at: Date().addingTimeInterval(-3600)) }
                                    }
                                    Divider()
                                    Button(L("Rename…")) { newName = ch.name; renaming = ch }
                                    Button(L("Hide")) { model.setHidden(ch, true) }
                                }
                        }
                    } label: {
                        Label {
                            Text(device.name).lineLimit(1)
                        } icon: {
                            Image(systemName: device.kind.symbol)
                        }
                    }
                }
            }

            Section {
                Label(AppSection.devices.title, systemImage: AppSection.devices.symbol).tag(AppSection.devices)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                model.showAddDevice = true
            } label: {
                Label(L("Add device"), systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .padding(12)
        }
        .alert(L("Rename camera"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("Name"), text: $newName)
            Button(L("Cancel"), role: .cancel) { renaming = nil }
            Button(L("Save")) {
                if let ch = renaming, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                    model.renameChannel(ch, to: newName.trimmingCharacters(in: .whitespaces))
                }
                renaming = nil
            }
        }
    }

    private func badge(for s: AppSection) -> Int {
        switch s {
        case .exports: return model.exports.activeCount
        case .events: return model.newEventCount
        default: return 0
        }
    }
}

struct SidebarHeader: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 10) {
            AppGlyph(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Vedetta").font(.headline).foregroundStyle(.primary)
                let online = model.allChannels.filter(\.isOnline).count
                Text(L("%@ of %@ cameras online", String(online), String(model.allChannels.count)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
        .padding(.bottom, 8)
    }
}

struct ChannelRow: View {
    var channel: Channel
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: channel.isOnline ? .green : .gray)
            Text(channel.name).lineLimit(1)
            Spacer(minLength: 4)
            if channel.hasPTZ {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.showChannelLive(channel.id) }
        .help(L("Drag onto a tile, or double-click to watch it"))
    }
}

/// Small brand glyph drawn with SwiftUI (matches the app icon).
struct AppGlyph: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(colors: [Theme.accentDeep, Theme.accent], startPoint: .bottomLeading, endPoint: .topTrailing))
            Circle().stroke(.white.opacity(0.9), lineWidth: size * 0.08).frame(width: size * 0.56)
            Circle().fill(.white).frame(width: size * 0.22)
            Circle().fill(Theme.accentDeep).frame(width: size * 0.1)
        }
        .frame(width: size, height: size)
    }
}

/// Reports window visibility so streams stop when nothing is on screen.
struct WindowObserver: NSViewRepresentable {
    @Environment(AppModel.self) private var model

    func makeNSView(context: Context) -> NSView {
        let v = ObserverView()
        v.onChange = { [weak model] window, visible in model?.windowVisibilityChanged(window, visible: visible) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ObserverView: NSView {
        var onChange: ((NSWindow, Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens.removeAll()
            guard let w = window else { return }
            let report: (Notification) -> Void = { [weak self, weak w] _ in
                guard let w else { return }
                let visible = w.occlusionState.contains(.visible) && !w.isMiniaturized && w.isVisible
                self?.onChange?(w, visible)
            }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { n in
                    if n.name == NSWindow.willCloseNotification { self.onChange?(w, false) } else { report(n) }
                })
            }
            onChange?(w, true)
        }
    }
}

/// Shown while macOS asks permission to read the saved passwords (typically after an update).
struct KeychainWaitView: View {
    var body: some View {
        VStack(spacing: 16) {
            AppGlyph(size: 64)
            ProgressView().controlSize(.small)
            Text(L("Accessing saved passwords…")).font(.title3.weight(.semibold))
            Text(L("If macOS asks for permission to use the Keychain, enter your Mac password and choose “Always Allow”."))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LockView: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 18) {
                AppGlyph(size: 72)
                Text(L("Vedetta is locked")).font(.title.weight(.semibold))
                Text(L("Unlock with Touch ID or your Mac password.")).foregroundStyle(.secondary)
                Button { unlock() } label: { Label(L("Unlock"), systemImage: "touchid").frame(minWidth: 160) }
                    .buttonStyle(.glassProminent).controlSize(.extraLarge)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .padding(40)
            .glassEffect(.regular, in: .rect(cornerRadius: 32))
        }
        .onAppear { unlock() }
    }
    private func unlock() {
        let ctx = LAContext()
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: L("unlock Vedetta")) { ok, err in
            DispatchQueue.main.async {
                if ok { withAnimation { model.isLocked = false } } else { error = err?.localizedDescription }
            }
        }
    }
}
