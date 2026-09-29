import SwiftUI
import AppKit
import VedettaCore
import NetKit
import VedettaL10n

// MARK: - Sign out / switch user

enum AccountActions {
    enum Kind { case signOut, switchUser }

    /// Asks for confirmation, then signs out (and opens the sign-in screen for "Switch user").
    @MainActor
    static func confirm(_ kind: Kind, device d: Device, model: AppModel) {
        let alert = NSAlert()
        switch kind {
        case .signOut:
            alert.messageText = L("Sign out of %@?", d.name)
            alert.informativeText = L("Vedetta closes the video, ends the session on the recorder and deletes the saved password. You can then sign in with another address, user or password.")
            alert.addButton(withTitle: L("Sign Out"))
        case .switchUser:
            alert.messageText = L("Switch the user of %@?", d.name)
            alert.informativeText = L("Vedetta first signs out completely (video closed, session ended on the recorder, password deleted), then asks for the new user.")
            alert.addButton(withTitle: L("Switch User"))
        }
        alert.addButton(withTitle: L("Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await model.signOut(d, switchUser: kind == .switchUser) }
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// "Sign out" and "Switch user" for each device (app menu, settings, device cards).
struct AccountMenuItems: View {
    var model: AppModel

    var body: some View {
        let list = model.devices
        if list.count == 1, let d = list.first {
            Button(L("Switch User…")) { AccountActions.confirm(.switchUser, device: d, model: model) }
            Button(L("Sign Out of %@…", d.name)) { AccountActions.confirm(.signOut, device: d, model: model) }
        } else if list.count > 1 {
            Menu(L("Switch User")) {
                ForEach(list) { d in Button(d.name) { AccountActions.confirm(.switchUser, device: d, model: model) } }
            }
            Menu(L("Sign Out")) {
                ForEach(list) { d in Button(d.name) { AccountActions.confirm(.signOut, device: d, model: model) } }
            }
        }
    }
}

// MARK: - Sign-in screen

/// Sign in to a device: after a sign out, a switch of user, refused credentials, a locked account or a
/// missing password. Nothing is attempted automatically while it is shown.
struct SignInView: View {
    let deviceID: UUID
    var clearUser = false
    var inSheet = false
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var form = ConnectFormModel()
    @State private var prepared = false

    var body: some View {
        if let device = model.devices.first(where: { $0.id == deviceID }) {
            content(device)
                .onAppear { prepare(device) }
                .animation(.snappy, value: form.error)
        }
    }

    private func content(_ device: Device) -> some View {
        let state = model.accessState(device)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                AppGlyph(size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Sign in to %@", device.name)).font(.title2.weight(.semibold))
                    Text([device.kind.label, device.model, device.host].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            AccessNotice(state: state)
            GlassCard(padding: 16) { ConnectFields(form: form, showKindPicker: false) }
            HStack(spacing: 10) {
                if form.isConnecting {
                    ProgressView().controlSize(.small)
                    Text(L("Connecting…")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if device.storedCredentials != nil, isRetryable(state) {
                    Button(L("Try Again")) { model.retryAccess(device) }
                        .buttonStyle(.glass)
                        .help(L("One new attempt with the saved password"))
                }
                if inSheet {
                    Button(L("Not Now")) { model.signIn = nil; dismiss() }
                        .buttonStyle(.glass).keyboardShortcut(.cancelAction)
                }
                Button(L("Sign In")) {
                    Task {
                        if let r = await form.connect() {
                            model.addOrUpdate(r, password: form.password)
                            if inSheet { dismiss() }
                        }
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!form.canConnect)
            }
            Text(L("Vedetta never repeats a refused password by itself and makes one attempt at a time, so the recorder does not lock the user."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(inSheet ? 24 : 32)
        .frame(width: 560)
    }

    private func isRetryable(_ s: AccessState) -> Bool {
        switch s {
        case .rejected, .locked: return true
        default: return false
        }
    }

    private func prepare(_ device: Device) {
        guard !prepared else { return }
        prepared = true
        let f = ConnectFormModel(editing: device)
        f.password = ""
        if clearUser { f.username = "" }
        form = f
    }
}

/// Full-window sign-in when no device can be used (single recorder signed out, refused, locked…).
struct SignInScreen: View {
    @Environment(AppModel.self) private var model
    @State private var selected: UUID?

    var body: some View {
        let list = model.devicesNeedingSignIn
        let current = selected.flatMap { id in list.first { $0.id == id } } ?? list.first
        VStack(spacing: 16) {
            if list.count > 1 {
                Picker(L("Device"), selection: Binding(get: { current?.id }, set: { selected = $0 })) {
                    ForEach(list) { Text($0.name).tag(Optional($0.id)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 560)
            }
            if let current {
                SignInView(deviceID: current.id, clearUser: model.signIn?.deviceID == current.id && model.signIn?.clearUser == true)
                    .id(current.id)
                    .glassEffect(.regular, in: .rect(cornerRadius: 28))
            }
            Button(L("Add another device…")) { model.showAddDevice = true }
                .buttonStyle(.plain).foregroundStyle(.secondary).font(.callout)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Explains why Vedetta is not connecting (refused, locked, missing password, signed out, offline).
struct AccessNotice: View {
    let state: AccessState

    var body: some View {
        if let (symbol, color) = style {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(color).font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                    if case .locked = state {
                        Text(L("To unlock it now, use the recorder's own screen or restart it; the recorder may also sound its buzzer for failed logins."))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(color.opacity(0.15)), in: .rect(cornerRadius: 12))
        }
    }

    private var style: (String, Color)? {
        switch state {
        case .rejected: return ("person.crop.circle.badge.xmark", .orange)
        case .locked: return ("lock.fill", .red)
        case .missingPassword: return ("key.slash", .orange)
        case .signedOut: return ("rectangle.portrait.and.arrow.right", .secondary)
        case .offline: return ("wifi.exclamationmark", .yellow)
        case .online, .unverified: return nil
        }
    }
}

/// Strip above the main content for devices that are offline or wait for the user.
struct AccessBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.devices.filter { d in
            let s = model.accessState(d)
            return s.needsUser || s.isOffline
        }
        if !items.isEmpty {
            VStack(spacing: 6) {
                ForEach(items) { d in row(d) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func row(_ d: Device) -> some View {
        let s = model.accessState(d)
        return HStack(spacing: 10) {
            Image(systemName: s.isOffline ? "wifi.exclamationmark" : (s == .signedOut ? "rectangle.portrait.and.arrow.right" : "lock.trianglebadge.exclamationmark"))
                .foregroundStyle(s.isOffline ? .yellow : .orange)
            Text(d.name).font(.callout.weight(.semibold))
            Text(s.message).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 8)
            if s.isOffline {
                Button(L("Check Now")) { model.retryAccess(d) }.buttonStyle(.glass).controlSize(.small)
            } else {
                Button(L("Sign In…")) { model.signIn = AppModel.SignInRequest(deviceID: d.id) }
                    .buttonStyle(.glassProminent).controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .glassEffect(.regular.tint((s.isOffline ? Color.yellow : Color.orange).opacity(0.12)), in: .capsule)
    }
}

// MARK: - Dedicated user advice

func isAdministratorName(_ user: String) -> Bool {
    ["admin", "administrator", "root", "supervisor", "amministratore"].contains(user.trimmingCharacters(in: .whitespaces).lowercased())
}

/// Shown under the user name field: recommends a dedicated view-only user instead of admin.
struct DedicatedUserHint: View {
    var username: String
    var body: some View {
        if isAdministratorName(username) {
            Label {
                Text(L("Not recommended: create a dedicated user on the recorder with view-only permissions (live view and playback). If the admin account got locked you would also lose the recorder management."))
            } icon: {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(L("Tip: a dedicated user with view-only permissions keeps the admin account safe."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
