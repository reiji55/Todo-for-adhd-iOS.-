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

/// Capture first, details later: a title is enough. Task or event is switched at the top; the day
/// starts open (いつでも) and, once one is picked, a time can be dialed in. 追加 saves and closes,
/// leaving a note with 取り消す on the screen underneath.
@MainActor
struct QuickAddSheet: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    @State private var isEvent: Bool
    @State private var title = ""
    @State private var day: Date?
    @State private var slot: TimeSlot?
    @State private var details: TaskItem?
    @State private var pendingID: UUID?
    @State private var detent: PresentationDetent = .medium
    @FocusState private var focused: Bool

    init(day: Date? = nil, isEvent: Bool = false) {
        _isEvent = State(initialValue: isEvent)
        // An event always happens on some day; a task can wait without one.
        _day = State(initialValue: day.map { Calendar.current.startOfDay(for: $0) } ?? (isEvent ? Calendar.current.startOfDay(for: Date()) : nil))
    }

    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(isEvent ? "予定（例：友達に会う）" : "やること", text: $title, axis: .vertical)
                        .font(.title3).lineLimit(1...4).focused($focused)
                        .submitLabel(.done).onSubmit(add)
                }
                Section {
                    OptionalDateRow(title: "日付", date: $day, placeholder: "未定（いつでも）", clearable: !isEvent,
                                    onExpand: { detent = .large })
                    if day != nil {
                        TimeDialRow(slot: $slot, placeholder: isEvent ? "終日" : "未定", onExpand: { detent = .large })
                    }
                }
                Section {
                    Button("くわしく書く", systemImage: "square.and.pencil") { details = makeTask() }
                        .font(.subheadline)
                }
            }
            .keyboardDismissable().navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    Picker("種類", selection: $isEvent) {
                        Text("タスク").tag(false)
                        Text("イベント").tag(true)
                    }
                    .pickerStyle(.segmented).frame(width: 170)
                }
                ToolbarItem(placement: .confirmationAction) { Button("追加", action: add).disabled(trimmed.isEmpty) }
            }
            .onChange(of: isEvent) { _, event in
                if event && day == nil { day = Calendar.current.startOfDay(for: Date()) }
            }
            .onChange(of: day) { _, day in if day == nil { slot = nil } }
            .onAppear { focused = true }
            // Saved from the full editor: that was the adding, so this sheet closes too.
            .sheet(item: $details, onDismiss: {
                if let id = pendingID, store.task(id) != nil { dismiss() }
                pendingID = nil
            }) { task in
                TaskEditor(task: task, original: nil).onAppear { pendingID = task.id }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .storeErrorAlert()
    }

    private func makeTask() -> TaskItem {
        var task = TaskItem(title: trimmed, plannedAt: day, isEvent: isEvent)
        if day != nil { task.slot = slot }
        return task
    }

    private func add() {
        guard !trimmed.isEmpty else { return }
        let added = trimmed
        if store.upsert(makeTask()) {
            store.offerUndo("「\(added)」を追加しました")
            dismiss()
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
                } footer: { Text("アイデアはタスクの候補や一覧には混ざりません。あとでタスクにできます。").onlyInDemo() }
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
