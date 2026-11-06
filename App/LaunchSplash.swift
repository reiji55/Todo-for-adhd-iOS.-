import SwiftUI

/// Where the いま mark sits on screen, so the bud of the launch sprout can land on it.
@MainActor
final class LaunchMark: ObservableObject {
    static let shared = LaunchMark()
    @Published var frame: CGRect?
    /// Only the launch needs to know; after it, the mark stops reporting.
    var listening = true

    func report(_ frame: CGRect) {
        guard listening, frame != self.frame else { return }
        self.frame = frame
    }
}

/// One flat part of the sprout, given in the app icon's 100 × 100 grid.
private struct Facet: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let mapped = points.map { CGPoint(x: rect.minX + $0.x / 100 * rect.width, y: rect.minY + $0.y / 100 * rect.height) }
        guard let first = mapped.first else { return path }
        path.move(to: first)
        for point in mapped.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }
}

private struct SproutColors {
    let stem: Color
    let light: Color
    let deep: Color
    let bud: Color

    static func of(_ scheme: ColorScheme) -> SproutColors {
        scheme == .dark
            ? SproutColors(stem: Color(red: 0.91, green: 0.95, blue: 0.93), light: Color(red: 0.55, green: 0.81, blue: 0.70),
                           deep: Color(red: 0.33, green: 0.65, blue: 0.52), bud: Color(red: 1, green: 0.72, blue: 0.30))
            : SproutColors(stem: Color(red: 0.18, green: 0.42, blue: 0.36), light: Color(red: 0.49, green: 0.77, blue: 0.60),
                           deep: Color(red: 0.31, green: 0.61, blue: 0.50), bud: Color(red: 0.95, green: 0.54, blue: 0.29))
    }
}

/// The first second after a cold start: the sprout of the app icon comes up in the middle, its two leaves
/// popping open, then its bud flies to the いま mark and becomes it as the screen opens. A tap skips it;
/// with Reduce Motion the sprout only fades.
@MainActor
struct LaunchSplash: View {
    @ObservedObject private var mark = LaunchMark.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    let onFinish: () -> Void

    @State private var stem: CGFloat = 0
    @State private var leftLeaf: CGFloat = 0
    @State private var rightLeaf: CGFloat = 0
    @State private var bud: CGFloat = 0
    @State private var flying = false
    @State private var landed = false
    @State private var hidden = false
    @State private var finished = false

    private let size: CGFloat = 120

    var body: some View {
        let colors = SproutColors.of(scheme)
        GeometryReader { geometry in
            let frame = geometry.frame(in: .global)
            let center = CGPoint(x: frame.width / 2, y: frame.height / 2 - 10)
            let home = CGPoint(x: center.x, y: center.y - size / 2 + size * 0.24)
            let target = mark.frame.map { CGPoint(x: $0.minX + 4 - frame.minX, y: $0.midY - frame.minY) }
            ZStack {
                Palette.paper.opacity(flying ? 0 : 1)
                sprout(colors)
                    .frame(width: size, height: size)
                    .scaleEffect(flying ? 0.92 : 1)
                    .opacity(flying ? 0 : 1)
                    .position(center)
                budView(colors)
                    .position(flying ? (target ?? home) : home)
                    .opacity(landed || (flying && target == nil) ? 0 : 1)
            }
            .opacity(hidden ? 0 : 1)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .accessibilityHidden(true)
        .task { await play() }
    }

    private func sprout(_ colors: SproutColors) -> some View {
        // Both leaves open from the top of the stem.
        let base = UnitPoint(x: 0.5, y: 0.58)
        return ZStack {
            Facet(points: [p(48.6, 86), p(51.4, 86), p(51.6, 58), p(48.4, 58)]).fill(colors.stem)
                .scaleEffect(x: 1, y: stem, anchor: UnitPoint(x: 0.5, y: 0.86))
            ZStack {
                Facet(points: [p(50, 58), p(28, 34), p(22, 52)]).fill(colors.light)
                Facet(points: [p(50, 58), p(28, 34), p(42, 36)]).fill(colors.deep)
            }
            .scaleEffect(leftLeaf, anchor: base)
            ZStack {
                Facet(points: [p(50, 58), p(76, 24), p(82, 47)]).fill(colors.light)
                Facet(points: [p(50, 58), p(76, 24), p(58, 30)]).fill(colors.deep)
            }
            .scaleEffect(rightLeaf, anchor: base)
        }
    }

    /// The bud: a small diamond above the leaves; flying, it turns into the round いま mark.
    private func budView(_ colors: SproutColors) -> some View {
        let side = size * 0.1
        let dot: CGFloat = 8
        return RoundedRectangle(cornerRadius: flying ? dot / 2 : 1.5, style: .continuous)
            .fill(flying ? Palette.accent : colors.bud)
            .frame(width: flying ? dot : side, height: flying ? dot : side)
            .rotationEffect(.degrees(flying ? 0 : 45))
            .scaleEffect(x: 1, y: flying ? 1 : 1.3)
            .scaleEffect(bud)
    }

    private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    private func play() async {
        if reduceMotion {
            stem = 1; leftLeaf = 1; rightLeaf = 1; bud = 1
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(.easeOut(duration: 0.25)) { hidden = true }
            try? await Task.sleep(for: .milliseconds(250))
            finish()
            return
        }
        withAnimation(.easeOut(duration: 0.18)) { stem = 1 }
        try? await Task.sleep(for: .milliseconds(100))
        withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { leftLeaf = 1 }
        try? await Task.sleep(for: .milliseconds(60))
        withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { rightLeaf = 1 }
        try? await Task.sleep(for: .milliseconds(150))
        withAnimation(.spring(response: 0.26, dampingFraction: 0.5)) { bud = 1 }
        try? await Task.sleep(for: .milliseconds(320))
        guard !finished else { return }
        withAnimation(.easeInOut(duration: 0.42)) { flying = true }
        try? await Task.sleep(for: .milliseconds(420))
        withAnimation(.easeOut(duration: 0.12)) { landed = true }
        try? await Task.sleep(for: .milliseconds(120))
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        LaunchMark.shared.listening = false
        onFinish()
    }
}
