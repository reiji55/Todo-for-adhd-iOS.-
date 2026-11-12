import SwiftUI

/// 今日 opens on this: one thing to do now, what comes after it, and the shape of the day. The full
/// timetable (the Today screen as it was) is one tap away, unchanged.
///
/// When nothing on the schedule is on now, the card first says so (空き時間, or the sleep or work that
/// holds the time) and asks for the condition; what it offers then follows that condition. The choice
/// holds for that stretch of time, and the next free stretch asks again.
@MainActor
struct NowView: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.refreshClock) private var refreshClock
    @Environment(\.selectedTab) private var selectedTab
    @State private var energy: Energy = EnergyMemory.load()
    /// The free stretch the condition was chosen in.
    @State private var chosenFor: String? = EnergyMemory.chosenFor()
    @State private var passed: [String] = PassedOver.load()
    /// Picked from ほかの候補, or kept in front while its 負荷 is changed; it leads until it is done or passed over.
    @State private var chosen: String?
    @State private var work: TaskWork?
    @State private var timetableOpen = false
    /// The thing tapped in 今日の流れ, for the timetable to bring into view and flash once.
    @State private var timetableFocus: String?
    @State private var rolloverOpen = false
    @State private var previewApplied = false
    let onOpen: (AgendaItem) -> Void
    let onWeek: () -> Void
    let onAdd: (AddKind) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = max(context.date, refreshClock)
            ScrollViewReader { proxy in
                ScrollView {
                    content(now: now)
                        .padding(16)
                        .frame(maxWidth: 620)
                        .frame(maxWidth: .infinity)
                        .id("nowTop")
                }
                .background(Palette.paper)
                .onChange(of: store.taskStartRequest) { _, request in
                    if request != nil, let started = store.claimTaskStartPresentation() {
                        work = started
                        showRequestedTask()
                        proxy.scrollTo("nowTop", anchor: .top)
                    }
                }
                .onAppear {
                    // Only a fresh explicit start may change the current navigation or position.
                    if let started = store.claimTaskStartPresentation() {
                        work = started
                        showRequestedTask()
                        proxy.scrollTo("nowTop", anchor: .top)
                    }
                }
            }
        }
        .navigationDestination(isPresented: $timetableOpen) {
            TodayView(onOpen: onOpen, onWeek: onWeek, focus: timetableFocus)
                .navigationTitle("時間割")
                .navigationBarTitleDisplayMode(.inline)
                .floatingAdd(onAdd)
                .keepsStore()
        }
        .sheet(isPresented: $rolloverOpen) { RolloverSheet() }
        // Leaving 今日 for another tab closes the timetable, so coming back shows the card. A task running on
        // the card keeps running.
        .onChange(of: selectedTab) { _, tab in
            if tab != RootView.Tab.today.rawValue { timetableOpen = false; rolloverOpen = false }
        }
        .onChange(of: store.notebook) { _, book in
            if let work, book.hasChildren(work.taskID) || !book.tasks.contains(where: {
                $0.id == work.taskID && !$0.isComplete && !$0.isEvent
            }) { self.work = nil }
            if let chosen, chosen.hasPrefix("task-"),
               !book.tasks.contains(where: { "task-\($0.id.uuidString)" == chosen && !$0.isComplete }) {
                self.chosen = nil
            }
        }
        .onAppear {
            energy = EnergyMemory.load()
            chosenFor = EnergyMemory.chosenFor()
            passed = PassedOver.load()
            applyPreviewArguments()
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let closed = store.closedDay == DayKey.of(now)
        VStack(alignment: .leading, spacing: 14) {
            header(now: now, closed: closed)
            if store.loadFailed {
                Label("保存データを開けません。設定から復旧できます。", systemImage: "exclamationmark.triangle")
                    .font(.subheadline).foregroundStyle(.red)
            }
            if closed {
                DayClosedView(now: now) { timetableOpen = true }
                    .transition(.opacity)
            } else {
                let book = store.notebook
                // A task started on an earlier day is not still running this morning.
                let running = work.flatMap { Calendar.current.isDate($0.startedAt, inSameDayAs: now) ? $0 : nil }
                let stretch = NowPlan.freeStretch(in: book, now: now)
                let picks = NowPlan.picks(in: book, energy: energy, now: now, passed: passed)
                // Whether there is anything to offer at all, whatever the condition.
                let offers = (energy == .any ? picks : NowPlan.picks(in: book, energy: .any, now: now))
                    .contains { $0.kind == .obligation || $0.kind == .candidate }
                if let stretch, stretch.key != chosenFor, offers, running == nil, chosen == nil {
                    FreeStretchCard(stretch: stretch, now: now) { setEnergy($0) }
                        .transition(.opacity)
                    flow(now: now, excluding: nil)
                } else {
                    let current = resolve(running.map { "task-\($0.taskID.uuidString)" } ?? chosen, in: picks, book: book)
                    if let current, !(current.kind == .upcoming && offers) {
                        let rest = picks.filter { $0.id != current.id }
                        NowCard(pick: current,
                                others: Array(rest.prefix(2)),
                                canPass: !rest.isEmpty,
                                stretch: stretch,
                                now: now,
                                work: running,
                                onStart: { id in
                                    let started = Date()
                                    if store.startTask(id, at: started) {
                                        chosen = current.id
                                        work = TaskWork(taskID: id, startedAt: started)
                                        return true
                                    }
                                    return false
                                },
                                onStop: {
                                    work = nil
                                    chosen = current.item.isDone ? nil : current.id
                                    if case .task(let id) = current.item.source, store.task(id)?.isComplete == true { chosen = nil }
                                    if let stretch { remember(stretch.key) }
                                },
                                onPass: { pass(current.id) },
                                onChoose: { chosen = $0 },
                                onKeep: { chosen = current.id },
                                onOpen: onOpen)
                            .id(current.id)
                            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                    } else if offers {
                        NoMatchCard(energy: energy, stretch: stretch, now: now) { setEnergy($0) }
                    } else {
                        NothingLeftCard(now: now)
                    }
                    flow(now: now, excluding: current?.id)
                }
                footer(now: now)
            }
        }
        .animation(.snappy, value: closed)
        .animation(.snappy, value: chosenFor)
    }

    private func header(now: Date, closed: Bool) -> some View {
        HStack {
            Text(Self.dateTitle(now)).font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
            Spacer()
            if !closed {
                Menu {
                    Picker("今の調子", selection: Binding(get: { energy }, set: { setEnergy($0) })) {
                        ForEach(Energy.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    Text("今の調子：\(energy.label)")
                        .font(.caption.weight(.semibold)).foregroundStyle(.primary)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                }
                .accessibilityLabel("今の調子：\(energy.label)")
            }
        }
    }

    /// A condition chosen, here or in the menu: it holds for the stretch of time now, and starts a new round.
    private func setEnergy(_ value: Energy) {
        let key = NowPlan.freeStretch(in: store.notebook, now: max(Date(), refreshClock))?.key
        withAnimation(.snappy) {
            energy = value
            if work == nil { chosen = nil }
            passed = []
            if let key { chosenFor = key }
        }
        EnergyMemory.save(value)
        if let key { EnergyMemory.markChosen(key) }
        PassedOver.save([])
    }

    /// The free stretch is settled: its question is not asked again, also after the app is reopened.
    private func remember(_ key: String) {
        chosenFor = key
        EnergyMemory.markChosen(key)
    }

    /// The pick to show: one picked or kept in front, else the first. One kept in front stays even when a
    /// change to its 負荷 takes it out of the condition, until it is done or passed over.
    private func resolve(_ id: String?, in picks: [NowPick], book: Notebook) -> NowPick? {
        guard let id else { return picks.first }
        if let pick = picks.first(where: { $0.id == id }) { return pick }
        if id.hasPrefix("task-"), let uuid = UUID(uuidString: String(id.dropFirst(5))),
           let task = book.tasks.first(where: { $0.id == uuid }), !task.isComplete {
            if book.hasChildren(task.id) {
                guard let child = book.nextChild(of: task.id) else { return picks.first }
                return NowPick(item: AgendaItem(task: child), kind: .candidate, label: "", parentID: task.id,
                               isMust: TaskBoard().isMust(child, among: book.tasks))
            }
            return NowPick(item: AgendaItem(task: task), kind: .candidate, label: "", parentID: task.parentID,
                           isMust: TaskBoard().isMust(task, among: book.tasks))
        }
        return picks.first
    }

    /// Timed things not done yet that are going on now or come later today, in order. One already going
    /// on is listed while something else holds the card (a task being worked on, or one picked).
    private func laterToday(_ now: Date, excluding id: String?) -> [AgendaItem] {
        let minute = Self.minute(of: now)
        return Agenda.items(on: now, tasks: store.notebook.tasks, routines: store.notebook.routines)
            .filter { item in
                guard !item.isBlock, !item.isDone, item.id != id, let slot = item.slot else { return false }
                return slot.start > minute || slot.end > minute
            }
    }

    /// The day's flow with the next two things below it, in one card. Its blocks and rows open the
    /// timetable at that thing; its heading opens the timetable as it is.
    private func flow(now: Date, excluding id: String?) -> some View {
        DayFlow(now: now, next: Array(laterToday(now, excluding: id).prefix(2)),
                onOpen: { timetableFocus = nil; timetableOpen = true },
                onItem: { timetableFocus = $0; timetableOpen = true })
    }

    private func footer(now: Date) -> some View {
        let leftovers = TaskBoard().pastPlanned(store.notebook.tasks, now: now)
        return HStack(spacing: 8) {
            if !leftovers.isEmpty {
                Button { rolloverOpen = true } label: {
                    Label("前の日から残っているタスク \(leftovers.count)件", systemImage: "tray.and.arrow.down")
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(Palette.must)
            }
            Spacer(minLength: 0)
            Button {
                withAnimation(.snappy) { work = nil; store.closeDay(now: now) }
            } label: {
                Text("今日を終える").font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14).frame(minHeight: 36)
                    .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.35)))
                    .contentShape(Capsule())
            }
            .foregroundStyle(.primary)
            .accessibilityHint("今日このあとのタスクとルーティンの通知を止めます。再開すると戻ります")
        }
        .padding(.horizontal, 4)
    }

    private func pass(_ id: String) {
        withAnimation(.snappy) {
            passed.removeAll { $0 == id }
            passed.append(id)
            chosen = nil
        }
        PassedOver.save(passed)
    }

    /// Starting from an idea or project returns from the timetable into the shared running card.
    private func showRequestedTask() {
        guard let work else { return }
        timetableOpen = false
        rolloverOpen = false
        chosen = "task-\(work.taskID.uuidString)"
        if let stretch = NowPlan.freeStretch(in: store.notebook, now: Date()) { remember(stretch.key) }
    }

    private func applyPreviewArguments() {
#if DEBUG
        guard !previewApplied else { return }
        previewApplied = true
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-uiTimetable") { timetableOpen = true }
        if arguments.contains("-uiDayClosed") { store.closeDayForPreview() }
        // Screenshot runs: the condition already chosen, to show the card it leads to.
        if let i = arguments.firstIndex(of: "-uiEnergy"), arguments.indices.contains(i + 1),
           let value = Energy(rawValue: arguments[i + 1]) {
            setEnergy(value)
        }
#endif
    }

    static func minute(of date: Date) -> Int {
        let calendar = Calendar.current
        return calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }

    /// "11月5日（木）", whatever the device's language.
    static func dateTitle(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day, .weekday], from: date)
        let names = ["日", "月", "火", "水", "木", "金", "土"]
        return "\(c.month ?? 0)月\(c.day ?? 0)日（\(names[((c.weekday ?? 1) - 1) % 7])）"
    }

    /// "2時間20分", "35分".
    static func duration(_ minutes: Int) -> String {
        let m = max(0, minutes)
        if m < 60 { return "\(m)分" }
        return m % 60 == 0 ? "\(m / 60)時間" : "\(m / 60)時間\(m % 60)分"
    }

    /// What holds the time now, in a word: 空き時間, or the name of the sleep or work holding it.
    static func stretchTitle(_ stretch: FreeStretch) -> String {
        stretch.held.map { "\($0.title)の時間" } ?? "空き時間"
    }

    /// "12:00まで", or that nothing more is on today.
    static func stretchEnd(_ stretch: FreeStretch) -> String {
        stretch.until.map { "\(TimeSlot.clock($0))まで" } ?? "このあと予定なし"
    }
}

/// What 入れ替える passed over today, in order. It only changes the order of the いま card and is
/// forgotten the next morning.
enum PassedOver {
    static func load(now: Date = Date()) -> [String] {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "passedDay") == DayKey.of(now) else { return [] }
        return defaults.stringArray(forKey: "passed") ?? []
    }

    static func save(_ ids: [String], now: Date = Date()) {
        UserDefaults.standard.set(ids, forKey: "passed")
        UserDefaults.standard.set(DayKey.of(now), forKey: "passedDay")
    }
}

/// The card stays in place while an ordinary task is being worked on. Routine runs continue to use
/// their existing focus screen and persistent timer; events only expose their existing done action.
@MainActor
private struct NowCard: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.startRoutine) private var startRoutine
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let pick: NowPick
    let others: [NowPick]
    let canPass: Bool
    let stretch: FreeStretch?
    let now: Date
    let work: TaskWork?
    let onStart: (UUID) -> Bool
    let onStop: () -> Void
    let onPass: () -> Void
    let onChoose: (String) -> Void
    let onKeep: () -> Void
    let onOpen: (AgendaItem) -> Void
    @State private var finished = 0
    @State private var weighed = 0
    @State private var showingNote = false
    @State private var draft = ""
    @FocusState private var noteFocused: Bool

    /// Marks on the dark card are white, in one family with its buttons; no second accent color.
    private let mark = Color.white
    private var task: TaskItem? {
        guard case .task(let id) = pick.item.source, let task = store.task(id), !task.isEvent else { return nil }
        return task
    }
    private var working: Bool { task?.id == work?.taskID && work != nil }
    private var parent: TaskItem? { pick.parentID.flatMap { store.task($0) } }
    private var children: [TaskItem] {
        guard let id = parent?.id ?? task?.id else { return [] }
        return store.children(of: id)
    }
    private var project: String { pick.item.project.isEmpty ? (parent?.project ?? "") : pick.item.project }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            focusCard
            if !others.isEmpty, !pick.item.isEvent { candidateChips }
        }
    }

    private var focusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Button { onOpen(pick.item) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    projectLine
                    kicker
                    Text(pick.item.title).font(.title2.weight(.bold))
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.white)
                    if let due = task?.deadline ?? parent?.deadline, !pick.label.contains("締切") {
                        Text("締切 \(ProjectText.day(due))").font(.caption).foregroundStyle(.white.opacity(0.75))
                    }
                    if hasInlineNotes {
                        ItemNotesView(item: pick.item, foreground: .white.opacity(0.85),
                                      includesContinuation: !pick.item.isRoutine)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("nowTaskDetails")
            .accessibilityHint("開いて編集します。メモの全文もここから読めます")
            if let note = routineContinuation {
                VStack(alignment: .leading, spacing: 2) {
                    Text("前回の続き").font(.caption).foregroundStyle(.white.opacity(0.75))
                    Text(note).font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if !children.isEmpty {
                ChildProgressView(children: children, tint: mark)
                    .accessibilityIdentifier("nowChildProgress")
            }
            actions
            if showingNote, let task, !working {
                HStack(alignment: .top, spacing: 8) {
                    TextField("次はどこから？（任意）", text: $draft,
                              prompt: Text("次はどこから？（任意）").foregroundColor(.white.opacity(0.65)), axis: .vertical)
                        .font(.subheadline).lineLimit(1...2)
                        .focused($noteFocused)
                        .padding(10).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("taskContinuationInput")
                    Button("残す") {
                        if store.saveTaskContinuation(task.id, note: draft) {
                            noteFocused = false; draft = ""; showingNote = false
                        }
                    }
                    .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("saveTaskContinuation")
                }
                .tint(.white)
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(alignment: .trailing) {
            FocusLeaves().opacity(0.35).padding(.trailing, 12)
        }
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.35, blue: 0.28),
                                              Color(red: 0.06, green: 0.22, blue: 0.16)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.25)))
                .shadow(color: Palette.accent.opacity(0.3), radius: 8, x: 4, y: 5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nowFocusCard")
        .sensoryFeedback(.success, trigger: finished)
        .sensoryFeedback(.selection, trigger: weighed)
    }

    private var header: some View {
        headerLayout {
            Text(working ? "実行中" : pick.kind == .upcoming ? "次" : "いま")
                .font(.caption.weight(.bold)).foregroundStyle(Color(red: 0.08, green: 0.24, blue: 0.18))
                .padding(.horizontal, 10).padding(.vertical, 6).background(mark, in: Capsule())
            if working, let work {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(ElapsedTimer.clock(work.elapsed(at: context.date)))
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                        .accessibilityIdentifier("taskElapsed")
                }
            } else if let slot = pick.item.slot, pick.kind == .inSlot || pick.kind == .upcoming {
                Text("\(slot.startLabel)–\(TimeSlot.clock(slot.end))")
                    .font(.caption).monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
            } else if let stretch {
                HStack(spacing: 3) {
                    Text(NowView.stretchTitle(stretch)).lineLimit(1).truncationMode(.tail)
                    Text("· " + NowView.stretchEnd(stretch)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                }
                .font(.caption2)
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            if let task {
                EffortBadge(effort: task.effort) { cycleEffort(of: task) }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if working {
            actionLayout {
                Button {
                    onStop()
                    draft = task?.continuationNote ?? ""
                    showingNote = true
                } label: { Label("中断する", systemImage: "pause.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(FocusActionStyle(kind: .secondary))
                    .accessibilityIdentifier("interruptTask")
                Button(action: complete) {
                    Label("完了", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(FocusActionStyle(kind: .primary))
                .accessibilityIdentifier("completeActiveTask")
            }
        } else if pick.item.isEvent {
            Button(action: complete) {
                Label("完了", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(FocusActionStyle(kind: .primary))
            .accessibilityIdentifier("completeEvent")
        } else {
            actionLayout {
                Button {
                    if let task {
                        if onStart(task.id) { showingNote = false }
                    } else if let startRoutine { startRoutine(pick.item) }
                } label: {
                    Label(store.isTiming(pick.item) ? "計測中" : "始める", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(FocusActionStyle(kind: .primary))
                .accessibilityIdentifier("startNowItem")
                if canPass {
                    Button(action: onPass) {
                        Label("入れ替える", systemImage: "arrow.left.arrow.right")
                    }
                    .buttonStyle(FocusActionStyle(kind: .secondary))
                }
            }
        }
    }

    private var actionLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
    }

    private var headerLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
    }

    @ViewBuilder private var projectLine: some View {
        if !project.isEmpty, !(pick.item.isRoutine || pick.item.isEvent) {
            let color = ProjectColor.color(for: store.colorName(forProject: project)) ?? Palette.accent
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(project).lineLimit(1)
            }
            .font(.footnote.weight(.bold)).foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
            // The agreed card is always dark; use the existing dark project palette on it.
            .environment(\.colorScheme, .dark)
            .accessibilityLabel("プロジェクト：\(project)")
        }
    }

    @ViewBuilder private var kicker: some View {
        let labels = kickerLabels
        if parent != nil || !labels.isEmpty {
            HStack(spacing: 6) {
                if let parent {
                    Text("↳ \(parent.title)").lineLimit(1)
                    if parent.isMust { Text("★").accessibilityLabel("必須") }
                }
                if !labels.isEmpty {
                    Text((parent == nil ? "" : "・ ") + labels.joined(separator: " ・ ")).lineLimit(1)
                }
            }
            .font(.footnote.weight(.bold))
            .foregroundStyle(kickerColor)
            .environment(\.colorScheme, .dark)
        }
    }

    private var kickerColor: Color {
        if pick.item.isRoutine || pick.item.isEvent { return Palette.accent }
        return pick.isMust || pick.label.contains("締切") ? Palette.must : Palette.accent
    }

    private var kickerLabels: [String] {
        var parts: [String] = []
        if pick.isMust && parent == nil { parts.append("★必須") }
        if !pick.label.isEmpty { parts.append(pick.label) }
        if pick.item.isRoutine || pick.item.isEvent, !pick.item.project.isEmpty { parts.append(pick.item.project) }
        if let task, let progress = store.notebook.listProgress(of: task) { parts.append("リスト \(progress.done)/\(progress.total)") }
        return parts
    }

    private var hasInlineNotes: Bool {
        switch pick.item.source {
        case .task(let id):
            guard let task = store.task(id) else { return false }
            return !task.memo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !task.continuationNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .routine(let id, _):
            return !(store.routine(id)?.memo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    private var routineContinuation: String? {
        guard case .routine(let id, _) = pick.item.source,
              let note = store.routine(id)?.resumeNote, !note.isEmpty else { return nil }
        return note
    }

    private var candidateChips: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ほかの候補").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(others) { other in
                    Button { withAnimation(.snappy) { onChoose(other.id) } } label: { chip(other) }
                        .buttonStyle(.plain)
                        .accessibilityHint("これを、いまのカードにします")
                }
            }
        }
        .disabled(working)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nowOtherCandidates")
    }

    private func chip(_ other: NowPick) -> some View {
        HStack(spacing: 4) {
            if other.isMust {
                Image(systemName: "star.fill").font(.caption2).foregroundStyle(Palette.must)
                    .accessibilityLabel("必須")
            }
            Text(other.item.title).foregroundStyle(.primary).lineLimit(1)
            let otherProject = other.item.project.isEmpty
                ? (other.parentID.flatMap { store.task($0)?.project } ?? "") : other.item.project
            if !otherProject.isEmpty, !(other.item.isRoutine || other.item.isEvent) {
                Circle().fill(ProjectColor.color(for: store.colorName(forProject: otherProject)) ?? Palette.accent)
                    .frame(width: 6, height: 6).accessibilityHidden(true)
                Text(otherProject).foregroundStyle(.secondary).lineLimit(1)
            }
            if !other.label.isEmpty {
                Text("・ \(other.label)")
                    .foregroundStyle(other.label.contains("締切") ? Palette.must : Color.secondary)
            }
        }
        .font(.footnote)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RaisedCardBackground(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func complete() {
        guard case .task(let id) = pick.item.source, let current = store.task(id), !current.isComplete,
              store.complete(id) else { return }
        onStop()
        store.offerUndo("「\(pick.item.title)」を完了にしました")
        finished += 1
    }

    private func cycleEffort(of task: TaskItem) {
        let all = Effort.allCases
        let next = all[((all.firstIndex(of: task.effort) ?? 0) + 1) % all.count]
        onKeep()
        store.change(task.id) { $0.effort = next }
        weighed += 1
    }
}

private struct FocusActionStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    let kind: Kind
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.bold))
            .foregroundStyle(kind == .secondary ? Color.white : Color(red: 0.08, green: 0.24, blue: 0.18))
            .padding(.horizontal, 18).frame(minHeight: 50)
            .background {
                Capsule().fill(kind == .secondary ? Color.clear : Color.white)
            }
            .overlay(Capsule().strokeBorder(kind == .secondary ? .white.opacity(0.7) : .clear))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// A task's 負荷 at the top right of the card, as three bars and a word. A tap moves it one step.
private struct EffortBadge: View {
    let effort: Effort
    let onCycle: () -> Void

    var body: some View {
        Button(action: onCycle) {
            HStack(spacing: 6) {
                Text("負荷").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                EffortMeter(level: effort.rank + 1, color: .white)
                Text(effort.label).font(.caption.weight(.bold)).foregroundStyle(.white)
            }
            .padding(.horizontal, 10).frame(minHeight: 30)
            .background(.white.opacity(0.1), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("負荷：\(effort.label)")
        .accessibilityHint("タップで、軽め・ふつう・じっくりを切り替えます")
    }
}

/// Three bars of rising height, lit up to the level (1 light … 3 heavy).
private struct EffortMeter: View {
    let level: Int
    var color: Color = .primary

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...3, id: \.self) { step in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(step <= level ? color : color.opacity(0.22))
                    .frame(width: 4, height: CGFloat(4 + step * 3))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Before anything is offered in free time: that the time is free (or held for sleep or work) and until
/// when, and the question of the condition. Nothing is suggested until it is answered.
@MainActor
private struct FreeStretchCard: View {
    let stretch: FreeStretch
    let now: Date
    let onChoose: (Energy) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NowMark(title: "いま", color: Palette.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(NowView.stretchTitle(stretch)).font(.title.weight(.heavy))
                Text(span).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit()
            }
            Divider().padding(.vertical, 2)
            Text("今の調子は？").font(.subheadline.weight(.bold))
            EnergyChoices(choices: [.high, .normal, .low, .any], onChoose: onChoose)
            Text("選んだ調子より重いものは出さず、重いものから順に出します。指定なしは優先度の順です。")
                .font(.caption).foregroundStyle(.secondary).onlyInDemo()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(RaisedCardBackground(cornerRadius: 24))
    }

    private var span: String {
        guard let until = stretch.until else { return "今日はこのあと予定なし" }
        return "\(TimeSlot.clock(until))まで ・ あと\(NowView.duration(until - NowView.minute(of: now)))"
    }
}

/// When nothing fits the condition chosen: say so, and offer the others.
@MainActor
private struct NoMatchCard: View {
    let energy: Energy
    let stretch: FreeStretch?
    let now: Date
    let onChoose: (Energy) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                NowMark(title: "いま", color: Palette.accent)
                if let stretch {
                    Text("\(NowView.stretchTitle(stretch)) ・ \(NowView.stretchEnd(stretch))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Text("「\(energy.label)」に合うタスクはありません").font(.title3.weight(.bold))
            Text("調子を変える").font(.caption).foregroundStyle(.secondary)
            EnergyChoices(choices: [Energy.high, .normal, .low, .any].filter { $0 != energy }, onChoose: onChoose)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(RaisedCardBackground(cornerRadius: 24))
    }
}

/// The conditions to choose from, two to a row.
private struct EnergyChoices: View {
    let choices: [Energy]
    let onChoose: (Energy) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(choices) { energy in
                Button { onChoose(energy) } label: {
                    HStack(spacing: 8) {
                        if let effort = energy.preferred { EffortMeter(level: effort.rank + 1, color: Palette.accent) }
                        Text(energy.label).font(.body.weight(.bold))
                    }
                    .foregroundStyle(Palette.accent)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("今の調子：\(energy.label)")
            }
        }
    }
}

/// The small dot and word at the top of a card: いま, 次, 今日は終了.
private struct NowMark: View {
    let title: String
    let color: Color
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
        }
        .font(.footnote.weight(.heavy)).foregroundStyle(color)
        // The launch sprout's bud lands on this mark.
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { LaunchMark.shared.report(geometry.frame(in: .global)) }
                    .onChange(of: geometry.frame(in: .global)) { _, frame in LaunchMark.shared.report(frame) }
            }
        }
    }
}

private struct NowButtonStyle: ButtonStyle {
    let prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.bold))
            .foregroundStyle(prominent ? Color.white : Palette.accent)
            .padding(.horizontal, 18)
            .frame(minHeight: 50)
            .background(Capsule().fill(prominent ? Palette.accent : Palette.accent.opacity(0.12)))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

/// One timed thing later today: its time, what kind it is, and its name. A tap opens the timetable at it.
private struct UpcomingRow: View {
    let item: AgendaItem
    var ongoing = false
    let onOpen: () -> Void
    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Text(item.slot?.startLabel ?? "").font(.subheadline.weight(.bold)).monospacedDigit()
                    .frame(width: 46, alignment: .leading)
                Image(systemName: item.isRoutine ? "arrow.triangle.2.circlepath" : item.isEvent ? "calendar" : "circle")
                    .font(.subheadline).foregroundStyle(Palette.accent).frame(width: 22)
                Text(item.title).font(.subheadline).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if ongoing {
                    Text("\(TimeSlot.clock(item.slot?.end ?? 0))まで").font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.accent).monospacedDigit()
                }
            }
            .padding(.horizontal, 14).frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ongoing ? "\(item.title)、\(TimeSlot.clock(item.slot?.end ?? 0))まで" : "\(item.slot?.startLabel ?? "") \(item.title)")
    }
}

/// When nothing is left for today.
@MainActor
private struct NothingLeftCard: View {
    @EnvironmentObject private var store: TaskStore
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NowMark(title: "いま", color: Palette.accent)
            Text("今日やることは残っていません").font(.title3.weight(.bold))
            if let first = NowPlan.firstOfNextDay(after: now, in: store.notebook) { NextDayLine(item: first) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(RaisedCardBackground(cornerRadius: 24))
    }
}

private struct NextDayLine: View {
    let item: AgendaItem
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("明日の最初").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let slot = item.slot { Text(slot.startLabel).foregroundStyle(Palette.accent).monospacedDigit() }
                Text(item.title).foregroundStyle(.primary)
            }
            .font(.title3.weight(.heavy))
        }
        .accessibilityElement(children: .combine)
    }
}

/// After 今日を終える: tomorrow's first thing, a way back, and what today held.
@MainActor
private struct DayClosedView: View {
    @EnvironmentObject private var store: TaskStore
    let now: Date
    let onTimetable: () -> Void

    private struct Done: Identifiable {
        let id: String
        let title: String
        let note: String
    }

    var body: some View {
        let today = Agenda.items(on: now, tasks: store.notebook.tasks, routines: store.notebook.routines)
            .filter { !$0.isBlock && !$0.isEvent }
        let left = today.filter { !$0.isDone }.count
        let done = doneToday(today)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                NowMark(title: "今日は終了", color: .secondary)
                if let first = NowPlan.firstOfNextDay(after: now, in: store.notebook) { NextDayLine(item: first) }
                Button { withAnimation(.snappy) { store.reopenDay() } } label: {
                    Label("再開する", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(NowButtonStyle(prominent: false))
                .accessibilityHint("今日の通知も戻ります")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(RaisedCardBackground(cornerRadius: 24))

            if !done.isEmpty {
                Text("今日やったこと").font(.footnote.weight(.bold)).foregroundStyle(.secondary).padding(.leading, 4)
                VStack(spacing: 0) {
                    ForEach(Array(done.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().padding(.leading, 46) }
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(Palette.accent)
                            Text(entry.title).font(.subheadline).lineLimit(2)
                            Spacer(minLength: 8)
                            Text(entry.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.horizontal, 14).frame(minHeight: 46)
                        .accessibilityElement(children: .combine)
                    }
                }
                .background(RaisedCardBackground(cornerRadius: 16))
            }
            if left > 0 {
                Button(action: onTimetable) {
                    HStack(spacing: 4) {
                        Text("残ったもの \(left)件")
                        Image(systemName: "chevron.right").font(.caption.weight(.bold))
                    }
                    .font(.footnote.weight(.semibold))
                    .frame(minHeight: 36)
                }
                .foregroundStyle(.primary)
                .padding(.leading, 4)
            }
        }
    }

    /// Tasks checked off today (a task in pieces counts by its pieces) and today's routines, in order.
    private func doneToday(_ today: [AgendaItem]) -> [Done] {
        let calendar = Calendar.current
        let book = store.notebook
        let tasks = book.tasks
            .filter { task in
                !task.isEvent && !book.hasChildren(task.id)
                    && task.completedAt.map { calendar.isDate($0, inSameDayAs: now) } == true
            }
            .sorted { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }
            .map { task in
                let parent = task.parentID.flatMap { id in book.tasks.first { $0.id == id } }
                return Done(id: "task-\(task.id.uuidString)", title: task.title, note: parent?.title ?? task.project)
            }
        let routines = today.filter { $0.isDone && $0.isRoutine }.map { item in
            Done(id: item.id, title: item.title, note: routineNote(item))
        }
        return tasks + routines
    }

    private func routineNote(_ item: AgendaItem) -> String {
        guard case .routine(let id, let day) = item.source, let seconds = store.routine(id)?.durations[day], seconds > 0 else {
            return "ルーティン"
        }
        return NowView.duration(seconds / 60)
    }
}

/// Today on a horizontal time axis, an hour to 64 points, scrolled so that now sits near the left edge.
/// Each block is as long as its time and carries its name; one too short for its name has it beside it.
/// Blocks share a row unless their names would collide. Held time (sleep, work) is shaded, what is past
/// is dimmed, and a red line marks the minute. A tap opens the timetable.
@MainActor
private struct DayFlow: View {
    @EnvironmentObject private var store: TaskStore
    let now: Date
    /// The next things not done yet (one going on now included), listed below the flow.
    var next: [AgendaItem] = []
    let onOpen: () -> Void
    /// A block or row tapped: the timetable opens at it.
    var onItem: (String) -> Void = { _ in }

    static let hourWidth: CGFloat = 64
    static let laneHeight: CGFloat = 54
    static let axisHeight: CGFloat = 20

    struct Placed: Identifiable {
        let item: AgendaItem
        let lane: Int
        let x: CGFloat
        let width: CGFloat
        /// The name fits inside the block; otherwise it sits to the right of it.
        let inside: Bool
        let labelWidth: CGFloat
        var id: String { item.id }
    }

    var body: some View {
        let items = Agenda.items(on: now, tasks: store.notebook.tasks, routines: store.notebook.routines)
        let held = items.filter { $0.isBlock && $0.slot != nil }
        let timed = items.filter { !$0.isBlock && $0.slot != nil }
        let range = Agenda.hourRange(for: timed)
        let placed = Self.place(timed, fromHour: range.lowerBound)
        let lanes = max(1, (placed.map(\.lane).max() ?? 0) + 1)
        let width = CGFloat(range.upperBound - range.lowerBound) * Self.hourWidth
        // Held time is named along the bottom, below the rows of blocks.
        let strip: CGFloat = held.isEmpty ? 0 : 16
        let height = Self.axisHeight + CGFloat(lanes) * Self.laneHeight + 4 + strip
        let nowX = Self.x(NowView.minute(of: now), fromHour: range.lowerBound)
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onOpen) {
                HStack {
                    Text("今日の流れ").font(.subheadline.weight(.bold)).foregroundStyle(.primary)
                    Spacer()
                    HStack(spacing: 3) {
                        Text("時間割")
                        Image(systemName: "chevron.right").font(.caption.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.accent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("今日の流れ、時間割を開く")
            .accessibilityIdentifier("openTimetable")
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    ZStack(alignment: .topLeading) {
                        ForEach(held) { item in
                            let slot = item.slot!
                            let start = max(0, Self.x(slot.start, fromHour: range.lowerBound))
                            let end = min(width, Self.x(slot.end, fromHour: range.lowerBound))
                            if end > start {
                                HeldFill(cornerRadius: 0)
                                    .frame(width: end - start, height: height).offset(x: start)
                                Text("\(item.title) \(slot.label)")
                                    .font(.system(size: 9, weight: .bold)).foregroundStyle(HeldFill.label)
                                    .lineLimit(1).truncationMode(.tail)
                                    .frame(width: max(0, end - start - 8), alignment: .leading)
                                    .offset(x: start + 4, y: height - 14)
                            }
                        }
                        if nowX > 0 {
                            Rectangle().fill(Color.primary.opacity(0.035)).frame(width: min(width, nowX), height: height)
                        }
                        ForEach(range.lowerBound..<range.upperBound, id: \.self) { hour in
                            let x = CGFloat(hour - range.lowerBound) * Self.hourWidth
                            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1, height: height).offset(x: x)
                            Text("\(hour % 24)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(.secondary).offset(x: x + 4, y: 3)
                        }
                        ForEach(placed) { block in
                            FlowBlock(block: block)
                                .contentShape(Rectangle())
                                .onTapGesture { onItem(block.item.id) }
                                .offset(x: block.x, y: Self.axisHeight + CGFloat(block.lane) * Self.laneHeight)
                        }
                        if nowX >= 0 && nowX <= width {
                            Capsule().fill(Color.red).frame(width: 2, height: height - 12).offset(x: nowX - 1, y: 12)
                            Circle().fill(Color.red).frame(width: 9, height: 9).offset(x: nowX - 4.5, y: 8)
                        }
                        // Where the view scrolls to: an hour before now.
                        HStack(spacing: 0) {
                            Color.clear.frame(width: max(0, min(width - 1, nowX - Self.hourWidth)), height: 1)
                            Color.clear.frame(width: 1, height: 1).id("now")
                        }
                    }
                    .frame(width: width, height: height, alignment: .topLeading)
                }
                .onAppear {
                    DispatchQueue.main.async { proxy.scrollTo("now", anchor: .leading) }
                }
            }
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken(timed))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onOpen() }
            .accessibilityIdentifier("dayFlowTimeline")
            if !next.isEmpty {
                VStack(spacing: 0) {
                    ForEach(next) { item in
                        Divider().padding(.leading, 14)
                        UpcomingRow(item: item, ongoing: (item.slot?.start ?? 0) <= NowView.minute(of: now)) { onItem(item.id) }
                            .accessibilityHint("時間割のこの場所を開きます")
                    }
                }
                .padding(.horizontal, -14)
            }
        }
        .padding(14)
        .background(RaisedCardBackground(cornerRadius: 16))
    }

    static func x(_ minute: Int, fromHour hour: Int) -> CGFloat {
        CGFloat(minute - hour * 60) / 60 * hourWidth
    }

    /// Rows for the blocks: each goes in the first row where it and its name clear the one before;
    /// with three rows full, in the row that frees up first.
    static func place(_ items: [AgendaItem], fromHour hour: Int) -> [Placed] {
        var ends: [CGFloat] = []
        var result: [Placed] = []
        for item in items.sorted(by: { ($0.slot?.start ?? 0) < ($1.slot?.start ?? 0) }) {
            guard let slot = item.slot else { continue }
            let x = Self.x(slot.start, fromHour: hour)
            let width = max(6, CGFloat(slot.duration) / 60 * hourWidth)
            let inside = width >= 60
            let labelWidth = min(170, CGFloat(item.title.count) * 12 + 14)
            let reach = inside ? x + width : x + width + 4 + labelWidth
            let lane: Int
            if let free = ends.firstIndex(where: { $0 <= x - 4 }) {
                lane = free
            } else if ends.count < 3 {
                lane = ends.count
            } else {
                lane = ends.indices.min { ends[$0] < ends[$1] } ?? 0
            }
            if lane == ends.count { ends.append(reach) } else { ends[lane] = max(ends[lane], reach) }
            result.append(Placed(item: item, lane: lane, x: x, width: width, inside: inside, labelWidth: labelWidth))
        }
        return result
    }

    private func spoken(_ timed: [AgendaItem]) -> String {
        let open = timed.filter { !$0.isDone }
        let list = open.prefix(4).map { "\($0.slot?.startLabel ?? "") \($0.title)" }.joined(separator: "、")
        return "今日の流れ。" + (open.isEmpty ? "時間の決まった予定はありません。" : "\(list)。") + "時間割を開きます"
    }
}

/// One block on the axis: filled in its project's color, outlined for an event, faded once done.
@MainActor
private struct FlowBlock: View {
    @EnvironmentObject private var store: TaskStore
    let block: DayFlow.Placed

    var body: some View {
        let item = block.item
        let color = ProjectColor.color(for: store.colorName(forProject: item.project)) ?? Palette.accent
        HStack(alignment: .top, spacing: 4) {
            ZStack(alignment: .topLeading) {
                if item.isEvent {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(color, lineWidth: 1.5))
                } else {
                    RoundedRectangle(cornerRadius: block.inside ? 7 : 3, style: .continuous).fill(color.opacity(block.inside ? 0.3 : 0.75))
                }
                if block.inside { label(color).padding(.horizontal, 6).padding(.vertical, 4) }
            }
            .frame(width: block.width, height: DayFlow.laneHeight - 6)
            if !block.inside { label(color).frame(width: block.labelWidth, alignment: .leading).padding(.top, 4) }
        }
        .opacity(item.isDone ? 0.5 : 1)
    }

    private func label(_ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(block.item.slot?.startLabel ?? "").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.secondary)
            Text(block.item.title).font(.system(size: 12, weight: .bold)).lineLimit(2)
                .strikethrough(block.item.isDone)
                .foregroundStyle(block.item.isEvent ? color : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
