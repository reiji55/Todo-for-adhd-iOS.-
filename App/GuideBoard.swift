import SwiftUI

struct GuideRoute: Identifiable, Hashable {
    let id: UUID
}

/// Lets a task card open its board card in a sheet, so the person stays where they were.
struct OpenGuideAction {
    let handler: (UUID) -> Void
    func callAsFunction(_ id: UUID) { handler(id) }
}

private struct OpenGuideKey: EnvironmentKey { static let defaultValue: OpenGuideAction? = nil }
extension EnvironmentValues {
    var openGuide: OpenGuideAction? {
        get { self[OpenGuideKey.self] }
        set { self[OpenGuideKey.self] = newValue }
    }
}

enum GuideSummary {
    /// "未完了 2件 · 今日 1件", or nil when nothing is open.
    static func text(_ tasks: [TaskItem], now: Date = Date()) -> String? {
        let open = tasks.filter { !$0.isComplete }
        guard !open.isEmpty else { return nil }
        let today = open.filter { $0.plannedAt.map { Calendar.current.isDate($0, inSameDayAs: now) } == true }.count
        return today > 0 ? "未完了 \(open.count)件 · 今日 \(today)件" : "未完了 \(open.count)件"
    }

    static func place(_ task: TaskItem, now: Date = Date()) -> String {
        guard let planned = task.plannedAt else { return "日付なし" }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: planned)).day ?? 0
        switch days {
        case 0: return "今日"
        case 1: return "明日"
        case -1: return "昨日"
        case ..<(-1): return "過ぎた予定 \(planned.shortDay)"
        default: return "先の予定 \(planned.shortDay)"
        }
    }
}

@MainActor
struct GuideBoardView: View {
    @EnvironmentObject private var store: TaskStore
    @State private var search = ""
    @State private var newTitle = ""
    @State private var opened: GuideRoute?
    let onEdit: (TaskItem) -> Void
    let onStart: (TaskItem) -> Void

    var body: some View {
        let cards = store.notebook.boardCards
        let shown = search.isEmpty ? cards : cards.filter { card in
            [card.title, card.purpose, card.goal, card.detail].joined(separator: "\n").localizedCaseInsensitiveContains(search)
        }
        List {
            Section {
                HStack {
                    TextField("やり方を書きたいこと（例：TOEIC対策）", text: $newTitle)
                        .submitLabel(.done).onSubmit(add)
                    Button(action: add) {
                        Image(systemName: "plus.circle.fill").font(.title2).frame(width: 44, height: 44)
                    }.buttonStyle(.borderless).disabled(trimmedTitle.isEmpty)
                        .accessibilityLabel("カードを追加")
                }
            } footer: {
                Text("タスクは「いま何をするか」、ボードは「どうやるか」。タスクのプロジェクト名とカードの見出しが同じなら（どちらかに含まれていても可）、タスクからこのカードを開けます。")
            }
            if cards.isEmpty {
                ContentUnavailableView("まだカードはありません", systemImage: "book.closed",
                                       description: Text("ルーチンの手順や、案件の目的・ゴール・進め方を書いておく場所です。3日間タスクの board.json は設定から読み込めます。"))
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: search)
            }
            Section {
                ForEach(shown) { card in
                    NavigationLink(value: GuideRoute(id: card.id)) {
                        GuideCardRow(card: card, tasks: store.linkedTasks(for: card))
                    }
                }
                // Reordering a filtered list would move cards the person cannot see.
                .onMove(perform: moveAction)
            }
        }
        .searchable(text: $search, prompt: "見出し・中身を検索")
        .navigationDestination(for: GuideRoute.self) { route in
            GuideCardView(cardID: route.id, onEdit: onEdit, onStart: onStart)
        }
        .navigationDestination(item: $opened) { route in
            GuideCardView(cardID: route.id, onEdit: onEdit, onStart: onStart)
        }
        .onAppear(perform: openForScreenshot)
    }

    private var trimmedTitle: String { newTitle.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func add() {
        let title = trimmedTitle
        guard !title.isEmpty else { return }
        let card = BoardCard(title: title)
        // Open the new card right away: a card with only a title has nothing to read yet.
        if store.upsertCard(card) { newTitle = ""; search = ""; opened = GuideRoute(id: card.id) }
    }

    private var moveAction: ((IndexSet, Int) -> Void)? {
        search.isEmpty ? { store.moveCards(from: $0, to: $1) } : nil
    }

    private func openForScreenshot() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiOpenFirstCard"), let first = store.notebook.boardCards.first {
            opened = GuideRoute(id: first.id)
        }
        #endif
    }
}

@MainActor
struct GuideCardRow: View {
    let card: BoardCard
    let tasks: [TaskItem]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.title).font(.headline).foregroundStyle(.primary)
            if let preview = [card.purpose, card.goal, card.detail]
                .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 8) {
                Text(card.createdAt.formatted(.dateTime.year().month().day()))
                if let summary = GuideSummary.text(tasks) { Text(summary).foregroundStyle(Palette.accent) }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }
}

@MainActor
struct GuideCardView: View {
    @EnvironmentObject private var store: TaskStore
    @State private var editing: BoardCard?
    let cardID: UUID
    /// Nil when shown over a task (editor, focus): the task list and adding tasks belong to the board tab.
    var onEdit: ((TaskItem) -> Void)? = nil
    var onStart: ((TaskItem) -> Void)? = nil

    var body: some View {
        Group {
            if let card = store.card(cardID) {
                content(card)
            } else {
                ContentUnavailableView("このカードはありません", systemImage: "book.closed",
                                       description: Text("削除されたか、取り消しで元に戻りました。"))
            }
        }
        .background(Palette.paper)
        .sheet(item: $editing) { card in GuideCardEditor(card: card) }
    }

    private func content(_ card: BoardCard) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title).font(.title2.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                    Text("作成 \(card.createdAt.formatted(.dateTime.year().month().day()))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if card.isBlank {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("目的・ゴール・やり方を書いておくと、タスクを始めるときにすぐ見返せます。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("書き始める", systemImage: "square.and.pencil") { editing = card }
                            .buttonStyle(.borderedProminent)
                    }.cardBackground()
                }
                field("目的", text: card.purpose)
                field("ゴール", text: card.goal)
                field("やり方", text: card.detail)
                if let onEdit, let onStart { tasksSection(card, onEdit: onEdit, onStart: onStart) }
            }.padding(16).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: card.shareText) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("カードの内容を共有")
                Button("編集") { editing = card }
            }
        }
    }

    @ViewBuilder private func field(_ label: String, text: String) -> some View {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(Palette.accent)
                Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.cardBackground()
        }
    }

    @ViewBuilder private func tasksSection(_ card: BoardCard, onEdit: @escaping (TaskItem) -> Void,
                                           onStart: @escaping (TaskItem) -> Void) -> some View {
        let tasks = store.linkedTasks(for: card)
        let open = tasks.filter { !$0.isComplete }
            .sorted { ($0.plannedAt ?? .distantFuture) < ($1.plannedAt ?? .distantFuture) }
        SectionHeading(title: "このカードのタスク", subtitle: "プロジェクト名が「\(card.title)」に当たる未完了のタスク")
        if open.isEmpty {
            Text("未完了のタスクはありません。").font(.subheadline).foregroundStyle(.secondary)
        }
        ForEach(open) { task in
            VStack(alignment: .leading, spacing: 4) {
                Text(GuideSummary.place(task)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                TaskCard(task: task, onEdit: onEdit, onStart: onStart)
            }
        }
        // This card is already open, so its tasks do not need a link back to it.
        .environment(\.openGuide, nil)
        if tasks.count > open.count {
            Text("完了 \(tasks.count - open.count)件").font(.caption).foregroundStyle(.secondary)
        }
        Button { onEdit(TaskItem(title: "", plannedAt: Date(), project: card.title)) } label: {
            Label("このカードのタスクを今日に追加", systemImage: "plus")
        }.frame(minHeight: 44)
    }
}

@MainActor
struct GuideCardEditor: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    private let original: BoardCard
    @State private var card: BoardCard
    @State private var showDelete = false
    @State private var confirmDiscard = false

    init(card: BoardCard) {
        original = card
        _card = State(initialValue: card)
    }

    private var changed: Bool { card != original }
    private var trimmedTitle: String { card.title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("見出し", text: $card.title, axis: .vertical).font(.headline).lineLimit(1...4)
                } footer: {
                    Text("タスクのプロジェクト名と同じ見出しにすると、そのタスクからこのカードを開けます。")
                }
                Section("目的（なぜやるのか）") {
                    TextField("例：本番の形式と時間配分に慣れる", text: $card.purpose, axis: .vertical).lineLimit(2...8)
                }
                Section("ゴール（どうなったら終わりか）") {
                    TextField("例：11月の試験で650点", text: $card.goal, axis: .vertical).lineLimit(2...8)
                }
                Section("やり方・手順・覚え書き") {
                    TextField("手順やコツ、段取りを何行でも", text: $card.detail, axis: .vertical).lineLimit(8...)
                }
                if store.card(card.id) != nil {
                    Section {
                        Button("このカードを削除", role: .destructive) { showDelete = true }
                    } footer: { Text("タスクは削除されません。直後なら取り消しで戻せます。") }
                }
            }
            .confirmationDialog("このカードを削除しますか？", isPresented: $showDelete, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    store.deleteCard(card.id)
                    if store.card(card.id) == nil { dismiss() }
                }
            } message: { Text("「\(original.title)」の目的・ゴール・やり方が消えます。") }
            .navigationTitle(store.card(card.id) == nil ? "カードを追加" : "カードを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { if changed { confirmDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        card.title = trimmedTitle
                        if store.upsertCard(card) { dismiss() }
                    }.disabled(trimmedTitle.isEmpty)
                }
            }
            // Long notes are costly to retype, so a stray swipe must not throw them away.
            .interactiveDismissDisabled(changed)
        }
        .confirmationDialog("書いた内容を破棄しますか？", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("破棄して閉じる", role: .destructive) { dismiss() }
        }
        .storeErrorAlert()
    }
}

private extension View {
    func cardBackground() -> some View {
        padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
