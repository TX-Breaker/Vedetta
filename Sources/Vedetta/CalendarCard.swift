import SwiftUI
import VedettaCore
import VedettaL10n

/// Month calendar highlighting the days that have recordings.
struct CalendarCard: View {
    @Binding var selectedDay: Date
    @Binding var displayedMonth: Date
    var recordedDays: Set<String>
    var isLoading: Bool
    var daysUnknown: Bool = false

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = AppLanguage.locale
        return c
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(Format.month.string(from: displayedMonth).firstCapitalized)
                    .font(.headline)
                if isLoading { ProgressView().controlSize(.mini).padding(.leading, 4) }
                Spacer()
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.glass).controlSize(.small)
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.glass).controlSize(.small)
                    .disabled(cal.isDate(displayedMonth, equalTo: Date(), toGranularity: .month))
            }
            // Very short weekday names in the interface language, starting from the locale's first weekday.
            let base = cal.veryShortStandaloneWeekdaySymbols
            let symbols = (0..<7).map { base[($0 + cal.firstWeekday - 1) % 7] }
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    Text(symbols[i]).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
                ForEach(days, id: \.self) { day in
                    dayCell(day)
                }
            }
            HStack(spacing: 12) {
                Button(L("Today")) { select(Date()) }.buttonStyle(.glass).controlSize(.small)
                Spacer()
                if daysUnknown {
                    Text(L("day list not available")).font(.caption2).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 4) {
                        Circle().fill(Theme.accent).frame(width: 6, height: 6)
                        Text(L("with recordings")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var days: [Date] {
        guard let interval = cal.dateInterval(of: .month, for: displayedMonth) else { return [] }
        let first = interval.start
        let weekday = cal.component(.weekday, from: first)
        let leading = (weekday - cal.firstWeekday + 7) % 7
        let start = cal.date(byAdding: .day, value: -leading, to: first)!
        return (0..<42).map { cal.date(byAdding: .day, value: $0, to: start)! }
    }

    @ViewBuilder
    private func dayCell(_ day: Date) -> some View {
        let inMonth = cal.isDate(day, equalTo: displayedMonth, toGranularity: .month)
        let isSelected = cal.isDate(day, inSameDayAs: selectedDay)
        let isToday = cal.isDateInToday(day)
        let hasRec = recordedDays.contains(RecordingIndex.dayKey(day))
        let future = day > Date()
        Button { select(day) } label: {
            VStack(spacing: 2) {
                Text("\(cal.component(.day, from: day))")
                    .font(.system(size: 12, weight: isSelected || isToday ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(isSelected ? .white : (inMonth ? (future ? Color.secondary.opacity(0.5) : .primary) : .secondary.opacity(0.5)))
                Circle().fill(hasRec ? (isSelected ? .white : Theme.accent) : .clear).frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .background {
                if isSelected {
                    Circle().fill(Theme.accent.gradient).frame(width: 30, height: 30)
                } else if isToday {
                    Circle().strokeBorder(Theme.accent, lineWidth: 1.5).frame(width: 30, height: 30)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(future)
    }

    private func select(_ d: Date) {
        withAnimation(.snappy) {
            selectedDay = cal.startOfDay(for: d)
            displayedMonth = d
        }
    }

    private func shiftMonth(_ n: Int) {
        withAnimation(.snappy) { displayedMonth = cal.date(byAdding: .month, value: n, to: displayedMonth) ?? displayedMonth }
    }
}
