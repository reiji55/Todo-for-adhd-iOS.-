import SwiftUI

/// 今日 opens on this: one thing to do now, what comes after it, and the shape of the day. The full
/// timetable (the Today screen as it was) is one tap away, unchanged.
@MainActor
struct NowView: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.refreshClock) private var refreshClock
    @State private var energy: Energy = EnergyMemory.load()
    @State private var passed: [String] = PassedOver.load()
    /// Picked from ほかの候補; it leads until it is done or passed over.
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
            passed = PassedOver.load()
            applyPreviewArguments()
        }
        .onChange(of: energy) { _, value in EnergyMemory.save(value) }
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
                let picks = NowPlan.picks(in: store.notebook, energy: energy, now: now, passed: passed)
                let current = chosen.flatMap { id in picks.first { $0.id == id } } ?? picks.first
                if let current {
                    NowCard(pick: current,
                            others: Array(picks.filter { $0.id != current.id }.prefix(2)),
                            canPass: picks.count > 1,
                            next: laterToday(now, excluding: current.id).first,
                            now: now,
                            onPass: { pass(current.id) },
                            onChoose: { chosen = $0 },
                            onOpen: onOpen)
                        .id(current.id)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                } else {
                    NothingLeftCard(now: now)
                }
                upcoming(now: now, excluding: current?.id)
                DayFlow(now: now) { timetableOpen = true }
                footer(now: now)
            }
        }
        .animation(.snappy, value: closed)
    }

    private func header(now: Date, closed: Bool) -> some View {
        HStack {
            Text(Self.dateTitle(now)).font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
            Spacer()
            if !closed {
                Menu {
                    Picker("今の調子", selection: $energy) {
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
    /// The next timed thing today, for "次の予定まで".
    let next: AgendaItem?
    let now: Date
    let onPass: () -> Void
    let onChoose: (String) -> Void
    let onOpen: (AgendaItem) -> Void
    @State private var finished = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                NowMark(title: pick.kind == .upcoming ? "次" : "いま", color: Palette.accent)
                Spacer(minLength: 8)
                trailing
            }
            Button { onOpen(pick.item) } label: {
                VStack(alignment: .leading, spacing: 4) {
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
            if let note = resumeNote {
                VStack(alignment: .leading, spacing: 2) {
                    Text("前回の続き").font(.caption).foregroundStyle(.secondary)
                    Text(note).font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if !pick.item.isEvent || canPass { actions }
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
        .background(RaisedCardBackground(cornerRadius: 24))
        .sensoryFeedback(.success, trigger: finished)
    }

    @ViewBuilder private var trailing: some View {
        if pick.kind == .inSlot || pick.kind == .upcoming, let slot = pick.item.slot {
            Label("\(slot.startLabel)–\(TimeSlot.clock(slot.end))", systemImage: "clock")
                .font(.caption.weight(.bold)).monospacedDigit()
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .overlay(Capsule().strokeBorder(Palette.accent.opacity(0.45), lineWidth: 1.5))
        } else if let next, let slot = next.slot {
            Text("次の予定まで \(NowView.duration(slot.start - NowView.minute(of: now)))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var kicker: some View {
        let parent = pick.parentID.flatMap { store.task($0) }
        let labels = kickerLabels
        if parent != nil || !labels.isEmpty {
            HStack(spacing: 6) {
                if let parent {
                    let pieces = store.children(of: parent.id)
                    Text("↳ \(parent.title)").lineLimit(1)
                    Text("\(pieces.filter(\.isComplete).count)/\(pieces.count)").monospacedDigit()
                }
                if !labels.isEmpty { Text(labels.joined(separator: " ・ ")).lineLimit(1) }
            }
            .font(.footnote.weight(.bold))
            .foregroundStyle(pick.item.isRoutine || pick.item.isEvent ? Palette.accent : Palette.must)
        }
    }

    private var kickerLabels: [String] {
        var parts: [String] = []
        if !pick.label.isEmpty { parts.append(pick.label) }
        if pick.item.isRoutine || pick.item.isEvent, !pick.item.project.isEmpty { parts.append(pick.item.project) }
        return parts
    }

    private var meta: String? {
        guard case .task(let id) = pick.item.source, let task = store.task(id), !task.isEvent else { return nil }
        var parts = [task.effort.label]
        let due = task.deadline ?? pick.parentID.flatMap { store.task($0)?.deadline }
        if let due, !pick.label.contains("締切") { parts.append("締切 \(ProjectText.day(due))") }
        return parts.joined(separator: " ・ ")
    }

    private var resumeNote: String? {
        guard case .routine(let id, _) = pick.item.source, let note = store.routine(id)?.resumeNote, !note.isEmpty else { return nil }
        return note
    }

    private var actions: some View {
        HStack(spacing: 10) {
            switch pick.item.source {
            case .task:
                if !pick.item.isEvent {
                    Button(action: complete) {
                        Label("完了にする", systemImage: "checkmark").frame(maxWidth: .infinity)
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
    }

    private func chip(_ other: NowPick) -> some View {
        HStack(spacing: 4) {
            Text(other.item.title).foregroundStyle(.primary).lineLimit(1)
            if !other.label.isEmpty {
                Text("・ \(other.label)")
                    .foregroundStyle(other.label.contains("締切") || other.label.contains("★") ? Palette.must : Color.secondary)
            }
        }
        .font(.footnote)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func complete() {
        guard case .task(let id) = pick.item.source else { return }
        let title = pick.item.title
        withAnimation(.snappy) { store.complete(id) }
        store.offerUndo("「\(title)」を完了にしました")
        finished += 1
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

/// The day as one thin bar, with now as a red line. A tap opens the timetable.
@MainActor
private struct DayFlow: View {
    @EnvironmentObject private var store: TaskStore
    let now: Date
    let onOpen: () -> Void

    var body: some View {
        let items = Agenda.items(on: now, tasks: store.notebook.tasks, routines: store.notebook.routines)
            .filter { !$0.isBlock && $0.slot != nil }
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("今日の流れ").font(.subheadline.weight(.bold)).foregroundStyle(.primary)
                    Spacer()
                    HStack(spacing: 3) {
                        Text("時間割を開く")
                        Image(systemName: "chevron.right").font(.caption.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.accent)
                }
                FlowBar(items: items, range: Agenda.hourRange(for: items), now: now)
                    .frame(height: 40)
            }
            .padding(14)
            .background(RaisedCardBackground(cornerRadius: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("今日の流れ。時間割を開く")
        .accessibilityAddTraits(.isButton)
    }
}

@MainActor
private struct FlowBar: View {
    @EnvironmentObject private var store: TaskStore
    let items: [AgendaItem]
    let range: ClosedRange<Int>
    let now: Date

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let minute = NowView.minute(of: now)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .frame(width: width, height: 22)
                ForEach(items) { item in
                    if let slot = item.slot {
                        let start = position(slot.start, width: width)
                        let end = position(slot.end, width: width)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(color(for: item).opacity(item.isDone ? 0.3 : 0.85))
                            .frame(width: max(3, end - start), height: 14)
                            .offset(x: start, y: 4)
                    }
                }
                if range.contains(minute / 60) {
                    Capsule().fill(Color.red).frame(width: 2, height: 28)
                        .offset(x: position(minute, width: width) - 1, y: -3)
                }
                ForEach(ticks, id: \.self) { hour in
                    Text("\(hour)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        .fixedSize()
                        .offset(x: max(0, min(width - 14, position(hour * 60, width: width) - 6)), y: 26)
                }
            }
        }
    }

    private var ticks: [Int] {
        Array(stride(from: ((range.lowerBound + 5) / 6) * 6, through: range.upperBound, by: 6))
    }

    private func position(_ minute: Int, width: CGFloat) -> CGFloat {
        let span = CGFloat(max(1, range.upperBound - range.lowerBound) * 60)
        return min(width, max(0, CGFloat(minute - range.lowerBound * 60) / span * width))
    }

    private func color(for item: AgendaItem) -> Color {
        ProjectColor.color(for: store.colorName(forProject: item.project)) ?? Palette.accent
    }
}
