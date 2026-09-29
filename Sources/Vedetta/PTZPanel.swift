import SwiftUI
import VedettaCore
import ONVIFKit
import VedettaL10n

/// Pan/tilt/zoom controls (ONVIF): joystick, zoom, presets.
struct PTZPanel: View {
    let device: Device
    let channel: Channel
    @Binding var isPresented: Bool
    @Environment(AppModel.self) private var model
    @State private var presets: [ONVIFPreset] = []
    @State private var knob: CGSize = .zero
    @State private var speed: Double = 0.5
    @State private var lastSent = Date.distantPast
    @State private var newPresetName = ""
    @State private var askName = false
    @State private var busy = false

    private let radius: CGFloat = 52

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(L("PTZ control")).font(.headline)
                Spacer()
                Button { withAnimation(.snappy) { isPresented = false } } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                joystick
                VStack(spacing: 8) {
                    zoomButton("plus.magnifyingglass", zoom: 1)
                    zoomButton("minus.magnifyingglass", zoom: -1)
                }
            }
            HStack {
                Image(systemName: "tortoise.fill").foregroundStyle(.secondary).font(.caption)
                Slider(value: $speed, in: 0.1...1)
                Image(systemName: "hare.fill").foregroundStyle(.secondary).font(.caption)
            }
            Divider()
            HStack {
                Menu {
                    if presets.isEmpty { Text(L("No saved positions")) }
                    ForEach(presets) { p in
                        Button(p.name) { run { try await client?.gotoPreset(profile: profile, preset: p.token) } }
                    }
                    if !presets.isEmpty {
                        Divider()
                        Menu(L("Delete")) {
                            ForEach(presets) { p in
                                Button(p.name, role: .destructive) {
                                    run {
                                        try await client?.removePreset(profile: profile, preset: p.token)
                                        await loadPresets()
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Label(L("Positions"), systemImage: "list.bullet")
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                Button { newPresetName = L("Position %@", String(presets.count + 1)); askName = true } label: {
                    Label(L("Save"), systemImage: "plus")
                }
                .buttonStyle(.glass)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 250)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .task { await loadPresets() }
        .alert(L("Save position"), isPresented: $askName) {
            TextField(L("Name"), text: $newPresetName)
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Save")) {
                let name = newPresetName
                run {
                    try await client?.setPreset(profile: profile, name: name)
                    await loadPresets()
                }
            }
        }
    }

    private var client: ONVIFClient? { DeviceClients.shared.onvif(for: device) }
    private var profile: String { channel.ptzProfile ?? "" }

    private var joystick: some View {
        ZStack {
            Circle().fill(.black.opacity(0.25))
            Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1)
            ForEach(0..<4) { i in
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .offset(y: -radius + 12)
                    .rotationEffect(.degrees(Double(i) * 90))
            }
            Circle()
                .fill(Theme.accent.gradient)
                .frame(width: 38, height: 38)
                .shadow(radius: 4)
                .offset(knob)
        }
        .frame(width: radius * 2, height: radius * 2)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    var d = v.translation
                    let len = sqrt(d.width * d.width + d.height * d.height)
                    if len > radius - 19 { let k = (radius - 19) / len; d = CGSize(width: d.width * k, height: d.height * k) }
                    knob = d
                    if Date().timeIntervalSince(lastSent) > 0.25 {
                        lastSent = Date()
                        let x = Double(d.width / (radius - 19)) * speed
                        let y = Double(-d.height / (radius - 19)) * speed
                        Task { try? await client?.continuousMove(profile: profile, pan: x, tilt: y, zoom: 0) }
                    }
                }
                .onEnded { _ in
                    withAnimation(.spring(duration: 0.25)) { knob = .zero }
                    Task { try? await client?.stop(profile: profile) }
                }
        )
        .help(L("Drag to move the camera"))
    }

    private func zoomButton(_ symbol: String, zoom: Double) -> some View {
        Image(systemName: symbol)
            .font(.title3)
            .frame(width: 40, height: 40)
            .glassEffect(.regular.interactive(), in: .circle)
            .onLongPressGesture(minimumDuration: 0.01, maximumDistance: 30) {
            } onPressingChanged: { pressing in
                Task {
                    if pressing { try? await client?.continuousMove(profile: profile, pan: 0, tilt: 0, zoom: zoom * speed) }
                    else { try? await client?.stop(profile: profile) }
                }
            }
            .help(zoom > 0 ? L("Hold to zoom in") : L("Hold to zoom out"))
    }

    private func loadPresets() async {
        presets = (try? await client?.presets(profile: profile)) ?? []
    }

    private func run(_ op: @escaping () async throws -> Void) {
        Task {
            do { try await op() } catch { model.toast(.error, L("PTZ command failed"), error.localizedDescription) }
        }
    }
}
