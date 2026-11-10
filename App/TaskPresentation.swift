import SwiftUI

/// Existing notes, shared by the focus card and timetable. Empty fields take no space; opening the
/// item's existing editor is still how the full text is read or edited.
@MainActor
struct ItemNotesView: View {
    @EnvironmentObject private var store: TaskStore
    let item: AgendaItem
    var foreground: Color = .secondary
    var includesContinuation = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch item.source {
            case .task(let id):
                if let task = store.task(id) {
                    if includesContinuation && !task.isComplete { note("前回の続き", task.continuationNote) }
                    note("メモ", task.memo)
                }
            case .routine(let id, _):
                if let routine = store.routine(id) {
                    if includesContinuation { note("前回の続き", routine.resumeNote) }
                    note("メモ", routine.memo)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(foreground)
    }

    @ViewBuilder private func note(_ label: String, _ text: String) -> some View {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            (Text(label + "  ").fontWeight(.semibold) + Text(text))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(label == "前回の続き" ? "itemContinuation" : "itemMemo")
        }
    }
}

/// Child completion, never elapsed time. The same representation is used before and during work.
/// The marks are indicators, not extra completion buttons.
struct ChildProgressView: View {
    let children: [TaskItem]
    var tint: Color = Palette.accent
    private var done: Int { children.filter(\.isComplete).count }

    var body: some View {
        HStack(spacing: 8) {
            if children.count <= 4 {
                HStack(spacing: 6) {
                    ForEach(children) { child in
                        ZStack {
                            Circle().strokeBorder(tint.opacity(child.isComplete ? 1 : 0.45), lineWidth: 1.5)
                            if child.isComplete {
                                Circle().fill(tint)
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Color.black.opacity(0.75))
                            }
                        }
                        .frame(width: 18, height: 18)
                    }
                }
            } else {
                ZStack {
                    Circle().stroke(tint.opacity(0.25), lineWidth: 3)
                    Circle().trim(from: 0, to: CGFloat(done) / CGFloat(children.count))
                        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 22, height: 22)
            }
            Text("\(done) / \(children.count)").font(.caption.weight(.semibold)).monospacedDigit()
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("子タスク\(children.count)件のうち\(done)件完了")
    }
}

/// Small botanical accent made of vector leaves; it never takes part in layout or hit testing.
struct FocusLeaves: View {
    var body: some View {
        ZStack {
            LeafShape().fill(LinearGradient(colors: [Color(red: 0.7, green: 0.9, blue: 0.25),
                                                    Color(red: 0.25, green: 0.55, blue: 0.14)],
                                           startPoint: .topTrailing, endPoint: .bottomLeading))
                .frame(width: 25, height: 43).rotationEffect(.degrees(18)).offset(x: 7, y: -11)
            LeafShape().fill(Color(red: 0.4, green: 0.68, blue: 0.2))
                .frame(width: 18, height: 30).rotationEffect(.degrees(-65)).offset(x: -10, y: 11)
            LeafShape().fill(Color(red: 0.25, green: 0.5, blue: 0.17))
                .frame(width: 16, height: 26).rotationEffect(.degrees(55)).offset(x: 10, y: 21)
        }
        .frame(width: 54, height: 76)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

private struct LeafShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control1: CGPoint(x: -rect.width * 0.15, y: rect.height * 0.3),
                       control2: CGPoint(x: rect.width * 0.8, y: rect.height * 0.2))
            p.addCurve(to: CGPoint(x: rect.minX, y: rect.maxY),
                       control1: CGPoint(x: rect.width * 1.1, y: rect.height * 0.7),
                       control2: CGPoint(x: rect.width * 0.5, y: rect.height * 0.95))
        }
    }
}
