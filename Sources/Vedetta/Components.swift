import SwiftUI
import AppKit
import VedettaCore
import VedettaL10n

enum Theme {
    static let accent = Color(red: 0.16, green: 0.72, blue: 0.86)
    static let accentDeep = Color(red: 0.05, green: 0.35, blue: 0.62)
    static let recording = Color(red: 1.0, green: 0.27, blue: 0.27)
    static let continuous = Color(red: 0.20, green: 0.62, blue: 0.95)
    static let motion = Color(red: 1.0, green: 0.62, blue: 0.16)
    static let alarm = Color(red: 1.0, green: 0.30, blue: 0.35)
    static let channelColors: [Color] = [
        Color(red: 0.20, green: 0.66, blue: 1.0), Color(red: 0.55, green: 0.85, blue: 0.35),
        Color(red: 0.98, green: 0.62, blue: 0.20), Color(red: 0.86, green: 0.45, blue: 0.96),
    ]

    static func color(for family: EventType.Family) -> Color {
        switch family {
        case .motion: return motion
        case .person: return Color(red: 0.36, green: 0.84, blue: 0.56)
        case .vehicle: return Color(red: 0.62, green: 0.52, blue: 1.0)
        case .line: return Color(red: 1.0, green: 0.84, blue: 0.20)
        case .area: return Color(red: 0.30, green: 0.85, blue: 0.95)
        case .other: return alarm
        }
    }
}

/// Rounded glass card used across the app.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 16
    var cornerRadius: CGFloat = 20
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}

struct SectionHeader: View {
    var title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                .textCase(.uppercase)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.tertiary) }
        }
    }
}

struct StatusDot: View {
    var color: Color
    var pulsing = false
    @State private var pulse = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(color.opacity(0.5), lineWidth: pulsing && pulse ? 6 : 0).opacity(pulse ? 0 : 1))
            .onAppear { if pulsing { withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { pulse = true } } }
    }
}

struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String
    var action: (label: String, run: () -> Void)?
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.accent.gradient)
                .symbolRenderingMode(.hierarchical)
            Text(title).font(.title2.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            if let action {
                Button(action.label, action: action.run)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .padding(.top, 6)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ToastStack: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(model.toasts) { t in
                ToastView(toast: t)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(!model.toasts.isEmpty)
    }
}

struct ToastView: View {
    var toast: Toast
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).font(.callout.weight(.semibold))
                if let d = toast.detail { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            }
            if let url = toast.fileURL {
                Button(L("Show")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.glass).controlSize(.small)
            }
            Button { model.toasts.removeAll { $0.id == toast.id } } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).font(.caption)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: 380, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
    var icon: String {
        switch toast.style {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
    var color: Color {
        switch toast.style {
        case .info: return Theme.accent
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

/// Glass icon button used on video overlays.
struct OverlayButton: View {
    var symbol: String
    var help: String
    var tint: Color? = nil
    var active = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .foregroundStyle(active ? (tint ?? Theme.accent) : .white)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.clear.interactive(), in: .circle)
        .help(help)
    }
}

extension View {
    /// Hover tracking helper.
    func onHoverChange(_ binding: Binding<Bool>) -> some View {
        onHover { h in withAnimation(.easeOut(duration: 0.18)) { binding.wrappedValue = h } }
    }
}

extension String {
    /// Capitalizes only the first letter ("lunedì 28 settembre" → "Lunedì 28 settembre").
    var firstCapitalized: String { prefix(1).uppercased() + dropFirst() }
}

enum Format {
    /// Formatters follow the interface language (month/day names, ordering) and the region.
    private static func make(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = AppLanguage.locale
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }
    static let time = make("HHmmss")
    static let shortTime = make("HHmm")
    static let dayLong = make("EEEEdMMMMyyyy")
    static let dayShort = make("EEEdMMM")
    static let month = make("LLLLyyyy")
    static let dateTime = make("dMMMyyyyHHmmss")

    static func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
    static func duration(_ s: TimeInterval) -> String {
        let t = Int(max(0, s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
    }
}
