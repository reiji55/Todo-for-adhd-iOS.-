import SwiftUI

/// Tasks without a day yet: those not on any day, and tasks in pieces none of whose open pieces has one.
/// What is due (today or before) is left out; it stands at the top of the timetable already.
enum UndatedTasks {
    static func list(_ book: Notebook, now: Date = Date()) -> [TaskItem] {
        let board = TaskBoard()
        let parents = book.parentIDs
        let datedParents = Set(book.tasks.filter { !$0.isComplete && $0.plannedAt != nil }.compactMap(\.parentID))
        return book.tasks.filter { task in
            guard !task.isComplete, !task.isEvent, task.parentID == nil, !board.isObligation(task, now: now) else { return false }
            return parents.contains(task.id) ? !datedParents.contains(task.id) : task.plannedAt == nil
        }
    }
}

/// At the foot of today's timetable: how many tasks have no day yet. A tap opens them (the sheet hangs on the
/// timetable itself), each with 今日へ: the same tasks as in すべて, here to pick what to bring into today.
@MainActor
struct UndatedTasksLink: View {
    @EnvironmentObject private var store: TaskStore
    let onTap: () -> Void

    var body: some View {
        let count = UndatedTasks.list(store.notebook).count
        if count > 0 {
            Button(action: onTap) {
                HStack(spacing: 4) {
                    Text("日付未確定のタスク")
                    Text("\(count)件").fontWeight(.bold).foregroundStyle(Palette.accent).monospacedDigit()
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(Palette.accent)
                }
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("日付未確定のタスク \(count)件")
            .accessibilityIdentifier("undatedTasks")
        }
    }
}

/// The tasks without a day, by project (those without one first), each with 今日へ. A task waiting for the one
/// before it in a つながり has none.
@MainActor
struct UndatedTasksSheet: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    let onOpen: (AgendaItem) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                let tasks = UndatedTasks.list(store.notebook)
                LazyVStack(alignment: .leading, spacing: 8) {
                    Text("「今日へ」で、今日の時間割の「時間を決めていない」に入ります。")
                        .font(.caption).foregroundStyle(.secondary)
                    if tasks.isEmpty {
                        ContentUnavailableView("日付未確定のタスクはありません", systemImage: "checkmark.circle")
                    }
                    ForEach(AllTasksView.folds(tasks), id: \.name) { fold in
                        HStack(spacing: 8) {
                            Circle().fill(ProjectColor.color(for: store.colorName(forProject: fold.name)) ?? Color.secondary.opacity(0.5))
                                .frame(width: 9, height: 9)
                            Text(fold.name.isEmpty ? "プロジェクトなし" : fold.name).font(.subheadline.weight(.bold)).lineLimit(1)
                            Text("\(fold.tasks.count)件").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(.top, 10)
                        ForEach(fold.tasks) { task in
                            if store.hasChildren(task.id) {
                                ParentTaskCard(parent: task) { onOpen(AgendaItem(task: $0)) }
                            } else {
                                AgendaRow(item: AgendaItem(task: task),
                                          onToday: store.notebook.isWaiting(task) ? nil : { store.putOnToday(task) },
                                          onOpen: onOpen)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Palette.paper)
            .navigationTitle("日付未確定のタスク")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
