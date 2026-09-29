import SwiftUI
import AppKit
import UserNotifications
import VedettaCore
import VedettaL10n

@main
struct VedettaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Vedetta", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1080, minHeight: 680)
                .onAppear { delegate.model = model }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1440, height: 900)
        .commands { AppCommands(model: model) }

        WindowGroup(L("Camera"), id: "channel", for: String.self) { $channelID in
            DetachedChannelWindow(channelID: channelID ?? "")
                .environment(model)
                .frame(minWidth: 480, minHeight: 300)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 960, height: 600)

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra(isInserted: Binding(get: { model.settings.keepInMenuBar },
                                         set: { v in if model.settings.keepInMenuBar != v { model.settings.keepInMenuBar = v } })) {
            MenuBarContent().environment(model)
        } label: {
            Image(systemName: "video.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !(model?.settings.keepInMenuBar ?? true) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = MainActor.assumeIsolated { model?.exports.activeCount ?? 0 }
        let recording = MainActor.assumeIsolated { !(model?.liveRecordings.isEmpty ?? true) }
        if busy == 0, recording {
            // Close the MP4 files properly before quitting.
            MainActor.assumeIsolated { model?.finishAllRecordings { NSApp.reply(toApplicationShouldTerminate: true) } }
            return .terminateLater
        }
        guard busy > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L("Exports in progress")
        alert.informativeText = L("There are %@ unfinished exports. If you quit they will be interrupted and resumed at the next launch.", String(busy))
        alert.addButton(withTitle: L("Quit anyway"))
        alert.addButton(withTitle: L("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            model?.pool.stopAll()
            DeviceClients.shared.logoutAll()   // no session left open on the recorders
            JSONStore<AppSettings>.flushAll()   // pending settings writes reach the disk
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let ch = info["channelID"] as? String, let t = info["time"] as? Double {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                self.model?.openPlayback(channelIDs: [ch], at: Date(timeIntervalSince1970: t - 5))
            }
        }
        completionHandler()
    }
}

struct AppCommands: Commands {
    var model: AppModel
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L("Add device…")) { model.showAddDevice = true }
                .keyboardShortcut("n")
        }
        CommandGroup(replacing: .importExport) {
            Button(L("Export Settings…")) { SettingsTransfer.export(model: model) }
            Button(L("Import Settings…")) { SettingsTransfer.importFile(model: model) }
        }
        CommandGroup(after: .appSettings) {
            Divider()
            AccountMenuItems(model: model)
        }
        CommandMenu(L("View")) {
            ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { i, s in
                Button(s.title) { model.section = s }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            Divider()
            Menu(L("Layout")) {
                ForEach(GridKind.allCases) { g in
                    Button(g.label) { model.section = .live; model.setGrid(g) }
                }
            }
            Button(model.tourRunning ? L("Stop automatic tour") : L("Start automatic tour")) { model.toggleTour() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button(L("Next page")) { model.nextPage() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button(L("Previous page")) { model.previousPage() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
        }
    }
}
