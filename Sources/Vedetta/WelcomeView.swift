import SwiftUI
import VedettaCore
import ONVIFKit
import VedettaL10n

/// First launch: pick what to connect (any brand), fill address and credentials, done.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var form = ConnectFormModel()
    @State private var appeared = false
    @State private var userPickedChoice = false

    var body: some View {
        ZStack {
            background
            ScrollView {
                VStack(spacing: 22) {
                    Spacer(minLength: 32)
                    hero
                    VStack(alignment: .leading, spacing: 18) {
                        Text(L("What do you want to connect?")).font(.headline)
                        choiceGrid
                        found
                        ConnectFields(form: form, showKindPicker: false)
                        connectButton
                    }
                    .padding(26)
                    .frame(width: 600)
                    .glassEffect(.regular, in: .rect(cornerRadius: 30))
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 20)

                    Label(L("Passwords stay in your Mac's Keychain. Vedetta only talks to the devices on your network."), systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 32)
                }
                .frame(maxWidth: .infinity)
                .animation(.snappy, value: form.error)
                .animation(.snappy, value: form.choice)
            }
            .scrollIndicators(.never)
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            withAnimation(.spring(duration: 0.8)) { appeared = true }
            Task { await discoverAndPrefill() }
        }
    }

    private var hero: some View {
        VStack(spacing: 12) {
            AppGlyph(size: 84)
                .shadow(color: Theme.accent.opacity(0.5), radius: 24)
                .scaleEffect(appeared ? 1 : 0.8)
            Text(L("Welcome to Vedetta"))
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text(L("Watch your cameras live, review recordings and save them on your Mac.\nWorks with VIGI, Hikvision, Dahua, Reolink and Uniview recorders and with any ONVIF device."))
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .opacity(appeared ? 1 : 0)
    }

    private var choiceGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(ConnectChoice.allCases) { c in
                let selected = form.choice == c
                Button {
                    userPickedChoice = true
                    form.choice = c
                    form.error = nil
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: c.symbol)
                            .font(.title3)
                            .foregroundStyle(selected ? .white : Theme.accent)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).font(.callout.weight(.semibold))
                            Text(c.subtitle).font(.caption).foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .glassEffect(selected ? .regular.tint(Theme.accent.opacity(0.55)).interactive() : .regular.interactive(),
                             in: .rect(cornerRadius: 16))
            }
        }
    }

    @ViewBuilder
    private var found: some View {
        let wantsRecorder = form.choice == .vigi || form.choice == .otherRecorder
        let list = model.discovered.filter { d in
            switch form.choice {
            case .vigi: return d.isRecorder && d.isVigi
            case .otherRecorder: return d.isRecorder && !d.isVigi
            case .camera: return !d.isRecorder
            case .rtsp: return false
            }
        }
        if form.choice != .rtsp {
            if model.isDiscovering && model.discovered.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("Looking for devices on the network…")).font(.callout).foregroundStyle(.secondary)
                }
            } else if !list.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(wantsRecorder ? L("Recorders found on your network") : L("Cameras found on your network"))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(list) { d in foundRow(d) }
                        }
                    }
                    .frame(maxHeight: list.count > 3 ? 170 : nil)
                }
            }
        }
    }

    private func foundRow(_ d: DiscoveredDevice) -> some View {
        let selected = form.address == d.ip
        return Button {
            form.fill(from: d)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: d.isRecorder ? "externaldrive.connected.to.line.below.fill" : (d.hasPTZ ? "video.circle.fill" : "video.fill"))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text(d.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(d.ip + (d.hasPTZ ? " · " + L("motorized") : "")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Theme.accent : .secondary)
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? Theme.accent.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private var connectButton: some View {
        Button {
            Task {
                if let r = await form.connect() {
                    withAnimation(.snappy) { model.addOrUpdate(r, password: form.password) }
                }
            }
        } label: {
            HStack {
                if form.isConnecting { ProgressView().controlSize(.small).tint(.white) }
                Text(form.isConnecting ? L("Connecting…") : L("Connect"))
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.extraLarge)
        .keyboardShortcut(.defaultAction)
        .disabled(!form.canConnect)
    }

    private func discoverAndPrefill() async {
        await model.discover()
        guard form.address.isEmpty, !userPickedChoice else { return }
        if let vigi = model.discovered.first(where: { $0.isRecorder && $0.isVigi }) {
            form.fill(from: vigi)
        } else if let other = model.discovered.first(where: \.isRecorder) {
            form.fill(from: other)
        } else if let cam = model.discovered.first {
            form.fill(from: cam)
        }
    }

    private var background: some View {
        MeshGradient(width: 3, height: 3, points: [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.5], [0.55, 0.45], [1, 0.5],
            [0, 1], [0.5, 1], [1, 1],
        ], colors: [
            Color(red: 0.02, green: 0.05, blue: 0.12), Color(red: 0.03, green: 0.14, blue: 0.26), Color(red: 0.02, green: 0.06, blue: 0.14),
            Color(red: 0.03, green: 0.20, blue: 0.32), Color(red: 0.06, green: 0.42, blue: 0.55), Color(red: 0.04, green: 0.16, blue: 0.30),
            Color(red: 0.02, green: 0.05, blue: 0.10), Color(red: 0.04, green: 0.12, blue: 0.22), Color(red: 0.02, green: 0.04, blue: 0.09),
        ])
        .ignoresSafeArea()
    }
}
