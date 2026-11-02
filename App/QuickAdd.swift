import SwiftUI

/// The four kinds of things Horme holds. The ⊕ button asks which one first.
enum AddKind: String, CaseIterable, Identifiable {
    case task, event, routine, idea
    var id: String { rawValue }
    var title: String {
        switch self {
        case .task: return "タスク"
        case .event: return "イベント"
        case .routine: return "ルーティン"
        case .idea: return "アイデア"
        }
    }
    var detail: String {
        switch self {
        case .task: return "その日にやること、単発で終わること"
        case .event: return "その日にある予定（買い物、人に会う）"
        case .routine: return "くり返しやること"
        case .idea: return "やるかはまだ決めていない思いつき"
        }
    }
    var icon: String {
        switch self {
        case .task: return "checkmark.circle"
        case .event: return "calendar"
        case .routine: return "arrow.triangle.2.circlepath"
        case .idea: return "lightbulb"
        }
    }
}

/// Capture first, details later: a title is enough, and the sheet stays open for the next one.
/// Used for tasks and events; events always have a day and no checkbox.
@MainActor
struct QuickAddSheet: View {
    enum When: Hashable { case today, tomorrow, other, anytime }
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    let isEvent: Bool
    @State private var title = ""
    @State private var when: When
    @State private var otherDay: Date
    @State private var slot: TimeSlot?
    @State private var added: [String] = []
    @State private var details: TaskItem?
    @State private var pendingID: UUID?
    @FocusState private var focused: Bool

    init(day: Date? = nil, isEvent: Bool = false) {
        self.isEvent = isEvent
        let calendar = Calendar.current
        _otherDay = State(initialValue: day ?? Date())
        if let day, !calendar.isDateInToday(day) {
            _when = State(initialValue: calendar.isDateInTomorrow(day) ? .tomorrow : .other)
        } else { _when = State(initialValue: .today) }
    }

    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(isEvent ? "予定（例：友達に会う）" : "やること", text: $title, axis: .vertical)
                        .font(.title3).lineLimit(1...4).focused($focused)
                        .submitLabel(.done).onSubmit(add)
                    Picker("いつ", selection: $when) {
                        Text("今日").tag(When.today)
                        Text("明日").tag(When.tomorrow)
                        Text("別の日").tag(When.other)
                        if !isEvent { Text("いつでも").tag(When.anytime) }
                    }.pickerStyle(.segmented)
                    if when == .other {
                        DatePicker("日付", selection: $otherDay, displayedComponents: .date)
                    }
                    if when != .anytime { TimeSlotFields(slot: $slot) }
                } footer: {
                    if !added.isEmpty {
                        Text("追加しました：\(added.suffix(3).joined(separator: "、"))").foregroundStyle(Palette.accent)
                    } else if isEvent {
                        Text("時間を決めなければ終日の予定になります。")
                    }
                }
                Section {
                    Button(isEvent ? "場所やメモも書く" : "必須・締切・工程も書く", systemImage: "square.and.pencil") { details = makeTask() }
                }
            }
            .navigationTitle(isEvent ? "イベントを追加" : "タスクを追加").keyboardDismissable().navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("追加", action: add).disabled(trimmed.isEmpty) }
            }
            .onAppear { focused = true }
            // Once saved from the full editor, clear the line so it is not added twice.
            .sheet(item: $details, onDismiss: {
                if let id = pendingID, store.task(id) != nil { added.append(trimmed); title = ""; slot = nil }
                pendingID = nil
            }) { task in
                TaskEditor(task: task, original: nil).onAppear { pendingID = task.id }
            }
        }
        .presentationDetents([.medium, .large])
        .storeErrorAlert()
    }

    private var day: Date? {
        switch when {
        case .today: return Date()
        case .tomorrow: return Calendar.current.date(byAdding: .day, value: 1, to: Date())
        case .other: return otherDay
        case .anytime: return nil
        }
    }

    private func makeTask() -> TaskItem {
        var task = TaskItem(title: trimmed, plannedAt: day, isEvent: isEvent)
        if day != nil { task.slot = slot }
        return task
    }

    private func add() {
        guard !trimmed.isEmpty else { return }
        if store.upsert(makeTask()) {
            added.append(trimmed)
            title = ""
            focused = true
        }
    }
}

/// Writing down an idea from the ⊕ button, without leaving the current screen.
@MainActor
struct IdeaQuickSheet: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("思いついたこと", text: $text, axis: .vertical).lineLimit(3...10).focused($focused)
                } footer: { Text("アイデアはタスクの候補や一覧には混ざりません。あとでタスクにできます。") }
            }
            .navigationTitle("アイデアを書き留める").keyboardDismissable().navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("書き留める") {
                        if store.commit({ $0.ideas.insert(Idea(text: trimmed), at: 0) }) { dismiss() }
                    }.disabled(trimmed.isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
        .storeErrorAlert()
    }
}
