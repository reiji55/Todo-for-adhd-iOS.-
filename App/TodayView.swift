import SwiftUI

@MainActor
struct TodayView: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.refreshClock) private var refreshClock
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var energy: Energy = EnergyMemory.load()
    @State private var drawerOpen = false
    @State private var rolloverOpen = false
    /// A fixed five-day window centered on today. Other days are for a look; reopening returns to today.
    @State private var dayOffset = 0
    let onOpen: (AgendaItem) -> Void
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
                        ScrollView { CandidatePanel(energy: $energy, now: now, onOpen: onOpen).padding(20) }
                            .frame(width: min(400, geometry.size.width * 0.38))
                    }
                } else {
                    ScrollView { main(now: now).padding(16) }
                        .overlay(alignment: .trailing) {
                            if dayOffset == 0 {
                                CandidateDrawer(isOpen: $drawerOpen) {
                                    CandidatePanel(energy: $energy, now: now, onOpen: onOpen)
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
            SectionHeading(title: "\(DaySwitcher.name(for: dayOffset))の時間割")
            if items.isEmpty {
                Text("\(DaySwitcher.name(for: dayOffset))の予定はありません。")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 6)
            }
            if !timed.isEmpty {
                TimelinePanel(items: timed, now: now, showsNow: false, onOpen: onOpen).padding(.bottom, 6)
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
        // Held time (sleep, work) is context for the week grid, not something to do; keep it out of this list.
        let agenda = Agenda.items(on: now, tasks: tasks, routines: store.notebook.routines).filter { !$0.isBlock }
        // Finished things stay where they were, struck through, so a look back at the day shows what it held.
        let visible = agenda
        // Today's planned work is already in the timetable; this list is what would otherwise be missed.
        // A task in pieces is left out when one of its pieces is in today's timetable.
        let required = board.obligations(placement, now: now).filter { task in
            task.plannedAt.map { calendar.isDate($0, inSameDayAs: now) } != true
                && !store.children(of: task.id).contains { !$0.isComplete && $0.plannedAt.map { calendar.isDate($0, inSameDayAs: now) } == true }
        }
        // ★ kept together below today's plan, folded: those not already on it above.
        let musts = board.musts(placement, now: now).filter { task in
            task.plannedAt.map { calendar.isDate($0, inSameDayAs: now) } != true
                && !store.children(of: task.id).contains { !$0.isComplete && $0.plannedAt.map { calendar.isDate($0, inSameDayAs: now) } == true }
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
                // What is due today starts open: folded, it would be easy to miss.
                TimetableFolder(title: "今日中に必要なもの", count: required.count, identifier: "requiredFolder", startsOpen: true) {
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
            SectionHeading(title: "今日の時間割")
            if visible.isEmpty {
                Text(agenda.isEmpty ? "今日の予定はまだありません。右下の＋から足せます。" : "今日の予定はすべて終わりました。")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 6)
            }
            // Timed things sit on a raised timeline; the rest are outlined, not placed yet.
            let timed = visible.filter { $0.slot != nil }
            let untimed = visible.filter { $0.slot == nil }
            if !timed.isEmpty {
                TimelinePanel(items: timed, now: now, onOpen: onOpen).padding(.bottom, 6)
            }
            if !untimed.isEmpty {
                Text("時間を決めていない").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, timed.isEmpty ? 0 : 8)
                ForEach(untimed) { item in UntimedAgendaRow(item: item, onOpen: onOpen) }
            }
            if !musts.isEmpty { MustFolder(tasks: musts, now: now, onOpen: onOpen).padding(.top, 6) }
            UpcomingDeadlines(now: now, onOpen: onOpen)

        }
        .frame(maxWidth: 760).frame(maxWidth: .infinity)
    }
}

/// Secondary sections start closed (what is due today starts open) without hiding their counts or removing existing actions.
private struct TimetableFolder<Content: View>: View {
    let title: String
    let count: Int
    var identifier: String
    @ViewBuilder let content: () -> Content
    @State private var open: Bool

    init(title: String, count: Int, identifier: String, startsOpen: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.count = count; self.identifier = identifier
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

/// ★ tasks, what cannot be dropped, folded below today's plan. Folded, it still says how many there are
/// and how near the nearest deadline is; a tap opens the list, nearest deadline first.
@MainActor
private struct MustFolder: View {
    @EnvironmentObject private var store: TaskStore
    let tasks: [TaskItem]
    let now: Date
    let onOpen: (AgendaItem) -> Void
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.down").font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary).rotationEffect(.degrees(open ? 180 : 0))
                    Text("必須").font(.headline).foregroundStyle(Palette.must)
                    Text("\(tasks.count)件").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit()
                    Spacer(minLength: 6)
                    if let nearest {
                        Text(nearest).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.horizontal, 14).frame(minHeight: 48)
                .background(RaisedCardBackground(cornerRadius: 16))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("必須 \(tasks.count)件。\(nearest ?? "")")
            .accessibilityIdentifier("mustFolder")
            .accessibilityValue(open ? "展開中" : "折りたたみ")
            .accessibilityHint(open ? "たたみます" : "広げます")
            if open {
                ForEach(tasks) { task in
                    let current = store.task(task.id) ?? task
                    if store.hasChildren(task.id) {
                        ParentTaskCard(parent: current, reason: plan(of: current)) { onOpen(AgendaItem(task: $0)) }
                    } else {
                        AgendaRow(item: AgendaItem(task: current), reason: plan(of: current), onOpen: onOpen)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    /// "次の締切 11/08（あと2日）".
    private var nearest: String? {
        guard let due = tasks.compactMap(\.deadline).min() else { return nil }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
        return "次の締切 \(due.shortDay)（\(days <= 1 ? "明日" : "あと\(days)日")）"
    }

    /// The day it is planned for, when it has one: ahead, or left from before.
    private func plan(of task: TaskItem) -> String? {
        let day = store.hasChildren(task.id)
            ? store.children(of: task.id).filter { !$0.isComplete }.compactMap(\.plannedAt).min()
            : task.plannedAt
        guard let day else { return nil }
        let calendar = Calendar.current
        return calendar.startOfDay(for: day) < calendar.startOfDay(for: now) ? "\(day.shortDay) から残っている" : "\(day.shortDay) にやる予定"
    }
}

/// Cards share a rail, but each connector stops before the control so an empty circle stays empty.
@MainActor
struct TimelinePanel: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .subheadline) private var timeWidth: CGFloat = 52
    let items: [AgendaItem]
    let now: Date
    var showsNow = true
    let onOpen: (AgendaItem) -> Void

    private let railWidth: CGFloat = 44
    private var minute: Int { NowView.minute(of: now) }
    private var nowIndex: Int {
        showsNow ? (items.firstIndex { ($0.slot?.start ?? Int.max) > minute } ?? items.count) : -1
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
        }.accessibilityIdentifier("untimed-" + item.id)
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
        let book = store.notebook
        let later = { (due: Date) in calendar.startOfDay(for: due) > calendar.startOfDay(for: now) }
        let upcoming = book.tasks.filter { task in
            guard !task.isComplete, let due = task.deadline else { return false }
            return later(due)
        }
        // A project's deadline counts once for all its open tasks that have none of their own.
        let projects: [(project: Project, open: Int)] = book.projects.compactMap { project in
            guard let due = project.deadline, later(due) else { return nil }
            let open = book.tasks.filter { !$0.isComplete && book.projectDeadline(for: $0) != nil
                && ProjectBook.key($0.project) == ProjectBook.key(project.name) }.count
            return open > 0 ? (project, open) : nil
        }
        let rows: [DeadlineRow] = (upcoming.map { DeadlineRow.task($0) } + projects.map { DeadlineRow.project($0.project, open: $0.open) })
            .sorted { $0.due < $1.due }
        if !rows.isEmpty {
            TimetableFolder(title: "これからの締切", count: rows.count, identifier: "deadlineFolder") {
            ForEach(rows.prefix(5)) { row in
                switch row {
                case .project(let project, let open):
                    Button { store.projectToOpen = ProjectBook.key(project.name) } label: {
                        HStack(spacing: 8) {
                            Text(project.deadline?.shortDay ?? "").font(.clock).foregroundStyle(Palette.must)
                            Image(systemName: "flag.fill").font(.caption)
                                .foregroundStyle(ProjectColor.color(for: store.colorName(forProject: project.name)) ?? Palette.accent)
                                .frame(width: 14).accessibilityHidden(true)
                            Text(project.name).lineLimit(1)
                            Text("\(open)件").foregroundStyle(.secondary).monospacedDigit()
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }.font(.subheadline).frame(minHeight: 40)
                    }
                    .accessibilityLabel("プロジェクト「\(project.name)」の期限 \(project.deadline?.shortDay ?? "")、締切のないタスク\(open)件")
                case .task(let task):
                Button { onOpen(AgendaItem(task: task)) } label: {
                    HStack(spacing: 8) {
                        Text(task.deadline?.shortDay ?? "").font(.clock).foregroundStyle(Palette.must)
                        // ★ in bold and the color of must; the mark's place is kept so the names line up.
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(Palette.must)
                            .opacity(task.isMust ? 1 : 0).frame(width: 14)
                            .accessibilityHidden(!task.isMust).accessibilityLabel("必須")
                        Text(task.title).fontWeight(task.isMust ? .bold : .regular)
                            .foregroundStyle(task.isMust ? Palette.must : Color.primary).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }.font(.subheadline).frame(minHeight: 40)
                }
                }
            }
            }
        }
    }

    private enum DeadlineRow: Identifiable {
        case task(TaskItem)
        case project(Project, open: Int)
        var id: String {
            switch self {
            case .task(let task): return "task-\(task.id.uuidString)"
            case .project(let project, _): return "project-\(project.id.uuidString)"
            }
        }
        var due: Date {
            switch self {
            case .task(let task): return task.deadline ?? .distantFuture
            case .project(let project, _): return project.deadline ?? .distantFuture
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

    var body: some View {
        let placement = store.notebook.tasksWithProjectDeadlines.map { task -> TaskItem in
            var copy = task
            if store.recentlyDone.contains(AgendaItem(task: task).id) { copy.completedAt = nil }
            return copy
        }
        let candidates = TaskBoard().candidates(placement, energy: energy, now: now)
        VStack(alignment: .leading, spacing: 10) {
            Text("今できそうなもの").font(.title3.weight(.bold))
            Text("気になるものから。大きなタスクは、その中の一つずつが出ます。").font(.caption).foregroundStyle(.secondary).onlyInDemo()
            Picker(selection: $energy) {
                ForEach(Energy.allCases) { Text($0.label).tag($0) }
            } label: { Text("今の調子") }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("candidateEnergy")
            .accessibilityHint("候補だけを変えます。今日が締切のものや全件一覧には影響しません。")
            Text("今の調子：\(energy.label)。選んだ調子より重いものは出さず、重いものから順に出します。")
                .font(.caption).foregroundStyle(.secondary).onlyInDemo()
            if candidates.isEmpty {
                Text("今の候補はありません。「すべて」からどのタスクでも始められます。")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ForEach(candidates) { candidate in
                AgendaRow(item: AgendaItem(task: store.task(candidate.task.id) ?? candidate.task), reason: candidate.reason,
                          onOpen: onOpen)
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
        .accessibilityIdentifier("toggleCandidateDrawer")
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
