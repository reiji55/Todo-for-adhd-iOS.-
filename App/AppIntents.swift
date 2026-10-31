import AppIntents
import Foundation

// Actions for Shortcuts, Siri and Spotlight. They run against the same store as the app, so results
// sync through iCloud like any other edit. Reads return plain text so a shortcut can hand it to an AI.

enum HormeIntentError: Error, CustomLocalizedStringResourceConvertible {
    case saveFailed(String), notFound
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .saveFailed(let reason): return "保存できませんでした。\(reason)"
        case .notFound: return "見つかりませんでした。削除されたか、別の端末で変更された可能性があります。"
        }
    }
}

enum HormeDay: String, AppEnum {
    case today, tomorrow, anytime
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "日"
    static var caseDisplayRepresentations: [HormeDay: DisplayRepresentation] = [
        .today: "今日", .tomorrow: "明日", .anytime: "いつでも（日付なし）"
    ]
}

struct TaskEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "タスク"
    static var defaultQuery = TaskEntityQuery()
    var id: UUID
    var title: String
    var summary: String

    init(_ task: TaskItem) {
        id = task.id
        title = task.title
        summary = [task.plannedAt.map { PlainText.dayTitle($0) }, task.slot?.label, task.project.isEmpty ? nil : task.project,
                   task.isComplete ? "完了" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: summary.isEmpty ? nil : "\(summary)")
    }
}

struct TaskEntityQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [TaskEntity] {
        TaskStore.shared.notebook.tasks.filter { identifiers.contains($0.id) }.map(TaskEntity.init)
    }
    @MainActor func entities(matching string: String) async throws -> [TaskEntity] {
        open().filter { $0.title.localizedCaseInsensitiveContains(string) }.map(TaskEntity.init)
    }
    @MainActor func suggestedEntities() async throws -> [TaskEntity] {
        open().prefix(40).map(TaskEntity.init)
    }
    /// Unfinished tasks, today's first, so the likely choice is near the top.
    @MainActor private func open() -> [TaskItem] {
        let calendar = Calendar.current
        return TaskStore.shared.notebook.tasks.filter { !$0.isComplete }.sorted { a, b in
            let at = a.plannedAt.map { calendar.isDateInToday($0) } ?? false
            let bt = b.plannedAt.map { calendar.isDateInToday($0) } ?? false
            if at != bt { return at }
            return (a.plannedAt ?? .distantFuture) < (b.plannedAt ?? .distantFuture)
        }
    }
}

struct BoardCardEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "ボードのカード"
    static var defaultQuery = BoardCardQuery()
    var id: UUID
    var title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct BoardCardQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [BoardCardEntity] {
        TaskStore.shared.notebook.boardCards.filter { identifiers.contains($0.id) }.map { BoardCardEntity(id: $0.id, title: $0.title) }
    }
    @MainActor func entities(matching string: String) async throws -> [BoardCardEntity] {
        TaskStore.shared.notebook.boardCards.filter { BoardLink.normalized($0.title).contains(BoardLink.normalized(string)) }
            .map { BoardCardEntity(id: $0.id, title: $0.title) }
    }
    @MainActor func suggestedEntities() async throws -> [BoardCardEntity] {
        TaskStore.shared.notebook.boardCards.map { BoardCardEntity(id: $0.id, title: $0.title) }
    }
}

struct GetTodayIntent: AppIntent {
    static var title: LocalizedStringResource = "今日の予定を取得"
    static var description = IntentDescription("今日の時間割（タスクとルーティン）、今日中に必要なもの、前の日から残っているものを文章で返します。")

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = PlainText.today(Date(), book: TaskStore.shared.notebook)
        return .result(value: text, dialog: "\(text)")
    }
}

struct GetDayIntent: AppIntent {
    static var title: LocalizedStringResource = "指定した日の予定を取得"
    static var description = IntentDescription("指定した日、またはその日から数日分の予定を文章で返します。")
    @Parameter(title: "日付") var date: Date
    @Parameter(title: "日数", default: 1, inclusiveRange: (1, 31)) var days: Int

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: PlainText.week(from: date, days: days, book: TaskStore.shared.notebook))
    }
}

struct GetWeekIntent: AppIntent {
    static var title: LocalizedStringResource = "今週の予定を取得"
    static var description = IntentDescription("今日から7日分の予定と、日付を決めていないタスクを文章で返します。")

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let book = TaskStore.shared.notebook
        return .result(value: PlainText.week(from: Date(), days: 7, book: book) + "\n\n" + PlainText.anytime(book: book))
    }
}

struct AddTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "タスクを追加"
    static var description = IntentDescription("Hormeにタスクを追加します。日付を指定すると「日」より優先します。")
    @Parameter(title: "タスク名") var name: String
    @Parameter(title: "日", default: .today) var day: HormeDay
    @Parameter(title: "日付") var date: Date?
    @Parameter(title: "開始時刻") var start: Date?
    @Parameter(title: "長さ（分）", default: 60, inclusiveRange: (5, 720)) var minutes: Int
    @Parameter(title: "プロジェクト") var project: String?
    @Parameter(title: "必須", default: false) var must: Bool
    @Parameter(title: "メモ") var memo: String?

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<TaskEntity> & ProvidesDialog {
        let store = TaskStore.shared
        let calendar = Calendar.current
        let planned: Date? = date ?? {
            switch day {
            case .today: return Date()
            case .tomorrow: return calendar.date(byAdding: .day, value: 1, to: Date())
            case .anytime: return nil
            }
        }()
        var task = TaskItem(title: name.trimmingCharacters(in: .whitespacesAndNewlines), plannedAt: planned, isMust: must,
                            project: project ?? "", memo: memo ?? "")
        if planned != nil, let start { task.slot = TimeSlot(start: ClockMinutes.minutes(start), duration: minutes) }
        guard !task.title.isEmpty else { throw HormeIntentError.saveFailed("タスク名が空です。") }
        guard store.upsert(task) else { throw HormeIntentError.saveFailed(store.error ?? "") }
        let when = [planned.map { PlainText.dayTitle($0) } ?? "いつでも", task.slot?.label].compactMap { $0 }.joined(separator: " ")
        return .result(value: TaskEntity(task), dialog: "「\(task.title)」を\(when)に追加しました。")
    }
}

struct CompleteTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "タスクを完了にする"
    @Parameter(title: "タスク") var task: TaskEntity

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = TaskStore.shared
        guard let current = store.task(task.id) else { throw HormeIntentError.notFound }
        if !current.isComplete { store.complete(current.id) }
        return .result(dialog: "「\(current.title)」を完了にしました。")
    }
}

struct MoveTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "タスクの日時を変える"
    static var description = IntentDescription("タスクを別の日・時刻に動かします。締切は変わりません。")
    @Parameter(title: "タスク") var task: TaskEntity
    @Parameter(title: "日付") var date: Date
    @Parameter(title: "開始時刻") var start: Date?
    @Parameter(title: "長さ（分）") var minutes: Int?

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = TaskStore.shared
        guard let current = store.task(task.id) else { throw HormeIntentError.notFound }
        let slot = start.map { TimeSlot(start: ClockMinutes.minutes($0), duration: minutes ?? current.slot?.duration ?? 60) }
        store.move(AgendaItem(task: current), to: date, slot: slot)
        return .result(dialog: "「\(current.title)」を\(PlainText.dayTitle(date))\(slot.map { " " + $0.label } ?? "")に動かしました。")
    }
}

struct AddIdeaIntent: AppIntent {
    static var title: LocalizedStringResource = "アイデアを書き留める"
    @Parameter(title: "内容") var text: String

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = TaskStore.shared
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HormeIntentError.saveFailed("内容が空です。") }
        guard store.commit({ $0.ideas.insert(Idea(text: trimmed), at: 0) }) else { throw HormeIntentError.saveFailed(store.error ?? "") }
        return .result(dialog: "アイデアに書き留めました。")
    }
}

struct ReadCardIntent: AppIntent {
    static var title: LocalizedStringResource = "ボードのやり方を読む"
    static var description = IntentDescription("ボードのカードの目的・ゴール・やり方を文章で返します。")
    @Parameter(title: "カード") var card: BoardCardEntity

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let found = TaskStore.shared.card(card.id) else { throw HormeIntentError.notFound }
        return .result(value: found.shareText)
    }
}

struct HormeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetTodayIntent(), phrases: ["\(.applicationName)で今日の予定", "\(.applicationName)の今日の予定を見る"],
                    shortTitle: "今日の予定", systemImageName: "sun.max")
        AppShortcut(intent: AddTaskIntent(), phrases: ["\(.applicationName)にタスクを追加", "\(.applicationName)でタスクを追加"],
                    shortTitle: "タスクを追加", systemImageName: "plus.circle")
        AppShortcut(intent: AddIdeaIntent(), phrases: ["\(.applicationName)にアイデアを書き留める"],
                    shortTitle: "アイデアを書き留める", systemImageName: "tray.and.arrow.down")
        AppShortcut(intent: GetWeekIntent(), phrases: ["\(.applicationName)で今週の予定"],
                    shortTitle: "今週の予定", systemImageName: "calendar")
    }
}
