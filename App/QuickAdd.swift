import SwiftUI

/// Capture first, details later: a title is enough, and the sheet stays open for the next one.
@MainActor
struct QuickAddSheet: View {
    enum When: Hashable { case today, tomorrow, anytime, day(Date) }
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var when: When
    @State private var slot: TimeSlot?
    @State private var added: [String] = []
    @State private var details: TaskItem?
    @State private var newRoutine: Routine?
    @FocusState private var focused: Bool

    init(day: Date? = nil) {
        let calendar = Calendar.current
        if let day, !calendar.isDateInToday(day) {
            _when = State(initialValue: calendar.isDateInTomorrow(day) ? .tomorrow : .day(day))
        } else { _when = State(initialValue: .today) }
    }

    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("やること", text: $title, axis: .vertical)
                        .font(.title3).lineLimit(1...4).focused($focused)
                        .submitLabel(.done).onSubmit(add)
                    Picker("いつ", selection: $when) {
                        Text("今日").tag(When.today)
                        Text("明日").tag(When.tomorrow)
                        Text("いつでも").tag(When.anytime)
                        if case .day(let date) = when { Text(date.shortDay).tag(when) }
                    }.pickerStyle(.segmented)
                    if when != .anytime { TimeSlotFields(slot: $slot) }
                } footer: {
                    if !added.isEmpty {
                        Text("追加しました：\(added.suffix(3).joined(separator: "、"))").foregroundStyle(Palette.accent)
                    }
                }
                Section {
                    Button("必須・締切・工程も書く", systemImage: "square.and.pencil") { details = makeTask() }
                    Button("ルーティンとして追加", systemImage: "arrow.triangle.2.circlepath") {
                        newRoutine = Routine(title: trimmed, time: slot?.label ?? "")
                    }
                }
            }
            .navigationTitle("追加").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("追加", action: add).disabled(trimmed.isEmpty) }
            }
            .onAppear { focused = true }
            // Once saved from the full editor, clear the line so it is not added twice.
            .sheet(item: $details, onDismiss: { clearIfSaved(store.task(pendingID ?? UUID()) != nil) }) { task in
                TaskEditor(task: task, original: nil).onAppear { pendingID = task.id }
            }
            .sheet(item: $newRoutine, onDismiss: { clearIfSaved(store.routine(pendingID ?? UUID()) != nil) }) { routine in
                RoutineEditor(routine: routine).onAppear { pendingID = routine.id }
            }
        }
        .presentationDetents([.medium, .large])
        .storeErrorAlert()
    }

    @State private var pendingID: UUID?

    private func clearIfSaved(_ saved: Bool) {
        if saved { added.append(trimmed); title = ""; slot = nil }
        pendingID = nil
    }

    private var day: Date? {
        switch when {
        case .today: return Date()
        case .tomorrow: return Calendar.current.date(byAdding: .day, value: 1, to: Date())
        case .anytime: return nil
        case .day(let date): return date
        }
    }

    private func makeTask() -> TaskItem {
        var task = TaskItem(title: trimmed, plannedAt: day)
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
