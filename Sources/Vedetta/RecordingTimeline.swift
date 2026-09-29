import SwiftUI
import AppKit
import VedettaCore

struct TimelineLane: Identifiable {
    var channel: Channel
    var color: Color
    var segments: [TimelineSegment]
    var id: String { channel.id }
}

/// Zoomable 24-hour timeline: recording lanes per channel, event markers, playhead and clip selection.
struct RecordingTimeline: View {
    var dayStart: Date
    var lanes: [TimelineLane]
    var events: [TimelineEvent]
    var current: Date
    @Binding var span: TimeInterval
    @Binding var center: Date
    @Binding var clip: ClosedRange<Date>?
    var clipMode: Bool
    /// true: the plain wheel zooms around the pointer (Shift + wheel or sideways scrolls); false: the wheel scrolls.
    var wheelZooms: Bool = true
    var onSeek: (Date) -> Void

    @State private var scrubTime: Date?
    @State private var hoverX: CGFloat?
    @State private var hovering = false
    @State private var monitor: Any?
    @State private var dragHandle: Int? // 0 = start, 1 = end
    @State private var lastUserScroll = Date.distantPast

    private let rulerHeight: CGFloat = 22
    private let eventRowHeight: CGFloat = 12
    private let laneHeight: CGFloat = 12
    private let laneGap: CGFloat = 5

    var dayEnd: Date { dayStart.addingTimeInterval(86400) }

    var height: CGFloat { rulerHeight + eventRowHeight + 6 + CGFloat(max(1, lanes.count)) * (laneHeight + laneGap) + 4 }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let range = visibleRange
            Canvas { ctx, size in
                draw(ctx: &ctx, size: size, range: range)
            }
            .overlay(alignment: .topLeading) { bubble(width: w, range: range) }
            .contentShape(Rectangle())
            .gesture(dragGesture(width: w, range: range))
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hoverX = p.x; hovering = true
                case .ended: hoverX = nil; hovering = false
                }
            }
            .onAppear { installMonitor(width: w) }
            .onDisappear { removeMonitor() }
            .onChange(of: w) { _, nw in removeMonitor(); installMonitor(width: nw) }
        }
        .frame(height: height)
        .onChange(of: current) { _, t in followPlayhead(t) }
    }

    // MARK: Geometry

    var visibleRange: ClosedRange<Date> {
        let half = span / 2
        var s = center.addingTimeInterval(-half)
        var e = center.addingTimeInterval(half)
        if s < dayStart { s = dayStart; e = dayStart.addingTimeInterval(span) }
        if e > dayEnd { e = dayEnd; s = dayEnd.addingTimeInterval(-span) }
        return s...e
    }

    private func x(for t: Date, width: CGFloat, range: ClosedRange<Date>) -> CGFloat {
        CGFloat(t.timeIntervalSince(range.lowerBound) / range.upperBound.timeIntervalSince(range.lowerBound)) * width
    }

    private func time(at x: CGFloat, width: CGFloat, range: ClosedRange<Date>) -> Date {
        let f = min(1, max(0, x / max(1, width)))
        return range.lowerBound.addingTimeInterval(Double(f) * range.upperBound.timeIntervalSince(range.lowerBound))
    }

    // MARK: Drawing

    private func draw(ctx: inout GraphicsContext, size: CGSize, range: ClosedRange<Date>) {
        let w = size.width
        let (major, minor, labelEvery) = tickSteps(span)
        let startSec = range.lowerBound.timeIntervalSince(dayStart)
        let endSec = range.upperBound.timeIntervalSince(dayStart)

        // Minor ticks
        var t = (startSec / minor).rounded(.down) * minor
        while t <= endSec {
            let xx = x(for: dayStart.addingTimeInterval(t), width: w, range: range)
            let isMajor = t.truncatingRemainder(dividingBy: major) == 0
            let h: CGFloat = isMajor ? 8 : 4
            ctx.fill(Path(CGRect(x: xx - 0.5, y: rulerHeight - h, width: 1, height: h)), with: .color(.secondary.opacity(isMajor ? 0.7 : 0.35)))
            if isMajor {
                ctx.fill(Path(CGRect(x: xx - 0.25, y: rulerHeight, width: 0.5, height: size.height - rulerHeight)), with: .color(.secondary.opacity(0.12)))
            }
            if t.truncatingRemainder(dividingBy: labelEvery) == 0 {
                let label = Text(label(for: t)).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                ctx.draw(label, at: CGPoint(x: xx, y: 6), anchor: .center)
            }
            t += minor
        }

        // Events row
        let evY = rulerHeight + 3
        for e in events where e.end >= range.lowerBound && e.start <= range.upperBound {
            let x0 = x(for: e.start, width: w, range: range)
            let x1 = max(x0 + 3, x(for: e.end, width: w, range: range))
            let r = CGRect(x: x0, y: evY, width: x1 - x0, height: eventRowHeight - 2)
            ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(Theme.color(for: e.info.family)))
        }

        // Lanes
        var y = rulerHeight + eventRowHeight + 6
        for lane in lanes {
            let bg = CGRect(x: 0, y: y, width: w, height: laneHeight)
            ctx.fill(Path(roundedRect: bg, cornerRadius: laneHeight / 2), with: .color(.primary.opacity(0.06)))
            for s in lane.segments where s.end >= range.lowerBound && s.start <= range.upperBound {
                let x0 = max(0, x(for: s.start, width: w, range: range))
                let x1 = min(w, max(x0 + 1.5, x(for: s.end, width: w, range: range)))
                let color: Color
                switch s.kind {
                case .continuous: color = lane.color.opacity(0.75)
                case .event: color = Theme.motion
                case .alarm: color = Theme.alarm
                }
                ctx.fill(Path(roundedRect: CGRect(x: x0, y: y + 1, width: x1 - x0, height: laneHeight - 2), cornerRadius: (laneHeight - 2) / 2), with: .color(color))
            }
            y += laneHeight + laneGap
        }

        // Clip selection
        if let clip {
            let x0 = x(for: clip.lowerBound, width: w, range: range)
            let x1 = x(for: clip.upperBound, width: w, range: range)
            let top = rulerHeight
            ctx.fill(Path(CGRect(x: x0, y: top, width: max(1, x1 - x0), height: size.height - top)), with: .color(Theme.accent.opacity(0.18)))
            for hx in [x0, x1] {
                ctx.fill(Path(roundedRect: CGRect(x: hx - 3, y: top, width: 6, height: size.height - top), cornerRadius: 3), with: .color(Theme.accent))
            }
        }

        // Hover line
        if let hoverX, scrubTime == nil, dragHandle == nil {
            ctx.fill(Path(CGRect(x: hoverX - 0.5, y: rulerHeight, width: 1, height: size.height - rulerHeight)), with: .color(.primary.opacity(0.35)))
        }

        // Playhead
        let shown = scrubTime ?? current
        if range.contains(shown) {
            let px = x(for: shown, width: w, range: range)
            ctx.fill(Path(CGRect(x: px - 1, y: rulerHeight - 4, width: 2, height: size.height - rulerHeight + 4)), with: .color(.white))
            ctx.fill(Path(ellipseIn: CGRect(x: px - 5, y: rulerHeight - 9, width: 10, height: 10)), with: .color(.white))
            ctx.stroke(Path(ellipseIn: CGRect(x: px - 5, y: rulerHeight - 9, width: 10, height: 10)), with: .color(Theme.accent), lineWidth: 2)
        }
    }

    @ViewBuilder
    private func bubble(width: CGFloat, range: ClosedRange<Date>) -> some View {
        if let t = scrubTime ?? (hovering ? hoverX.map { time(at: $0, width: width, range: range) } : nil) {
            let px = x(for: t, width: width, range: range)
            Text(Format.time.string(from: t))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 7).padding(.vertical, 3)
                .glassEffect(.regular, in: .capsule)
                .fixedSize()
                .position(x: min(max(px, 34), width - 34), y: -14)
                .allowsHitTesting(false)
        }
    }

    private func tickSteps(_ span: TimeInterval) -> (major: Double, minor: Double, label: Double) {
        switch span {
        case 43200...: return (3600, 900, 7200)
        case 14400...: return (1800, 300, 3600)
        case 3600...: return (600, 60, 1200)
        case 1200...: return (300, 60, 300)
        case 300...: return (60, 10, 120)
        default: return (30, 5, 30)
        }
    }

    private func label(for secondsFromMidnight: Double) -> String {
        let s = Int(secondsFromMidnight)
        if s >= 86400 { return "24:00" }
        return span < 1200 ? String(format: "%02d:%02d", s / 3600, (s / 60) % 60)
                           : String(format: "%02d:%02d", s / 3600, (s / 60) % 60)
    }

    // MARK: Interaction

    private func dragGesture(width: CGFloat, range: ClosedRange<Date>) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let t = time(at: v.location.x, width: width, range: range)
                if clipMode {
                    if dragHandle == nil {
                        if let clip {
                            let x0 = x(for: clip.lowerBound, width: width, range: range)
                            let x1 = x(for: clip.upperBound, width: width, range: range)
                            if abs(v.startLocation.x - x0) < 10 { dragHandle = 0 }
                            else if abs(v.startLocation.x - x1) < 10 { dragHandle = 1 }
                        }
                        if dragHandle == nil {
                            // Start a new selection.
                            let t0 = time(at: v.startLocation.x, width: width, range: range)
                            clip = min(t0, t)...max(t0, t.addingTimeInterval(1))
                            dragHandle = 1
                        }
                    }
                    if let h = dragHandle, let c = clip {
                        if h == 0 { clip = min(t, c.upperBound.addingTimeInterval(-1))...c.upperBound }
                        else { clip = c.lowerBound...max(t, c.lowerBound.addingTimeInterval(1)) }
                    }
                } else {
                    scrubTime = t
                }
            }
            .onEnded { v in
                if clipMode {
                    dragHandle = nil
                } else {
                    let t = time(at: v.location.x, width: width, range: range)
                    scrubTime = nil
                    onSeek(t)
                }
            }
    }

    private func installMonitor(width: CGFloat) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
            guard hovering else { return event }
            if event.type == .magnify {
                zoom(by: 1 - event.magnification * 1.5)
                return nil
            }
            let secondsPerPoint = span / Double(max(1, width))
            let sideways = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            let shift = event.modifierFlags.contains(.shift)
            let wantsZoom = wheelZooms ? (!sideways && !shift) : event.modifierFlags.contains(.command)
            if wantsZoom {
                // One notch of a mouse wheel = ±20 %; trackpads zoom smoothly.
                let dy = Double(event.scrollingDeltaY)
                guard dy != 0 else { return nil }
                let factor = event.hasPreciseScrollingDeltas ? exp(-dy * 0.01) : (dy > 0 ? 0.8 : 1.25)
                zoom(by: factor, anchorX: hoverX, width: width)
            } else {
                // Shift + vertical wheel scrolls sideways (a mouse without a horizontal wheel).
                let raw = sideways ? event.scrollingDeltaX : event.scrollingDeltaY
                let factor = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
                pan(by: -Double(raw) * factor * secondsPerPoint)
            }
            return nil
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Zooms keeping the time under the pointer still (or the centre, without a pointer).
    private func zoom(by factor: Double, anchorX: CGFloat? = nil, width: CGFloat = 0) {
        let old = visibleRange
        let newSpan = min(86400, max(60, span * factor))
        if let anchorX, width > 0 {
            let f = Double(min(1, max(0, anchorX / width)))
            let anchor = old.lowerBound.addingTimeInterval(f * span)
            center = anchor.addingTimeInterval((0.5 - f) * newSpan)
        }
        span = newSpan
        lastUserScroll = Date()
        clampCenter()
    }

    private func pan(by seconds: Double) {
        center = center.addingTimeInterval(seconds)
        lastUserScroll = Date()
        clampCenter()
    }

    private func clampCenter() {
        let half = span / 2
        if center < dayStart.addingTimeInterval(half) { center = dayStart.addingTimeInterval(half) }
        if center > dayEnd.addingTimeInterval(-half) { center = dayEnd.addingTimeInterval(-half) }
    }

    private func followPlayhead(_ t: Date) {
        guard span < 86400, Date().timeIntervalSince(lastUserScroll) > 4, scrubTime == nil else { return }
        let r = visibleRange
        let margin = span * 0.1
        if t > r.upperBound.addingTimeInterval(-margin) || t < r.lowerBound {
            center = t.addingTimeInterval(span * 0.3)
            clampCenter()
        }
    }
}
