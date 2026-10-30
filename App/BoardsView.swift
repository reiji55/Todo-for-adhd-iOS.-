import SwiftUI

@MainActor
struct TodayView: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.refreshClock) private var refreshClock
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var energy: Energy = .any
    @State private var offset = 0
    @State private var quickTitle = ""
    let onEdit: (TaskItem) -> Void
    let onStart: (TaskItem) -> Void
    let onAll: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = max(context.date, refreshClock)
            let board = TaskBoard()
            let tasks = store.notebook.tasks
            let obligations = board.obligations(tasks, now: now)
            let candidates = board.candidates(tasks, energy: energy, now: now)
            let selectedDay = Calendar.current.date(byAdding: .day, value: offset, to: now) ?? now
            let visibleTopIDs = Set(obligations.map(\.id) + candidates.map(\.id))
            let scheduled = board.scheduled(tasks, for: selectedDay)
                .filter { offset != 0 || !visibleTopIDs.contains($0.id) }
            let unfinished = tasks.filter { !$0.isComplete }
            let futureDue = unfinished.filter { task in
                guard let due = task.deadline else { return false }
                return Calendar.current.startOfDay(for: due) > Calendar.current.startOfDay(for: now)
            }.sorted { ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture) }

            GeometryReader { geometry in
                if geometry.size.width >= 760 && !dynamicTypeSize.isAccessibilitySize {
                    HStack(alignment: .top, spacing: 0) {
                        // Separate scrolling keeps obligations in view while browsing suggestions.
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                overview(now: now, count: unfinished.count)
                                requiredSection(obligations, board: board, now: now)
                                upcomingSection(futureDue)
                            }.padding(20)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("today.required")

                        Divider()

                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                candidateSection(candidates, isEmpty: unfinished.isEmpty)
                                scheduleSection(scheduled, day: selectedDay,
                                                pastCount: board.pastPlanned(tasks, now: now).count)
                            }.padding(20)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("today.candidates")
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            overview(now: now, count: unfinished.count)
                            requiredSection(obligations, board: board, now: now)
                            candidateSection(candidates, isEmpty: unfinished.isEmpty)
                            upcomingSection(futureDue)
                            scheduleSection(scheduled, day: selectedDay,
                                            pastCount: board.pastPlanned(tasks, now: now).count)
                        }.padding(16)
                    }
                    .accessibilityIdentifier("today.singleColumn")
                }
            }.background(Palette.paper)
        }
    }

    @ViewBuilder private func overview(now: Date, count: Int) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(now.formatted(.dateTime.month().day().weekday()))
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button("全体 \(count)件", action: onAll).font(.subheadline.weight(.medium))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(now.formatted(.dateTime.month().day().weekday()))
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("全体 \(count)件", action: onAll).font(.subheadline.weight(.medium))
            }
        }
        if store.loadFailed {
            Label("保存データを開けません。設定から復旧できます。", systemImage: "exclamationmark.triangle")
                .font(.subheadline).foregroundStyle(.red)
        }
    }

    @ViewBuilder private func requiredSection(_ tasks: [TaskItem], board: TaskBoard, now: Date) -> some View {
        SectionHeading(title: "今日の必須・締切", subtitle: "今日までに必要なもの。調子や提案に左右されません。", color: Palette.must)
        if tasks.isEmpty {
            Text("今日の必須・締切タスクはありません。")
                .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
        }
        ForEach(tasks) { task in
            TaskCard(task: task, reason: board.obligationReason(task, now: now), emphasized: true,
                     onEdit: onEdit, onStart: onStart)
        }
    }

    @ViewBuilder private func candidateSection(_ candidates: [Candidate], isEmpty: Bool) -> some View {
        SectionHeading(title: "今できそうなもの", subtitle: "気になるものから。途中で切り替えても、続きは残ります。")
        Picker("今の調子", selection: $energy) {
            ForEach(Energy.allCases) { Text($0.label).tag($0) }
        }.pickerStyle(.menu)
            .accessibilityHint("候補の並びだけを変えます。必須や全件一覧には影響しません。")
        if candidates.isEmpty {
            Text(isEmpty ? "タイトルだけで、最初のタスクを追加できます。" : "今の候補はありません。「すべて」からどのタスクでも始められます。")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        ForEach(candidates) { candidate in
            TaskCard(task: candidate.task, reason: candidate.reason, showDefer: true,
                     onEdit: onEdit, onStart: onStart)
        }
    }

    @ViewBuilder private func upcomingSection(_ tasks: [TaskItem]) -> some View {
        if !tasks.isEmpty {
            SectionHeading(title: "これからの締切", subtitle: "候補に出ていなくても、ここで確認できます。")
            ForEach(tasks) { task in
                Button { onEdit(task) } label: {
                    HStack(alignment: .top) {
                        Text(task.deadline?.shortDay ?? "").monospacedDigit().foregroundStyle(Palette.must)
                        Text(task.title).foregroundStyle(.primary).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }.font(.subheadline).padding(.vertical, 8).frame(minHeight: 44)
                }
            }
        }
    }

    @ViewBuilder private func scheduleSection(_ tasks: [TaskItem], day: Date, pastCount: Int) -> some View {
        Divider().padding(.vertical, 8)
        Picker("予定の日", selection: $offset) {
            Text("昨日").tag(-1); Text("今日").tag(0); Text("明日").tag(1)
        }.pickerStyle(.segmented)
        HStack {
            TextField("\(offset == 0 ? "今日" : day.shortDay)のタスクを追加", text: $quickTitle)
                .submitLabel(.done).onSubmit { addQuick(on: day) }
            Button { addQuick(on: day) } label: {
                Image(systemName: "plus.circle.fill").font(.title).frame(width: 44, height: 44)
            }.disabled(quickTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("タイトルだけでタスクを追加")
        }.padding(10).background(.background, in: RoundedRectangle(cornerRadius: 12))
        Button { onEdit(TaskItem(title: "", plannedAt: day)) } label: {
            Label("日付・必須・締切を指定して追加", systemImage: "slider.horizontal.3").font(.caption)
        }.frame(minHeight: 44)

        SectionHeading(title: offset == 0 ? "今日のほかの予定" : "\(day.shortDay)の予定")
        if tasks.isEmpty {
            Text(offset == 0 ? "ほかの予定はありません。" : "この日の予定はありません。")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        ForEach(tasks) { task in TaskCard(task: task, onEdit: onEdit, onStart: onStart) }
        if pastCount > 0 {
            Button(action: onAll) {
                Label("過ぎた日の予定が\(pastCount)件あります。全体で確認", systemImage: "tray.full")
                    .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
            }
        }
        Text("日付を決めていないタスクも「すべて」に残っています。アイデアは別の置き場に保存できます。")
            .font(.caption).foregroundStyle(.secondary).padding(.vertical, 12)
    }

    private func addQuick(on day: Date) {
        let title = quickTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if store.upsert(TaskItem(title: title, plannedAt: day)) { quickTitle = "" }
    }
}

@MainActor
struct AllTasksView: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var search = ""
    @State private var showDone = false
    let onEdit: (TaskItem) -> Void
    let onStart: (TaskItem) -> Void

    var body: some View {
        let matches = store.notebook.tasks.filter { task in
            search.isEmpty || [task.title, task.project, task.memo, task.handoff, task.resumeNote]
                .joined(separator: " ").localizedCaseInsensitiveContains(search)
                || task.steps.contains { $0.title.localizedCaseInsensitiveContains(search) }
        }
        let open = matches.filter { !$0.isComplete }
        let board = TaskBoard()
        let now = Date()
        let required = board.obligations(open, now: now)
        let remaining = open.filter { !board.isObligation($0, now: now) }
        let dated = remaining.filter { $0.plannedAt != nil }.sorted { ($0.plannedAt ?? .distantFuture) < ($1.plannedAt ?? .distantFuture) }
        let undated = remaining.filter { $0.plannedAt == nil }
        let done = matches.filter(\.isComplete).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("未完了 \(open.count)件").font(.headline)
                    Spacer()
                    Button { onEdit(TaskItem(title: "")) } label: { Label("追加", systemImage: "plus") }
                }
                Text("予定日や調子にかかわらず、すべてここにあります。")
                    .font(.caption).foregroundStyle(.secondary)
                if open.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "タスクはありません" : "見つかりませんでした",
                                           systemImage: "checklist", description: Text(search.isEmpty ? "右上の追加から、タイトルだけで登録できます。" : "別の言葉で検索してみてください。"))
                }
                if !required.isEmpty {
                    SectionHeading(title: "必須・締切 \(required.count)件", color: Palette.must)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(required) { task in
                            TaskCard(task: task, reason: board.obligationReason(task, now: now), emphasized: true, onEdit: onEdit, onStart: onStart)
                        }
                    }
                }
                if !dated.isEmpty {
                    SectionHeading(title: "予定日あり \(dated.count)件")
                    taskGrid(dated)
                }
                if !undated.isEmpty {
                    SectionHeading(title: "日付を決めていない \(undated.count)件")
                    taskGrid(undated)
                }
                Toggle("完了したタスクを表示（\(done.count)件）", isOn: $showDone).font(.subheadline).padding(.vertical)
                if showDone {
                    taskGrid(done)
                }
            }.padding(16).frame(maxWidth: 1200).frame(maxWidth: .infinity)
        }.background(Palette.paper)
            .searchable(text: $search, prompt: "タスク・メモ・プロジェクトを検索")
    }

    private var columns: [GridItem] {
        [GridItem(dynamicTypeSize.isAccessibilitySize || horizontalSizeClass != .regular ? .flexible() : .adaptive(minimum: 360), spacing: 12, alignment: .top)]
    }

    private func taskGrid(_ tasks: [TaskItem]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(tasks) { task in TaskCard(task: task, onEdit: onEdit, onStart: onStart) }
        }
    }
}

@MainActor
struct IdeasView: View {
    @EnvironmentObject private var store: TaskStore
    @State private var draft = ""
    @State private var editing: Idea?
    let onEditTask: (TaskItem) -> Void
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("思いつきを、そのまま。やるかどうかは後で決められます。")
                    .font(.subheadline).foregroundStyle(.secondary)
                VStack(alignment: .trailing) {
                    TextField("アイデアや気になること", text: $draft, axis: .vertical)
                        .lineLimit(3...8).frame(minHeight: 80, alignment: .topLeading)
                    Button("書き留める", systemImage: "tray.and.arrow.down") {
                        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if store.commit({ $0.ideas.insert(Idea(text: text), at: 0) }) { draft = "" }
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
                                store.commit { $0.ideas.removeAll { $0.id == idea.id } }
                            } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
                                .accessibilityLabel("アイデアを削除")
                        }
                    }.padding().background(.background, in: RoundedRectangle(cornerRadius: 16))
                }
            }.padding(16).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }.background(Palette.paper)
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
