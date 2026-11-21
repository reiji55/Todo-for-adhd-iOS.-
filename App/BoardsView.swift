import SwiftUI

@MainActor
struct AllTasksView: View {
    enum Mode: String, CaseIterable { case tasks = "タスク", events = "イベント", routines = "ルーティン" }
    @EnvironmentObject private var store: TaskStore
    @State private var mode: Mode = .tasks
    @State private var search = ""
    @State private var showDone = false
    @State private var confirmClearDone = false
    /// The projects opened, kept between visits (names joined by a separator).
    @AppStorage("allOpenProjects") private var openProjects = ""
    /// How the tasks are laid out: by project under the deadlines, or all by nearest deadline.
    @AppStorage("allTasksOrder") private var order = Order.project.rawValue
    /// A project opened from its flag: its page comes straight up here, not by way of the board.
    @State private var openedProject: ProjectRoute?
    enum Order: String, CaseIterable { case project = "プロジェクト別", deadline = "締切が近い順" }
    let onOpen: (AgendaItem) -> Void
    let onEditRoutine: (Routine) -> Void

    var body: some View {
        ScrollView {
            // Like an index file: the other two folders show their tabs and what is next; the chosen one is in front.
            IndexFolders(selected: $mode, count: count, preview: preview) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    switch mode {
                    case .tasks: taskList
                    case .events: eventList
                    case .routines: RoutineList(search: search, todayIDs: todayRoutineIDs, onEdit: onEditRoutine)
                    }
                }
            }
            .padding(16).frame(maxWidth: 900).frame(maxWidth: .infinity)
        }
        .background(Palette.paper)
        .searchable(text: $search, prompt: mode == .routines ? "ルーティンを検索" : mode == .events ? "イベントを検索" : "タスク・メモ・プロジェクトを検索")
        .navigationDestination(item: $openedProject) { route in
            ProjectPage(key: route.key, onEdit: { onOpen(AgendaItem(task: $0)) }).keepsStore()
        }
    }

    private var todayRoutineIDs: Set<UUID> {
        Set(Agenda.items(on: Date(), tasks: [], routines: store.notebook.routines).compactMap { item in
            if case .routine(let id, _) = item.source { return id }
            return nil
        })
    }

    private func isToday(_ task: TaskItem) -> Bool {
        task.plannedAt.map { Calendar.current.isDateInToday($0) } == true
    }

    private func count(_ mode: Mode) -> Int {
        switch mode {
        case .tasks: return store.notebook.tasks.filter { !$0.isEvent && !$0.isComplete && $0.parentID == nil }.count
        case .events:
            let today = Calendar.current.startOfDay(for: Date())
            return store.notebook.tasks.filter { $0.isEvent && ($0.plannedAt ?? today) >= today }.count
        case .routines: return store.notebook.routines.filter { !$0.isPaused }.count
        }
    }

    /// One line shown on a folder in the back, so it is clear what is inside without opening it.
    private func preview(_ mode: Mode) -> String {
        let calendar = Calendar.current
        let now = Date()
        switch mode {
        case .tasks:
            let today = store.notebook.tasks.filter { !$0.isEvent && !$0.isComplete && isToday($0) }
            if let first = today.sorted(by: TaskBoard().scheduledOrder).first {
                return "今日：\(first.title)" + (today.count > 1 ? " ほか\(today.count - 1)件" : "")
            }
            return count(.tasks) == 0 ? "タスクはありません" : "今日の予定はありません"
        case .events:
            let upcoming = store.notebook.tasks.filter { $0.isEvent && ($0.plannedAt ?? now) >= calendar.startOfDay(for: now) }
                .sorted { ($0.plannedAt ?? now, $0.slot?.start ?? -1) < ($1.plannedAt ?? now, $1.slot?.start ?? -1) }
            guard let next = upcoming.first else { return "これからのイベントはありません" }
            let day = next.plannedAt.map { calendar.isDateInToday($0) ? "今日" : $0.formatted(.dateTime.month().day()) } ?? ""
            return "次：\(day)\(next.slot.map { " \($0.startLabel)" } ?? "") \(next.title)"
        case .routines:
            let today = Agenda.items(on: now, tasks: [], routines: store.notebook.routines).filter { !$0.isBlock && !$0.isDone }
            if let next = today.first { return "今日：\(next.slot.map { "\($0.startLabel) " } ?? "")\(next.title)" }
            return "今日のルーティンはありません"
        }
    }

    /// What the person holds, not split by day (the day is a mark on each row; today is the timetable, moving
    /// days is the week). On top what has a deadline and ★, then everything else by project; or all of it by
    /// the nearest deadline.
    @ViewBuilder private var taskList: some View {
        let book = store.notebook
        // Top level only: a task in pieces is one card, and a piece is found through its task.
        let matches = book.tasks.filter { task in
            !task.isEvent && task.parentID == nil
                && (matchesSearch(task) || book.children(of: task.id).contains(where: matchesSearch))
        }
        // Checked off here a moment ago: keep in place, struck through, until the person leaves.
        let open = matches.filter { !$0.isComplete || store.recentlyDone.contains(AgendaItem(task: $0).id) }
        let done = matches.filter { $0.isComplete && !open.contains($0) }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        let openCount = open.filter { !$0.isComplete }.count
        Text(store.isDemo ? "未完了 \(openCount)件。予定日や調子にかかわらず、すべてここにあります。横にスワイプすると削除できます。" : "未完了 \(openCount)件")
            .font(.caption).foregroundStyle(.secondary)
        HStack(spacing: 6) {
            ForEach(Order.allCases, id: \.rawValue) { choice in
                Button { withAnimation(.snappy) { order = choice.rawValue } } label: {
                    Text(choice.rawValue).font(.caption.weight(.bold))
                        .foregroundStyle(order == choice.rawValue ? Color.white : Color.secondary)
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .background(Capsule().fill(order == choice.rawValue ? Palette.accent : Color(uiColor: .secondarySystemGroupedBackground)))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(order == choice.rawValue ? .isSelected : [])
                .accessibilityIdentifier("allOrder-\(choice == .project ? "project" : "deadline")")
            }
        }
        if open.isEmpty {
            ContentUnavailableView(search.isEmpty ? "タスクはありません" : "見つかりませんでした", systemImage: "checklist",
                                   description: Text(search.isEmpty ? "右下の＋から、タイトルだけで登録できます。" : "別の言葉で検索してみてください。"))
        } else if order == Order.deadline.rawValue {
            byDeadline(open)
        } else {
            byProject(open)
        }
        Toggle("完了したタスクを表示（\(done.count)件）", isOn: $showDone).font(.subheadline).padding(.vertical)
        if showDone {
            ForEach(done) { task in
                if store.hasChildren(task.id) {
                    FinishedFamilyCard(parent: task) { onOpen(AgendaItem(task: $0)) }
                } else {
                    AgendaRow(item: AgendaItem(task: task), onOpen: onOpen)
                }
            }
            // Small and quiet at the very end: clearing away what is finished, after a question.
            if !done.isEmpty {
                Button { confirmClearDone = true } label: {
                    Label("完了したタスクをすべて削除", systemImage: "trash")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .accessibilityIdentifier("clearDoneTasks")
                .confirmationDialog("完了したタスク\(done.count)件を削除しますか？", isPresented: $confirmClearDone, titleVisibility: .visible) {
                    Button("\(done.count)件を削除", role: .destructive) { store.deleteCompleted(done.map(\.id)) }
                } message: { Text(search.isEmpty ? "子タスクも一緒に消えます。すぐなら「取り消す」で戻せます。" : "いま検索で表示されている分だけ消えます。") }
            }
        }
    }

    /// 締切・★ on top: what has a deadline of its own and projects with one (nearest first), then ★ without one.
    /// Below, everything else by project, those without one first.
    @ViewBuilder private func byProject(_ open: [TaskItem]) -> some View {
        let book = store.notebook
        let now = Date()
        let calendar = Calendar.current
        let dated = open.filter { $0.deadline != nil }
        let musts = open.filter { $0.isMust && $0.deadline == nil }
            .sorted { (listedDay($0) ?? .distantFuture, $0.createdAt) < (listedDay($1) ?? .distantFuture, $1.createdAt) }
        // A project's deadline is on its own fold below, so the project is not shown twice.
        let rows = dated.map { DeadlineEntry.task($0) }.sorted { ($0.due, $0.id) < ($1.due, $1.id) }
        let projectDue: (String) -> Date = { name in
            name.isEmpty ? .distantPast : ProjectBook.project(named: name, in: book)?.deadline ?? .distantFuture
        }
        let top = Set(dated.map(\.id) + musts.map(\.id))
        let rest = open.filter { !top.contains($0.id) }
            .sorted { (listedDay($0) ?? .distantFuture, $0.createdAt) < (listedDay($1) ?? .distantFuture, $1.createdAt) }
        if !rows.isEmpty || !musts.isEmpty {
            SectionHeading(title: "締切・★ \(dated.count + musts.count)件", subtitle: "締切が近い順", color: Palette.must)
            ForEach(rows) { entry in
                switch entry {
                case .task(let task):
                    row(task, reason: dueReason(task, now: now), raised: listedDay(task).map(calendar.isDateInToday) == true, showsDay: true)
                case .project(let project, let tasks):
                    ProjectDeadlineCard(project: project, tasks: tasks, now: now, onOpen: onOpen,
                                        onOpenProject: { openedProject = ProjectRoute(key: ProjectBook.key($0)) })
                }
            }
            ForEach(musts) { task in row(task, showsDay: true) }
        }
        // Without a project first, then projects with a deadline, nearest first, then the rest as they come.
        let folds = Self.folds(rest).enumerated()
            .sorted { (projectDue($0.element.name), $0.offset) < (projectDue($1.element.name), $1.offset) }.map(\.element)
        ForEach(folds, id: \.name) { fold in
            let unfolded = !search.isEmpty || isOpen(fold.name)
            foldHeader(fold.name, tasks: fold.tasks, open: unfolded)
            if unfolded {
                ForEach(fold.tasks) { task in
                    row(task, raised: listedDay(task).map(calendar.isDateInToday) == true, showsDay: true).padding(.leading, 14)
                }
            }
        }
    }

    /// Everything by the nearest deadline (its own, else its project's); then those without one, by day.
    @ViewBuilder private func byDeadline(_ open: [TaskItem]) -> some View {
        let book = store.notebook
        let now = Date()
        let calendar = Calendar.current
        let due: (TaskItem) -> Date? = { task in task.deadline ?? book.projectDeadline(for: task) }
        let withDue = open.filter { due($0) != nil }.sorted { (due($0)!, $0.createdAt) < (due($1)!, $1.createdAt) }
        let without = open.filter { due($0) == nil }
            .sorted { (listedDay($0) ?? .distantFuture, $0.createdAt) < (listedDay($1) ?? .distantFuture, $1.createdAt) }
        if !withDue.isEmpty {
            SectionHeading(title: "締切あり \(withDue.count)件", color: Palette.must)
            ForEach(withDue) { task in
                row(task, reason: dueReason(task, due: due(task), now: now),
                    raised: listedDay(task).map(calendar.isDateInToday) == true, showsDay: true)
            }
        }
        if !without.isEmpty {
            SectionHeading(title: "締切なし \(without.count)件")
            ForEach(AllTasksView.chainOrdered(without)) { task in
                row(task, raised: listedDay(task).map(calendar.isDateInToday) == true, showsDay: true)
            }
        }
    }

    /// "今日が締切", "締切を過ぎています", "あと3日" (a project's: "プロジェクトの期限まであと3日").
    private func dueReason(_ task: TaskItem, due: Date? = nil, now: Date) -> String? {
        guard let date = due ?? task.deadline else { return nil }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        let own = task.deadline != nil
        if days < 0 { return own ? "締切を過ぎています" : "プロジェクトの期限を過ぎています" }
        if days == 0 { return own ? "今日が締切" : "プロジェクトの期限が今日" }
        return own ? "あと\(days)日" : "プロジェクトの期限まであと\(days)日"
    }

    private enum DeadlineEntry: Identifiable {
        case task(TaskItem)
        case project(Project, tasks: [TaskItem])
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

    /// Tasks by project: those without one first, then each project where its first task stands.
    static func folds(_ tasks: [TaskItem]) -> [(name: String, tasks: [TaskItem])] {
        var order: [String] = []
        var byName: [String: [TaskItem]] = [:]
        for task in tasks {
            let name = task.project.trimmingCharacters(in: .whitespacesAndNewlines)
            if byName[name] == nil { order.append(name) }
            byName[name, default: []].append(task)
        }
        return (order.filter(\.isEmpty) + order.filter { !$0.isEmpty }).map { ($0, chainOrdered(byName[$0] ?? [])) }
    }

    /// The same tasks with those of a つながり next to each other, in its order: a task added as the next of
    /// another sits right under it, not at the end of the list.
    static func chainOrdered(_ tasks: [TaskItem]) -> [TaskItem] {
        let ids = Set(tasks.map(\.id))
        var after: [UUID: [TaskItem]] = [:]
        for task in tasks {
            if let before = task.follows, ids.contains(before) { after[before, default: []].append(task) }
        }
        guard !after.isEmpty else { return tasks }
        var result: [TaskItem] = []
        var seen = Set<UUID>()
        func emit(_ task: TaskItem) {
            guard seen.insert(task.id).inserted else { return }
            result.append(task)
            for next in after[task.id] ?? [] { emit(next) }
        }
        for task in tasks where task.follows.map(ids.contains) != true { emit(task) }
        // Anything left is in a loop (edits crossed on two devices): keep it, in the order it came.
        for task in tasks { emit(task) }
        return result
    }

    private static let separator: Character = "\u{1F}"
    /// The stored name of a fold. Tasks without a project have an empty name, which a split of the stored
    /// names would drop, so they are kept under a mark of their own.
    static func foldKey(_ name: String) -> String { name.isEmpty ? "\u{1E}none" : name }
    private func isOpen(_ name: String) -> Bool {
        openProjects.split(separator: Self.separator).contains { $0 == Self.foldKey(name) }
    }
    private func toggle(_ name: String) {
        let key = Self.foldKey(name)
        var names = openProjects.split(separator: Self.separator).map(String.init)
        if let index = names.firstIndex(of: key) { names.remove(at: index) } else { names.append(key) }
        openProjects = names.joined(separator: String(Self.separator))
    }

    /// A project's fold: its name and count, and while folded, the next of its tasks.
    /// A project's fold: its name and count, its deadline when it has one (with the flag that goes to it on the
    /// board), and while folded, the next of its tasks.
    private func foldHeader(_ name: String, tasks: [TaskItem], open: Bool) -> some View {
        let color = name.isEmpty ? nil : ProjectColor.color(for: store.colorName(forProject: name))
        let project = name.isEmpty ? nil : ProjectBook.project(named: name, in: store.notebook)
        return HStack(spacing: 6) {
            Button { withAnimation(.snappy) { toggle(name) } } label: {
                VStack(alignment: .leading, spacing: 3) {
                    if let due = project?.deadline {
                        Text("期限 \(due.shortDay)・\(Self.left(due))").font(.caption2.weight(.semibold))
                            .foregroundStyle(Palette.must).padding(.leading, 17)
                    }
                    HStack(spacing: 8) {
                        Circle().fill(color ?? Color.secondary.opacity(0.5)).frame(width: 9, height: 9)
                        Text(name.isEmpty ? "プロジェクトなし" : name).font(.subheadline.weight(.bold)).lineLimit(1)
                        Text("\(tasks.count)件").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        Spacer(minLength: 0)
                        Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    if !open, let next = tasks.first {
                        Text("次：\(next.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .padding(.leading, 17)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name.isEmpty ? "プロジェクトなし" : name)、\(tasks.count)件" + (project?.deadline.map { "、期限 \($0.shortDay)" } ?? ""))
            .accessibilityValue(open ? "展開中" : "折りたたみ")
            .accessibilityIdentifier("projectFold-\(name.isEmpty ? "none" : name)")
            if project?.deadline != nil, let color {
                // The flag opens the project's page.
                Button { openedProject = ProjectRoute(key: ProjectBook.key(name)) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "flag.fill").foregroundStyle(color)
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Capsule().fill(color.opacity(0.14)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("プロジェクト「\(name)」を開く")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .secondarySystemGroupedBackground)))
    }

    /// "あと3日", "今日まで", "過ぎています".
    static func left(_ due: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
        return days < 0 ? "過ぎています" : days == 0 ? "今日まで" : "あと\(days)日"
    }

    private func matchesSearch(_ task: TaskItem) -> Bool {
        search.isEmpty || [task.title, task.project, task.memo, task.handoff]
            .joined(separator: " ").localizedCaseInsensitiveContains(search)
    }

    /// The day a task is listed under: its own, or for a task in pieces, that of its next planned piece.
    private func listedDay(_ task: TaskItem) -> Date? {
        let calendar = Calendar.current
        if store.hasChildren(task.id) {
            return store.children(of: task.id).filter { !$0.isComplete }.compactMap(\.plannedAt).min().map { calendar.startOfDay(for: $0) }
        }
        return task.plannedAt.map { calendar.startOfDay(for: $0) }
    }

    @ViewBuilder private func row(_ task: TaskItem, reason: String? = nil, raised: Bool = false, startsOpen: Bool = false,
                                  showsDay: Bool = false) -> some View {
        if store.hasChildren(task.id) {
            ParentTaskCard(parent: task, reason: reason, startsOpen: startsOpen, raised: raised) { onOpen(AgendaItem(task: $0)) }
        } else {
            AgendaRow(item: AgendaItem(task: task), reason: reason, style: raised ? .raised : .card, showsDay: showsDay, onOpen: onOpen)
        }
    }

    /// Events from today on, by day; past ones fold away.
    @ViewBuilder private var eventList: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let events = store.notebook.tasks.filter { task in
            task.isEvent && (search.isEmpty || [task.title, task.project, task.memo].joined(separator: " ").localizedCaseInsensitiveContains(search))
        }
        let upcoming = events.filter { ($0.plannedAt.map { calendar.startOfDay(for: $0) } ?? today) >= today }
        let past = events.filter { ($0.plannedAt.map { calendar.startOfDay(for: $0) } ?? today) < today }
            .sorted { ($0.plannedAt ?? .distantPast) > ($1.plannedAt ?? .distantPast) }
        let byDay = Dictionary(grouping: upcoming) { calendar.startOfDay(for: $0.plannedAt ?? today) }
        Text("その日にある予定。チェックはなく、タスクの候補には入りません。").font(.caption).foregroundStyle(.secondary).onlyInDemo()
        if upcoming.isEmpty {
            ContentUnavailableView(search.isEmpty ? "これからのイベントはありません" : "見つかりませんでした", systemImage: "calendar",
                                   description: Text(search.isEmpty ? "右下の＋から「イベント」を選ぶと追加できます。" : "別の言葉で検索してみてください。"))
        }
        ForEach(byDay.keys.sorted(), id: \.self) { day in
            SectionHeading(title: dayTitle(day, now: Date()))
            ForEach(byDay[day]!.sorted(by: TaskBoard().scheduledOrder)) { task in
                AgendaRow(item: AgendaItem(task: task), style: calendar.isDateInToday(day) ? .raised : .card, onOpen: onOpen)
            }
        }
        if !past.isEmpty {
            Toggle("過ぎたイベントを表示（\(past.count)件）", isOn: $showDone).font(.subheadline).padding(.vertical)
            if showDone {
                ForEach(past) { task in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.plannedAt.map { PlainText.dayTitle($0) } ?? "").font(.caption).foregroundStyle(.secondary)
                        AgendaRow(item: AgendaItem(task: task), onOpen: onOpen)
                    }
                }
            }
        }
    }

    private func dayTitle(_ day: Date, now: Date) -> String {
        let calendar = Calendar.current
        let label = day.formatted(.dateTime.month().day().weekday())
        let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: day).day ?? 0
        switch offset {
        case 0: return "今日 \(label)"
        case 1: return "明日 \(label)"
        case -1: return "昨日 \(label)"
        case ..<(-1): return "\(label)（過ぎた日）"
        default: return label
        }
    }
}

@MainActor
struct IdeaEditor: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    @State var idea: Idea
    var body: some View {
        NavigationStack {
            TextEditor(text: $idea.text).padding()
                .navigationTitle("アイデアを編集").keyboardDismissable().navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            idea.text = idea.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if store.saveIdea(idea) { dismiss() }
                        }.disabled(idea.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }.storeErrorAlert()
    }
}

extension AllTasksView.Mode {
    /// Each kind has its own divider color, as in an index file.
    var color: Color {
        switch self {
        case .tasks: return Palette.accent
        case .events: return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 0.56, green: 0.76, blue: 0.96, alpha: 1) : UIColor(red: 0.18, green: 0.42, blue: 0.62, alpha: 1) })
        case .routines: return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 0.78, green: 0.68, blue: 0.97, alpha: 1) : UIColor(red: 0.42, green: 0.31, blue: 0.61, alpha: 1) })
        }
    }
    var icon: String {
        switch self {
        case .tasks: return "checkmark.circle"
        case .events: return "calendar"
        case .routines: return "arrow.triangle.2.circlepath"
        }
    }
    /// The tabs sit at different places along the top, like real dividers, so they never hide each other.
    var tabAlignment: Alignment {
        switch self {
        case .tasks: return .leading
        case .events: return .center
        case .routines: return .trailing
        }
    }
}

/// Folders stacked like an index file: the folders behind show their tab and one line of what is inside;
/// tapping one brings it to the front, where its whole list is.
@MainActor
struct IndexFolders<Content: View>: View {
    @Binding var selected: AllTasksView.Mode
    let count: (AllTasksView.Mode) -> Int
    let preview: (AllTasksView.Mode) -> String
    @ViewBuilder let content: Content

    var body: some View {
        let back = AllTasksView.Mode.allCases.filter { $0 != selected }
        VStack(spacing: 0) {
            ForEach(Array(back.enumerated()), id: \.element) { index, mode in
                Button { withAnimation(.snappy) { selected = mode } } label: {
                    VStack(spacing: 0) {
                        tab(mode, front: false)
                        HStack(spacing: 6) {
                            Image(systemName: mode.icon).font(.caption.weight(.semibold))
                            Text(preview(mode)).font(.subheadline).lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.up").font(.caption2.weight(.bold)).opacity(0.6)
                        }
                        .foregroundStyle(mode.color)
                        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 22)
                        .background(folderShape(mode))
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, index == 0 ? 0 : -14)
                .shadow(color: .black.opacity(index == 0 ? 0 : 0.08), radius: 4, y: -2)
                .zIndex(Double(index))
                .accessibilityLabel("\(mode.rawValue)のフォルダーを開く、\(count(mode))件。\(preview(mode))")
            }
            VStack(spacing: 0) {
                tab(selected, front: true)
                content
                    .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(folderShape(selected, front: true))
            }
            .padding(.top, back.isEmpty ? 0 : -14)
            .shadow(color: .black.opacity(0.06), radius: 6, y: -1)
            .zIndex(10)
        }
        .animation(.snappy, value: selected)
    }

    private func tab(_ mode: AllTasksView.Mode, front: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(mode.color).frame(width: 8, height: 8)
            Text(mode.rawValue).font(front ? .subheadline.weight(.bold) : .footnote.weight(.bold))
            Text("\(count(mode))").font(.caption.weight(.bold)).monospacedDigit()
                .padding(.horizontal, 7).padding(.vertical, 1)
                .background(Capsule().fill(Color(uiColor: .secondarySystemGroupedBackground).opacity(front ? 1 : 0.7)))
        }
        .foregroundStyle(mode.color)
        .padding(.horizontal, 14).frame(height: front ? 34 : 30)
        .background(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12)
            .fill(mode.color.opacity(front ? Self.frontTint : Self.backTint)))
        .frame(maxWidth: .infinity, alignment: mode.tabAlignment)
    }

    /// The folder in front is only faintly tinted, so its white cards read like the rest of the app; the
    /// folders behind keep a little more color to tell them apart.
    private static var frontTint: Double { 0.09 }
    private static var backTint: Double { 0.14 }
    private static var radius: CGFloat { 16 }

    /// The folder itself; the corner under its tab is square so the tab and folder read as one piece.
    private func folderShape(_ mode: AllTasksView.Mode, front: Bool = false) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: mode.tabAlignment == .leading ? 0 : Self.radius,
                                           bottomLeadingRadius: Self.radius, bottomTrailingRadius: Self.radius,
                                           topTrailingRadius: mode.tabAlignment == .trailing ? 0 : Self.radius)
        return shape.fill(mode.color.opacity(front ? Self.frontTint : Self.backTint))
            .background(shape.fill(Palette.paper))
    }
}

/// A project's deadline among the deadlines in すべて: its name opens the tasks that go by it, the flag and
/// arrow go to its page on the board.
@MainActor
struct ProjectDeadlineCard: View {
    @EnvironmentObject private var store: TaskStore
    let project: Project
    let tasks: [TaskItem]
    let now: Date
    let onOpen: (AgendaItem) -> Void
    let onOpenProject: (String) -> Void
    @State private var open = false

    var body: some View {
        let color = ProjectColor.color(for: store.colorName(forProject: project.name)) ?? Palette.accent
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { withAnimation(.snappy) { open.toggle() } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "flag.fill").font(.caption).foregroundStyle(color).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(left).font(.caption2.weight(.semibold)).foregroundStyle(Palette.must)
                            HStack(spacing: 6) {
                                Text(project.name).font(.body.weight(.medium)).lineLimit(1)
                                Text("\(tasks.count)件").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                                Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            Text("プロジェクトの期限 \(project.deadline?.shortDay ?? "")").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("プロジェクト「\(project.name)」の期限 \(project.deadline?.shortDay ?? "")、締切のないタスク\(tasks.count)件")
                .accessibilityValue(open ? "展開中" : "折りたたみ")
                .accessibilityIdentifier("deadlineProject-\(project.name)")
                // The flag opens the project's page.
                Button { onOpenProject(project.name) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "flag.fill").foregroundStyle(color)
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Capsule().fill(color.opacity(0.14)))
                    .frame(minHeight: 40).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("プロジェクト「\(project.name)」を開く")
                .accessibilityIdentifier("deadlineProjectBoard-\(project.name)")
            }
            .padding(.vertical, 9).padding(.horizontal, 12)
            if open {
                ForEach(tasks) { task in
                    Button { onOpen(AgendaItem(task: task)) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: task.isMust ? "star.fill" : "circle").font(.system(size: 7))
                                .foregroundStyle(task.isMust ? Palette.must : Color.secondary).frame(width: 14)
                            Text(task.title).fontWeight(task.isMust ? .bold : .regular)
                                .foregroundStyle(task.isMust ? Palette.must : Color.primary).lineLimit(1)
                            Spacer(minLength: 0)
                            if let day = task.plannedAt {
                                Text(day.shortDay).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .font(.subheadline).frame(minHeight: 36).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 38).padding(.trailing, 12)
                }
                .padding(.bottom, 6)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 10)
        }
    }

    /// "あと3日", "今日まで", "期限を過ぎています".
    private var left: String {
        guard let due = project.deadline else { return "" }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
        return days < 0 ? "期限を過ぎています" : days == 0 ? "今日が期限" : "あと\(days)日"
    }
}
