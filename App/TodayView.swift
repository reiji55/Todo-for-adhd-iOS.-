import SwiftUI

@MainActor
struct TodayView: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.refreshClock) private var refreshClock
    @State private var rolloverOpen = false
    /// A fixed five-day window centered on today. Other days are for a look; reopening returns to today.
    @State private var dayOffset = 0
    let onOpen: (AgendaItem) -> Void
    let onWeek: () -> Void
    /// Opened from a block in 今日の流れ: that thing is brought into view and flashes once.
    var focus: String? = nil
    @State private var flashed: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = max(context.date, refreshClock)
            ScrollViewReader { proxy in
            // Suggestions live with the いま card on Today and in the free time of this timetable.
            ScrollView { main(now: now).padding(16) }
            .background(Palette.paper)
            .environment(\.flashedItem, flashed)
            .task(id: focus) { await bringIntoView(proxy) }
            }
        }
        .sheet(isPresented: $rolloverOpen) { RolloverSheet() }
        .onAppear { dayOffset = 0 }
        .onDisappear { dayOffset = 0 }
    }

    /// What the free time between today's things can hold: the いま card's own order (its condition and
    /// what was passed over), without the one on the card and without things that already have a time.
    static func gapSuggestions(_ book: Notebook, now: Date) -> [NowPick] {
        let picks = NowPlan.picks(in: book, energy: EnergyMemory.load(now: now), now: now, passed: PassedOver.load(now: now))
        return picks.dropFirst().filter { ($0.kind == .candidate || $0.kind == .obligation) && $0.item.slot == nil && !$0.item.isEvent }
    }

    @ViewBuilder private func main(now: Date) -> some View {
        if dayOffset == 0 { today(now: now) } else { otherDay(now: now) }
    }

    /// Scrolls to the thing it was opened at, then lights it up briefly so the eye finds it.
    private func bringIntoView(_ proxy: ScrollViewProxy) async {
        guard let focus else { return }
        try? await Task.sleep(for: .milliseconds(350))
        withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(focus, anchor: .center) }
        try? await Task.sleep(for: .milliseconds(300))
        withAnimation(.easeIn(duration: 0.2)) { flashed = focus }
        try? await Task.sleep(for: .milliseconds(1100))
        withAnimation(.easeOut(duration: 0.6)) { flashed = nil }
    }

    /// Yesterday or tomorrow, to look at: the same timeline and list, without today's extras.
    private func otherDay(now: Date) -> some View {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: dayOffset, to: now) ?? now
        let all = Agenda.items(on: day, tasks: store.notebook.tasks, routines: store.notebook.routines)
        let held = all.filter { $0.isBlock && $0.slot != nil }
        let items = all.filter { !$0.isBlock }
        let timed = items.filter { $0.slot != nil }
        let untimed = items.filter { $0.slot == nil }
        return LazyVStack(alignment: .leading, spacing: 10) {
            DaySwitcher(offset: $dayOffset, now: now)
            SectionHeading(title: "\(DaySwitcher.name(for: dayOffset))の時間割")
            if items.isEmpty && held.isEmpty {
                Text("\(DaySwitcher.name(for: dayOffset))の予定はありません。")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 6)
            }
            if !timed.isEmpty || !held.isEmpty {
                TimedSchedule(items: timed, held: held, now: now, showsNow: false, onOpen: onOpen, allHeld: true).padding(.bottom, 6)
            }
            if !untimed.isEmpty {
                Text("時間を決めていない").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, timed.isEmpty ? 0 : 8)
                ForEach(untimed) { item in UntimedAgendaRow(item: item, onOpen: onOpen) }
            }
            if dayOffset < 0 {
                Text("やり残したものは、今日の画面の「前の日から残っているタスク」から振り分けられます。")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 6).onlyInDemo()
            }
        }
        .frame(maxWidth: 760).frame(maxWidth: .infinity)
    }

    @ViewBuilder private func today(now: Date) -> some View {
        let board = TaskBoard()
        let tasks = store.notebook.tasks
        // Something checked off a moment ago keeps its place until the person leaves this screen. A task without
        // its own deadline goes by its project's.
        let placement = store.notebook.tasksWithProjectDeadlines.map { task -> TaskItem in
            var copy = task
            if store.recentlyDone.contains(AgendaItem(task: task).id) { copy.completedAt = nil }
            return copy
        }
        let calendar = Calendar.current
        let day = Agenda.items(on: now, tasks: tasks, routines: store.notebook.routines)
        // Held time (sleep, work) is laid out as bands, not as things to do.
        let agenda = day.filter { !$0.isBlock }
        let held = day.filter { $0.isBlock && $0.slot != nil }
        let onToday: (TaskItem) -> Bool = { task in
            task.plannedAt.map { calendar.isDate($0, inSameDayAs: now) } == true
                || store.children(of: task.id).contains { !$0.isComplete && $0.plannedAt.map { calendar.isDate($0, inSameDayAs: now) } == true }
        }
        // Today's planned work is already in the timetable; this list is what would otherwise be missed.
        // A task in pieces is left out when one of its pieces is in today's timetable.
        let required = board.obligations(placement, now: now).filter { !onToday($0) }
        // 期間タスク in their stretch today, not on today's list already and not due today (that is above).
        let stretch = store.notebook.periodTasks(on: now).filter { task in
            !onToday(task) && !required.contains { $0.id == task.id }
        }
        let leftovers = board.pastPlanned(tasks, now: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let tomorrowCount = Agenda.items(on: tomorrow, tasks: tasks, routines: store.notebook.routines)
            .filter { !$0.isDone && !$0.isBlock }.count

        LazyVStack(alignment: .leading, spacing: 10) {
            DaySwitcher(offset: $dayOffset, now: now, tomorrowCount: tomorrowCount)
            if store.loadBroken {
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
                // What is due today starts open: folded, it would be easy to miss.
                TimetableFolder(title: "今日までの締切", count: required.count, identifier: "requiredFolder", startsOpen: true) {
                    ForEach(required) { task in
                        let current = store.task(task.id) ?? task
                        if store.hasChildren(task.id) {
                            ParentTaskCard(parent: current, reason: board.obligationReason(task, now: now)) { onOpen(AgendaItem(task: $0)) }
                        } else {
                            AgendaRow(item: AgendaItem(task: current), reason: board.obligationReason(task, now: now), onOpen: onOpen)
                        }
                    }
                }
            }
            HStack(alignment: .lastTextBaseline) {
                SectionHeading(title: "今日の時間割")
                Spacer()
                GapSuggestionToggle()
            }
            if agenda.isEmpty && held.isEmpty {
                Text("今日の予定はまだありません。右下の＋から足せます。")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 6)
            }
            // Timed things sit on a raised timeline, with the held time of the day as bands between them; the
            // rest are outlined, not placed yet.
            let timed = agenda.filter { $0.slot != nil }
            let untimed = agenda.filter { $0.slot == nil }
            if !timed.isEmpty || !held.isEmpty {
                TimedSchedule(items: timed, held: held, now: now, showsNow: true, onOpen: onOpen,
                              suggestions: Self.gapSuggestions(store.notebook, now: now), allHeld: true).padding(.bottom, 6)
            }
            if !untimed.isEmpty {
                Text("時間を決めていない").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, timed.isEmpty ? 0 : 8)
                ForEach(untimed) { item in UntimedAgendaRow(item: item, onOpen: onOpen) }
            }
            if !stretch.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("期間中").font(.subheadline.weight(.bold))
                        Text("\(stretch.count)件").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                    ForEach(stretch) { task in
                        if store.hasChildren(task.id) {
                            ParentTaskCard(parent: task, reason: task.period.map { PeriodTag.left($0, now: now) }) { onOpen(AgendaItem(task: $0)) }
                        } else {
                            AgendaRow(item: AgendaItem(task: task), reason: task.period.map { PeriodTag.left($0, now: now) },
                                      onToday: { store.putOnToday(task, now: now) }, onOpen: onOpen)
                        }
                    }
                }
                .padding(.top, 8)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("periodSection")
            }
            UndatedTasksLink(onOpen: onOpen)
                .padding(.top, 12)
        }
        .frame(maxWidth: 760).frame(maxWidth: .infinity)
    }
}

/// Secondary sections start closed (what is due today starts open) without hiding their counts or removing existing actions.
private struct TimetableFolder<Content: View>: View {
    let title: String
    let count: Int
    var identifier: String
    /// A word beside the title, readable while folded (the nearest deadline).
    var detail: String?
    @ViewBuilder let content: () -> Content
    @State private var open: Bool

    init(title: String, count: Int, identifier: String, detail: String? = nil, startsOpen: Bool = false,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.count = count; self.identifier = identifier; self.detail = detail
        self.content = content
        _open = State(initialValue: startsOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.down").font(.subheadline.weight(.semibold))
                        .rotationEffect(.degrees(open ? 180 : 0))
                    Text(title).font(.headline)
                    if let detail {
                        Text(detail).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.must).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    Text("\(count)件").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
                .foregroundStyle(.primary).padding(.horizontal, 14).frame(minHeight: 48)
                .background(RaisedCardBackground(cornerRadius: 16)).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier(identifier)
            .accessibilityValue(open ? "展開中" : "折りたたみ")
            .accessibilityHint(open ? "たたみます" : "広げます")
            if open { content() }
        }
    }
}

/// Cards share a rail, but each connector stops before the control so an empty circle stays empty.
/// The day's timed things on their timeline. Those that fall in time held for something else (sleep, work)
/// sit together on a faint hatched band named for it, so a task put into working hours shows as such.
/// With `allHeld`, held time with nothing in it shows too, as a band of its own, and on today the free
/// time between bands and things shows as a gap, so a day held only for sleep and work still reads.
@MainActor
struct TimedSchedule: View {
    let items: [AgendaItem]
    let held: [AgendaItem]
    let now: Date
    let showsNow: Bool
    let onOpen: (AgendaItem) -> Void
    /// Today only: the free time between things shows as a gap, with one of these when suggestions are on.
    var suggestions: [NowPick]? = nil
    /// Held time with nothing in it shows as an empty band.
    var allHeld = false
    @AppStorage(GapSuggestionToggle.key) private var suggestionsOn = true

    struct Part: Identifiable {
        let id: String
        let block: AgendaItem?
        var items: [AgendaItem]
        /// From the band's start (or the first thing's) to the band's end or the last thing's, whichever is later.
        var start: Int { block?.slot?.start ?? items.first?.slot?.start ?? 0 }
        var end: Int { max(block?.slot?.end ?? 0, items.compactMap { $0.slot?.end }.max() ?? 0) }
    }

    /// Runs of things in the same held time (or in none), in order. With `allHeld`, held time with nothing in
    /// it is a part of its own, which also ends a run of free things around it.
    static func parts(_ items: [AgendaItem], held: [AgendaItem], allHeld: Bool = false) -> [Part] {
        func holder(_ start: Int) -> AgendaItem? {
            held.first { block in
                guard let slot = block.slot else { return false }
                return slot.start <= start && start < slot.end
            }
        }
        let used = Set(items.compactMap { item in item.slot.flatMap { holder($0.start)?.id } })
        let empty = allHeld ? held.filter { $0.slot != nil && !used.contains($0.id) } : []
        // In order of start; held time first when both start together.
        let entries = (items.compactMap { item in item.slot.map { (start: $0.start, isBlock: false, item: item) } }
            + empty.compactMap { block in block.slot.map { (start: $0.start, isBlock: true, item: block) } })
            .enumerated()
            .sorted { a, b in
                if a.element.start != b.element.start { return a.element.start < b.element.start }
                if a.element.isBlock != b.element.isBlock { return a.element.isBlock }
                return a.offset < b.offset
            }
            .map { $0.element }
        var parts: [Part] = []
        for entry in entries {
            if entry.isBlock {
                parts.append(Part(id: "held-\(entry.item.id)-empty", block: entry.item, items: []))
                continue
            }
            let block = holder(entry.start)
            if let last = parts.last, last.block?.id == block?.id {
                parts[parts.count - 1].items.append(entry.item)
            } else {
                parts.append(Part(id: (block.map { "held-\($0.id)-" } ?? "free-") + entry.item.id, block: block, items: [entry.item]))
            }
        }
        return parts
    }

    /// Where the line for now goes: in a part whose time holds now (before its first thing still to start),
    /// before a part that has not begun, or after the last.
    enum NowSpot: Equatable { case inPart(Int, Int), before(Int), after }

    static func nowSpot(_ parts: [Part], minute: Int) -> NowSpot? {
        guard !parts.isEmpty else { return nil }
        for (k, part) in parts.enumerated() {
            if minute < part.start { return .before(k) }
            if minute < part.end {
                return .inPart(k, part.items.firstIndex { ($0.slot?.start ?? Int.max) > minute } ?? part.items.count)
            }
        }
        return .after
    }

    /// Free time of at least this many minutes between two things shows as a gap.
    static let gapMinutes = 20

    /// The free time still to come before each part, and after the last until the day ends. Today only.
    struct GapPlan {
        var before: [Int: (start: Int, end: Int)] = [:]
        var after: (start: Int, end: Int)?
    }

    static func gapPlan(_ parts: [Part], minute: Int) -> GapPlan {
        var plan = GapPlan()
        var reach = minute
        for (k, part) in parts.enumerated() {
            let start = max(reach, minute)
            if part.start - start >= gapMinutes { plan.before[k] = (start, part.start) }
            reach = max(reach, part.end)
        }
        let start = max(reach, minute)
        if !parts.isEmpty, 24 * 60 - start >= gapMinutes { plan.after = (start, 24 * 60) }
        return plan
    }

    var body: some View {
        let parts = Self.parts(items, held: held, allHeld: allHeld)
        let minute = NowView.minute(of: now)
        let spot = showsNow ? Self.nowSpot(parts, minute: minute) : nil
        // Free time between parts shows on today's timetable when held time is laid out in full.
        let plan = suggestions != nil && allHeld ? Self.gapPlan(parts, minute: minute) : GapPlan()
        let gapBase = gapIndexes(parts, plan: plan)
        VStack(spacing: 12) {
            ForEach(Array(parts.enumerated()), id: \.element.id) { k, part in
                let gap = plan.before[k]
                // Between parts, the line for now stands above the free time that begins now, or above a band.
                if spot == .before(k), part.block != nil || gap != nil { nowLine }
                if let gap, let suggestions {
                    FreeGapRow(start: gap.start, end: gap.end, day: now, suggestions: suggestions,
                               index: gapBase.before[k] ?? 0, showsSuggestion: suggestionsOn, onOpen: onOpen)
                }
                partView(part, nowAt: nowAt(spot, part: k, of: parts, plan: plan), gapsBefore: gapBase.inside[k] ?? 0)
            }
            if spot == .after, parts.last?.block != nil || plan.after != nil { nowLine }
            if let gap = plan.after, let suggestions {
                FreeGapRow(start: gap.start, end: gap.end, day: now, suggestions: suggestions,
                           index: gapBase.after, showsSuggestion: suggestionsOn, onOpen: onOpen)
            }
        }
    }

    /// The line for now inside a part's own timeline, or -1 when it stands elsewhere.
    private func nowAt(_ spot: NowSpot?, part k: Int, of parts: [Part], plan: GapPlan) -> Int {
        switch spot {
        case .inPart(k, let index)?: return index
        case .before(k)? where parts[k].block == nil && plan.before[k] == nil: return 0
        case .after? where k == parts.count - 1 && parts[k].block == nil && plan.after == nil: return parts[k].items.count
        default: return -1
        }
    }

    /// Which gap of the day each one is, in order, so each takes a different suggestion.
    private func gapIndexes(_ parts: [Part], plan: GapPlan) -> (before: [Int: Int], inside: [Int: Int], after: Int) {
        guard suggestions != nil else { return ([:], [:], 0) }
        var before: [Int: Int] = [:], inside: [Int: Int] = [:]
        var count = 0
        for (k, part) in parts.enumerated() {
            if plan.before[k] != nil { before[k] = count; count += 1 }
            inside[k] = count
            if part.block == nil { count += gaps(in: part).count }
        }
        return (before, inside, count)
    }

    @ViewBuilder private func partView(_ part: Part, nowAt: Int, gapsBefore: Int) -> some View {
        if let block = part.block, let slot = block.slot {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(HeldFill.label.opacity(0.6)).frame(width: 8, height: 8)
                    Text(block.title).lineLimit(1)
                    Text(slot.label).fontWeight(.semibold).foregroundStyle(HeldFill.label.opacity(0.8)).monospacedDigit()
                }
                .font(.caption.weight(.bold)).foregroundStyle(HeldFill.label)
                .padding(.leading, 6)
                .accessibilityElement(children: .combine)
                if !part.items.isEmpty || nowAt >= 0 {
                    TimelinePanel(items: part.items, now: now, showsNow: showsNow, nowAt: nowAt, onOpen: onOpen)
                }
            }
            .padding(.horizontal, 6).padding(.top, 10).padding(.bottom, part.items.isEmpty && nowAt < 0 ? 10 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HeldFill(cornerRadius: 16))
            .accessibilityIdentifier(part.items.isEmpty ? "heldBand" : "heldPart")
        } else if let suggestions {
            freePart(part, nowAt: nowAt, suggestions: suggestions, gapsBefore: gapsBefore)
        } else {
            TimelinePanel(items: part.items, now: now, showsNow: showsNow, nowAt: nowAt, onOpen: onOpen)
        }
    }

    /// The line for now on its own, between parts.
    private var nowLine: some View {
        TimelinePanel(items: [], now: now, showsNow: true, nowAt: 0, onOpen: onOpen)
    }

    /// Where a free part breaks: after the item at each index, the free time that follows it (still to come).
    func gaps(in part: Part) -> [(after: Int, start: Int, end: Int)] {
        let minute = NowView.minute(of: now)
        var result: [(after: Int, start: Int, end: Int)] = []
        var reach = 0
        for (index, item) in part.items.enumerated() {
            reach = max(reach, item.slot?.end ?? 0)
            guard index + 1 < part.items.count, let next = part.items[index + 1].slot?.start else { continue }
            let start = max(reach, minute)
            if next - start >= Self.gapMinutes { result.append((index, start, next)) }
        }
        return result
    }

    /// The line for now inside one panel of a free part, or -1 when it falls in another. At a panel's end it
    /// belongs to the next panel's start, except in the last panel.
    static func line(_ nowAt: Int, lower: Int, upper: Int, last: Bool) -> Int {
        guard nowAt >= lower, nowAt < upper || (last && nowAt == upper) else { return -1 }
        return nowAt - lower
    }

    /// A free part, broken into panels at its gaps. The line for now stays in the panel it falls in.
    @ViewBuilder private func freePart(_ part: Part, nowAt: Int, suggestions: [NowPick], gapsBefore: Int) -> some View {
        let gaps = gaps(in: part)
        let bounds = [0] + gaps.map { $0.after + 1 } + [part.items.count]
        VStack(spacing: 8) {
            ForEach(0..<(bounds.count - 1), id: \.self) { run in
                let lower = bounds[run], upper = bounds[run + 1]
                TimelinePanel(items: Array(part.items[lower..<upper]), now: now, showsNow: showsNow,
                              nowAt: Self.line(nowAt, lower: lower, upper: upper, last: run == bounds.count - 2), onOpen: onOpen)
                if run < gaps.count {
                    let gap = gaps[run]
                    FreeGapRow(start: gap.start, end: gap.end, day: now, suggestions: suggestions,
                               index: gapsBefore + run, showsSuggestion: suggestionsOn, onOpen: onOpen)
                }
            }
        }
    }
}

/// 空き時間に候補: on, the free time in today's timetable shows one thing to do there; off, only a thin line.
struct GapSuggestionToggle: View {
    static let key = "gapSuggestions"
    @AppStorage(Self.key) private var on = true

    var body: some View {
        Button { withAnimation(.snappy) { on.toggle() } } label: {
            Label("空き時間に候補", systemImage: "sparkles")
                .font(.caption.weight(.bold))
                .foregroundStyle(on ? Color.white : Palette.accent)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(on ? Palette.accent : Palette.accent.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("空き時間に候補を出す")
        .accessibilityValue(on ? "オン" : "オフ")
        .accessibilityIdentifier("gapSuggestionToggle")
    }
}

/// Free time between two things in today's timetable. With suggestions on, one thing that fits there, from the
/// いま card's order: a long gap offers ここでやる (puts it in that time) and 別の候補; a short one names it.
@MainActor
struct FreeGapRow: View {
    @EnvironmentObject private var store: TaskStore
    let start: Int
    let end: Int
    let day: Date
    let suggestions: [NowPick]
    /// Which gap of the day this is, so each takes a different suggestion.
    let index: Int
    let showsSuggestion: Bool
    let onOpen: (AgendaItem) -> Void
    @State private var shift = 0

    private var length: Int { end - start }
    private var pick: NowPick? {
        guard !suggestions.isEmpty else { return nil }
        return suggestions[(index + shift) % suggestions.count]
    }

    var body: some View {
        if showsSuggestion, let pick {
            VStack(alignment: .leading, spacing: 4) {
                Text("空き \(NowView.duration(length))  \(TimeSlot.clock(start))–\(TimeSlot.clock(end))")
                    .font(.caption.weight(.bold)).foregroundStyle(Palette.accent).monospacedDigit()
                Button { onOpen(pick.item) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        (Text("ここでやれそう：").foregroundStyle(.secondary) + Text(pick.item.title).fontWeight(.semibold))
                            .font(.subheadline).lineLimit(2).multilineTextAlignment(.leading)
                        if !reason(pick).isEmpty {
                            Text(reason(pick)).font(.caption)
                                .foregroundStyle(pick.label.contains("締切") ? Palette.must : Color.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if length >= 30 {
                    HStack(spacing: 8) {
                        Button { place(pick) } label: {
                            Label("ここでやる", systemImage: "play.fill").font(.caption.weight(.bold))
                                .foregroundStyle(.white).padding(.horizontal, 11).padding(.vertical, 6)
                                .background(Capsule().fill(Palette.accent))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("この時間に予定します")
                        if suggestions.count > 1 {
                            Button { withAnimation(.snappy) { shift += 1 } } label: {
                                Label("別の候補", systemImage: "arrow.left.arrow.right").font(.caption.weight(.bold))
                                    .foregroundStyle(Palette.accent).padding(.horizontal, 11).padding(.vertical, 6)
                                    .overlay(Capsule().strokeBorder(Palette.accent, lineWidth: 1.2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Palette.accent.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("freeGap")
        } else {
            HStack(spacing: 8) {
                Rectangle().fill(Palette.accent.opacity(0.35)).frame(height: 1)
                Text("空き \(NowView.duration(length))").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .monospacedDigit().fixedSize()
                Rectangle().fill(Palette.accent.opacity(0.35)).frame(height: 1)
            }
            .padding(.horizontal, 24).frame(height: 18)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("freeGap")
        }
    }

    private func reason(_ pick: NowPick) -> String {
        var parts: [String] = []
        if !pick.label.isEmpty { parts.append(pick.label) }
        if case .task(let id) = pick.item.source, let task = store.task(id) { parts.append(task.effort.label) }
        return parts.joined(separator: " · ")
    }

    /// Puts it in this free time: from the start (or now, when the gap has begun), up to an hour.
    private func place(_ pick: NowPick) {
        let slot = TimeSlot(start: start, duration: min(length, 60))
        store.move(pick.item, to: day, slot: slot)
        store.offerUndo("「\(pick.item.title)」を\(slot.label)に入れました")
    }

}

@MainActor
struct TimelinePanel: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .subheadline) private var timeWidth: CGFloat = 52
    let items: [AgendaItem]
    let now: Date
    var showsNow = true
    /// Where the line for now goes, when a schedule split into parts decides it; -1 for none.
    var nowAt: Int? = nil
    let onOpen: (AgendaItem) -> Void

    private let railWidth: CGFloat = 44
    private var minute: Int { NowView.minute(of: now) }
    private var nowIndex: Int {
        if let nowAt { return nowAt }
        return showsNow ? (items.firstIndex { ($0.slot?.start ?? Int.max) > minute } ?? items.count) : -1
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index == nowIndex { nowRow(first: index == 0, last: false) }
                row(item)
                    .padding(.bottom, index == items.count - 1 && nowIndex != items.count ? 0 : 12)
                    .background {
                        rail(first: index == 0 && nowIndex != 0,
                             last: index == items.count - 1 && nowIndex != items.count,
                             bottomInset: index == items.count - 1 && nowIndex != items.count ? 0 : 12)
                    }
            }
            if nowIndex == items.count { nowRow(first: items.isEmpty, last: true) }
        }
    }

    private func row(_ item: AgendaItem) -> some View {
        rowContent(item)
            .overlay(alignment: .trailing) { FlashRing(id: item.id).padding(.leading, timeWidth + railWidth) }
            .id(item.id)
    }

    private func rowContent(_ item: AgendaItem) -> some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .trailing, spacing: 2) {
                if let slot = item.slot {
                    Text(slot.startLabel).font(.system(.subheadline, design: .rounded).weight(.bold)).monospacedDigit()
                    Text(TimeSlot.clock(slot.end)).font(.system(.caption, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(width: timeWidth, alignment: .trailing)
            .accessibilityElement(children: .ignore).accessibilityLabel(item.slot?.label ?? "")
            AgendaCheck(item: item).frame(width: railWidth)
            AgendaRow(item: item, showsTime: false, style: .timeline, showsCheck: false,
                      showsChildProgress: true, onOpen: onOpen)
                .padding(.horizontal, 12).padding(.vertical, 3)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                        .overlay {
                            if isCurrent(item) {
                                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.accent.opacity(0.09))
                            }
                        }
                        .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0.07), radius: 5, x: 2, y: 3)
                }
                .overlay(alignment: .leading) {
                    if isCurrent(item) {
                        UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16)
                            .fill(Palette.accent).frame(width: 4).padding(.vertical, 5)
                    }
                }
        }
    }

    private func isCurrent(_ item: AgendaItem) -> Bool {
        guard showsNow, !item.isDone, let slot = item.slot else { return false }
        return slot.start <= minute && minute < slot.end
    }

    private func rail(first: Bool, last: Bool, bottomInset: CGFloat) -> some View {
        GeometryReader { geometry in
            let center = (geometry.size.height - bottomInset) / 2
            let gap: CGFloat = 17
            Path { path in
                let x = timeWidth + railWidth / 2
                if !first {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: max(0, center - gap)))
                }
                if !last {
                    path.move(to: CGPoint(x: x, y: center + gap))
                    path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                }
            }
            .stroke(Palette.accent.opacity(0.24), lineWidth: 1.5)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private func nowRow(first: Bool, last: Bool) -> some View {
        HStack(spacing: 0) {
            Text(now.formatted(date: .omitted, time: .shortened)).font(.clock).foregroundStyle(.red)
                .frame(width: timeWidth, alignment: .trailing)
            Circle().fill(Color.red).frame(width: 8, height: 8).frame(width: railWidth)
                .background(alignment: .trailing) {
                    Rectangle().fill(Color.red).frame(width: railWidth / 2 + 10, height: 1.5)
                }
            Rectangle().fill(Color.red).frame(height: 1.5)
        }
        .padding(.vertical, 6)
        .background {
            GeometryReader { geometry in
                Path { path in
                    let x = timeWidth + railWidth / 2
                    let center = geometry.size.height / 2
                    if !first {
                        path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: center - 5))
                    }
                    if !last {
                        path.move(to: CGPoint(x: x, y: center + 5)); path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                    }
                }.stroke(Palette.accent.opacity(0.24), lineWidth: 1.5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("現在 \(now.formatted(date: .omitted, time: .shortened))")
    }
}

/// The untimed control stays on the same axis as the timed controls, outside its dotted card.
@MainActor
private struct UntimedAgendaRow: View {
    @ScaledMetric(relativeTo: .subheadline) private var timeWidth: CGFloat = 52
    let item: AgendaItem
    let onOpen: (AgendaItem) -> Void
    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: timeWidth).accessibilityHidden(true)
            AgendaCheck(item: item).frame(width: 44)
            AgendaRow(item: item, showsTime: false, style: .loose, showsCheck: false,
                      showsChildProgress: true, onOpen: onOpen)
                .overlay { FlashRing(id: item.id) }
        }
        .accessibilityIdentifier("untimed-" + item.id)
        .id(item.id)
    }
}

private struct FlashedItemKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    /// The thing on the timetable lit up for a moment, after it was opened at it.
    var flashedItem: String? {
        get { self[FlashedItemKey.self] }
        set { self[FlashedItemKey.self] = newValue }
    }
}

/// A soft ring of the accent color around a row while it is the one being pointed to.
private struct FlashRing: View {
    @Environment(\.flashedItem) private var flashed
    let id: String
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Palette.accent, lineWidth: 2.5)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.accent.opacity(0.10)))
            .shadow(color: Palette.accent.opacity(0.45), radius: 8)
            .opacity(flashed == id ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
                    Text("時間は前の日のまま残ります。「いつでも」に送ると日付と時間を外します。").onlyInDemo()
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

/// Five fixed positions centered on the real today, never on the selected date.
struct DaySwitcher: View {
    @Binding var offset: Int
    let now: Date
    var tomorrowCount = 0

    static func name(for offset: Int) -> String {
        switch offset {
        case -2: return "一昨日"
        case -1: return "昨日"
        case 1: return "明日"
        case 2: return "明後日"
        default: return "今日"
        }
    }

    var body: some View {
        let calendar = Calendar.current
        HStack(spacing: 8) {
            ForEach(-2...2, id: \.self) { value in
                let day = calendar.date(byAdding: .day, value: value, to: now) ?? now
                let selected = value == offset
                Button { withAnimation(.snappy) { offset = value } } label: {
                    VStack(spacing: 7) {
                        Text(Self.weekday(day)).font(.caption.weight(.semibold))
                        Text("\(calendar.component(.day, from: day))")
                            .font(.system(.title2, design: .rounded).weight(.bold)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.5)
                        Text(value == -2 ? "2日前" : value == 2 ? "2日後" : Self.name(for: value))
                            .font(.caption2).lineLimit(1).minimumScaleFactor(0.5)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .foregroundStyle(selected ? Color(uiColor: .systemBackground) : Color.primary)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.accent)
                        } else {
                            RaisedCardBackground(cornerRadius: 18)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if value == 1, tomorrowCount > 0, !selected {
                            Text("\(tomorrowCount)").font(.system(size: 9, weight: .bold)).monospacedDigit()
                                .padding(4).background(Palette.accent.opacity(0.15), in: Circle()).offset(x: 2, y: -2)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 18))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(Self.name(for: value))、\(day.formatted(.dateTime.month().day().weekday()))")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("timetableDay\(value)")
            }
        }
        .padding(.vertical, 4)
    }

    private static func weekday(_ date: Date) -> String {
        ["日", "月", "火", "水", "木", "金", "土"][(Calendar.current.component(.weekday, from: date) - 1) % 7]
    }
}
