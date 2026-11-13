import SwiftUI

@MainActor
struct AllTasksView: View {
    enum Mode: String, CaseIterable { case tasks = "タスク", events = "イベント", routines = "ルーティン" }
    @EnvironmentObject private var store: TaskStore
    @State private var mode: Mode = .tasks
    @State private var search = ""
    @State private var showDone = false
    /// The projects opened in いつでも, kept between visits (names joined by a separator).
    @AppStorage("allOpenProjects") private var openProjects = ""
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

    @ViewBuilder private var taskList: some View {
        let book = store.notebook
        // Top level only: a task in pieces is one card, and a piece is found through its task.
        let matches = book.tasks.filter { task in
            !task.isEvent && task.parentID == nil
                && (matchesSearch(task) || book.children(of: task.id).contains(where: matchesSearch))
        }
        // Checked off here a moment ago: keep in place, struck through, until the person leaves.
        let open = matches.filter { !$0.isComplete || store.recentlyDone.contains(AgendaItem(task: $0).id) }
        let board = TaskBoard()
        let now = Date()
        let calendar = Calendar.current
        // Due today or earlier, ★ or not: above everything.
        let required = open.filter { task in
            var reopened = task
            reopened.completedAt = nil
            return board.isObligation(reopened, now: now)
        }
        // ★ without a day of their own yet, kept together. Those with a day stay on it, marked.
        let musts = open.filter { $0.isMust && !required.contains($0) && listedDay($0) == nil }
            .sorted { ($0.deadline ?? .distantFuture, $0.createdAt) < ($1.deadline ?? .distantFuture, $1.createdAt) }
        let remaining = open.filter { !required.contains($0) && !musts.contains($0) }
        let byDay = Dictionary(grouping: remaining.filter { listedDay($0) != nil }) { listedDay($0)! }
        let days = byDay.keys.sorted()
        let undated = remaining.filter { listedDay($0) == nil }
        let done = matches.filter { $0.isComplete && !open.contains($0) }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        // The ★ group stands where its nearest deadline falls among the days: on 11/6 with the nearest on
        // 11/8, after 11/6 and 11/7. Without a deadline, after the last day, before いつでも.
        let nearest = musts.compactMap(\.deadline).min().map { calendar.startOfDay(for: $0) }
        let mustsBefore = nearest.flatMap { day in days.first { $0 >= day } }

        let openCount = open.filter { !$0.isComplete }.count
        Text(store.isDemo ? "未完了 \(openCount)件。予定日や調子にかかわらず、すべてここにあります。横にスワイプすると削除できます。" : "未完了 \(openCount)件")
            .font(.caption).foregroundStyle(.secondary)
        if open.isEmpty {
            ContentUnavailableView(search.isEmpty ? "タスクはありません" : "見つかりませんでした", systemImage: "checklist",
                                   description: Text(search.isEmpty ? "右下の＋から、タイトルだけで登録できます。" : "別の言葉で検索してみてください。"))
        }
        if !required.isEmpty {
            SectionHeading(title: "今日までの締切 \(required.count)件", color: Palette.must)
            ForEach(required) { task in
                row(task, reason: board.obligationReason(task, now: now), raised: listedDay(task).map(calendar.isDateInToday) == true)
            }
        }
        ForEach(days, id: \.self) { day in
            if !musts.isEmpty && mustsBefore == day { mustSection(musts, nearest: nearest) }
            SectionHeading(title: dayTitle(day, now: now))
            // Today's things are lifted off the page so they stand out from the rest; a task in pieces
            // with a piece today shows its pieces.
            ForEach(byDay[day]!.sorted(by: TaskBoard().scheduledOrder)) { task in
                row(task, raised: calendar.isDateInToday(day), startsOpen: calendar.isDateInToday(day))
            }
        }
        if !musts.isEmpty && mustsBefore == nil { mustSection(musts, nearest: nearest) }
        if !undated.isEmpty {
            SectionHeading(title: "いつでも \(undated.count)件", subtitle: "日付を決めていないもの・プロジェクトごと")
            // Folded by project, those without one first. A search opens them all so every match shows.
            ForEach(Self.folds(undated), id: \.name) { fold in
                let open = !search.isEmpty || isOpen(fold.name)
                foldHeader(fold.name, tasks: fold.tasks, open: open)
                if open {
                    ForEach(fold.tasks) { task in row(task).padding(.leading, 14) }
                }
            }
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
        }
    }

    /// いつでも's tasks by project: those without one first, then each project where its first task stands.
    static func folds(_ tasks: [TaskItem]) -> [(name: String, tasks: [TaskItem])] {
        var order: [String] = []
        var byName: [String: [TaskItem]] = [:]
        for task in tasks {
            let name = task.project.trimmingCharacters(in: .whitespacesAndNewlines)
            if byName[name] == nil { order.append(name) }
            byName[name, default: []].append(task)
        }
        return (order.filter(\.isEmpty) + order.filter { !$0.isEmpty }).map { ($0, byName[$0] ?? []) }
    }

    private static let separator: Character = "\u{1F}"
    private func isOpen(_ name: String) -> Bool { openProjects.split(separator: Self.separator).contains { $0 == name } }
    private func toggle(_ name: String) {
        var names = openProjects.split(separator: Self.separator).map(String.init)
        if let index = names.firstIndex(of: name) { names.remove(at: index) } else { names.append(name) }
        openProjects = names.joined(separator: String(Self.separator))
    }

    /// A project's fold in いつでも: its name and count, and while folded, the next of its tasks.
    private func foldHeader(_ name: String, tasks: [TaskItem], open: Bool) -> some View {
        let color = name.isEmpty ? nil : ProjectColor.color(for: store.colorName(forProject: name))
        return Button { withAnimation(.snappy) { toggle(name) } } label: {
            VStack(alignment: .leading, spacing: 3) {
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
            .padding(.horizontal, 12).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .secondarySystemGroupedBackground)))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name.isEmpty ? "プロジェクトなし" : name)、\(tasks.count)件")
        .accessibilityValue(open ? "展開中" : "折りたたみ")
        .accessibilityIdentifier("projectFold-\(name.isEmpty ? "none" : name)")
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

    /// ★ not given a day yet, nearest deadline first.
    @ViewBuilder private func mustSection(_ musts: [TaskItem], nearest: Date?) -> some View {
        SectionHeading(title: "★ 必須 \(musts.count)件",
                       subtitle: nearest.map { "日付を決めていないもの。いちばん近い締切 \($0.shortDay)" } ?? "日付を決めていないもの",
                       color: Palette.must)
        ForEach(musts) { task in row(task) }
    }

    @ViewBuilder private func row(_ task: TaskItem, reason: String? = nil, raised: Bool = false, startsOpen: Bool = false) -> some View {
        if store.hasChildren(task.id) {
            ParentTaskCard(parent: task, reason: reason, startsOpen: startsOpen, raised: raised) { onOpen(AgendaItem(task: $0)) }
        } else {
            AgendaRow(item: AgendaItem(task: task), reason: reason, style: raised ? .raised : .card, onOpen: onOpen)
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
    private static let frontTint = 0.09
    private static let backTint = 0.14
    private static let radius: CGFloat = 16

    /// The folder itself; the corner under its tab is square so the tab and folder read as one piece.
    private func folderShape(_ mode: AllTasksView.Mode, front: Bool = false) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: mode.tabAlignment == .leading ? 0 : Self.radius,
                                           bottomLeadingRadius: Self.radius, bottomTrailingRadius: Self.radius,
                                           topTrailingRadius: mode.tabAlignment == .trailing ? 0 : Self.radius)
        return shape.fill(mode.color.opacity(front ? Self.frontTint : Self.backTint))
            .background(shape.fill(Palette.paper))
    }
}
