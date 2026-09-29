import Foundation
import UserNotifications
import VedettaCore
import VigiKit
import VedettaL10n

/// Polls the NVR for new detection events and posts macOS notifications.
@MainActor
final class EventMonitor {
    private weak var model: AppModel?
    private var timer: Timer?
    private var seen = Set<String>()
    private var lastCheck = Date()
    private var running = false

    init(model: AppModel) { self.model = model }

    func start() {
        guard !running else { return }
        running = true
        lastCheck = Date().addingTimeInterval(-120)
        Notifier.requestAuthorization()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.poll() }
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
    }

    func restart() {
        guard running else { return }
        stop()
        start()
    }

    private func poll() {
        guard running, let model else { return }
        let from = lastCheck.addingTimeInterval(-30)
        let to = Date()
        lastCheck = to
        let vigi = model.devices.filter { $0.kind == .vigiNVR }
        let onvif = model.devices.filter { ($0.kind == .onvifNVR || $0.kind == .onvifCamera) && $0.channels.contains { $0.recordingToken != nil } }
        Task { @MainActor in
            var candidates: [(Channel, Int, Date)] = []
            func add(_ ch: Channel, _ type: Int, _ start: Date) { candidates.append((ch, type, start)) }
            for d in vigi {
                let client = DeviceClients.shared.vigi(for: d)
                for ch in d.visibleChannels where ch.isOnline {
                    guard let evs = try? await client.events(channel: ch.number, from: from, to: to) else { continue }
                    for e in evs { add(ch, e.eventType, e.start) }
                }
            }
            // Other brands: detections stored with the ONVIF recordings (Profile G).
            for d in onvif {
                guard let client = DeviceClients.shared.onvif(for: d) else { continue }
                for ch in d.visibleChannels {
                    guard let token = ch.recordingToken,
                          let raw = try? await client.findEvents(recording: token, from: from, to: to, maxMatches: 200) else { continue }
                    for e in PlaybackBackend.detections(raw, channelID: ch.id) { add(ch, e.type, e.start) }
                }
            }
            var fresh: [(Channel, Int, Date)] = []
            for (ch, type, start) in candidates where start >= from {
                let key = "\(ch.id)-\(Int(start.timeIntervalSince1970))-\(type)"
                if self.seen.insert(key).inserted { fresh.append((ch, type, start)) }
            }
            if self.seen.count > 5000 { self.seen.removeAll() }
            guard !fresh.isEmpty else { return }
            model.newEventCount += fresh.count
            let tf = DateFormatter()
            tf.timeStyle = .medium
            for (ch, type, start) in fresh.prefix(5) {
                let content = UNMutableNotificationContent()
                content.title = "\(EventType(code: type).name) · \(ch.name)"
                content.body = L("Detected at %@. Click to review.", tf.string(from: start))
                content.sound = .default
                content.threadIdentifier = ch.id
                content.userInfo = ["channelID": ch.id, "time": start.timeIntervalSince1970]
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
            if fresh.count > 5 {
                Notifier.post(title: L("%@ more events", String(fresh.count - 5)), body: L("Open Vedetta › Events to see them all."))
            }
        }
    }
}
