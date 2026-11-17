import SwiftUI
import UIKit

/// A day that may be left open: a row reading 未定 until tapped. The tap puts in today and opens a
/// calendar under the row; picking a day there closes it again. × puts the row back to 未定.
@MainActor
struct OptionalDateRow: View {
    let title: String
    @Binding var date: Date?
    var placeholder = "未定"
    /// Events always have a day, so they offer no ×.
    var clearable = true
    /// Called as the calendar opens, so the sheet holding the row can make room for it.
    var onExpand: (() -> Void)? = nil
    @State private var open = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.snappy) {
                    if date == nil { date = Calendar.current.startOfDay(for: Date()) }
                    open.toggle()
                }
                if open { dismissKeyboard(); onExpand?() }
            } label: {
                HStack {
                    Text(title).foregroundStyle(Color.primary)
                    Spacer()
                    Text(date.map(Self.label) ?? placeholder)
                        .fontWeight(date == nil ? .regular : .semibold)
                        .foregroundStyle(date == nil ? Color.secondary : Palette.accent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityValue(date.map(Self.label) ?? placeholder)
            if date != nil && clearable {
                Button {
                    withAnimation(.snappy) { date = nil; open = false }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(title)を\(placeholder)に戻す")
            }
        }
        if open {
            DatePicker(title, selection: Binding(
                get: { date ?? Date() },
                set: { picked in
                    date = picked
                    withAnimation(.snappy) { open = false }
                }
            ), displayedComponents: .date)
            .datePickerStyle(.graphical)
            .labelsHidden()
        }
    }

    static func label(_ date: Date) -> String {
        let calendar = Calendar.current
        let day = date.formatted(.dateTime.month().day().weekday(.abbreviated))
        if calendar.isDateInToday(date) { return "今日 \(day)" }
        if calendar.isDateInTomorrow(date) { return "明日 \(day)" }
        return day
    }
}

/// A start time and length picked on dials. The hour dial begins at 未定 (or 終日 for an event);
/// turning it to an hour sets the time, and the minute and length dials wake up.
@MainActor
struct TimeDialRow: View {
    @Binding var slot: TimeSlot?
    var placeholder = "未定"
    var onExpand: (() -> Void)? = nil
    @State private var open = false

    /// 未定 first, then the day from six in the morning round to five the next, so the usual hours are near.
    private static let hours = [-1] + Array(6...23) + Array(0...5)
    private static let minutes = Array(stride(from: 0, to: 60, by: 5))

    var body: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.snappy) { open.toggle() }
                if open { dismissKeyboard(); onExpand?() }
            } label: {
                HStack {
                    Text("時間").foregroundStyle(Color.primary)
                    Spacer()
                    Text(slot.map { "\($0.label)（\(ClockMinutes.label($0.duration))）" } ?? placeholder)
                        .monospacedDigit()
                        .fontWeight(slot == nil ? .regular : .semibold)
                        .foregroundStyle(slot == nil ? Color.secondary : Palette.accent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityValue(slot?.label ?? placeholder)
            if slot != nil {
                Button {
                    withAnimation(.snappy) { slot = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("時間を\(placeholder)に戻す")
            }
        }
        if open { dials }
    }

    private var dials: some View {
        let current = slot
        return HStack(spacing: 0) {
            Picker("時", selection: Binding(
                get: { current.map { $0.start / 60 } ?? -1 },
                set: { hour in
                    guard hour >= 0 else { slot = nil; return }
                    slot = TimeSlot(start: hour * 60 + (current?.start ?? 0) % 60, duration: current?.duration ?? 60)
                }
            )) {
                ForEach(Self.hours, id: \.self) { hour in
                    Text(hour < 0 ? placeholder : "\(hour)時").tag(hour)
                }
            }
            .frame(maxWidth: .infinity).clipped()
            Picker("分", selection: Binding(
                get: { (current?.start ?? 0) % 60 / 5 * 5 },
                set: { minute in
                    guard let current else { return }
                    slot = TimeSlot(start: current.start / 60 * 60 + minute, duration: current.duration)
                }
            )) {
                ForEach(Self.minutes, id: \.self) { Text(String(format: "%02d分", $0)).tag($0) }
            }
            .frame(maxWidth: .infinity).clipped()
            .disabled(current == nil).opacity(current == nil ? 0.35 : 1)
            Picker("長さ", selection: Binding(
                get: { current?.duration ?? 60 },
                set: { duration in
                    guard let current else { return }
                    slot = TimeSlot(start: current.start, duration: duration)
                }
            )) {
                ForEach(Array(Set(ClockMinutes.durations + [current?.duration ?? 60])).sorted(), id: \.self) {
                    Text(ClockMinutes.label($0)).tag($0)
                }
            }
            .frame(maxWidth: .infinity).clipped()
            .disabled(current == nil).opacity(current == nil ? 0.35 : 1)
        }
        .pickerStyle(.wheel)
        .frame(height: 150)
    }
}

@MainActor
func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

/// 期間タスク: a stretch of days, picked on one calendar by tapping its first day and then its last. The row reads
/// なし until set, then "12/1〜12/31". The last day is the task's deadline, so × takes both off.
@MainActor
struct PeriodRow: View {
    @Binding var start: Date?
    @Binding var end: Date?
    var onExpand: (() -> Void)? = nil
    @State private var open = false
    /// The first day tapped, waiting for the last.
    @State private var first: Date?

    private var period: TaskPeriod? {
        guard let start, let end else { return nil }
        return TaskPeriod(start: start, end: end)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.snappy) { open.toggle(); first = nil }
                if open { dismissKeyboard(); onExpand?() }
            } label: {
                HStack {
                    Text("期間タスク").foregroundStyle(Color.primary)
                    Spacer()
                    Text(period?.text() ?? "なし")
                        .fontWeight(period == nil ? .regular : .semibold)
                        .foregroundStyle(period == nil ? Color.secondary : Palette.accent)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityValue(period?.text() ?? "なし")
            .accessibilityIdentifier("periodRow")
            if period != nil {
                Button {
                    withAnimation(.snappy) { start = nil; end = nil; open = false; first = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("期間をなくす")
            }
        }
        if open {
            VStack(alignment: .leading, spacing: 8) {
                Text(first == nil ? "始まりの日をタップ" : "終わりの日をタップ")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                RangeCalendar(start: first ?? start, end: first == nil ? end : nil, onTap: tap)
            }
            .padding(.vertical, 4)
        }
    }

    private func tap(_ day: Date) {
        guard let begin = first else { first = day; return }
        start = min(begin, day); end = max(begin, day); first = nil
        withAnimation(.snappy) { open = false }
    }
}

/// A month of days to tap, with the stretch from `start` to `end` shaded. ‹ › turn the month.
@MainActor
struct RangeCalendar: View {
    let start: Date?
    let end: Date?
    let onTap: (Date) -> Void
    @State private var month: Date

    init(start: Date?, end: Date?, onTap: @escaping (Date) -> Void) {
        self.start = start; self.end = end; self.onTap = onTap
        let calendar = Calendar.current
        _month = State(initialValue: calendar.date(from: calendar.dateComponents([.year, .month], from: start ?? Date())) ?? Date())
    }

    private var calendar: Calendar { .current }

    private var days: [Date?] {
        guard let count = calendar.range(of: .day, in: .month, for: month)?.count else { return [] }
        let lead = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: lead)
            + (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: month) }
    }

    private var weekdays: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(month.formatted(.dateTime.year().month(.wide))).font(.subheadline.weight(.bold))
                Spacer()
                Button { turn(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 32) }
                    .buttonStyle(.borderless).accessibilityLabel("前の月")
                Button { turn(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 32) }
                    .buttonStyle(.borderless).accessibilityLabel("次の月")
            }
            let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(height: 18)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day { cell(day) } else { Color.clear.frame(height: 38) }
                }
            }
        }
    }

    private func turn(_ months: Int) {
        withAnimation(.snappy) { month = calendar.date(byAdding: .month, value: months, to: month) ?? month }
    }

    private func cell(_ day: Date) -> some View {
        let isStart = start.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let isEnd = end.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let inside = start.flatMap { s in end.map { e in TaskPeriod(start: s, end: e).contains(day, calendar: calendar) } } ?? false
        let today = calendar.isDateInToday(day)
        return Button { onTap(calendar.startOfDay(for: day)) } label: {
            Text("\(calendar.component(.day, from: day))")
                .font(.system(.subheadline, design: .rounded).weight(isStart || isEnd || today ? .bold : .regular))
                .monospacedDigit()
                .foregroundStyle(isStart || isEnd ? Color.white : today ? Palette.accent : Color.primary)
                .frame(maxWidth: .infinity).frame(height: 38)
                .background {
                    ZStack {
                        if inside && !(isStart && isEnd) {
                            Rectangle().fill(Palette.accent.opacity(0.14))
                                .padding(.leading, isStart ? 18 : 0).padding(.trailing, isEnd ? 18 : 0)
                                .padding(.vertical, 2)
                        }
                        if isStart || isEnd { Circle().fill(Palette.accent).frame(width: 34, height: 34) }
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(day.formatted(.dateTime.month().day().weekday()))
        .accessibilityAddTraits(isStart || isEnd ? .isSelected : [])
    }
}
