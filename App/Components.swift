import SwiftUI
import UIKit

/// The task-3days palette. A name always gets the same color, so a project's tag, its board card
/// and its blocks on the week grid read as one thing.
enum ProjectColor {
    private static let light: [UInt32] = [0x3b6fd4, 0xc2571f, 0x2f8f6b, 0x8a4fbf, 0xb0345c, 0x5c7a1e, 0x1f7f9c, 0x8a6a1f]
    private static let dark: [UInt32] = [0x7fa9ff, 0xff9d5c, 0x4fd3a0, 0xc48cf5, 0xff7f9f, 0xb8d858, 0x5ccbe8, 0xe8b85c]

    /// FNV-1a over the normalized name: stable across launches and devices, unlike `hashValue`.
    static func index(for name: String) -> Int? {
        let key = BoardLink.normalized(name)
        guard !key.isEmpty else { return nil }
        var hash: UInt32 = 2_166_136_261
        for scalar in key.unicodeScalars { hash = (hash ^ scalar.value) &* 16_777_619 }
        return Int(hash % UInt32(Self.light.count))
    }

    static func color(for name: String) -> Color? {
        guard let i = index(for: name) else { return nil }
        return Color(UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? Self.dark[i] : Self.light[i])
        })
    }

    /// The project color softened toward the background, as task-3days did for its cards (34% color).
    static func tint(for name: String, amount: Double = 0.34) -> Color {
        guard let i = index(for: name) else { return Color(uiColor: .secondarySystemGroupedBackground) }
        return Color(UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let base = UIColor(rgb: isDark ? Self.dark[i] : Self.light[i])
            let paper = isDark ? UIColor(rgb: 0x1c1c1a) : UIColor.white
            return base.mixed(with: paper, amount: isDark ? amount * 0.8 : amount)
        })
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
                  blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
    func mixed(with other: UIColor, amount: Double) -> UIColor {
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let t = CGFloat(amount)
        return UIColor(red: r1 * t + r2 * (1 - t), green: g1 * t + g2 * (1 - t), blue: b1 * t + b2 * (1 - t), alpha: 1)
    }
}

extension TaskStore {
    /// Tasks linked to a board card take the card's color, so "TOEIC" and "TOEIC対策" match.
    func colorName(forProject project: String) -> String {
        project
    }
}

/// Diagonal lines, used for finished blocks and for time held for something else (sleep, work).
struct Hatch: Shape {
    var spacing: CGFloat = 6
    var reversed = false
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = -rect.height
        while x < rect.width {
            if reversed {
                path.move(to: CGPoint(x: x + rect.height, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
            } else {
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x + rect.height, y: rect.maxY))
            }
            x += spacing
        }
        return path
    }
}

struct ProjectTag: View {
    @EnvironmentObject private var store: TaskStore
    let name: String
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(ProjectColor.color(for: store.colorName(forProject: name)) ?? .secondary).frame(width: 7, height: 7)
            Text(name).lineLimit(1)
        }.font(.caption).foregroundStyle(.secondary)
    }
}

extension Font {
    /// Times use the rounded face, a step bolder, so they stand out from titles as in task-3days.
    static let clock = Font.system(.caption, design: .rounded).weight(.semibold).monospacedDigit()
}

/// One compact row for a task or a day of a routine. Same shape for both, as asked.
@MainActor
struct AgendaRow: View {
    /// card: a filled card. timeline: no surface of its own, for the raised timeline panel.
    /// loose: a dotted outline, for things without a time that are not placed yet.
    /// raised: a card lifted off the page, for today's things in longer lists.
    enum Style { case card, timeline, loose, raised }
    @EnvironmentObject private var store: TaskStore
    @Environment(\.openGuide) private var openGuide
    let item: AgendaItem
    var reason: String? = nil
    var showsTime = true
    var style: Style = .card
    let onOpen: (AgendaItem) -> Void
    var onStart: ((TaskItem) -> Void)? = nil

    private var task: TaskItem? {
        if case .task(let id) = item.source { return store.task(id) }
        return nil
    }

    /// The board card for the item's project, when there is a way to open it from here.
    private var guide: BoardCard? { openGuide == nil ? nil : store.linkedCard(forProject: item.project) }

    var body: some View {
        let done = item.isDone
        let task = self.task
        HStack(alignment: .center, spacing: 8) {
            check
            RowButton { onOpen(item) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    if let reason {
                        Text(reason).font(.caption2.weight(.semibold)).foregroundStyle(Palette.accent)
                    }
                    HStack(spacing: 6) {
                        if showsTime, let slot = item.slot { Text(slot.label).font(.clock).foregroundStyle(.primary) }
                        if item.isRoutine {
                            Image(systemName: "arrow.triangle.2.circlepath").font(.caption2).foregroundStyle(.secondary)
                                .accessibilityLabel("ルーティン")
                        }
                        if item.isEvent {
                            Image(systemName: "calendar").font(.caption2).foregroundStyle(Palette.accent)
                                .accessibilityLabel("イベント")
                            if item.slot == nil { Text("終日").font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                        }
                        if item.isMust {
                            Image(systemName: "star.fill").font(.caption2).foregroundStyle(Palette.must).accessibilityLabel("必須")
                        }
                        if let deadline = task?.deadline, !done {
                            Text("締切 \(deadline.shortDay)").font(.caption2.weight(.semibold)).foregroundStyle(Palette.must)
                        }
                        if !item.project.isEmpty { ProjectTag(name: item.project) }
                    }
                    Text(item.title).font(.body.weight(.medium))
                        .strikethrough(done).foregroundStyle(done ? .secondary : .primary)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    if !done, let next = task?.nextStep {
                        Text("次：\(next.title)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if !done, let note = task?.resumeNote, !note.isEmpty {
                        Label(note, systemImage: "bookmark").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            // The method of a routine (or a task) one tap away, at the end of its row.
            if let card = guide, let openGuide { GuideBookButton(card: card) { openGuide(card.id) } }
        }
        .padding(.vertical, 9).padding(.leading, style == .timeline ? 0 : 6)
        .padding(.trailing, style == .timeline || guide != nil ? 4 : 10)
        .background { surface }
        .overlay(alignment: .leading) {
            if style != .timeline, let color = ProjectColor.color(for: store.colorName(forProject: item.project)) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 10)
            }
        }
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 14))
        .opacity(done ? 0.5 : 1)
        .animation(.easeOut(duration: 0.2), value: done)
        .contextMenu { menu }
        // Any task or event, done or not, slides aside to delete (with 取り消す after).
        // A routine row is one day of something that repeats, so it does not.
        .swipeToDelete(enabled: task != nil) { if let task { store.delete(task.id) } }
    }

    @ViewBuilder private var surface: some View {
        switch style {
        case .card: RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .secondarySystemGroupedBackground))
        case .raised: RaisedCardBackground()
        case .timeline: Color.clear
        case .loose:
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Palette.accent.opacity(0.4), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
        }
    }

    @ViewBuilder private var check: some View {
        if item.isEvent {
            // A square box tells an event from a task; checking it only records that it happened.
            RowButton { store.toggle(item) } label: {
                Image(systemName: item.isDone ? "checkmark.square.fill" : "square").font(.title2).frame(width: 44, height: 44)
            }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                .accessibilityLabel(item.isDone ? "\(item.title)の済んだ印を外す" : "\(item.title)に済んだ印を付ける")
        } else if item.isBlock {
            Hatch(spacing: 4).stroke(Color.secondary.opacity(0.6), lineWidth: 1)
                .frame(width: 20, height: 20).clipShape(RoundedRectangle(cornerRadius: 5))
                .frame(width: 44, height: 44).accessibilityLabel("時間を押さえているだけの予定")
        } else if item.isRoutine && !item.isDone {
            // A routine is timed right here: ▶ starts the dial, a tap on the dial finishes it.
            if store.isTiming(item), let run = store.routineRun {
                Button { store.finishRoutineTimer() } label: {
                    ElapsedTimer(start: run.startedAt, minutes: plannedMinutes(item.slot), size: 30).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.title)を計測中。タップで完了")
            } else {
                Button { store.startRoutineTimer(item) } label: { playMark }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item.title)を始める")
            }
        } else if let task, !item.isDone, !task.isEvent, let onStart {
            // A task starts from here; it is checked off when its steps are done in the focus screen.
            if let session = store.notebook.activeSession, session.taskID == task.id {
                RowButton { onStart(task) } label: {
                    ElapsedTimer(start: session.startedAt, minutes: plannedMinutes(task.slot), size: 30).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(task.title)に取り組み中。集中画面を開く")
            } else {
                RowButton { onStart(task) } label: { playMark }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(task.title)を今やる")
            }
        } else {
            RowButton { store.toggle(item) } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle").font(.title2).frame(width: 44, height: 44)
            }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                .accessibilityLabel(item.isDone ? "\(item.title)を未完了に戻す" : "\(item.title)を完了")
        }
    }

    private var playMark: some View {
        Image(systemName: "play.fill").font(.subheadline.weight(.bold)).foregroundStyle(Palette.accent)
            .frame(width: 32, height: 32).background(Circle().fill(Palette.accent.opacity(0.14)))
            .frame(width: 44, height: 44).contentShape(Rectangle())
    }

    /// A long press offers only checking off (or undoing it); opening is a tap, deleting a slide.
    @ViewBuilder private var menu: some View {
        if item.isRoutine && store.isTiming(item) {
            Button("計測をやめる（完了にしない）", systemImage: "stop") { store.cancelRoutineTimer() }
        }
        if !item.isBlock {
            Button(item.isDone ? "未完了に戻す" : "完了にする", systemImage: item.isDone ? "arrow.uturn.backward" : "checkmark") {
                store.toggle(item)
            }
        }
    }
}

/// A button in a row that can be slid aside: the finger lifting after a slide must not press it.
private struct RowButton<Label: View>: View {
    @Environment(\.rowSwiping) private var swiping
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: { if !swiping { action() } }, label: label)
    }
}

/// A card lifted off the page, lit from the top left (the soft, raised look of the timeline panel).
struct RaisedCardBackground: View {
    @Environment(\.colorScheme) private var scheme
    var cornerRadius: CGFloat = 14

    var body: some View {
        let dark = scheme == .dark
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground))
            .shadow(color: dark ? .black.opacity(0.65) : Color(red: 0.36, green: 0.42, blue: 0.48).opacity(0.34), radius: 8, x: 4, y: 5)
            .shadow(color: dark ? Color.white.opacity(0.07) : .white, radius: 6, x: -3, y: -3)
    }
}

/// The small round ⊕ in the lower right. It first asks which kind of thing to add.
struct FloatingAddButton: View {
    let onPick: (AddKind) -> Void
    var body: some View {
        Menu {
            ForEach(AddKind.allCases) { kind in
                Button { onPick(kind) } label: {
                    Label { Text(kind.title); Text(kind.detail) } icon: { Image(systemName: kind.icon) }
                }
            }
        } label: {
            // Lighter and see-through, so a block or row underneath still shows.
            Image(systemName: "plus").font(.title3.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Palette.accent.opacity(0.7)))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
        .menuOrder(.fixed)
        .accessibilityLabel("追加する")
        .accessibilityHint("タスク・イベント・ルーティン・アイデアから選びます")
    }
}

extension View {
    /// Keeps the add button clear of the last row by reserving its space at the bottom.
    func floatingAdd(_ onPick: @escaping (AddKind) -> Void) -> some View {
        safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
            FloatingAddButton(onPick: onPick).padding(.trailing, 20).padding(.bottom, 10)
        }
    }
}

/// Mood for suggestions, kept for the rest of the day and reset the next morning.
enum EnergyMemory {
    static func load(now: Date = Date()) -> Energy {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "energyDay") == DayKey.of(now),
              let raw = defaults.string(forKey: "energy"), let energy = Energy(rawValue: raw) else { return .any }
        return energy
    }
    static func save(_ energy: Energy, now: Date = Date()) {
        UserDefaults.standard.set(energy.rawValue, forKey: "energy")
        UserDefaults.standard.set(DayKey.of(now), forKey: "energyDay")
    }
}

/// A row that slides left to show a delete button behind it, for things that are finished and only
/// in the way. A tap on the slid row slides it back.
private struct RowSwipingKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var rowSwiping: Bool {
        get { self[RowSwipingKey.self] }
        set { self[RowSwipingKey.self] = newValue }
    }
}

private struct SwipeToDelete: ViewModifier {
    var enabled = true
    let onDelete: () -> Void
    @State private var offset: CGFloat = 0
    @State private var settled: CGFloat = 0
    @State private var swiping = false
    private let reveal: CGFloat = 80

    @ViewBuilder func body(content: Content) -> some View {
        if enabled { slidable(content) } else { content }
    }

    private func slidable(_ content: Content) -> some View {
        content
            .environment(\.rowSwiping, swiping || settled < 0)
            .overlay {
                if settled < 0 {
                    Color.clear.contentShape(Rectangle()).onTapGesture { close() }
                }
            }
            .offset(x: offset)
            .background(alignment: .trailing) {
                Button(role: .destructive) {
                    close()
                    onDelete()
                } label: {
                    Image(systemName: "trash.fill").font(.title3).foregroundStyle(.white)
                        .frame(width: reveal - 10).frame(maxHeight: .infinity)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .opacity(min(1, -offset / 30))
                .accessibilityLabel("完全に削除")
            }
            // Alongside the scroll view's own drag, and only for sideways movement.
            .simultaneousGesture(
                DragGesture(minimumDistance: 18)
                    .onChanged { value in
                        guard abs(value.translation.width) > abs(value.translation.height) * 1.2 else { return }
                        swiping = true
                        offset = min(0, max(-reveal * 1.5, settled + value.translation.width))
                    }
                    .onEnded { value in
                        let end = settled + value.predictedEndTranslation.width
                        withAnimation(.snappy(duration: 0.25)) { offset = end < -reveal / 2 ? -reveal : 0 }
                        settled = offset
                        // The row's own tap lands as the finger lifts; keep it held off until then.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { swiping = false }
                    }
            )
            .accessibilityAction(named: "完全に削除", onDelete)
    }

    private func close() {
        withAnimation(.snappy(duration: 0.25)) { offset = 0 }
        settled = 0
    }
}

extension View {
    func swipeToDelete(enabled: Bool = true, _ onDelete: @escaping () -> Void) -> some View {
        modifier(SwipeToDelete(enabled: enabled, onDelete: onDelete))
    }
}
