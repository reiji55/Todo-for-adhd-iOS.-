import SwiftUI

@MainActor
struct TodayView: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.refreshClock) private var refreshClock
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var energy: Energy = EnergyMemory.load()
    @State private var drawerOpen = false
    @State private var rolloverOpen = false
    /// -1 yesterday, 0 today, 1 tomorrow. Yesterday and tomorrow are for a look; coming back is always today.
    @State private var dayOffset = 0
    let onOpen: (AgendaItem) -> Void
    let onStart: (TaskItem) -> Void
    let onWeek: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = max(context.date, refreshClock)
            GeometryReader { geometry in
                if geometry.size.width >= 760 && !dynamicTypeSize.isAccessibilitySize {
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView { main(now: now).padding(20) }.frame(maxWidth: .infinity)
                        Divider()
                        // Wide screens have room to keep suggestions in view.
                        ScrollView { CandidatePanel(energy: $energy, now: now, onOpen: onOpen, onStart: onStart).padding(20) }
                            .frame(width: min(400, geometry.size.width * 0.38))
                    }
                } else {
                    ScrollView { main(now: now).padding(16) }
                        .overlay(alignment: .trailing) {
                            if dayOffset == 0 {
                                CandidateDrawer(isOpen: $drawerOpen) {
                                    CandidatePanel(energy: $energy, now: now, onOpen: onOpen, onStart: onStart)
                                }
                            }
                        }
                }
            }
            .background(Palette.paper)
        }
        .sheet(isPresented: $rolloverOpen) { RolloverSheet() }
        .onChange(of: energy) { _, value in EnergyMemory.save(value) }
        .onAppear { dayOffset = 0 }
        .onDisappear { dayOffset = 0 }
    }

    @ViewBuilder private func main(now: Date) -> some View {
        if dayOffset == 0 { today(now: now) } else { otherDay(now: now) }
    }

    /// Yesterday or tomorrow, to look at: the same timeline and list, without today's extras.
    private func otherDay(now: Date) -> some View {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: dayOffset, to: now) ?? now
        let items = Agenda.items(on: day, tasks: store.notebook.tasks, routines: store.notebook.routines).filter { !$0.isBlock }
        let timed = items.filter { $0.slot != nil }
        let untimed = items.filter { $0.slot == nil }
        return LazyVStack(alignment: .leading, spacing: 10) {
            DaySwitcher(offset: $dayOffset, now: now)
            SectionHeading(title: dayOffset > 0 ? "明日の時間割" : "昨日の時間割")
            if items.isEmpty {
                Text(dayOffset > 0 ? "明日の予定はまだありません。右下の＋から足せます。" : "昨日の予定はありませんでした。")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 6)
            }
            if !timed.isEmpty {
                TimelinePanel(items: timed, now: now, showsNow: false, onOpen: onOpen, onStart: onStart).padding(.bottom, 6)
            }
            if !untimed.isEmpty {
                Text("時間を決めていない").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, timed.isEmpty ? 0 : 8)
                ForEach(untimed) { item in AgendaRow(item: item, style: .loose, onOpen: onOpen, onStart: onStart) }
            }
            if dayOffset < 0 {
                Text("やり残したものは、今日の画面の「前の日から残っているタスク」から振り分けられます。")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }
        }
        .frame(maxWidth: 760).frame(maxWidth: .infinity)
    }

    @ViewBuilder private func today(now: Date) -> some View {
        let board = TaskBoard()
        let tasks = store.notebook.tasks
        // Something checked off a moment ago keeps its place until the person leaves this screen.
        let placement = tasks.map { task -> TaskItem in
            var copy = task
            if store.recentlyDone.contains(AgendaItem(task: task).id) { copy.completedAt = nil }
            return copy
        }
        let calendar = Calendar.current
        // Held time (sleep, work) is context for the week grid, not something to do; keep it out of this list.
        let agenda = Agenda.items(on: now, tasks: tasks, routines: store.notebook.routines).filter { !$0.isBlock }
        // Finished things stay where they were, struck through, so a look back at the day shows what it held.
        let visible = agenda
        // Today's planned work is already in the timetable; this list is what would otherwise be missed.
        let required = board.obligations(placement, now: now).filter { task in
            task.plannedAt.map { calendar.isDate($0, inSameDayAs: now) } != true
        }
        let leftovers = board.pastPlanned(tasks, now: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let tomorrowCount = Agenda.items(on: tomorrow, tasks: tasks, routines: store.notebook.routines)
            .filter { !$0.isDone && !$0.isBlock }.count

        LazyVStack(alignment: .leading, spacing: 10) {
            DaySwitcher(offset: $dayOffset, now: now, tomorrowCount: tomorrowCount)
            if store.loadFailed {
                Label("保存データを開けません。設定から復旧できます。", systemImage: "exclamationmark.triangle")
                    .font(.subheadline).foregroundStyle(.red)
            }
            if !leftovers.isEmpty {
                Button { rolloverOpen = true } label: {
                    HStack {
                        Image(systemName: "tray.and.arrow.down")
                        Text("前の日から残っているタスク \(leftovers.count)件").frame(maxWidth: .infinity, alignment: .leading)
                        Text("振り分ける").fontWeight(.semibold)
                    }
                    .font(.subheadline).padding(12)
                    .background(Palette.must.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).foregroundStyle(Palette.must)
            }
            if !required.isEmpty {
                SectionHeading(title: "今日中に必要なもの", color: Palette.must)
                ForEach(required) { task in
                    let item = AgendaItem(task: store.task(task.id) ?? task)
                    AgendaRow(item: item, reason: board.obligationReason(task, now: now), onOpen: onOpen, onStart: onStart)
                }
            }
            SectionHeading(title: "今日の時間割")
            if visible.isEmpty {
                Text(agenda.isEmpty ? "今日の予定はまだありません。右下の＋から足せます。" : "今日の予定はすべて終わりました。")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 6)
            }
            // Timed things sit on a raised timeline; the rest are outlined, not placed yet.
            let timed = visible.filter { $0.slot != nil }
            let untimed = visible.filter { $0.slot == nil }
            if !timed.isEmpty {
                TimelinePanel(items: timed, now: now, onOpen: onOpen, onStart: onStart).padding(.bottom, 6)
            }
            if !untimed.isEmpty {
                Text("時間を決めていない").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, timed.isEmpty ? 0 : 8)
                ForEach(untimed) { item in AgendaRow(item: item, style: .loose, onOpen: onOpen, onStart: onStart) }
            }
            UpcomingDeadlines(now: now, onOpen: onOpen)
        }
        .frame(maxWidth: 760).frame(maxWidth: .infinity)
    }
}

/// Today's timed items as a timeline: start and end times on the left, a rail with a mark per item,
/// and the current time crossing it, on a soft raised panel.
@MainActor
struct TimelinePanel: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.colorScheme) private var scheme
    let items: [AgendaItem]
    let now: Date
    /// The red line for now; off for days other than today.
    var showsNow = true
    let onOpen: (AgendaItem) -> Void
    let onStart: (TaskItem) -> Void

    private let timeWidth: CGFloat = 46
    private let railWidth: CGFloat = 20

    var body: some View {
        let calendar = Calendar.current
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let nowIndex = showsNow ? (items.firstIndex { ($0.slot?.start ?? Int.max) > minute } ?? items.count) : -1
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index == nowIndex {
                    nowRow
                } else if index > 0 {
                    Divider().padding(.leading, 8 + timeWidth + railWidth + 44)
                }
                row(item)
            }
            if nowIndex == items.count { nowRow }
        }
        .padding(.vertical, 6)
        .background(alignment: .leading) {
            Rectangle().fill(Palette.accent.opacity(0.22)).frame(width: 2).frame(maxHeight: .infinity)
                .padding(.vertical, 26).padding(.leading, 8 + timeWidth + railWidth / 2 - 1)
        }
        .background { RaisedPanel() }
    }

    private func row(_ item: AgendaItem) -> some View {
        let color = ProjectColor.color(for: store.colorName(forProject: item.project)) ?? Palette.accent
        return HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .trailing, spacing: 1) {
                if let slot = item.slot {
                    Text(slot.startLabel).font(.system(.subheadline, design: .rounded).weight(.bold)).monospacedDigit()
                    Text(TimeSlot.clock(slot.end)).font(.system(.caption2, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(width: timeWidth, alignment: .trailing)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.slot?.label ?? "")
            // An event's mark is square like its check box; a filled mark means it is done.
            Group {
                if item.isEvent {
                    RoundedRectangle(cornerRadius: 3).fill(item.isDone ? color : RaisedPanel.fill(scheme))
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(color, lineWidth: 2))
                } else {
                    Circle().fill(item.isDone ? color : RaisedPanel.fill(scheme)).overlay(Circle().strokeBorder(color, lineWidth: 2))
                }
            }
            .frame(width: 11, height: 11).frame(width: railWidth)
            .accessibilityHidden(true)
            AgendaRow(item: item, showsTime: false, style: .timeline, onOpen: onOpen, onStart: onStart)
        }
        .padding(.leading, 8)
    }

    private var nowRow: some View {
        HStack(spacing: 0) {
            Text(now.formatted(date: .omitted, time: .shortened)).font(.clock).foregroundStyle(.red)
                .frame(width: timeWidth, alignment: .trailing)
            Circle().fill(Color.red).frame(width: 9, height: 9).frame(width: railWidth)
            Rectangle().fill(Color.red).frame(height: 1.5)
        }
        .padding(.leading, 8).padding(.trailing, 12).padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("現在 \(now.formatted(date: .omitted, time: .shortened))")
    }
}

/// A soft surface the same color as the page, lit from the top left so it seems to rise out of it.
struct RaisedPanel: View {
    @Environment(\.colorScheme) private var scheme
    var cornerRadius: CGFloat = 22

    static func fill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(uiColor: .secondarySystemGroupedBackground) : Palette.paper
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let dark = scheme == .dark
        shape.fill(Self.fill(scheme))
            .shadow(color: dark ? .black.opacity(0.7) : Color(red: 0.6, green: 0.64, blue: 0.72).opacity(0.45), radius: 10, x: 6, y: 6)
            .shadow(color: dark ? Color.white.opacity(0.05) : .white, radius: 9, x: -5, y: -5)
            .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(dark ? 0.1 : 0.85), Color.white.opacity(0)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
    }
}

@MainActor
private struct UpcomingDeadlines: View {
    @EnvironmentObject private var store: TaskStore
    let now: Date
    let onOpen: (AgendaItem) -> Void
    var body: some View {
        let calendar = Calendar.current
        let upcoming = store.notebook.tasks.filter { task in
            guard !task.isComplete, let due = task.deadline else { return false }
            return calendar.startOfDay(for: due) > calendar.startOfDay(for: now)
        }.sorted { ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture) }
        if !upcoming.isEmpty {
            SectionHeading(title: "これからの締切")
            ForEach(upcoming.prefix(5)) { task in
                Button { onOpen(AgendaItem(task: task)) } label: {
                    HStack {
                        Text(task.deadline?.shortDay ?? "").font(.clock).foregroundStyle(Palette.must)
                        Text(task.title).foregroundStyle(.primary).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }.font(.subheadline).frame(minHeight: 40)
                }
            }
        }
    }
}

/// "今できそうなもの": up to three things to start now, explained.
@MainActor
struct CandidatePanel: View {
    @EnvironmentObject private var store: TaskStore
    @Binding var energy: Energy
    let now: Date
    let onOpen: (AgendaItem) -> Void
    let onStart: (TaskItem) -> Void

    var body: some View {
        let placement = store.notebook.tasks.map { task -> TaskItem in
            var copy = task
            if store.recentlyDone.contains(AgendaItem(task: task).id) { copy.completedAt = nil }
            return copy
        }
        let candidates = TaskBoard().candidates(placement, energy: energy, now: now)
        VStack(alignment: .leading, spacing: 10) {
            Text("今できそうなもの").font(.title3.weight(.bold))
            Text("気になるものから。途中で切り替えても、続きは残ります。").font(.caption).foregroundStyle(.secondary)
            Picker(selection: $energy) {
                ForEach(Energy.allCases) { Text($0.label).tag($0) }
            } label: { Text("今の調子") }
            .pickerStyle(.segmented)
            .accessibilityHint("候補の並びだけを変えます。必須や全件一覧には影響しません。")
            Text("今の調子：\(energy.label)。同じ優先度の中で、近い負荷のものを先に出します。")
                .font(.caption).foregroundStyle(.secondary)
            if candidates.isEmpty {
                Text("今の候補はありません。「すべて」からどのタスクでも始められます。")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ForEach(candidates) { candidate in
                AgendaRow(item: AgendaItem(task: store.task(candidate.task.id) ?? candidate.task), reason: candidate.reason,
                          onOpen: onOpen, onStart: onStart)
            }
        }
    }
}

/// Pulled in from the right edge on narrow screens. A tab on the edge shows it is there.
struct CandidateDrawer<Content: View>: View {
    @Binding var isOpen: Bool
    @ViewBuilder let content: () -> Content
    @GestureState private var dragX: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let width = min(340, geometry.size.width * 0.88)
            // Positive while pushing it back to the right; negative while pulling it in.
            let offset = isOpen ? max(0, dragX) : max(0, width + dragX)
            ZStack(alignment: .trailing) {
                if isOpen || dragX < 0 {
                    Color.black.opacity(0.25 * Double(1 - offset / width)).ignoresSafeArea()
                        .onTapGesture { withAnimation(.snappy) { isOpen = false } }
                }
                HStack(spacing: 0) {
                    handle
                    ScrollView { content().padding(16) }
                        .frame(width: width)
                        .background(Color(uiColor: .systemGroupedBackground))
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20))
                        .shadow(color: .black.opacity(isOpen ? 0.18 : 0), radius: 12, x: -2)
                }
                .offset(x: offset)
                .gesture(drag(width: width))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .animation(.snappy, value: isOpen)
        }
    }

    private var handle: some View {
        Button { withAnimation(.snappy) { isOpen.toggle() } } label: {
            VStack(spacing: 4) {
                Image(systemName: isOpen ? "chevron.right" : "sparkles").font(.caption.weight(.bold))
                if !isOpen { Text("今できそう").font(.caption2.weight(.semibold)).fixedSize() .rotationEffect(.degrees(-90)).frame(width: 14, height: 64) }
            }
            .foregroundStyle(.white)
            .frame(width: 26, height: isOpen ? 44 : 104)
            .background(Palette.accent, in: UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOpen ? "候補を閉じる" : "今できそうなものを開く")
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($dragX) { value, state, _ in
                // Follow the finger only horizontally, so vertical scrolling inside the panel still works.
                if abs(value.translation.width) > abs(value.translation.height) { state = value.translation.width }
            }
            .onEnded { value in
                let moved = value.predictedEndTranslation.width
                withAnimation(.snappy) { isOpen = isOpen ? moved < width / 3 : moved < -width / 4 }
            }
    }
}

/// Batch handling of tasks left on earlier days: pick some, send them to a day, or close them.
@MainActor
struct RolloverSheet: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var initialized = false

    var body: some View {
        let leftovers = TaskBoard().pastPlanned(store.notebook.tasks, now: Date())
            .sorted { ($0.plannedAt ?? .distantPast) < ($1.plannedAt ?? .distantPast) }
        NavigationStack {
            List {
                Section {
                    ForEach(leftovers) { task in
                        Button { toggle(task.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selected.contains(task.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3).foregroundStyle(Palette.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(task.title).foregroundStyle(.primary)
                                    Text([task.plannedAt.map { "予定 \($0.shortDay)" }, task.slot?.label, task.project.isEmpty ? nil : task.project]
                                        .compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("\(selected.count)件を選択中")
                        Spacer()
                        Button(selected.count == leftovers.count ? "選択を外す" : "すべて選ぶ") {
                            selected = selected.count == leftovers.count ? [] : Set(leftovers.map(\.id))
                        }.font(.caption)
                    }
                } footer: {
                    Text("時間は前の日のまま残ります。「いつでも」に送ると日付と時間を外します。")
                }
            }
            .navigationTitle("残っているタスク").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("今日へ") { apply { store.plan($0, on: Date()) } }
                    Spacer()
                    Button("明日へ") { apply { store.plan($0, on: Calendar.current.date(byAdding: .day, value: 1, to: Date())) } }
                    Spacer()
                    Button("いつでもへ") { apply { store.plan($0, on: nil) } }
                    Spacer()
                    Menu("ほか") {
                        Button("完了にする", systemImage: "checkmark") { apply { store.completeAll($0) } }
                        Button("削除", systemImage: "trash", role: .destructive) { apply { store.deleteAll($0) } }
                    }
                }
            }
            .overlay {
                if leftovers.isEmpty {
                    ContentUnavailableView("振り分けが終わりました", systemImage: "checkmark.circle")
                }
            }
            .onAppear {
                guard !initialized else { return }
                selected = Set(leftovers.map(\.id)); initialized = true
            }
        }
        .storeErrorAlert()
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func apply(_ action: (Set<UUID>) -> Void) {
        guard !selected.isEmpty else { return }
        action(selected)
        selected = []
        if TaskBoard().pastPlanned(store.notebook.tasks, now: Date()).isEmpty { dismiss() }
    }
}

/// 昨日 · 今日 · 明日, as in task-3days. Each shows its date; 明日 shows how many things are planned.
struct DaySwitcher: View {
    @Binding var offset: Int
    let now: Date
    var tomorrowCount = 0

    var body: some View {
        let calendar = Calendar.current
        HStack(spacing: 4) {
            ForEach([-1, 0, 1], id: \.self) { value in
                let day = calendar.date(byAdding: .day, value: value, to: now) ?? now
                let selected = value == offset
                Button { withAnimation(.snappy) { offset = value } } label: {
                    VStack(spacing: 1) {
                        HStack(spacing: 4) {
                            Text(["昨日", "今日", "明日"][value + 1]).font(.subheadline.weight(selected ? .bold : .medium))
                            if value == 1 && tomorrowCount > 0 && !selected {
                                Text("\(tomorrowCount)").font(.caption2.weight(.bold)).monospacedDigit()
                                    .padding(.horizontal, 5).background(Capsule().fill(Palette.accent.opacity(0.18)))
                            }
                        }
                        Text(day.formatted(.dateTime.month(.defaultDigits).day().weekday(.abbreviated)))
                            .font(.caption2).monospacedDigit().opacity(0.8)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Palette.accent : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(["昨日", "今日", "明日"][value + 1])
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 15).fill(Color(uiColor: .secondarySystemGroupedBackground)))
    }
}
