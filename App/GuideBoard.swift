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
    @Environment(\.horizontalSizeClass) private var sizeClass
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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    TextField("やり方を書きたいこと（例：TOEIC対策）", text: $newTitle)
                        .submitLabel(.done).onSubmit(add)
                    Button(action: add) {
                        Image(systemName: "plus.circle.fill").font(.title2).frame(width: 44, height: 44)
                    }.buttonStyle(.borderless).disabled(trimmedTitle.isEmpty).accessibilityLabel("カードを追加")
                }
                .padding(.leading, 14).padding(.vertical, 2)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                Text("タスクは「いま何をするか」、ボードは「どうやるか」。タスクやルーティンのプロジェクト名とカードの見出しが同じなら（どちらかに含まれていても可）、そこからこのカードを開けます。")
                    .font(.caption).foregroundStyle(.secondary)
                if cards.isEmpty {
                    ContentUnavailableView("まだカードはありません", systemImage: "book.closed",
                                           description: Text("ルーチンの手順や、案件の目的・ゴール・進め方を書いておく場所です。3日間タスクの board.json は設定から読み込めます。"))
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
                if sizeClass == .regular {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                        ForEach(shown) { card in face(card, stacked: false, ids: shown.map(\.id)) }
                    }
                } else {
                    // Overlapping, as in task-3days: the edge of the next card shows there is more.
                    VStack(spacing: -16) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, card in
                            face(card, stacked: true, ids: shown.map(\.id)).zIndex(Double(index))
                        }
                    }.padding(.top, 8)
                }
            }
            .padding(16).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }
        .background(Palette.paper)
        .searchable(text: $search, prompt: "見出し・中身を検索")
        .navigationDestination(for: GuideRoute.self) { route in
            GuidePager(startID: route.id, cardIDs: shown.map(\.id), onEdit: onEdit, onStart: onStart)
        }
        .navigationDestination(item: $opened) { route in
            GuidePager(startID: route.id, cardIDs: shown.map(\.id), onEdit: onEdit, onStart: onStart)
        }
        .onAppear(perform: openForScreenshot)
    }

    private func face(_ card: BoardCard, stacked: Bool, ids: [UUID]) -> some View {
        NavigationLink(value: GuideRoute(id: card.id)) {
            GuideCardFace(card: card, tasks: store.linkedTasks(for: card), stacked: stacked)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if search.isEmpty, let index = store.notebook.boardCards.firstIndex(where: { $0.id == card.id }) {
                Button("いちばん上へ", systemImage: "arrow.up.to.line") { store.moveCards(from: IndexSet([index]), to: 0) }
                Button("いちばん下へ", systemImage: "arrow.down.to.line") {
                    store.moveCards(from: IndexSet([index]), to: store.notebook.boardCards.count)
                }
            }
            ShareLink(item: card.shareText) { Label("共有", systemImage: "square.and.arrow.up") }
            Button("削除", systemImage: "trash", role: .destructive) { store.deleteCard(card.id) }
        }
    }

    private var trimmedTitle: String { newTitle.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func add() {
        let title = trimmedTitle
        guard !title.isEmpty else { return }
        let card = BoardCard(title: title)
        // Open the new card right away: a card with only a title has nothing to read yet.
        if store.upsertCard(card) { newTitle = ""; search = ""; opened = GuideRoute(id: card.id) }
    }

    private func openForScreenshot() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiOpenFirstCard"), let first = store.notebook.boardCards.first {
            opened = GuideRoute(id: first.id)
        }
        #endif
    }
}

/// The colored card in the list: the date and a large title, like the task-3days board.
@MainActor
struct GuideCardFace: View {
    let card: BoardCard
    let tasks: [TaskItem]
    let stacked: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.createdAt.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))
                    .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(Color.primary.opacity(0.5))
                Spacer()
                if let summary = GuideSummary.text(tasks) {
                    Text(summary).font(.caption2.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
            }
            Text(card.title).font(.system(size: 24, weight: .bold)).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if !stacked, !card.purpose.isEmpty {
                Text(card.purpose).font(.subheadline).foregroundStyle(Color.primary.opacity(0.65)).lineLimit(3)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 20).padding(.top, 17).padding(.bottom, stacked ? 30 : 22)
        .frame(maxWidth: .infinity, minHeight: stacked ? 0 : 150, alignment: .topLeading)
        .background(ProjectColor.tint(for: card.title), in: RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.2), radius: 6, y: -2)
        .contentShape(RoundedRectangle(cornerRadius: 24))
    }
}

/// Cards side by side: swipe to the next one, as on the original board.
@MainActor
struct GuidePager: View {
    @EnvironmentObject private var store: TaskStore
    @State private var current: UUID
    @State private var editing: BoardCard?
    let cardIDs: [UUID]
    var onEdit: ((TaskItem) -> Void)? = nil
    var onStart: ((TaskItem) -> Void)? = nil

    init(startID: UUID, cardIDs: [UUID], onEdit: ((TaskItem) -> Void)? = nil, onStart: ((TaskItem) -> Void)? = nil) {
        _current = State(initialValue: startID)
        self.cardIDs = cardIDs.contains(startID) ? cardIDs : [startID]
        self.onEdit = onEdit; self.onStart = onStart
    }

    var body: some View {
        let ids = cardIDs.filter { store.card($0) != nil }
        Group {
            if ids.isEmpty {
                ContentUnavailableView("このカードはありません", systemImage: "book.closed",
                                       description: Text("削除されたか、取り消しで元に戻りました。"))
            } else {
                TabView(selection: $current) {
                    ForEach(ids, id: \.self) { id in
                        GuideCardView(cardID: id, onEdit: onEdit, onStart: onStart) { editing = store.card(id) }.tag(id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    if ids.count > 1 {
                        HStack(spacing: 5) {
                            ForEach(ids, id: \.self) { id in
                                Circle().fill(Color.primary.opacity(id == current ? 0.6 : 0.2)).frame(width: 5, height: 5)
                            }
                        }.padding(.top, 2).accessibilityHidden(true)
                    }
                }
            }
        }
        .background(ProjectColor.tint(for: store.card(current)?.title ?? "").ignoresSafeArea())
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if let card = store.card(current) {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ShareLink(item: card.shareText) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("カードの内容を共有")
                    Button("編集") { editing = card }
                }
            }
        }
        .sheet(item: $editing) { card in GuideCardEditor(card: card) }
    }
}

private struct HeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// One card: its color fills the screen with the title, purpose and goal; a white sheet holding the method
/// rises over it as the person scrolls. On a wide screen the two sit side by side.
@MainActor
struct GuideCardView: View {
    @EnvironmentObject private var store: TaskStore
    @State private var headerHeight: CGFloat = 0
    let cardID: UUID
    /// Nil when shown over a task (editor, focus): the task list and adding tasks belong to the board tab.
    var onEdit: ((TaskItem) -> Void)? = nil
    var onStart: ((TaskItem) -> Void)? = nil
    var onWrite: () -> Void = {}

    var body: some View {
        if let card = store.card(cardID) {
            GeometryReader { geometry in
                if geometry.size.width >= 700 {
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView { header(card).padding(28) }.frame(width: geometry.size.width * 0.4)
                        ScrollView { sheet(card).padding(24).padding(.top, 8) }
                            .background(Color(uiColor: .systemBackground),
                                        in: UnevenRoundedRectangle(topLeadingRadius: 26, bottomLeadingRadius: 26))
                            .shadow(color: .black.opacity(0.12), radius: 14, x: -4)
                    }
                } else {
                    ZStack(alignment: .top) {
                        header(card).padding(.horizontal, 22).padding(.top, 14)
                            .background(GeometryReader { Color.clear.preference(key: HeaderHeightKey.self, value: $0.size.height) })
                        ScrollView {
                            VStack(spacing: 0) {
                                Color.clear.frame(height: headerHeight + 22)
                                VStack(alignment: .leading, spacing: 0) {
                                    Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 38, height: 4)
                                        .frame(maxWidth: .infinity).padding(.bottom, 14)
                                    sheet(card)
                                }
                                .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 60)
                                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                                .background(Color(uiColor: .systemBackground),
                                            in: UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26))
                                .shadow(color: .black.opacity(0.16), radius: 16, y: -6)
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                    .onPreferenceChange(HeaderHeightKey.self) { headerHeight = $0 }
                }
            }
        } else {
            ContentUnavailableView("このカードはありません", systemImage: "book.closed",
                                   description: Text("削除されたか、取り消しで元に戻りました。"))
        }
    }

    private func header(_ card: BoardCard) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(card.title).font(.system(size: 32, weight: .bold)).fixedSize(horizontal: false, vertical: true)
            if !card.purpose.isEmpty { row("目的", card.purpose) }
            if !card.goal.isEmpty { row("ゴール", card.goal) }
            row("作成", card.createdAt.formatted(.dateTime.year().month().day()))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(Color.primary.opacity(0.55))
            Text(value).font(.subheadline.weight(.medium)).lineSpacing(3).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func sheet(_ card: BoardCard) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                // Small label underlined in the card's color, as on the original board.
                Text("やり方").font(.caption.weight(.bold)).tracking(2).foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(ProjectColor.color(for: card.title) ?? Palette.accent).frame(height: 2.5)
                    }
                if card.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("手順やコツを書いておくと、タスクを始めるときにすぐ見返せます。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("書き始める", systemImage: "square.and.pencil", action: onWrite).buttonStyle(.borderedProminent)
                } else {
                    Text(card.detail).font(.system(size: 15)).lineSpacing(6).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let onEdit, let onStart { tasksSection(card, onEdit: onEdit, onStart: onStart) }
        }
    }

    @ViewBuilder private func tasksSection(_ card: BoardCard, onEdit: @escaping (TaskItem) -> Void,
                                           onStart: @escaping (TaskItem) -> Void) -> some View {
        let tasks = store.linkedTasks(for: card)
        let open = tasks.filter { !$0.isComplete }
            .sorted { ($0.plannedAt ?? .distantFuture) < ($1.plannedAt ?? .distantFuture) }
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(title: "このカードのタスク", subtitle: "プロジェクト名が「\(card.title)」に当たる未完了のタスク")
            if open.isEmpty {
                Text("未完了のタスクはありません。").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(open) { task in
                VStack(alignment: .leading, spacing: 4) {
                    Text(GuideSummary.place(task)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    AgendaRow(item: AgendaItem(task: task), onOpen: { _ in onEdit(task) }, onStart: onStart)
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
