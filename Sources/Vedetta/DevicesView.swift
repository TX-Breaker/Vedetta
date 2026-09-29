import SwiftUI
import AppKit
import WebKit
import VedettaCore
import ONVIFKit
import NetKit
import VedettaL10n

// MARK: - Connection form (shared by onboarding and "Add device")

/// What the user wants to connect (drives the form fields).
enum ConnectChoice: String, CaseIterable, Identifiable {
    case vigi, otherRecorder, camera, rtsp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .vigi: return L("VIGI NVR")
        case .otherRecorder: return L("Other NVR brands")
        case .camera: return L("ONVIF camera")
        case .rtsp: return L("RTSP address")
        }
    }
    var subtitle: String {
        switch self {
        case .vigi: return L("TP-Link VIGI recorders: live view, recordings and events.")
        case .otherRecorder: return L("Hikvision, Dahua, Reolink, Uniview and any ONVIF NVR.")
        case .camera: return L("ONVIF cameras of any brand, including PTZ models.")
        case .rtsp: return L("Any RTSP video stream (rtsp://…).")
        }
    }
    var symbol: String {
        switch self {
        case .vigi: return "externaldrive.connected.to.line.below.fill"
        case .otherRecorder: return "externaldrive.fill.badge.plus"
        case .camera: return "video.fill"
        case .rtsp: return "link"
        }
    }
    static func from(_ kind: DeviceKind) -> ConnectChoice {
        switch kind {
        case .vigiNVR: return .vigi
        case .onvifNVR, .rtspRecorder: return .otherRecorder
        case .onvifCamera: return .camera
        case .rtspCamera: return .rtsp
        }
    }
}

@MainActor
@Observable
final class ConnectFormModel {
    var choice: ConnectChoice = .otherRecorder
    var brand: RecorderBrand? = nil
    var address = ""
    var httpPort = "443"
    var rtspPort = "554"
    var onvifURL = ""
    var rtspURL = ""
    var name = ""
    var username = ""
    var password = ""
    var isConnecting = false
    var error: String?
    var editing: Device?

    init(editing: Device? = nil) {
        self.editing = editing
        if let d = editing {
            choice = .from(d.kind)
            brand = d.kind == .rtspRecorder || d.kind == .onvifNVR ? d.brand : nil
            address = d.host
            httpPort = "\(d.httpPort)"
            rtspPort = "\(d.rtspPort)"
            onvifURL = d.onvifURL ?? ""
            rtspURL = d.channels.first?.mainURL ?? ""
            name = d.name
            username = d.username
        }
    }

    func fill(from found: DiscoveredDevice) {
        address = found.ip
        onvifURL = found.serviceURL.absoluteString
        if found.isRecorder {
            choice = found.isVigi ? .vigi : .otherRecorder
            brand = found.isVigi ? nil : RecorderBrand.guess(from: found.name + " " + found.hardware)
        } else {
            choice = .camera
        }
        name = found.name
        error = nil
    }

    var canConnect: Bool {
        guard !isConnecting, !password.isEmpty || choice == .rtsp else { return false }
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty || choice == .rtsp else { return false }
        switch choice {
        case .vigi, .otherRecorder: return !address.trimmingCharacters(in: .whitespaces).isEmpty
        case .camera: return !address.trimmingCharacters(in: .whitespaces).isEmpty || !onvifURL.isEmpty
        case .rtsp: return URL(string: rtspURL)?.scheme?.hasPrefix("rtsp") == true
        }
    }

    func connect() async -> ConnectResult? {
        isConnecting = true
        error = nil
        defer { isConnecting = false }
        let id = editing?.id ?? UUID()
        let user = username.trimmingCharacters(in: .whitespaces)
        // Existing device: its guard serializes this attempt with the automatic ones (one login at a time).
        let g = editing.map { DeviceClients.shared.accessGuard(for: $0) }
        do {
            var result: ConnectResult
            switch choice {
            case .vigi:
                result = try await DeviceConnector.connectNVR(address: address, httpPort: Int(httpPort) ?? 443, rtspPort: Int(rtspPort) ?? 554,
                                                              username: user, password: password, id: id, accessGuard: g)
            case .otherRecorder:
                result = try await DeviceConnector.connectRecorder(address: address, onvifURL: onvifURL.isEmpty ? nil : onvifURL,
                                                                   brand: brand == .vigi ? nil : brand, rtspPort: Int(rtspPort) ?? 554,
                                                                   username: user, password: password, id: id, accessGuard: g)
            case .camera:
                let url = URL(string: onvifURL).flatMap { $0.host == nil ? nil : $0 }
                    ?? URL(string: "http://\(address.trimmingCharacters(in: .whitespaces))/onvif/device_service")
                guard let url else { throw ConnectError.invalidAddress }
                result = try await DeviceConnector.connectONVIF(url: url, username: user, password: password, id: id, accessGuard: g)
            case .rtsp:
                guard let url = URL(string: rtspURL) else { throw ConnectError.invalidAddress }
                result = try await DeviceConnector.connectRTSP(url: url, name: name, username: user, password: password, id: id, accessGuard: g)
            }
            if let editing {
                result.device.name = editing.name
                result.device.addedAt = editing.addedAt
                result.device.replayTimeSuffix = editing.replayTimeSuffix
                for i in result.device.channels.indices {
                    if let old = editing.channels.first(where: { $0.number == result.device.channels[i].number }) {
                        result.device.channels[i].isHidden = old.isHidden
                        result.device.channels[i].name = old.name
                    }
                }
            } else if !name.isEmpty, choice == .rtsp || choice == .camera {
                result.device.name = name
            }
            return result
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}

struct ConnectFields: View {
    @Bindable var form: ConnectFormModel
    var showKindPicker = true
    @State private var advanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showKindPicker {
                Picker(L("Type"), selection: $form.choice) {
                    ForEach(ConnectChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(form.editing != nil)
                Text(form.choice.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                switch form.choice {
                case .vigi, .otherRecorder, .camera:
                    GridRow {
                        Text(L("Address")).foregroundStyle(.secondary)
                        TextField(L("e.g. 192.168.1.100"), text: $form.address).textFieldStyle(.roundedBorder)
                    }
                    if form.choice == .camera {
                        GridRow {
                            Text(L("Name")).foregroundStyle(.secondary)
                            TextField(L("optional, e.g. Backyard"), text: $form.name).textFieldStyle(.roundedBorder)
                        }
                    }
                case .rtsp:
                    GridRow {
                        Text(L("Name")).foregroundStyle(.secondary)
                        TextField(L("e.g. Gate"), text: $form.name).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text(L("RTSP URL")).foregroundStyle(.secondary)
                        TextField("rtsp://192.168.1.50:554/stream1", text: $form.rtspURL).textFieldStyle(.roundedBorder)
                    }
                }
                GridRow {
                    Text(L("User")).foregroundStyle(.secondary)
                    TextField(L("e.g. vedetta"), text: $form.username).textFieldStyle(.roundedBorder).textContentType(.username)
                }
                if form.choice != .rtsp {
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        DedicatedUserHint(username: form.username)
                    }
                }
                GridRow {
                    Text(L("Password")).foregroundStyle(.secondary)
                    SecureField(form.editing != nil ? L("Enter the password again") : L("Device password"), text: $form.password)
                        .textFieldStyle(.roundedBorder).textContentType(.password)
                }
            }
            if form.choice != .rtsp {
                DisclosureGroup(L("Advanced options"), isExpanded: $advanced) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        if form.choice == .otherRecorder {
                            GridRow {
                                Text(L("Brand")).foregroundStyle(.secondary)
                                Picker(L("Brand"), selection: $form.brand) {
                                    Text(L("Detect automatically (ONVIF)")).tag(RecorderBrand?.none)
                                    ForEach(RecorderBrand.allCases.filter { $0 != .vigi }) { b in Text(b.label).tag(RecorderBrand?.some(b)) }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 300)
                            }
                        }
                        if form.choice == .vigi {
                            GridRow {
                                Text(L("HTTPS port")).foregroundStyle(.secondary)
                                TextField("443", text: $form.httpPort).textFieldStyle(.roundedBorder).frame(width: 90)
                            }
                        }
                        if form.choice == .vigi || form.choice == .otherRecorder {
                            GridRow {
                                Text(L("RTSP port")).foregroundStyle(.secondary)
                                TextField("554", text: $form.rtspPort).textFieldStyle(.roundedBorder).frame(width: 90)
                            }
                        }
                        if form.choice != .vigi {
                            GridRow {
                                Text(L("ONVIF service")).foregroundStyle(.secondary)
                                TextField(L("automatic"), text: $form.onvifURL).textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.callout)
            }
            if let err = form.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular.tint(.orange.opacity(0.15)), in: .rect(cornerRadius: 12))
                .transition(.opacity)
            }
        }
    }
}

struct DiscoveryList: View {
    var onPick: (DiscoveredDevice) -> Void
    var onlyRecorders = false
    @Environment(AppModel.self) private var model

    var body: some View {
        let list = model.discovered.filter { !onlyRecorders || $0.isRecorder }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(onlyRecorders ? L("Recorders found on the network") : L("Devices found on the network")).font(.headline)
                Spacer()
                if model.isDiscovering { ProgressView().controlSize(.small) }
                Button { Task { await model.discover() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.glass).controlSize(.small).help(L("Search again"))
            }
            if list.isEmpty && !model.isDiscovering {
                Text(L("No device found automatically. Enter the address manually."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(list) { d in
                let added = model.devices.contains { $0.host == d.ip }
                Button { onPick(d) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: d.isRecorder ? "externaldrive.connected.to.line.below.fill" : (d.hasPTZ ? "video.circle.fill" : "video.fill"))
                            .foregroundStyle(Theme.accent).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.name).lineLimit(1)
                            Text(d.ip + (d.hasPTZ ? " · " + L("motorized") : "")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if added { Text(L("Already added")).font(.caption).foregroundStyle(.secondary) }
                        else { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                    }
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                .disabled(added)
            }
        }
    }
}

struct AddDeviceSheet: View {
    var editing: Device? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var form = ConnectFormModel()
    @State private var done: ConnectResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                AppGlyph(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(editing == nil ? L("Add a device") : L("Edit %@", editing!.name)).font(.title2.weight(.semibold))
                    Text(editing == nil ? L("Recorders (VIGI, Hikvision, Dahua, Reolink, Uniview, ONVIF), ONVIF cameras of any brand or RTSP addresses.")
                                        : L("Update the device address and credentials."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let done {
                successView(done)
            } else {
                if editing == nil {
                    GlassCard(padding: 14) {
                        DiscoveryList { found in withAnimation(.snappy) { form.fill(from: found) } }
                    }
                }
                GlassCard(padding: 16) { ConnectFields(form: form) }
                HStack {
                    if form.isConnecting {
                        ProgressView().controlSize(.small)
                        Text(L("Connecting…")).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("Cancel")) { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                    Button(editing == nil ? L("Connect") : L("Save")) {
                        Task {
                            if let r = await form.connect() {
                                model.addOrUpdate(r, password: form.password)
                                withAnimation(.snappy) { done = r }
                            }
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!form.canConnect)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .animation(.snappy, value: form.error)
        .onAppear {
            form = ConnectFormModel(editing: editing)
            if editing == nil && model.discovered.isEmpty { Task { await model.discover() } }
        }
    }

    private func successView(_ r: ConnectResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 34)).foregroundStyle(.green)
                VStack(alignment: .leading) {
                    Text(L("%@ connected", r.device.name)).font(.headline)
                    Text(L("%@ cameras ready", String(r.device.channels.count))).foregroundStyle(.secondary)
                }
            }
            GlassCard(padding: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(r.device.channels.prefix(16)) { ch in
                        HStack { StatusDot(color: ch.isOnline ? .green : .gray); Text(ch.name); Spacer()
                            if ch.hasPTZ { Text("PTZ").font(.caption2.weight(.bold)).foregroundStyle(Theme.accent) } }
                    }
                }
            }
            HStack {
                Spacer()
                Button(L("Done")) { dismiss(); model.section = .live }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Devices list

struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Device?
    @State private var confirmRemove: Device?
    @State private var refreshing: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(model.devices) { d in deviceCard(d) }
                Button {
                    model.showAddDevice = true
                } label: {
                    Label(L("Add device"), systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
            .padding(20)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(L("Devices"))
        .toolbar { ToolbarItem(placement: .navigation) { Text(L("Devices")).font(.headline).padding(.horizontal, 6) } }
        .sheet(item: $editing) { d in AddDeviceSheet(editing: d) }
        .alert(L("Remove %@?", confirmRemove?.name ?? ""), isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button(L("Cancel"), role: .cancel) { confirmRemove = nil }
            Button(L("Remove"), role: .destructive) { if let d = confirmRemove { model.remove(d) }; confirmRemove = nil }
        } message: {
            Text(L("The device and its cameras will be removed from Vedetta. Recordings on the recorder are not touched."))
        }
    }

    private func deviceCard(_ d: Device) -> some View {
        GlassCard(padding: 18, cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accent.gradient.opacity(0.9)).frame(width: 52, height: 52)
                        Image(systemName: d.kind.symbol).font(.title2).foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(d.name).font(.title3.weight(.semibold))
                        Text([d.kind.label, d.model, d.host].compactMap { $0 }.joined(separator: " · "))
                            .font(.callout).foregroundStyle(.secondary)
                        if let fw = d.firmware { Text(L("Firmware %@", fw)).font(.caption).foregroundStyle(.tertiary) }
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Button {
                            Task { await refresh(d) }
                        } label: {
                            if refreshing == d.id { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                        }
                        .help(L("Refresh the camera list"))
                        if d.kind != .rtspCamera {
                            Button { WebInterfaceWindow.open(device: d) } label: { Image(systemName: "safari") }
                                .help(L("Open the device web interface (all settings)"))
                        }
                        Button { editing = d } label: { Image(systemName: "pencil") }.help(L("Edit credentials"))
                        Menu {
                            Button(L("Switch User…")) { AccountActions.confirm(.switchUser, device: d, model: model) }
                            Button(L("Sign Out…")) { AccountActions.confirm(.signOut, device: d, model: model) }
                        } label: {
                            Image(systemName: "person.crop.circle")
                        }
                        .menuIndicator(.hidden)
                        .help(L("User: %@", d.username))
                        Button(role: .destructive) { confirmRemove = d } label: { Image(systemName: "trash") }.help(L("Remove"))
                    }
                    .buttonStyle(.glass)
                }
                let state = model.accessState(d)
                if state.needsUser || state.isOffline {
                    AccessNotice(state: state)
                } else if isAdministratorName(d.username) {
                    DedicatedUserHint(username: d.username)
                }
                Divider()
                VStack(spacing: 0) {
                    ForEach(d.channels) { ch in
                        ChannelSettingsRow(channel: ch)
                        if ch.id != d.channels.last?.id { Divider().opacity(0.5) }
                    }
                }
            }
        }
    }

    private func refresh(_ d: Device) async {
        refreshing = d.id
        defer { refreshing = nil }
        do {
            let r = try await DeviceConnector.refresh(d)
            model.addOrUpdate(r, password: CredentialCache.shared.password(for: d.id) ?? "")
            model.toast(.success, L("List updated"), L("%@ cameras", String(r.device.channels.count)))
        } catch {
            model.toast(.error, L("Update failed"), error.localizedDescription)
        }
    }
}

struct ChannelSettingsRow: View {
    let channel: Channel
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(color: channel.isOnline ? .green : .gray)
            Text(channel.number, format: .number).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22)
            TextField(L("Name"), text: $name)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { commit() }
                .onChange(of: focused) { _, f in if !f { commit() } }
            if channel.hasPTZ { Text("PTZ").font(.caption2.weight(.bold)).foregroundStyle(Theme.accent) }
            Spacer()
            Toggle(L("Visible"), isOn: Binding(get: { !channel.isHidden }, set: { model.setHidden(channel, !$0) }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .help(L("Show or hide this camera"))
        }
        .padding(.vertical, 8)
        .onAppear { name = channel.name }
    }

    private func commit() {
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty, n != channel.name { model.renameChannel(channel, to: n) } else { name = channel.name }
    }
}

// MARK: - Device web interface (full settings, like the original app)

enum WebInterfaceWindow {
    @MainActor static var windows: [UUID: NSWindow] = [:]

    @MainActor static func open(device: Device) {
        if let w = windows[device.id] { w.makeKeyAndOrderFront(nil); return }
        let url: URL?
        switch device.kind {
        case .vigiNVR: url = URL(string: device.httpPort == 443 ? "https://\(device.host)" : "https://\(device.host):\(device.httpPort)")
        default: url = URL(string: "http://\(device.host)\(device.httpPort == 80 ? "" : ":\(device.httpPort)")")
        }
        guard let url else { return }
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let delegate = TrustingNavigationDelegate()
        web.navigationDelegate = delegate
        objc_setAssociatedObject(web, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        web.load(URLRequest(url: url))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = L("%@ — web interface", device.name)
        w.contentView = web
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        windows[device.id] = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { windows[device.id] = nil }
        }
    }
}

final class TrustingNavigationDelegate: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust,
           TrustStore.shared.evaluate(host: space.host, port: space.port, trust: trust) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
