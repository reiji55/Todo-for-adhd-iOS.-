import SwiftUI

@MainActor
struct TodayView: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.refreshClock) private var refreshClock
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var energy: Energy = EnergyMemory.load()
    @State private var drawerOpen = false
    @State private var rolloverOpen = false
    @State private var showDone = false
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
                            CandidateDrawer(isOpen: $drawerOpen) {
                                CandidatePanel(energy: $energy, now: now, onOpen: onOpen, onStart: onStart)
                            }
                        }
                }
            }
            .background(Palette.paper)
        }
        .sheet(isPresented: $rolloverOpen) { RolloverSheet() }
        .onChange(of: energy) { _, value in EnergyMemory.save(value) }
    }

    @ViewBuilder private func main(now: Date) -> some View {
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
        let visible = agenda.filter { !$0.isDone || store.recentlyDone.contains($0.id) }
        let doneEarlier = agenda.filter { $0.isDone && !store.recentlyDone.contains($0.id) }
        // Today's planned work is already in the timetable; this list is what would otherwise be missed.
        let required = board.obligations(placement, now: now).filter { task in
            task.plannedAt.map { calendar.isDate($0, inSameDayAs: now) } != true
        }
        let leftovers = board.pastPlanned(tasks, now: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let tomorrowCount = Agenda.items(on: tomorrow, tasks: tasks, routines: store.notebook.routines)
            .filter { !$0.isDone && !$0.isBlock }.count

        LazyVStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(now.formatted(.dateTime.month().day().weekday(.wide))).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button(tomorrowCount > 0 ? "明日 \(tomorrowCount)件 ›" : "週を見る ›", action: onWeek).font(.subheadline)
            }
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
            let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
            let nowIndex = visible.firstIndex { ($0.slot?.start ?? Int.max) > minute } ?? visible.count
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                if index == nowIndex && visible.contains(where: { $0.slot != nil }) { NowLine(now: now) }
                if index > 0, item.slot == nil, visible[index - 1].slot != nil {
                    Text("時間を決めていない").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                }
                AgendaRow(item: item, onOpen: onOpen, onStart: onStart)
            }
            if nowIndex == visible.count && visible.contains(where: { $0.slot != nil }) && !visible.isEmpty
                && visible.last?.slot != nil { NowLine(now: now) }
            if !doneEarlier.isEmpty {
                Button { withAnimation { showDone.toggle() } } label: {
                    Label("今日やったこと \(doneEarlier.count)件", systemImage: showDone ? "chevron.down" : "chevron.right")
                        .font(.subheadline).frame(minHeight: 44)
                }
                if showDone {
                    ForEach(doneEarlier) { item in AgendaRow(item: item, onOpen: onOpen) }
                }
            }
            UpcomingDeadlines(now: now, onOpen: onOpen)
        }
        .frame(maxWidth: 760).frame(maxWidth: .infinity)
    }
}

/// The red line for the current time, as in the task-3days timetable.
struct NowLine: View {
    let now: Date
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Text(now.formatted(date: .omitted, time: .shortened)).font(.clock).foregroundStyle(.red)
            Rectangle().fill(Color.red).frame(height: 1.5)
        }
        .padding(.vertical, 2)
        .accessibilityLabel("現在 \(now.formatted(date: .omitted, time: .shortened))")
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
