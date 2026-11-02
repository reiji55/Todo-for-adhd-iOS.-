import SwiftUI
import UIKit

/// A timer ring: full at the start, it empties as the planned time is used up; the minutes left are
/// in the middle. Past the plan a red ring grows instead, with the minutes over in the middle.
struct ElapsedTimer: View {
    let start: Date
    let minutes: Int
    var size: CGFloat = 30
    /// For a ring on a colored bar.
    var tint: Color? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(start))
            let total = Double(max(1, minutes) * 60)
            let over = elapsed > total
            let fraction = over ? min(1, (elapsed - total) / total) : max(0, 1 - elapsed / total)
            let color = over ? Color.red : (tint ?? Palette.accent)
            let line = max(3, size * 0.16)
            let number = over ? "+\(Int((elapsed - total) / 60))" : "\(Int(ceil((total - elapsed) / 60)))"
            ZStack {
                Circle().stroke(color.opacity(0.2), lineWidth: line)
                Circle().trim(from: 0, to: fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(number).font(.system(size: max(9, size * 0.3), weight: .bold, design: .rounded)).monospacedDigit()
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .foregroundStyle(over ? Color.red : (tint ?? Color.primary))
                    .padding(line)
            }
            .padding(line / 2)
            .frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Time spent so far, ticking: "12:34".
struct ElapsedText: View {
    let start: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(ElapsedTimer.clock(context.date.timeIntervalSince(start))).monospacedDigit()
        }
    }
}

/// The planned length for a timer: the time slot when there is one, else one pomodoro.
func plannedMinutes(_ slot: TimeSlot?) -> Int { slot?.duration ?? 25 }

extension View {
    /// Every editor gets a 完了 key above the keyboard, and dragging the form puts the keyboard away.
    func keyboardDismissable() -> some View {
        scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完了") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                    .fontWeight(.semibold)
                }
            }
    }
}
