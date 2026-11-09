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
    @State private var energy: Energy = EnergyMemory.load()
    /// The free stretch the condition was chosen in.
    @State private var chosenFor: String? = EnergyMemory.chosenFor()
    @State private var passed: [String] = PassedOver.load()
    /// Picked from ほかの候補, or kept in front while its 負荷 is changed; it leads until it is done or passed over.
    @State private var chosen: String?
    @State private var work: TaskWork?
    @State private var timetableOpen = false
    @State private var rolloverOpen = false
    @State private var previewApplied = false
    let onOpen: (AgendaItem) -> Void
    let onWeek: () -> Void
    let onAdd: (AddKind) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = max(context.date, refreshClock)
            ScrollView {
                content(now: now)
                    .padding(16)
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
            }
            .background(Palette.paper)
        }
        .navigationDestination(isPresented: $timetableOpen) {
            TodayView(onOpen: onOpen, onWeek: onWeek)
                .navigationTitle("時間割")
                .navigationBarTitleDisplayMode(.inline)
                .floatingAdd(onAdd)
        }
        .sheet(isPresented: $rolloverOpen) { RolloverSheet() }
        .onChange(of: store.notebook) { _, book in
            if let work, !book.tasks.contains(where: { $0.id == work.taskID && !$0.isComplete && !$0.isEvent }) {
                self.work = nil
            }
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
                let stretch = NowPlan.freeStretch(in: book, now: now)
                let picks = NowPlan.picks(in: book, energy: energy, now: now, passed: passed)
                // Whether there is anything to offer at all, whatever the condition.
                let offers = (energy == .any ? picks : NowPlan.picks(in: book, energy: .any, now: now))
                    .contains { $0.kind == .obligation || $0.kind == .candidate }
                if let stretch, stretch.key != chosenFor, offers, work == nil, chosen == nil {
                    FreeStretchCard(stretch: stretch, now: now) { setEnergy($0) }
                        .transition(.opacity)
                    upcoming(now: now, excluding: nil)
                } else {
                    let current = resolve(work.map { "task-\($0.taskID.uuidString)" } ?? chosen, in: picks, book: book)
                    if let current, !(current.kind == .upcoming && offers) {
                        let rest = picks.filter { $0.id != current.id }
                        NowCard(pick: current,
                                others: Array(rest.prefix(2)),
                                canPass: !rest.isEmpty,
                                stretch: stretch,
                                now: now,
                                work: work,
                                onStart: { id in
                                    let started = Date()
                                    if store.startTask(id, at: started) {
                                        chosen = current.id
                                        work = TaskWork(taskID: id, startedAt: started)
                                    }
                                },
                                onStop: {
                                    work = nil
                                    chosen = current.item.isDone ? nil : current.id
                                    if case .task(let id) = current.item.source, store.task(id)?.isComplete == true { chosen = nil }
                                    if let stretch { chosenFor = stretch.key }
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
                    upcoming(now: now, excluding: current?.id)
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

    /// The pick to show: one picked or kept in front, else the first. One kept in front stays even when a
    /// change to its 負荷 takes it out of the condition, until it is done or passed over.
    private func resolve(_ id: String?, in picks: [NowPick], book: Notebook) -> NowPick? {
        guard let id else { return picks.first }
        if let pick = picks.first(where: { $0.id == id }) { return pick }
        if id.hasPrefix("task-"), let uuid = UUID(uuidString: String(id.dropFirst(5))),
           let task = book.tasks.first(where: { $0.id == uuid }), !task.isComplete {
            return NowPick(item: AgendaItem(task: task), kind: .candidate, label: "", parentID: task.parentID,
                           isMust: TaskBoard().isMust(task, among: book.tasks))
        }
        return picks.first
    }

    /// Timed things later today, not done yet, in order.
    private func laterToday(_ now: Date, excluding id: String?) -> [AgendaItem] {
        let minute = Self.minute(of: now)
        return Agenda.items(on: now, tasks: store.notebook.tasks, routines: store.notebook.routines)
            .filter { !$0.isBlock && !$0.isDone && $0.id != id && ($0.slot?.start ?? -1) > minute }
    }

    private func upcoming(now: Date, excluding id: String?) -> some View {
        let items = Array(laterToday(now, excluding: id).prefix(2))
        return VStack(alignment: .leading, spacing: 10) {
            Button { timetableOpen = true } label: {
                HStack {
                    Text("このあとの流れ").font(.subheadline.weight(.bold)).foregroundStyle(.primary)
                    Spacer()
                    Text("時間割を開く").font(.caption.weight(.semibold))
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("openTimetable")
            if !items.isEmpty {
                TimelinePanel(items: items, now: now, showsNow: false, onOpen: onOpen)
            } else {
                Text("このあとの時間が決まった予定はありません")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            }
        }
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
    let pick: NowPick
    let others: [NowPick]
    let canPass: Bool
    let stretch: FreeStretch?
    let now: Date
    let work: TaskWork?
    let onStart: (UUID) -> Void
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

    private let mint = Color(red: 0.7, green: 0.95, blue: 0.52)
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
        VStack(alignment: .leading, spacing: 10) {
            header
            Button { onOpen(pick.item) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    if !project.isEmpty {
                        Text(project).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.75))
                    }
                    if let parent {
                        Label(parent.title, systemImage: "arrow.turn.down.right")
                            .font(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    }
                    if pick.isMust || !pick.label.isEmpty {
                        Text((pick.isMust ? "★必須" : "") + (!pick.label.isEmpty ? (pick.isMust ? " ・ " : "") + pick.label : ""))
                            .font(.caption.weight(.semibold)).foregroundStyle(mint)
                    }
                    Text(pick.item.title).font(.title2.weight(.bold))
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.white)
                    if let due = task?.deadline ?? parent?.deadline, !pick.label.contains("締切") {
                        Text("締切 \(ProjectText.day(due))").font(.caption).foregroundStyle(.white.opacity(0.75))
                    }
                    ItemNotesView(item: pick.item, foreground: .white.opacity(0.85))
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("開いて編集します。メモの全文もここから読めます")
            if !children.isEmpty { ChildProgressView(children: children, tint: mint) }
            actions
            if showingNote, let task, !working {
                HStack(alignment: .top, spacing: 8) {
                    TextField("次はどこから？（任意）", text: $draft, axis: .vertical)
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
            if !others.isEmpty, !pick.item.isEvent {
                Divider().overlay(.white.opacity(0.25))
                candidateChips
            }
        }
        .foregroundStyle(.white)
        .padding(16)
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
        .sensoryFeedback(.success, trigger: finished)
        .sensoryFeedback(.selection, trigger: weighed)
        .accessibilityIdentifier("nowCard")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(working ? "実行中" : pick.kind == .upcoming ? "次" : "いま")
                .font(.caption.weight(.bold)).foregroundStyle(Color.black.opacity(0.8))
                .padding(.horizontal, 10).padding(.vertical, 6).background(mint, in: Capsule())
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
                Text("\(NowView.stretchTitle(stretch)) · \(NowView.stretchEnd(stretch))")
                    .font(.caption2).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if let task {
                EffortBadge(effort: task.effort) { cycleEffort(of: task) }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if working {
            HStack(spacing: 10) {
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
                .buttonStyle(FocusActionStyle(kind: .complete))
                .accessibilityIdentifier("completeActiveTask")
            }
        } else if pick.item.isEvent {
            Button(action: complete) {
                Label("完了", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(FocusActionStyle(kind: .primary))
            .accessibilityIdentifier("completeEvent")
        } else {
            HStack(spacing: 10) {
                Button {
                    if let task {
                        showingNote = false
                        onStart(task.id)
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

    private var candidateChips: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text("ほかの候補").font(.caption2).foregroundStyle(.white.opacity(0.7))
                chips
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("ほかの候補").font(.caption2).foregroundStyle(.white.opacity(0.7))
                chips
            }
        }
        .disabled(working)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(others) { other in
                    Button { withAnimation(.snappy) { onChoose(other.id) } } label: {
                        Text(other.item.title).font(.caption).lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(.white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("これを、いまのカードにします")
                }
            }
        }
    }

    private func complete() {
        guard case .task(let id) = pick.item.source, store.complete(id) else { return }
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
    enum Kind { case primary, secondary, complete }
    let kind: Kind
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundStyle(kind == .secondary ? Color.white : Color(red: 0.08, green: 0.24, blue: 0.18))
            .padding(.horizontal, 14).frame(minHeight: 44)
            .background {
                Capsule().fill(kind == .secondary ? Color.clear : kind == .complete
                    ? Color(red: 0.7, green: 0.95, blue: 0.52) : Color.white)
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
                EffortMeter(level: effort.rank + 1, color: Color(red: 0.7, green: 0.95, blue: 0.52))
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
                        if let effort = energy.preferred { EffortMeter(level: effort.rank + 1, color: Color(red: 0.7, green: 0.95, blue: 0.52)) }
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

/// One timed thing later today: its time, what kind it is, and its name. A tap opens it.
private struct UpcomingRow: View {
    let item: AgendaItem
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
            }
            .padding(.horizontal, 14).frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.slot?.startLabel ?? "") \(item.title)")
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
