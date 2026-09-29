import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VedettaCore
import NetKit
import VedettaL10n

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label(L("General"), systemImage: "gearshape") }
            AccountSettings().tabItem { Label(L("Accounts"), systemImage: "person.badge.key") }
            VideoSettings().tabItem { Label(L("Video"), systemImage: "play.rectangle") }
            FolderSettings().tabItem { Label(L("Folders"), systemImage: "folder") }
            AdvancedSettings().tabItem { Label(L("Advanced"), systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 560)
        .padding(.vertical, 8)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var language = AppLanguage.override
    @State private var askRestart = false
    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker(L("Language"), selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .onChange(of: language) { _, new in
                    AppLanguage.override = new
                    askRestart = true
                }
                Text(L("Vedetta follows the language of macOS. Choose a language to override it."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(L("Open Vedetta when the Mac starts"), isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Toggle(L("Keep running in the menu bar when the window is closed"), isOn: $model.settings.keepInMenuBar)
            }
            Section {
                Toggle(L("Notifications for motion, people and vehicles"), isOn: $model.settings.notificationsEnabled)
                Text(L("Vedetta checks the recorder events every minute and notifies you. Click the notification to review the moment."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(L("Lock the app with Touch ID or your Mac password"), isOn: $model.settings.lockWithTouchID)
            }
        }
        .formStyle(.grouped)
        .alert(L("Restart Vedetta to apply the new language."), isPresented: $askRestart) {
            Button(L("Later"), role: .cancel) {}
            Button(L("Restart now")) { AppRelauncher.relaunch() }
        }
    }
}

/// Export / import of every setting (File menu and Settings › Advanced). Passwords are never in the file.
enum SettingsTransfer {
    @MainActor
    static func export(model: AppModel) {
        let panel = NSSavePanel()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "Vedetta \(L("settings")) \(f.string(from: Date())).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportSettings(to: url)
            model.toast(.success, L("Settings exported"), L("Passwords are not included."), file: url)
        } catch {
            model.toast(.error, L("Cannot export the settings"), error.localizedDescription)
        }
    }

    @MainActor
    static func importFile(model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let backup = try SettingsBackup.decode(Data(contentsOf: url))
            let alert = NSAlert()
            alert.messageText = L("Replace the current settings?")
            alert.informativeText = L("Devices, cameras, layout and preferences will be replaced by those in the file (%@ devices). For devices without a saved password Vedetta will ask you to sign in.", String(backup.devices.count))
            alert.addButton(withTitle: L("Import"))
            alert.addButton(withTitle: L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            model.importSettings(backup)
            model.toast(.success, L("Settings imported"), L("%@ devices", String(backup.devices.count)))
        } catch {
            model.toast(.error, L("This is not a Vedetta settings file"), error.localizedDescription)
        }
    }
}

/// Relaunches the app (used to apply a new interface language).
enum AppRelauncher {
    static func relaunch() {
        let url = Bundle.main.bundleURL
        // Start the new instance once this one has quit.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"\(url.path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// Users in use on each device, sign out / switch user, dedicated-user advice and the connection log.
private struct AccountSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section(L("Devices")) {
                if model.devices.isEmpty {
                    Text(L("No device yet.")).foregroundStyle(.secondary)
                }
                ForEach(model.devices) { d in
                    let state = model.accessState(d)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            StatusDot(color: color(state))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.name).font(.body.weight(.medium))
                                Text(L("User: %@", d.username.isEmpty ? "—" : d.username) + " · " + (state.isUsable ? L("Connected") : shortState(state)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if state.needsUser {
                                Button(L("Sign In…")) {
                                    model.signIn = AppModel.SignInRequest(deviceID: d.id)
                                    NSApp.activate(ignoringOtherApps: true)
                                }
                            } else {
                                Button(L("Switch User…")) { AccountActions.confirm(.switchUser, device: d, model: model) }
                                Button(L("Sign Out")) { AccountActions.confirm(.signOut, device: d, model: model) }
                            }
                        }
                        if state.needsUser || state.isOffline {
                            Text(state.message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        } else if d.kind != .rtspCamera {
                            DedicatedUserHint(username: d.username)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            Section(L("Dedicated user")) {
                Text(L("Create a user just for Vedetta on the recorder with live view and playback permissions only, and sign in with it here. Vedetta never retries a refused password, but a separate user also keeps the admin account and the recorder's own apps unaffected."))
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text(L("VIGI recorders: in the settings (web interface or local screen) open user management and add a user. Other brands: the same in the web interface (for ONVIF, an “Operator” or “User” level)."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(L("Connection log")) {
                LabeledContent(L("Logins, checks and errors")) {
                    HStack {
                        Button(L("Open")) {
                            let url = AccessLog.shared.fileURL
                            AccessLog.shared.flush()
                            if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
                            else { model.toast(.info, L("The log is empty"), L("Nothing has been recorded yet.")) }
                        }
                        Button(L("Show in Finder")) {
                            AccessLog.shared.flush()
                            NSWorkspace.shared.activateFileViewerSelecting([AccessLog.shared.fileURL])
                        }
                    }
                }
                Text(L("Every connection attempt is recorded on this Mac with time, result and error code, to understand what happened. Passwords are never written."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func color(_ s: AccessState) -> Color {
        switch s {
        case .online: return .green
        case .unverified: return .yellow
        case .offline: return .yellow
        case .locked: return .red
        default: return .orange
        }
    }

    private func shortState(_ s: AccessState) -> String {
        switch s {
        case .offline: return L("Not reachable")
        case .rejected: return L("Password refused")
        case .locked: return L("User locked")
        case .missingPassword: return L("Password missing")
        case .signedOut: return L("Signed out")
        default: return L("Connecting…")
        }
    }
}

private struct VideoSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Form {
            Section(L("Live")) {
                Picker(L("Quality"), selection: $model.settings.liveQuality) {
                    ForEach(StreamQuality.allCases) { Text($0.label).tag($0) }
                }
                Text(L("“Automatic” uses the light stream in small tiles and high quality when you enlarge: it uses less network and CPU."))
                    .font(.caption).foregroundStyle(.secondary)
                Picker(L("Picture in the tiles"), selection: $model.settings.tileFit) {
                    ForEach(TileFit.allCases) { Text($0.label).tag($0) }
                }
                Text(L("Cameras with black bars send their light stream in 4:3 (e.g. 640×480) while the tiles are 16:9. “Fill” crops the edges, and with them the camera clock; “Stretch” shows everything. The best fix is to set the camera's sub-stream to 16:9 (e.g. 640×360) on the recorder."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker(L("Camera names"), selection: $model.settings.tileLabels) {
                    ForEach(TileLabelMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle(L("Show codec, resolution and bitrate"), isOn: $model.settings.showStreamInfo)
                Stepper(L("Automatic tour every %@ seconds", String(model.settings.tourIntervalSeconds)),
                        value: $model.settings.tourIntervalSeconds, in: 5...600, step: 5)
            }
            Section(L("Recordings")) {
                Picker(L("Mouse wheel on the timeline"), selection: $model.settings.timelineWheel) {
                    ForEach(TimelineWheel.allCases) { Text($0.label).tag($0) }
                }
                Toggle(L("Include the audio when saving recordings"), isOn: $model.settings.exportAudio)
                Text(L("Snapshots and recordings on this Mac always use the camera's full-quality stream, even when the tile shows the light one."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

private struct FolderSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Form {
            folderRow(L("Snapshots"), path: $model.settings.snapshotsPath)
            folderRow(L("Live recordings"), path: $model.settings.recordingsPath)
            folderRow(L("Exports from the recorder"), path: $model.settings.exportsPath)
        }
        .formStyle(.grouped)
    }

    private func folderRow(_ title: String, path: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack {
                Text(path.wrappedValue.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Button(L("Change…")) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.directoryURL = URL(fileURLWithPath: path.wrappedValue)
                    if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
                }
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: path.wrappedValue)) } label: { Image(systemName: "arrow.forward.circle") }
                    .buttonStyle(.borderless).help(L("Open in Finder"))
            }
        }
    }
}

private struct AdvancedSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false
    var body: some View {
        Form {
            Section(L("Security")) {
                LabeledContent(L("Device certificates")) {
                    Button(L("Forget")) {
                        TrustStore.shared.forgetAll()
                        model.toast(.info, L("Certificates forgotten"), L("They will be stored again at the next connection."))
                    }
                }
                Text(L("Vedetta remembers each device's certificate at the first connection and warns you if it changes."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Data")) {
                LabeledContent(L("Recordings cache")) {
                    Button(L("Empty")) { model.index.clearCache() }
                }
                LabeledContent(L("Configuration")) {
                    Button(L("Show in Finder")) { NSWorkspace.shared.open(AppPaths.supportDirectory) }
                }
                LabeledContent(L("All settings and devices")) {
                    HStack {
                        Button(L("Export…")) { SettingsTransfer.export(model: model) }
                        Button(L("Import…")) { SettingsTransfer.importFile(model: model) }
                    }
                }
                Text(L("Settings are saved automatically as you change them. The export file contains devices, cameras, layout and preferences, but no passwords: they stay in the Keychain."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(L("About")) {
                LabeledContent(L("Version"), value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                LabeledContent(L("Video decoding"), value: L("Hardware (VideoToolbox)"))
                LabeledContent(L("Language"), value: AppLanguage(rawValue: AppLanguage.current)?.displayName ?? AppLanguage.current)
                LabeledContent(L("Source code")) {
                    Link("github.com/TX-Breaker/vedetta", destination: URL(string: "https://github.com/TX-Breaker/vedetta")!)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AppGlyph(size: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Vedetta").font(.headline)
                    Text(L("%@ cameras online", String(model.allChannels.filter(\.isOnline).count))).font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.exports.activeCount > 0 {
                Label(L("%@ exports in progress", String(model.exports.activeCount)), systemImage: "arrow.down.circle")
                    .font(.callout)
            }
            Divider()
            menuButton(L("Live"), "play.rectangle.on.rectangle.fill") { open(.live) }
            menuButton(L("Recordings"), "clock.arrow.circlepath") { open(.playback) }
            menuButton(L("Events"), "bell.badge") { open(.events) }
            menuButton(L("Exports"), "square.and.arrow.down") { open(.exports) }
            Divider()
            menuButton(L("Quit Vedetta"), "power") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 260)
    }

    private func open(_ s: AppSection) {
        model.section = s
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.windows.contains(where: { $0.isVisible && $0.title == "Vedetta" }) { openWindow(id: "main") }
        NSApp.windows.first { $0.title == "Vedetta" }?.makeKeyAndOrderFront(nil)
    }

    private func menuButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
