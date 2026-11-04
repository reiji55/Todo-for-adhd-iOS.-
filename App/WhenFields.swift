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
