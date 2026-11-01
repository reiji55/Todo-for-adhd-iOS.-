import SwiftUI

@MainActor
struct AllTasksView: View {
    enum Mode: String, CaseIterable { case tasks = "タスク", events = "イベント", routines = "ルーティン" }
    @EnvironmentObject private var store: TaskStore
    @State private var mode: Mode = .tasks
    @State private var search = ""
    @State private var showDone = false
    let onOpen: (AgendaItem) -> Void
    let onStart: (TaskItem) -> Void
    let onEditRoutine: (Routine) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Picker("表示", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                switch mode {
                case .tasks: taskList
                case .events: eventList
                case .routines: RoutineList(search: search, onEdit: onEditRoutine)
                }
            }.padding(16).frame(maxWidth: 900).frame(maxWidth: .infinity)
        }
        .background(Palette.paper)
        .searchable(text: $search, prompt: mode == .routines ? "ルーティンを検索" : mode == .events ? "イベントを検索" : "タスク・メモ・プロジェクトを検索")
    }

    @ViewBuilder private var taskList: some View {
        let matches = store.notebook.tasks.filter { task in
            !task.isEvent && (search.isEmpty || [task.title, task.project, task.memo, task.handoff, task.resumeNote]
                .joined(separator: " ").localizedCaseInsensitiveContains(search)
                || task.steps.contains { $0.title.localizedCaseInsensitiveContains(search) })
        }
        // Checked off here a moment ago: keep in place, struck through, until the person leaves.
        let open = matches.filter { !$0.isComplete || store.recentlyDone.contains(AgendaItem(task: $0).id) }
        let board = TaskBoard()
        let now = Date()
        let required = open.filter { task in
            var reopened = task
            reopened.completedAt = nil
            return board.isObligation(reopened, now: now)
        }
        let remaining = open.filter { !required.contains($0) }
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: remaining.filter { $0.plannedAt != nil }) { calendar.startOfDay(for: $0.plannedAt!) }
        let undated = remaining.filter { $0.plannedAt == nil }
        let done = matches.filter { $0.isComplete && !open.contains($0) }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }

        Text("未完了 \(open.filter { !$0.isComplete }.count)件。予定日や調子にかかわらず、すべてここにあります。")
            .font(.caption).foregroundStyle(.secondary)
        if open.isEmpty {
            ContentUnavailableView(search.isEmpty ? "タスクはありません" : "見つかりませんでした", systemImage: "checklist",
                                   description: Text(search.isEmpty ? "右下の＋から、タイトルだけで登録できます。" : "別の言葉で検索してみてください。"))
        }
        if !required.isEmpty {
            SectionHeading(title: "必須・締切 \(required.count)件", color: Palette.must)
            ForEach(required) { task in
                AgendaRow(item: AgendaItem(task: task), reason: board.obligationReason(task, now: now), onOpen: onOpen, onStart: onStart)
            }
        }
        ForEach(byDay.keys.sorted(), id: \.self) { day in
            SectionHeading(title: dayTitle(day, now: now))
            ForEach(byDay[day]!.sorted(by: TaskBoard().scheduledOrder)) { task in
                AgendaRow(item: AgendaItem(task: task), onOpen: onOpen, onStart: onStart)
            }
        }
        if !undated.isEmpty {
            SectionHeading(title: "いつでも \(undated.count)件", subtitle: "日付を決めていないもの")
            ForEach(undated) { task in AgendaRow(item: AgendaItem(task: task), onOpen: onOpen, onStart: onStart) }
        }
        Toggle("完了したタスクを表示（\(done.count)件）", isOn: $showDone).font(.subheadline).padding(.vertical)
        if showDone {
            ForEach(done) { task in AgendaRow(item: AgendaItem(task: task), onOpen: onOpen) }
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
        Text("その日にある予定。チェックはなく、タスクの候補には入りません。").font(.caption).foregroundStyle(.secondary)
        if upcoming.isEmpty {
            ContentUnavailableView(search.isEmpty ? "これからのイベントはありません" : "見つかりませんでした", systemImage: "calendar",
                                   description: Text(search.isEmpty ? "右下の＋から「イベント」を選ぶと追加できます。" : "別の言葉で検索してみてください。"))
        }
        ForEach(byDay.keys.sorted(), id: \.self) { day in
            SectionHeading(title: dayTitle(day, now: Date()))
            ForEach(byDay[day]!.sorted(by: TaskBoard().scheduledOrder)) { task in
                AgendaRow(item: AgendaItem(task: task), onOpen: onOpen)
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
struct IdeasView: View {
    @EnvironmentObject private var store: TaskStore
    @State private var draft = ""
    @State private var editing: Idea?
    @FocusState private var writing: Bool
    let onEditTask: (TaskItem) -> Void
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("思いつきを、そのまま。やるかどうかは後で決められます。")
                    .font(.subheadline).foregroundStyle(.secondary)
                VStack(alignment: .trailing) {
                    TextField("アイデアや気になること", text: $draft, axis: .vertical)
                        .lineLimit(3...8).frame(minHeight: 80, alignment: .topLeading).focused($writing)
                    Button("書き留める", systemImage: "tray.and.arrow.down") {
                        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if store.commit({ $0.ideas.insert(Idea(text: text), at: 0) }) { draft = ""; writing = false }
                    }.buttonStyle(.borderedProminent)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding().background(.background, in: RoundedRectangle(cornerRadius: 16))
                if store.notebook.ideas.isEmpty {
                    ContentUnavailableView("まだ書き留めたものはありません", systemImage: "lightbulb", description: Text("アイデアは、タスク候補や必須の一覧には混ざりません。"))
                }
                ForEach(store.notebook.ideas.sorted { $0.createdAt > $1.createdAt }) { idea in
                    VStack(alignment: .leading, spacing: 12) {
                        Button { editing = idea } label: {
                            Text(idea.text).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        Text(idea.createdAt.shortDay).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Menu {
                                Button("今日のタスクにする") { _ = store.convert(idea, plannedAt: Date()) }
                                Button("日付なしのタスクにする") { _ = store.convert(idea, plannedAt: nil) }
                            } label: { Label("タスクにする", systemImage: "arrow.up.right").font(.subheadline) }
                            Spacer()
                            Button(role: .destructive) {
                                store.deleteIdea(idea.id)
                            } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
                                .accessibilityLabel("アイデアを削除")
                        }
                    }.padding().background(.background, in: RoundedRectangle(cornerRadius: 16))
                }
            }.padding(16).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }.background(Palette.paper)
            // The keyboard covers the tab bar; it must always be easy to put away.
            .scrollDismissesKeyboard(.immediately)
            .onTapGesture { writing = false }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完了") { writing = false }
                }
            }
            .sheet(item: $editing) { idea in IdeaEditor(idea: idea) }
            .alert("保存・読み込みのお知らせ", isPresented: Binding(
                get: { editing == nil && store.error != nil }, set: { if !$0 { store.error = nil } }
            )) { Button("閉じる", role: .cancel) { store.error = nil } } message: { Text(store.error ?? "") }
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
                .navigationTitle("アイデアを編集").navigationBarTitleDisplayMode(.inline)
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
