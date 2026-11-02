import SwiftUI
import UIKit

/// A slice from twelve o'clock, clockwise: how much of the planned time has passed.
struct PieSlice: Shape {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard progress > 0 else { return path }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(center: center, radius: min(rect.width, rect.height) / 2, startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + 360 * min(progress, 1)), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// A pomodoro-style dial that fills as time passes against a planned length. It shows time spent, not
/// time left; past the plan it turns orange and keeps counting.
struct ElapsedTimer: View {
    let start: Date
    let minutes: Int
    var size: CGFloat = 30
    /// For a dial on a colored bar.
    var tint: Color? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(start))
            let total = Double(max(1, minutes) * 60)
            let color = tint ?? (elapsed >= total ? Color.orange : Palette.accent)
            ZStack {
                Circle().fill(tint == nil ? Color(uiColor: .secondarySystemGroupedBackground) : color.opacity(0.2))
                PieSlice(progress: elapsed / total).fill(color.opacity(0.85))
                Circle().strokeBorder(color.opacity(0.7), lineWidth: max(1, size / 22))
                if size >= 80 {
                    // Quarter marks, as on a kitchen timer.
                    ForEach(0..<12, id: \.self) { mark in
                        Capsule().fill(color.opacity(0.5))
                            .frame(width: mark % 3 == 0 ? 2.5 : 1.5, height: mark % 3 == 0 ? 9 : 5)
                            .offset(y: -size / 2 + 8)
                            .rotationEffect(.degrees(Double(mark) * 30))
                    }
                }
            }
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
