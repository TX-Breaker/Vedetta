import SwiftUI
import AppKit
import VedettaCore
import NetKit
import VedettaL10n

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label(L("General"), systemImage: "gearshape") }
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
                Toggle(L("Fill the tiles (crop the edges)"), isOn: $model.settings.fillTiles)
                Toggle(L("Show codec, resolution and bitrate"), isOn: $model.settings.showStreamInfo)
                Stepper(L("Automatic tour every %@ seconds", String(model.settings.tourIntervalSeconds)),
                        value: $model.settings.tourIntervalSeconds, in: 5...600, step: 5)
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
