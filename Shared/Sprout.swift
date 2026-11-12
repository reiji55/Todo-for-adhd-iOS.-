import SwiftUI

/// Horme's mark: the two leaves, stem and bud of the app icon, drawn in the icon's colors.
/// Used for いま in the app and on the lock screen.
struct SproutMark: View {
    var dark = false

    /// The icon's own colors; the dark set is the dark icon's.
    private var lightLeaf: Color { dark ? Color(red: 0.55, green: 0.81, blue: 0.70) : Color(red: 0.49, green: 0.77, blue: 0.60) }
    private var deepLeaf: Color { dark ? Color(red: 0.33, green: 0.65, blue: 0.52) : Color(red: 0.31, green: 0.61, blue: 0.50) }
    private var stem: Color { dark ? Color(red: 0.91, green: 0.95, blue: 0.93) : Color(red: 0.18, green: 0.42, blue: 0.36) }
    private var bud: Color { dark ? Color(red: 1.0, green: 0.72, blue: 0.30) : Color(red: 0.95, green: 0.54, blue: 0.29) }

    var body: some View {
        Canvas { context, size in
            // The icon's drawing spans 330 × 380 of its 512 grid, from (100, 70).
            let scale = min(size.width / 330, size.height / 380)
            let dx = (size.width - 330 * scale) / 2, dy = (size.height - 380 * scale) / 2
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: dx + (x - 100) * scale, y: dy + (y - 70) * scale) }
            func shape(_ points: [(CGFloat, CGFloat)], _ color: Color) {
                var path = Path()
                path.addLines(points.map { point($0.0, $0.1) })
                path.closeSubpath()
                context.fill(path, with: .color(color))
            }
            shape([(145, 174), (214, 184), (256, 296)], deepLeaf)
            shape([(145, 174), (256, 296), (113, 266)], lightLeaf)
            shape([(297, 154), (389, 123), (256, 296)], deepLeaf)
            shape([(389, 123), (419, 240), (256, 296)], lightLeaf)
            shape([(248, 296), (264, 296), (264, 440), (248, 440)], stem)
            shape([(256, 82), (287, 123), (256, 163), (225, 123)], bud)
        }
        .aspectRatio(330 / 380, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
