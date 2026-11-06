import SwiftUI

/// 振り分け: the ideas one at a time, from a stack of their sticky notes. For each, the first step is
/// written in one line and given a day, or the idea is split into tasks, made a project, left to rest
/// or peeled off. A sideways swipe sends the front note to the back of the stack, to decide later.
@MainActor
struct SortIdeasView: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.refreshClock) private var refreshClock
    let onShowToday: () -> Void

    fileprivate enum Choice: Equatable {
        case slot, today, tomorrow, anytime, date, split, project, rest, peel, back
        /// Changes saved data, so taking it back goes through the store's undo.
        var changesData: Bool { ![.rest, .back].contains(self) }
        /// Made in a sheet of its own, which offers no undo here.
        var undoable: Bool { ![.split, .project].contains(self) }
        var madeTask: Bool { [.slot, .today, .tomorrow, .anytime, .date, .split].contains(self) }
    }

    fileprivate struct Decision: Equatable {
        let id: UUID
        let choice: Choice
        let message: String
    }

    @State private var queue: [UUID]
    @State private var log: [Decision] = []
    @State private var step = ""
    @State private var stepFor: UUID?
    @State private var dragX: CGFloat = 0
    @State private var flying: UUID?
    @State private var flyDirection: CGFloat = 1
    @State private var returning: UUID?
    @State private var toast: Decision?
    @State private var datePicking: Idea?
    @State private var pickedDay = Date()
    @State private var splitting: Idea?
    @State private var projecting: Idea?
    /// The note a sheet was opened for, and how many projects there were then.
    @State private var sheetFor: UUID?
    @State private var projectsBefore = 0
    /// Whether the drag under way is sideways; a mostly vertical one is left to the scroll view.
    @State private var dragSideways: Bool?
    @State private var decisions = 0
    @FocusState private var editingStep: Bool

    init(ideaIDs: [UUID], onShowToday: @escaping () -> Void) {
        _queue = State(initialValue: ideaIDs)
        self.onShowToday = onShowToday
    }

    /// The order of the wall: warm notes first, warmest and latest touched on top, then the cold ones.
    nonisolated static func order(_ ideas: [Idea], now: Date) -> [UUID] {
        let warm = ideas.filter { $0.warmth(now: now) > 0 }
            .sorted { ($0.warmth(now: now), $0.lastTouched) > ($1.warmth(now: now), $1.lastTouched) }
        let cold = ideas.filter { $0.warmth(now: now) == 0 }.sorted { $0.lastTouched > $1.lastTouched }
        return (warm + cold).map(\.id)
    }

    /// The stack as it stands, without notes removed meanwhile on another device.
    private var live: [UUID] { queue.filter { store.idea($0) != nil } }
    private var total: Int { live.count + log.filter { $0.choice != .back }.count }
    private var decided: Int { log.filter { $0.choice != .back }.count }

    var body: some View {
        let now = max(Date(), refreshClock)
        VStack(spacing: 0) {
            header
            if let id = live.first, let idea = store.idea(id) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        stack(now: now)
                        firstStep
                        choices(idea, now: now)
                    }
                    .padding(.horizontal, 18).padding(.bottom, 90)
                    .frame(maxWidth: 560).frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
            } else {
                summary
                Spacer()
            }
        }
        .background(Palette.paper.ignoresSafeArea())
        .overlay(alignment: .bottom) { toastView }
        .sensoryFeedback(.success, trigger: decisions)
        .onAppear(perform: syncStep)
        .onChange(of: live.first) { _, _ in syncStep() }
        // One line: return ends the writing instead of starting a second line.
        .onChange(of: step) { _, text in
            guard text.contains(where: \.isNewline) else { return }
            step = text.filter { !$0.isNewline }
            editingStep = false
        }
        .storeErrorAlert()
        .sheet(item: $datePicking) { idea in datePicker(idea) }
        .sheet(item: $splitting, onDismiss: { afterSheet(.split) }) { IdeaToTasksSheet(idea: $0) }
        .sheet(item: $projecting, onDismiss: { afterSheet(.project) }) { IdeaToProjectSheet(idea: $0) }
    }

    private var header: some View {
        HStack {
            Button("終える") { dismiss() }.font(.body).frame(minHeight: 44)
            Spacer()
            Text("振り分け").font(.headline.weight(.heavy))
            Spacer()
            Text(live.isEmpty ? "" : "\(decided + 1) / \(total)")
                .font(.subheadline.weight(.bold)).monospacedDigit().foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .trailing)
        }
        .padding(.horizontal, 18).padding(.top, 8)
    }

    // MARK: The stack

    private func stack(now: Date) -> some View {
        let ids = live
        let shown = Array(ids.prefix(3)) + [returning].compactMap { $0 }.filter { !ids.prefix(3).contains($0) }
        return GeometryReader { geometry in
            let width = min(310, geometry.size.width - 64)
            ZStack(alignment: .topLeading) {
                ForEach(shown, id: \.self) { id in
                    if let idea = store.idea(id) {
                        card(idea, slot: ids.firstIndex(of: id) ?? ids.count, width: width, now: now)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .frame(height: 300)
        .padding(.top, 8)
    }

    private func card(_ idea: Idea, slot: Int, width: CGFloat, now: Date) -> some View {
        let depth = min(slot, 3)
        var x: CGFloat = [0, 18, 36, 54][depth]
        var y: CGFloat = [0, -33, -66, -99][depth]
        var angle: Double = [-1, 1, 2.5, 4][depth]
        var opacity: Double = [1, 1, 0.75, 0][depth]
        var layer = Double(30 - depth * 10)
        let isFront = slot == 0 && flying != idea.id && returning != idea.id
        if flying == idea.id {
            x = flyDirection * 440; y = 24; angle = Double(flyDirection) * 16; opacity = 1; layer = 40
        } else if returning == idea.id {
            // Tucked in behind the others, then it settles out of sight with the rest of the stack.
            layer = 2; opacity = slot <= 1 ? 1 : slot == 2 ? 0.75 : 0.6
        } else if slot == 0 {
            x = dragX; y = 0; angle = -1 + Double(dragX / 40)
        }
        return SortCard(idea: idea, big: isFront || flying == idea.id, now: now)
            .frame(width: width, height: 200)
            .rotationEffect(.degrees(angle), anchor: .bottom)
            .offset(x: 4 + x, y: 99 + y)
            .opacity(opacity)
            .zIndex(layer)
            .transition(.asymmetric(insertion: .opacity, removal: .scale(scale: 0.9).combined(with: .opacity)))
            .simultaneousGesture(drag, including: isFront && live.count > 1 ? .all : .subviews)
            .accessibilityElement(children: .combine)
            .accessibilityHidden(!isFront)
            .accessibilityAction(named: "束の後ろに回す") { sendBack(1) }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard flying == nil else { return }
                if dragSideways == nil { dragSideways = abs(value.translation.width) > abs(value.translation.height) }
                if dragSideways == true { dragX = value.translation.width }
            }
            .onEnded { value in
                defer { dragSideways = nil }
                guard flying == nil, dragSideways == true else { return }
                let thrown = value.translation.width + (value.predictedEndTranslation.width - value.translation.width) * 0.3
                if abs(thrown) > 100 { sendBack(thrown > 0 ? 1 : -1) } else { withAnimation(.snappy) { dragX = 0 } }
            }
    }

    // MARK: The first step and the choices

    private var firstStep: some View {
        let bud = Color(red: 0.95, green: 0.54, blue: 0.29)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 18) {
                Rectangle().fill(bud.opacity(0.8)).frame(width: 2, height: 22)
                    .mask(VStack(spacing: 3) { ForEach(0..<4, id: \.self) { _ in Rectangle().frame(height: 3) } })
                    .padding(.leading, 11)
                Text("最初の一手").font(.caption.weight(.heavy)).foregroundStyle(Color(red: 0.71, green: 0.34, blue: 0.11))
            }
            HStack(spacing: 10) {
                Circle().fill(bud).frame(width: 20, height: 20)
                    .background(Circle().fill(bud.opacity(0.18)).frame(width: 30, height: 30))
                    .accessibilityHidden(true)
                HStack(spacing: 10) {
                    TextField("最初の一手", text: $step, axis: .vertical)
                        .lineLimit(1...3)
                        .font(.headline.weight(.heavy)).foregroundStyle(.white).tint(.white)
                        .focused($editingStep).submitLabel(.done)
                        .onSubmit { editingStep = false }
                    Image(systemName: "pencil").foregroundStyle(.white.opacity(0.75)).accessibilityHidden(true)
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                .frame(minHeight: 56)
                .background(Capsule().fill(Palette.accent).shadow(color: Palette.accent.opacity(0.3), radius: 10, y: 6))
            }
        }
    }

    private func choices(_ idea: Idea, now: Date) -> some View {
        let free = nextFreeSlots(now: now, tasks: store.notebook.tasks, routines: store.notebook.routines, limit: 1).first
        return VStack(alignment: .leading, spacing: 10) {
            Text("付箋：\(Self.firstLine(idea.text))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text("いつやる").font(.footnote.weight(.bold)).foregroundStyle(.secondary).padding(.top, 2)
            FlowLayout(spacing: 8) {
                if let free {
                    let slot = ideaWorkSlot(free.gap)
                    chip("\(freeDayLabel(free.day)) \(slot.label)", prominent: true) {
                        decide(.slot, day: free.day, slot: slot, label: "\(freeDayLabel(free.day)) \(slot.label) のタスクにしました")
                    }
                }
                chip("今日", prominent: free == nil) { decide(.today, day: now, label: "今日のタスクにしました") }
                chip("明日") {
                    decide(.tomorrow, day: Calendar.current.date(byAdding: .day, value: 1, to: now), label: "明日のタスクにしました")
                }
                chip("いつでも") { decide(.anytime, day: nil, label: "いつでものタスクにしました") }
                chip("日付…") { pickedDay = now; datePicking = idea }
            }
            Divider().padding(.vertical, 4)
            HStack(spacing: 8) {
                wide("分けて作る", foreground: Palette.accent, background: Palette.accent.opacity(0.1)) {
                    sheetFor = idea.id; splitting = idea
                }
                wide("プロジェクトにする", foreground: Palette.accent, background: Palette.accent.opacity(0.1)) {
                    sheetFor = idea.id; projectsBefore = store.notebook.projects.count; projecting = idea
                }
            }
            HStack(spacing: 8) {
                wide("寝かせる", foreground: .primary, background: Color(uiColor: .secondarySystemGroupedBackground)) {
                    record(Decision(id: idea.id, choice: .rest, message: "「\(Self.firstLine(idea.text))」を寝かせました"))
                }
                wide("はがす", foreground: .red, background: Color.red.opacity(0.1)) {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { store.deleteIdea(idea.id) }
                    guard store.idea(idea.id) == nil else { return }
                    record(Decision(id: idea.id, choice: .peel, message: "「\(Self.firstLine(idea.text))」をはがしました"))
                }
            }
        }
    }

    private func chip(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.bold))
                .padding(.horizontal, 16).frame(minHeight: 44)
                .foregroundStyle(prominent ? Palette.accent : Color.primary)
                .background(Capsule().fill(prominent ? Palette.accent.opacity(0.08) : Color(uiColor: .secondarySystemGroupedBackground)))
                .overlay(Capsule().strokeBorder(prominent ? Palette.accent : .clear, lineWidth: 1.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func wide(_ title: String, foreground: Color, background: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.bold)).foregroundStyle(foreground)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(background))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func datePicker(_ idea: Idea) -> some View {
        NavigationStack {
            DatePicker("やる日", selection: $pickedDay, in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                .datePickerStyle(.graphical).padding(.horizontal)
                .navigationTitle("やる日").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("やめる") { datePicking = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("この日にする") {
                            let day = pickedDay
                            datePicking = nil
                            decide(.date, day: day, label: "\(day.formatted(.dateTime.month(.defaultDigits).day()))のタスクにしました")
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Deciding

    /// The front note becomes one task: its first step, on the day chosen. The note's words and notes
    /// go into the task's memo, so nothing written is lost.
    private func decide(_ choice: Choice, day: Date?, slot: TimeSlot? = nil, label: String) {
        guard let id = live.first, let idea = store.idea(id) else { return }
        let typed = step.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = typed.isEmpty ? Self.firstLine(idea.text) : typed
        var memo: [String] = []
        if title != idea.text.trimmingCharacters(in: .whitespacesAndNewlines) { memo.append("アイデアから：\n\(idea.text)") }
        memo += idea.notes.map { "・\($0.text)" }
        var task = TaskItem(title: title, plannedAt: day, memo: memo.joined(separator: "\n"))
        if day != nil { task.slot = slot }
        guard withAnimation(.spring(response: 0.42, dampingFraction: 0.86), {
            store.makeTasks(from: idea, [task], keepIdea: false)
        }) else { return }
        store.offerUndo("「\(title)」をタスクにしました")
        record(Decision(id: id, choice: choice, message: "「\(title)」を\(label)"))
    }

    /// After a sheet: the idea counts as decided when it was turned into tasks or a project.
    private func afterSheet(_ choice: Choice) {
        guard let id = sheetFor else { return }
        sheetFor = nil
        let made = store.idea(id) == nil || (choice == .project && store.notebook.projects.count > projectsBefore)
        guard made, queue.contains(id) else { return }
        record(Decision(id: id, choice: choice, message: choice == .split ? "分けてタスクにしました" : "プロジェクトにしました"))
    }

    private func record(_ decision: Decision) {
        editingStep = false
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            queue.removeAll { $0 == decision.id }
            log.append(decision)
        }
        decisions += 1
        show(decision)
    }

    private func sendBack(_ direction: CGFloat) {
        guard live.count > 1, let id = live.first, flying == nil else {
            withAnimation(.snappy) { dragX = 0 }
            return
        }
        editingStep = false
        let message = "「\(Self.firstLine(store.idea(id)?.text ?? ""))」を束の後ろに回しました"
        if reduceMotion {
            dragX = 0
            withAnimation(.easeOut(duration: 0.2)) { rotate(id) }
            show(Decision(id: id, choice: .back, message: message))
            return
        }
        flyDirection = direction
        withAnimation(.easeIn(duration: 0.2)) { flying = id; dragX = 0 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
                flying = nil
                returning = id
                rotate(id)
            }
            show(Decision(id: id, choice: .back, message: message))
            try? await Task.sleep(for: .milliseconds(560))
            withAnimation(.easeOut(duration: 0.25)) { if returning == id { returning = nil } }
        }
    }

    private func rotate(_ id: UUID) {
        queue.removeAll { $0 == id }
        queue.append(id)
        log.append(Decision(id: id, choice: .back, message: ""))
    }

    private func undo() {
        guard let last = log.last, last.choice.undoable else { toast = nil; return }
        if last.choice.changesData {
            guard store.undoOffer != nil else { toast = nil; return }
            store.undo()
        }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            log.removeLast()
            queue.removeAll { $0 == last.id }
            queue.insert(last.id, at: 0)
        }
        stepFor = nil
        syncStep()
        toast = nil
    }

    private func show(_ decision: Decision) {
        withAnimation(.snappy) { toast = decision }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if toast == decision { withAnimation(.snappy) { toast = nil } }
        }
    }

    private func syncStep() {
        guard let id = live.first, stepFor != id else { return }
        stepFor = id
        step = Self.firstLine(store.idea(id)?.text ?? "")
    }

    nonisolated static func firstLine(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? text
    }

    // MARK: The end and the toast

    private var summary: some View {
        func tally(_ choices: [Choice]) -> Int { log.filter { choices.contains($0.choice) }.count }
        let all: [(label: String, count: Int)] = [
            ("今日のタスクに", tally([.slot, .today])), ("明日のタスクに", tally([.tomorrow])),
            ("いつでものタスクに", tally([.anytime])), ("日付を決めてタスクに", tally([.date])),
            ("分けてタスクに", tally([.split])), ("プロジェクトに", tally([.project])),
            ("寝かせた", tally([.rest])), ("はがした", tally([.peel]))
        ]
        let rows = all.filter { $0.count > 0 }
        return VStack(alignment: .leading, spacing: 12) {
            Text(rows.isEmpty ? "振り分ける付箋はありません" : "振り分けました").font(.title2.weight(.heavy))
            if !rows.isEmpty {
                VStack(spacing: 8) {
                    ForEach(rows, id: \.label) { row in
                        HStack {
                            Text(row.label)
                            Spacer()
                            Text("\(row.count)件").monospacedDigit().fontWeight(.bold)
                        }
                        .font(.subheadline)
                    }
                }
            }
            HStack(spacing: 10) {
                Button("今日を見る") { dismiss(); onShowToday() }.buttonStyle(.borderedProminent)
                Button("閉じる") { dismiss() }.buttonStyle(.bordered)
            }
            .padding(.top, 6)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RaisedCardBackground(cornerRadius: 22))
        .padding(18)
        .frame(maxWidth: 560)
    }

    @ViewBuilder private var toastView: some View {
        if let toast, !toast.message.isEmpty {
            HStack(spacing: 10) {
                Text(toast.message).font(.subheadline).lineLimit(2)
                Spacer(minLength: 4)
                if toast.choice.undoable {
                    Button("取り消す") { undo() }.font(.subheadline.weight(.bold))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16).padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// One idea's sticky note in the stack: in front it shows everything; behind, only its first line
/// along the top edge.
private struct SortCard: View {
    let idea: Idea
    let big: Bool
    let now: Date

    var body: some View {
        let warmth = idea.warmth(now: now)
        let colors = StickyColor.colors(for: idea, warmth: warmth)
        ZStack(alignment: .topLeading) {
            UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6, bottomTrailingRadius: 22, topTrailingRadius: 6)
                .fill(colors.paper)
            Text(SortIdeasView.firstLine(idea.text)).font(.footnote.weight(.bold)).lineLimit(1)
                .padding(.horizontal, 18).padding(.top, 10)
                .opacity(big ? 0 : 0.8)
            VStack(alignment: .leading, spacing: 8) {
                Text(idea.text).font(.title3.weight(.heavy)).lineLimit(3).multilineTextAlignment(.leading)
                ForEach(idea.notes.suffix(2)) { note in
                    Text("・\(note.text)").font(.subheadline).lineLimit(1).opacity(0.8)
                }
                Spacer(minLength: 0)
                HStack {
                    WarmthBar(level: warmth, ink: colors.ink)
                    Spacer()
                    Text(ideaDayLabel(idea.lastTouched, now: now)).font(.caption.weight(.bold))
                }
            }
            .padding(.top, 26).padding(.horizontal, 18).padding(.bottom, 14)
            .opacity(big ? 1 : 0)
        }
        .foregroundStyle(colors.ink)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.5)).frame(width: 64, height: 15).offset(y: -7) }
        .overlay(alignment: .topLeading) { StickyCorner(size: 14, paper: colors.paper) }
        .saturation(warmth == 3 ? 1 : warmth == 2 ? 0.85 : warmth == 1 ? 0.55 : 1)
        .shadow(color: .black.opacity(0.22), radius: 10, y: 8)
        .animation(.easeOut(duration: 0.25), value: big)
        .accessibilityLabel(idea.text)
        .accessibilityHint("横にスワイプすると束の後ろに回ります")
    }
}

/// Lays its views in rows, wrapping to the next row when one is full.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
