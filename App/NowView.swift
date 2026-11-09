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
                if let stretch, stretch.key != chosenFor, offers {
                    FreeStretchCard(stretch: stretch, now: now) { setEnergy($0) }
                        .transition(.opacity)
                    upcoming(now: now, excluding: nil)
                } else {
                    let current = resolve(chosen, in: picks, book: book)
                    if let current, !(current.kind == .upcoming && offers) {
                        let rest = picks.filter { $0.id != current.id }
                        NowCard(pick: current,
                                others: Array(rest.prefix(2)),
                                canPass: !rest.isEmpty,
                                stretch: stretch,
                                now: now,
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
                DayFlow(now: now) { timetableOpen = true }
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
            chosen = nil
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

    @ViewBuilder private func upcoming(now: Date, excluding id: String?) -> some View {
        let items = Array(laterToday(now, excluding: id).prefix(2))
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("このあと").font(.footnote.weight(.bold)).foregroundStyle(.secondary).padding(.leading, 4)
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().padding(.leading, 72) }
                        UpcomingRow(item: item) { onOpen(item) }
                    }
                }
                .background(RaisedCardBackground(cornerRadius: 16))
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
                withAnimation(.snappy) { store.closeDay(now: now) }
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

/// The one card: what it is, why it is here, and the two things to do with it.
@MainActor
private struct NowCard: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.startRoutine) private var startRoutine
    let pick: NowPick
    let others: [NowPick]
    let canPass: Bool
    /// The free stretch the card is offered in; nil while something on the schedule is on now.
    let stretch: FreeStretch?
    let now: Date
    let onPass: () -> Void
    let onChoose: (String) -> Void
    /// Keeps this card in front, as when its 負荷 is changed.
    let onKeep: () -> Void
    let onOpen: (AgendaItem) -> Void
    @State private var finished = 0
    @State private var weighed = 0
    @State private var taskFocusOpen = false
    @State private var taskStartedAt = Date()

    private var task: TaskItem? {
        guard case .task(let id) = pick.item.source, let task = store.task(id), !task.isEvent else { return nil }
        return task
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                NowMark(title: pick.kind == .upcoming ? "次" : "いま", color: Palette.accent)
                context
                Spacer(minLength: 4)
                if let task { EffortBadge(effort: task.effort) { cycleEffort(of: task) } }
            }
            Button { onOpen(pick.item) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    projectLine
                    kicker
                    Text(pick.item.title).font(.title.weight(.heavy)).foregroundStyle(.primary)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    if let meta { Text(meta).font(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("開いて編集します")
            if let support = supportText {
                VStack(alignment: .leading, spacing: 2) {
                    Text(support.label).font(.caption).foregroundStyle(.secondary)
                    Text(support.text).font(.subheadline.weight(.semibold)).lineLimit(3)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if !pick.item.isEvent || canPass { actions }
            if task != nil {
                HStack {
                    Spacer()
                    Button(action: complete) {
                        Label("完了にする", systemImage: "checkmark.circle")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("このタスクを完了します。間違えた場合は取り消せます")
                }
            }
            if !others.isEmpty {
                Divider().padding(.vertical, 2)
                Text("ほかの候補").font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(others) { other in
                        Button { withAnimation(.snappy) { onChoose(other.id) } } label: { chip(other) }
                            .buttonStyle(.plain)
                            .accessibilityHint("これを、いまのカードにします")
                    }
                }
            }
        }
        .padding(18)
        .background(alignment: .topTrailing) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 60, weight: .ultraLight))
                .rotationEffect(.degrees(-24))
                .foregroundStyle(Palette.accent.opacity(0.08))
                .padding(.top, 70)
                .padding(.trailing, 20)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .background(RaisedCardBackground(cornerRadius: 24))
        .sensoryFeedback(.success, trigger: finished)
        .sensoryFeedback(.selection, trigger: weighed)
        .sheet(isPresented: $taskFocusOpen) {
            if let task { TaskStartSheet(taskID: task.id, startedAt: taskStartedAt) }
        }
    }

    /// Beside いま: the time of what is on now, or the free stretch this is offered in.
    @ViewBuilder private var context: some View {
        if pick.kind == .inSlot || pick.kind == .upcoming, let slot = pick.item.slot {
            Label("\(slot.startLabel)–\(TimeSlot.clock(slot.end))", systemImage: "clock")
                .font(.caption.weight(.bold)).monospacedDigit()
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .overlay(Capsule().strokeBorder(Palette.accent.opacity(0.45), lineWidth: 1.5))
                .lineLimit(1)
        } else if let stretch {
            Text("\(NowView.stretchTitle(stretch)) ・ \(NowView.stretchEnd(stretch))")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// The project a task belongs to (or its parent does), so a suggestion says what it is for.
    private var project: String {
        if !pick.item.project.isEmpty { return pick.item.project }
        return pick.parentID.flatMap { store.task($0)?.project } ?? ""
    }

    @ViewBuilder private var projectLine: some View {
        if !project.isEmpty, !(pick.item.isRoutine || pick.item.isEvent) {
            let color = ProjectColor.color(for: store.colorName(forProject: project)) ?? Palette.accent
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(project).lineLimit(1)
            }
            .font(.footnote.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
            .accessibilityLabel("プロジェクト：\(project)")
        }
    }

    @ViewBuilder private var kicker: some View {
        let parent = pick.parentID.flatMap { store.task($0) }
        let labels = kickerLabels(hasParent: parent != nil)
        if parent != nil || !labels.isEmpty {
            HStack(spacing: 6) {
                if let parent {
                    let pieces = store.children(of: parent.id)
                    Text("↳ \(parent.title)").lineLimit(1)
                    if parent.isMust { Text("★").accessibilityLabel("必須") }
                    Text("\(pieces.filter(\.isComplete).count)/\(pieces.count)").monospacedDigit()
                }
                if !labels.isEmpty { Text((parent == nil ? "" : "・ ") + labels.joined(separator: " ・ ")).lineLimit(1) }
            }
            .font(.footnote.weight(.bold))
            .foregroundStyle(kickerColor)
        }
    }

    /// ★ and what is due in the color of must; the rest in the app's own.
    private var kickerColor: Color {
        if pick.item.isRoutine || pick.item.isEvent { return Palette.accent }
        return pick.isMust || pick.label.contains("締切") ? Palette.must : Palette.accent
    }

    private func kickerLabels(hasParent: Bool) -> [String] {
        var parts: [String] = []
        if pick.isMust && !hasParent { parts.append("★必須") }
        if !pick.label.isEmpty { parts.append(pick.label) }
        if pick.item.isRoutine || pick.item.isEvent, !pick.item.project.isEmpty { parts.append(pick.item.project) }
        return parts
    }

    /// The deadline, when the reason above does not already say it.
    private var meta: String? {
        guard let task else { return nil }
        let due = task.deadline ?? pick.parentID.flatMap { store.task($0)?.deadline }
        guard let due, !pick.label.contains("締切") else { return nil }
        return "締切 \(ProjectText.day(due))"
    }

    /// Only display existing data; never invent a motivational summary.
    private var supportText: (label: String, text: String)? {
        if let task {
            if !task.resumeNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ("前回の続き", task.resumeNote)
            }
            if let child = store.children(of: task.id).first(where: { !$0.isComplete }) {
                return ("最初の一手", child.title)
            }
            if let step = task.steps.first(where: { !$0.isDone }) {
                return ("最初の一手", step.title)
            }
            if !task.memo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ("メモ", task.memo)
            }
        }
        if case .routine(let id, _) = pick.item.source,
           let note = store.routine(id)?.resumeNote, !note.isEmpty {
            return ("前回の続き", note)
        }
        return nil
    }

    private var actions: some View {
        HStack(spacing: 10) {
            switch pick.item.source {
            case .task:
                if !pick.item.isEvent {
                    Button(action: startTask) {
                        Label("始める", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NowButtonStyle(prominent: true))
                }
            case .routine:
                Button {
                    if let startRoutine { startRoutine(pick.item) }
                } label: {
                    Label(store.isTiming(pick.item) ? "計測中" : "始める", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(NowButtonStyle(prominent: true))
            }
            if canPass {
                Button(action: onPass) {
                    Label("入れ替える", systemImage: "arrow.left.arrow.right")
                        .frame(maxWidth: pick.item.isEvent ? .infinity : nil)
                }
                .buttonStyle(NowButtonStyle(prominent: false))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Intentionally no tap overlay: the two main actions must stay unobstructed.
            EmptyView()
        }
    }

    private func chip(_ other: NowPick) -> some View {
        HStack(spacing: 4) {
            if other.isMust {
                Image(systemName: "star.fill").font(.caption2).foregroundStyle(Palette.must).accessibilityLabel("必須")
            }
            Text(other.item.title).foregroundStyle(.primary).lineLimit(1)
            let otherProject = other.item.project.isEmpty ? (other.parentID.flatMap { store.task($0)?.project } ?? "") : other.item.project
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
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func startTask() {
        guard let task else { return }
        let started = Date()
        store.change(task.id) { $0.lastStartedAt = started }
        guard store.task(task.id)?.lastStartedAt == started else { return }
        taskStartedAt = started
        taskFocusOpen = true
    }

    private func complete() {
        guard case .task(let id) = pick.item.source else { return }
        let title = pick.item.title
        withAnimation(.snappy) { store.complete(id) }
        store.offerUndo("「\(title)」を完了にしました")
        finished += 1
    }

    /// 軽め → ふつう → じっくり → 軽め. The card stays in front while it is set.
    private func cycleEffort(of task: TaskItem) {
        let all = Effort.allCases
        let next = all[((all.firstIndex(of: task.effort) ?? 0) + 1) % all.count]
        onKeep()
        store.change(task.id) { $0.effort = next }
        weighed += 1
    }
}


/// A deliberately lightweight starting place for an ordinary task. This does not create a
/// second task-management system: it uses the existing resume note and complete operations.
@MainActor
private struct TaskStartSheet: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    let taskID: UUID
    let startedAt: Date
    @State private var note = ""
    @State private var loaded = false

    private var task: TaskItem? { store.task(taskID) }

    private var nextAction: (label: String, text: String)? {
        guard let task else { return nil }
        if !task.resumeNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ("前回の続き", task.resumeNote)
        }
        if let child = store.children(of: task.id).first(where: { !$0.isComplete }) {
            return ("最初の一手", child.title)
        }
        if let step = task.steps.first(where: { !$0.isDone }) {
            return ("最初の一手", step.title)
        }
        if !task.memo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ("メモ", task.memo)
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let task {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("取り組み中", systemImage: "play.circle.fill")
                                .font(.subheadline.weight(.bold)).foregroundStyle(Palette.accent)
                            Text(task.title).font(.largeTitle.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("経過時間").font(.caption).foregroundStyle(.secondary)
                                Text(ElapsedTimer.clock(max(0, context.date.timeIntervalSince(startedAt))))
                                    .font(.system(size: 36, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(24)
                            .background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
                        }
                        if let nextAction {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(nextAction.label).font(.caption.weight(.bold)).foregroundStyle(Palette.accent)
                                Text(nextAction.text).font(.title3.weight(.medium))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(Color(uiColor: .secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 16))
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("次に始める場所").font(.subheadline.weight(.semibold))
                            TextField("中断するときに、次の一手を一言メモ", text: $note, axis: .vertical)
                                .lineLimit(2...5)
                                .textFieldStyle(.roundedBorder)
                            Text("中断すると、このメモが次回の「いま」カードに表示されます。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 12) {
                            Button(action: pause) {
                                Label("中断する", systemImage: "pause.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            Button(action: completeTask) {
                                Label("完了にする", systemImage: "checkmark").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                    } else {
                        Text("タスクが見つかりません").foregroundStyle(.secondary)
                        Button("閉じる") { dismiss() }
                    }
                }
                .padding(20)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.paper)
            .navigationTitle("始める")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("中断") { pause() }
                }
            }
            .interactiveDismissDisabled()
            .onAppear {
                guard !loaded else { return }
                note = task?.resumeNote ?? ""
                loaded = true
            }
        }
    }

    private func saveResumeNote() {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        store.change(taskID) { $0.resumeNote = text }
    }

    private func pause() {
        saveResumeNote()
        dismiss()
    }

    private func completeTask() {
        saveResumeNote()
        guard let task = store.task(taskID) else { dismiss(); return }
        store.complete(taskID)
        store.offerUndo("「\(task.title)」を完了にしました")
        dismiss()
    }
}

/// A task's 負荷 at the top right of the card, as three bars and a word. A tap moves it one step.
private struct EffortBadge: View {
    let effort: Effort
    let onCycle: () -> Void

    var body: some View {
        Button(action: onCycle) {
            HStack(spacing: 6) {
                Text("負荷").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                EffortMeter(level: effort.rank + 1, color: Palette.accent)
                Text(effort.label).font(.caption.weight(.bold)).foregroundStyle(.primary)
            }
            .padding(.horizontal, 10).frame(minHeight: 30)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
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

/// Today on a horizontal time axis, an hour to 64 points, scrolled so that now sits near the left edge.
/// Each block is as long as its time and carries its name; one too short for its name has it beside it.
/// Blocks share a row unless their names would collide. Held time (sleep, work) is shaded, what is past
/// is dimmed, and a red line marks the minute. A tap opens the timetable.
@MainActor
private struct DayFlow: View {
    @EnvironmentObject private var store: TaskStore
    let now: Date
    let onOpen: () -> Void

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
        let held = items.filter(\.isBlock).compactMap(\.slot)
        let timed = items.filter { !$0.isBlock && $0.slot != nil }
        let range = Agenda.hourRange(for: timed)
        let placed = Self.place(timed, fromHour: range.lowerBound)
        let lanes = max(1, (placed.map(\.lane).max() ?? 0) + 1)
        let width = CGFloat(range.upperBound - range.lowerBound) * Self.hourWidth
        let height = Self.axisHeight + CGFloat(lanes) * Self.laneHeight + 4
        let nowX = Self.x(NowView.minute(of: now), fromHour: range.lowerBound)
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onOpen) {
                HStack {
                    Text("今日の流れ").font(.subheadline.weight(.bold)).foregroundStyle(.primary)
                    Spacer()
                    HStack(spacing: 3) {
                        Text("時間割を開く")
                        Image(systemName: "chevron.right").font(.caption.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.accent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(held.enumerated()), id: \.offset) { _, slot in
                            let start = max(0, Self.x(slot.start, fromHour: range.lowerBound))
                            let end = min(width, Self.x(slot.end, fromHour: range.lowerBound))
                            if end > start {
                                Rectangle().fill(Color.primary.opacity(0.06))
                                    .frame(width: end - start, height: height).offset(x: start)
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
        return "今日の流れ。" + (open.isEmpty ? "時間の決まった予定はありません。" : "\(list)。") + "時間割を開く"
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
