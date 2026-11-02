import SwiftUI

/// Ideas as sticky notes. Each note keeps its color; its strength follows its warmth, which rises when
/// the idea is written, opened or added to, and cools over days left alone. Warm notes come first,
/// cold ones gather at the bottom, gray. Above them, a free stretch of today's schedule is offered
/// for the warmest idea.
@MainActor
struct IdeasView: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.refreshClock) private var refreshClock
    @State private var opened: UUID?
    @State private var writing = false
    @State private var planning: IdeaPlan?
    let onEditTask: (TaskItem) -> Void

    var body: some View {
        let now = max(Date(), refreshClock)
        let ideas = store.notebook.ideas
        let warm = ideas.filter { $0.warmth(now: now) > 0 }
            .sorted { ($0.warmth(now: now), $0.lastTouched) > ($1.warmth(now: now), $1.lastTouched) }
        let cold = ideas.filter { $0.warmth(now: now) == 0 }.sorted { $0.lastTouched > $1.lastTouched }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let hottest = warm.first {
                    FreeTimeCard(idea: hottest, now: now) { day, slot in
                        planning = IdeaPlan(idea: hottest, day: day, slot: slot)
                    }
                }
                if ideas.isEmpty {
                    ContentUnavailableView {
                        Label("まだ付箋はありません", systemImage: "note.text")
                    } description: {
                        Text("思いつきを、そのまま貼っておく場所です。タスクや必須の一覧には混ざりません。")
                    } actions: {
                        Button("付箋を書く") { writing = true }.buttonStyle(.borderedProminent)
                    }
                }
                StickyWall(ideas: warm, now: now, onOpen: { opened = $0.id }, onPlan: { planning = IdeaPlan(idea: $0) })
                if !cold.isEmpty {
                    HStack(spacing: 8) {
                        Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
                        Text("2週間以上さわっていない").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).fixedSize()
                        Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
                    }
                    .padding(.top, 8)
                    StickyWall(ideas: cold, now: now, onOpen: { opened = $0.id }, onPlan: { planning = IdeaPlan(idea: $0) })
                }
            }
            .padding(16).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }
        .background(Palette.paper)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { writing = true } label: {
                    Image(systemName: "plus").font(.headline.weight(.bold)).foregroundStyle(StickyColor.palette[0].ink)
                        .frame(width: 34, height: 34).background(Circle().fill(StickyColor.palette[0].paper))
                }
                .accessibilityLabel("付箋を書く")
            }
        }
        .sheet(isPresented: $writing) { IdeaQuickSheet() }
        .onAppear {
            #if DEBUG
            // Screenshot runs: open the warmest note.
            if ProcessInfo.processInfo.arguments.contains("-uiOpenFirstIdea") {
                opened = store.notebook.ideas.max { ($0.warmth(now: Date()), $0.lastTouched) < ($1.warmth(now: Date()), $1.lastTouched) }?.id
            }
            #endif
        }
        .sheet(item: Binding(get: { opened.map(IdeaRoute.init) }, set: { opened = $0?.id })) { route in
            IdeaDetailSheet(ideaID: route.id)
        }
        .sheet(item: $planning) { plan in
            IdeaToTasksSheet(idea: plan.idea, day: plan.day, slot: plan.slot, keepIdea: plan.slot != nil)
        }
    }
}

struct IdeaRoute: Identifiable { let id: UUID }

/// What the task sheet should start from: an idea, and maybe a free time for it.
struct IdeaPlan: Identifiable {
    let id = UUID()
    var idea: Idea
    var day: Date? = nil
    var slot: TimeSlot? = nil
}

/// Sticky note colors: each idea keeps one, chosen from its identity.
enum StickyColor {
    static let palette: [(paper: Color, ink: Color)] = [
        (Color(red: 1.0, green: 0.78, blue: 0.35), Color(red: 0.16, green: 0.11, blue: 0.02)),
        (Color(red: 1.0, green: 0.62, blue: 0.52), Color(red: 0.23, green: 0.09, blue: 0.06)),
        (Color(red: 0.79, green: 0.73, blue: 0.95), Color(red: 0.12, green: 0.09, blue: 0.22)),
        (Color(red: 0.55, green: 0.82, blue: 0.72), Color(red: 0.06, green: 0.16, blue: 0.14)),
        (Color(red: 0.56, green: 0.77, blue: 0.95), Color(red: 0.05, green: 0.14, blue: 0.22))
    ]
    static let cold = (paper: Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.3, alpha: 1) : UIColor(white: 0.84, alpha: 1) }),
                       ink: Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.86, alpha: 1) : UIColor(white: 0.25, alpha: 1) }))

    static func colors(for idea: Idea, warmth: Int) -> (paper: Color, ink: Color) {
        warmth == 0 ? cold : palette[Int(idea.id.uuid.0) % palette.count]
    }
}

/// "今日", "昨日", "3日前", or the date.
func ideaDayLabel(_ date: Date, now: Date) -> String {
    let calendar = Calendar.current
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
    switch days {
    case ..<1: return "今日"
    case 1: return "昨日"
    case 2..<7: return "\(days)日前"
    default: return date.formatted(.dateTime.month(.defaultDigits).day())
    }
}

/// Three short bars: how warm an idea is.
struct WarmthBar: View {
    let level: Int
    let ink: Color
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Capsule().fill(ink.opacity(index < level ? 0.75 : 0.18)).frame(width: 14, height: 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("温度 \(level)")
    }
}

/// Two columns of notes, the second set a little lower, as if stuck on a wall.
struct StickyWall: View {
    let ideas: [Idea]
    let now: Date
    let onOpen: (Idea) -> Void
    let onPlan: (Idea) -> Void

    var body: some View {
        let left = ideas.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let right = ideas.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        HStack(alignment: .top, spacing: 14) {
            column(left, tilt: -1.2)
            column(right, tilt: 1.2).padding(.top, 16)
        }
    }

    private func column(_ items: [Idea], tilt: Double) -> some View {
        VStack(spacing: 16) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, idea in
                PeelableSticky(idea: idea, now: now, tilt: index % 2 == 0 ? tilt : -tilt * 0.6, onOpen: onOpen, onPlan: onPlan)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// A sticky note that peels off from its top-left corner: drag the corner down and to the right far
/// enough and it comes away and is gone, with 取り消す as for any deletion. Short of that it springs back.
/// Only drags that start at the corner peel, so scrolling over the notes works as usual.
@MainActor
struct PeelableSticky: View {
    @EnvironmentObject private var store: TaskStore
    let idea: Idea
    let now: Date
    let tilt: Double
    let onOpen: (Idea) -> Void
    let onPlan: (Idea) -> Void
    @State private var pull: CGSize = .zero
    @State private var gone = false
    @State private var armed = false
    private let distance: CGFloat = 150

    var body: some View {
        let progress = min(1, hypot(pull.width, pull.height) / distance)
        Button { onOpen(idea) } label: { StickyNote(idea: idea, now: now, tilt: tilt, peel: progress) }
            .buttonStyle(.plain)
            .contextMenu {
                Button("タスクにする", systemImage: "arrow.up.right") { onPlan(idea) }
                Button("はがす", systemImage: "trash", role: .destructive) { store.deleteIdea(idea.id) }
            }
            .overlay(alignment: .topLeading) { corner }
            // Lifting from the top-left, hinged at the bottom-right corner that is still stuck down.
            .rotation3DEffect(.degrees(Double(progress) * 34 + (gone ? 46 : 0)), axis: (x: 1, y: -1, z: 0),
                              anchor: .bottomTrailing, perspective: 0.6)
            .offset(x: pull.width * 0.3 + (gone ? 340 : 0), y: pull.height * 0.3 + (gone ? 560 : 0))
            .scaleEffect(1 + progress * 0.05)
            .shadow(color: .black.opacity(Double(progress) * 0.35), radius: 14 * progress, x: 6 * progress, y: 10 * progress)
            .opacity(gone ? 0 : 1)
            .zIndex(progress > 0 || gone ? 10 : 0)
            .accessibilityAction(named: "はがす") { store.deleteIdea(idea.id) }
    }

    private var corner: some View {
        Color.clear.frame(width: 60, height: 60).contentShape(Rectangle())
            .onTapGesture { onOpen(idea) }
            .modifier(PeelGesture(onChange: follow, onEnd: release))
            .accessibilityHidden(true)
    }

    private func follow(_ translation: CGSize) {
        pull = CGSize(width: max(0, translation.width), height: max(0, translation.height))
        let ready = hypot(pull.width, pull.height) >= distance
        if ready != armed {
            armed = ready
            UIImpactFeedbackGenerator(style: ready ? .medium : .light).impactOccurred()
        }
    }

    /// Let go past the line, or flicked hard enough toward it: off it comes. Otherwise it springs back.
    private func release(_ translation: CGSize, _ projected: CGSize) {
        let thrown = hypot(max(0, projected.width), max(0, projected.height))
        if armed || thrown >= distance * 1.8 {
            peelOff()
        } else {
            armed = false
            withAnimation(.spring(response: 0.35, dampingFraction: 0.68)) { pull = .zero }
        }
    }

    private func peelOff() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.easeIn(duration: 0.34)) { gone = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { store.deleteIdea(idea.id) }
    }
}

/// The top-left corner folded over: a small dog-ear at rest that shows where to grab, growing as the
/// note is peeled.
struct StickyCorner: View {
    let size: CGFloat
    let paper: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Where the corner lifted, the page shows through.
            Path { path in
                path.move(to: .zero); path.addLine(to: CGPoint(x: size, y: 0)); path.addLine(to: CGPoint(x: 0, y: size))
                path.closeSubpath()
            }
            .fill(Palette.paper)
            // The flap: the corner turned over, its back a little lighter.
            Path { path in
                path.move(to: CGPoint(x: size, y: 0)); path.addLine(to: CGPoint(x: 0, y: size)); path.addLine(to: CGPoint(x: size, y: size))
                path.closeSubpath()
            }
            .fill(LinearGradient(colors: [Color.white.opacity(0.9), paper], startPoint: .bottomTrailing, endPoint: .topLeading))
            .shadow(color: .black.opacity(0.25), radius: 3, x: 2, y: 2)
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

struct StickyNote: View {
    let idea: Idea
    let now: Date
    var tilt: Double = 0
    /// 0 at rest … 1 ready to come off.
    var peel: CGFloat = 0

    var body: some View {
        let warmth = idea.warmth(now: now)
        let colors = StickyColor.colors(for: idea, warmth: warmth)
        VStack(alignment: .leading, spacing: 8) {
            Text(idea.text).font(.system(size: 15, weight: .heavy)).lineLimit(6)
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            if !idea.notes.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(idea.notes.suffix(3)) { note in
                        Text("・\(note.text)").font(.caption).lineLimit(2)
                    }
                    if idea.notes.count > 3 { Text("ほか\(idea.notes.count - 3)件").font(.caption2.weight(.semibold)) }
                }
                .opacity(0.85)
            }
            HStack {
                WarmthBar(level: warmth, ink: colors.ink)
                Spacer(minLength: 4)
                Text(ideaDayLabel(idea.lastTouched, now: now)).font(.caption2.weight(.bold))
            }
        }
        .foregroundStyle(colors.ink)
        .padding(.top, 16).padding(.horizontal, 12).padding(.bottom, 12)
        .background(UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6, bottomTrailingRadius: 18, topTrailingRadius: 6)
            .fill(colors.paper))
        .overlay(alignment: .top) {
            // A strip of tape holding it up.
            Rectangle().fill(Color.white.opacity(0.5)).frame(width: 44, height: 13).offset(y: -6)
        }
        .overlay(alignment: .topLeading) { StickyCorner(size: 12 + peel * 70, paper: colors.paper) }
        // Cooler notes lose some color before they go gray.
        .saturation(warmth == 3 ? 1 : warmth == 2 ? 0.85 : warmth == 1 ? 0.55 : 1)
        .rotationEffect(.degrees(tilt))
        .shadow(color: warmth == 3 ? colors.paper.opacity(0.35) : .clear, radius: 10, y: 6)
        .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint("開くと、メモを足したり時間に入れたりできます")
    }
}

/// The next stretches of free time: today's (from now), tomorrow's and the day after's.
func nextFreeSlots(now: Date, tasks: [TaskItem], routines: [Routine]) -> [(day: Date, gap: TimeSlot)] {
    let calendar = Calendar.current
    let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
    return (0..<3).compactMap { offset in
        guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)),
              let gap = FreeTime.gaps(on: day, tasks: tasks, routines: routines, notBefore: offset == 0 ? minute : nil).first
        else { return nil }
        return (day, gap)
    }
}

/// A free stretch of time is at most two hours of work on an idea.
func ideaWorkSlot(_ gap: TimeSlot) -> TimeSlot { TimeSlot(start: gap.start, duration: min(gap.duration, 120)) }

func freeDayLabel(_ day: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(day) { return "今日" }
    if calendar.isDateInTomorrow(day) { return "明日" }
    return day.formatted(.dateTime.weekday(.wide))
}

/// The day's schedule as a thin bar, its free stretch lit, and the warmest idea offered for it.
struct FreeTimeCard: View {
    @EnvironmentObject private var store: TaskStore
    let idea: Idea
    let now: Date
    let onPlace: (Date, TimeSlot) -> Void

    private let from = 8 * 60, to = 22 * 60

    var body: some View {
        if let next = nextFreeSlots(now: now, tasks: store.notebook.tasks, routines: store.notebook.routines).first {
            let busy = Agenda.items(on: next.day, tasks: store.notebook.tasks, routines: store.notebook.routines).compactMap(\.slot)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ForEach([8, 12, 16, 20], id: \.self) { hour in
                        Text("\(hour):00").font(.system(size: 10, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                        if hour != 20 { Spacer() }
                    }
                }
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let x = { (minute: Int) in CGFloat(min(max(minute, from), to) - from) / CGFloat(to - from) * width }
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        ForEach(Array(busy.enumerated()), id: \.offset) { _, slot in
                            Rectangle().fill(Color.secondary.opacity(0.45))
                                .frame(width: max(0, x(slot.end) - x(slot.start))).offset(x: x(slot.start))
                        }
                        Rectangle().fill(Palette.accent)
                            .frame(width: max(4, x(next.gap.end) - x(next.gap.start))).offset(x: x(next.gap.start))
                            .shadow(color: Palette.accent.opacity(0.6), radius: 6)
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 14)
                .accessibilityHidden(true)
                HStack(alignment: .center, spacing: 10) {
                    (Text("\(freeDayLabel(next.day)) \(next.gap.label) が空き。").bold().foregroundColor(Palette.accent)
                     + Text("「\(Self.firstLine(idea.text))」を入れる？"))
                        .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("入れる") { onPlace(next.day, ideaWorkSlot(next.gap)) }
                        .font(.subheadline.weight(.bold)).buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        }
    }

    static func firstLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? text
    }
}

/// One sticky note opened: the idea large, its メモ, free times to put it in, and the way out
/// (making tasks, or peeling it off).
@MainActor
struct IdeaDetailSheet: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    let ideaID: UUID
    @State private var note = ""
    @State private var editing: Idea?
    @State private var planning: IdeaPlan?
    @State private var confirmDelete = false
    @FocusState private var noteFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let idea = store.idea(ideaID) { content(idea) } else { Color.clear.onAppear { dismiss() } }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("編集") { editing = store.idea(ideaID) }
                }
            }
        }
        .onAppear { store.touchIdea(ideaID) }
        .sheet(item: $editing) { IdeaEditor(idea: $0) }
        .sheet(item: $planning) { plan in
            IdeaToTasksSheet(idea: plan.idea, day: plan.day, slot: plan.slot, keepIdea: plan.slot != nil)
        }
        .storeErrorAlert()
    }

    private func content(_ idea: Idea) -> some View {
        let now = Date()
        let warmth = idea.warmth(now: now)
        let colors = StickyColor.colors(for: idea, warmth: warmth)
        let slots = nextFreeSlots(now: now, tasks: store.notebook.tasks, routines: store.notebook.routines)
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(idea.createdAt.formatted(.dateTime.month(.defaultDigits).day())) に書いた")
                        Spacer()
                        WarmthBar(level: warmth, ink: colors.ink)
                    }
                    .font(.caption.weight(.bold))
                    Text(idea.text).font(.system(size: 21, weight: .black)).fixedSize(horizontal: false, vertical: true)
                    Text("最後にさわった：\(ideaDayLabel(idea.lastTouched, now: now))").font(.caption2.weight(.semibold)).opacity(0.75)
                }
                .foregroundStyle(colors.ink)
                .padding(.top, 20).padding(.horizontal, 16).padding(.bottom, 16)
                .background(UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6, bottomTrailingRadius: 20, topTrailingRadius: 6)
                    .fill(colors.paper))
                .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.5)).frame(width: 50, height: 14).offset(y: -7) }
                .rotationEffect(.degrees(-0.8))
                .padding(.top, 6)

                VStack(alignment: .leading, spacing: 10) {
                    Text("メモ").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                    if idea.notes.isEmpty {
                        Text("思いついたことを足していくと、付箋がいちばん温かい段階まで育ちます。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(idea.notes) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Circle().fill(colors.paper).frame(width: 8, height: 8).padding(.top, 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.text).fixedSize(horizontal: false, vertical: true)
                                Text(ideaDayLabel(item.createdAt, now: now)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contextMenu {
                            Button("このメモを消す", systemImage: "trash", role: .destructive) { store.deleteIdeaNote(item.id, from: idea.id) }
                        }
                    }
                    HStack(spacing: 8) {
                        TextField("ひとこと足す…", text: $note, axis: .vertical).lineLimit(1...4).focused($noteFocused)
                            .submitLabel(.done).onSubmit(addNote)
                        Button(action: addNote) {
                            Image(systemName: "arrow.up").font(.subheadline.weight(.bold)).foregroundStyle(colors.ink)
                                .frame(width: 34, height: 34).background(Circle().fill(colors.paper))
                        }
                        .buttonStyle(.plain)
                        .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("メモを足す")
                    }
                    .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 22).fill(Color(uiColor: .tertiarySystemFill)))
                }

                if !slots.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("空いている時間に入れる").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(slots.enumerated()), id: \.offset) { index, next in
                                    Button("\(freeDayLabel(next.day)) \(ideaWorkSlot(next.gap).label)") {
                                        planning = IdeaPlan(idea: idea, day: next.day, slot: ideaWorkSlot(next.gap))
                                    }
                                    .font(.subheadline.weight(index == 0 ? .bold : .regular))
                                    .buttonStyle(.bordered).buttonBorderShape(.capsule)
                                    .tint(index == 0 ? Palette.accent : .secondary)
                                }
                            }
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button { planning = IdeaPlan(idea: idea) } label: {
                        Text("タスクにする（分けて作る）").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Text("はがす").font(.subheadline.weight(.bold)).padding(.vertical, 8).padding(.horizontal, 6)
                    }
                    .buttonStyle(.bordered).tint(.red)
                }
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .confirmationDialog("この付箋をはがしますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("はがす", role: .destructive) {
                store.deleteIdea(idea.id)
                dismiss()
            }
        } message: { Text("すぐ下に出る「取り消す」で戻せます。") }
    }

    private func addNote() {
        if store.addIdeaNote(note, to: ideaID) { note = "" }
    }
}

/// The drag that peels a note. From iOS 18 it is a UIKit pan the scroll view waits for, so a drag that
/// starts on the corner moves the note at once instead of scrolling first (no press-and-hold needed).
private struct PeelGesture: ViewModifier {
    let onChange: (CGSize) -> Void
    /// The translation, and where the flick would carry it.
    let onEnd: (CGSize, CGSize) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.gesture(PeelPan(onChange: onChange, onEnd: onEnd))
        } else {
            content.gesture(DragGesture(minimumDistance: 4)
                .onChanged { onChange($0.translation) }
                .onEnded { onEnd($0.translation, $0.predictedEndTranslation) })
        }
    }
}

@available(iOS 18.0, *)
private struct PeelPan: UIGestureRecognizerRepresentable {
    let onChange: (CGSize) -> Void
    let onEnd: (CGSize, CGSize) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let t = recognizer.translation(in: recognizer.view)
        let translation = CGSize(width: t.x, height: t.y)
        switch recognizer.state {
        case .began, .changed:
            onChange(translation)
        case .ended, .cancelled, .failed:
            let v = recognizer.velocity(in: recognizer.view)
            onEnd(translation, CGSize(width: t.x + v.x * 0.25, height: t.y + v.y * 0.25))
        default:
            break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Scrolling waits until this pan has failed, so a drag from the corner never becomes a scroll.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer.view is UIScrollView
        }
    }
}
