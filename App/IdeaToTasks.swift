import SwiftUI

/// Turning an idea into tasks. The idea stays in view while it is rewritten as one or more tasks:
/// split a big one into small steps, or derive tasks while keeping the idea for later.
@MainActor
struct IdeaToTasksSheet: View {
    enum When: Hashable { case today, tomorrow, other, anytime }

    struct Draft: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var when: When = .anytime
        var day = Date()
        /// A time picked from the free time in the schedule.
        var slot: TimeSlot?
    }

    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    let idea: Idea
    @State private var drafts: [Draft]
    @State private var keepIdea: Bool
    /// A draft opened in the full editor, and how many were saved from there.
    @State private var detailed: TaskItem?
    @State private var detailedDraft: UUID?
    @State private var detailedTask: UUID?
    @State private var savedInEditor = 0
    @FocusState private var focused: UUID?

    /// With a day and time from the free-time suggestion, the first task starts there, and the idea
    /// stays by default: working on it in that time is a step, not the end of it.
    init(idea: Idea, day: Date? = nil, slot: TimeSlot? = nil, keepIdea: Bool = false) {
        self.idea = idea
        let lines = Self.lines(of: idea.text)
        var first = Draft(title: lines.first ?? idea.text)
        if let day {
            let calendar = Calendar.current
            first.when = calendar.isDateInToday(day) ? .today : calendar.isDateInTomorrow(day) ? .tomorrow : .other
            first.day = day
            first.slot = slot
        }
        _drafts = State(initialValue: [first])
        _keepIdea = State(initialValue: keepIdea)
    }

    /// The idea's lines without list marks, for splitting it one task per line.
    static func lines(of text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t　・-*•‐")) }
            .filter { !$0.isEmpty }
    }

    private var lines: [String] { Self.lines(of: idea.text) }
    private var ready: [Draft] { drafts.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    var body: some View {
        NavigationStack {
            Form {
                Section("元のアイデア") {
                    Text(idea.text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Section {
                    ForEach($drafts) { $draft in draftRow($draft) }
                    Button("タスクをもう1つ", systemImage: "plus.circle") {
                        let draft = Draft(title: "")
                        drafts.append(draft)
                        focused = draft.id
                    }
                    if lines.count > 1 && drafts.map(\.title) != lines {
                        Button("1行ずつタスクに分ける（\(lines.count)件）", systemImage: "list.bullet.indent") {
                            withAnimation { drafts = lines.map { Draft(title: $0) } }
                        }
                    }
                } header: {
                    Text("作るタスク")
                } footer: {
                    Text(savedInEditor > 0 ? "詳しく書いたタスクは \(savedInEditor)件 作成済みです。"
                         : "大きければ分けて、すぐ始められる大きさに。")
                }
                Section {
                    Toggle("アイデアを残す", isOn: $keepIdea)
                } footer: {
                    Text(keepIdea ? "残しておくと、あとでここから続きのタスクを作れます。" : "タスクを作ると、このアイデアは一覧から消えます。")
                }
            }
            .navigationTitle("タスクにする").keyboardDismissable().navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(ready.isEmpty ? "完了" : "作る（\(ready.count)件）", action: make)
                        .disabled(ready.isEmpty && savedInEditor == 0)
                }
            }
            .sheet(item: $detailed, onDismiss: afterEditor) { task in TaskEditor(task: task, original: nil) }
        }
        .storeErrorAlert()
    }

    private func draftRow(_ draft: Binding<Draft>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                TextField("タスク名", text: draft.title, axis: .vertical).font(.body.weight(.medium))
                    .lineLimit(1...3).focused($focused, equals: draft.wrappedValue.id)
                if drafts.count > 1 {
                    Button { withAnimation { drafts.removeAll { $0.id == draft.wrappedValue.id } } } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless).accessibilityLabel("このタスクをやめる")
                }
            }
            Picker("いつ", selection: draft.when) {
                Text("今日").tag(When.today)
                Text("明日").tag(When.tomorrow)
                Text("別の日").tag(When.other)
                Text("いつでも").tag(When.anytime)
            }.pickerStyle(.segmented)
            if draft.wrappedValue.when == .other {
                DatePicker("日付", selection: draft.day, displayedComponents: .date)
            }
            freeTimes(draft)
            if draft.wrappedValue.when != .anytime, let slot = draft.wrappedValue.slot {
                HStack {
                    Label(slot.label, systemImage: "clock").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.accent)
                    Spacer()
                    Button("時間を外す") { draft.wrappedValue.slot = nil }.font(.subheadline).buttonStyle(.borderless)
                }
            }
            Button("必須・締切・工程も書く", systemImage: "square.and.pencil") { openEditor(draft.wrappedValue) }
                .font(.subheadline).buttonStyle(.borderless)
                .disabled(draft.wrappedValue.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.vertical, 4)
    }

    /// The next free stretches of the schedule, one tap to put this task there.
    @ViewBuilder private func freeTimes(_ draft: Binding<Draft>) -> some View {
        let options = nextFreeSlots(now: Date(), tasks: store.notebook.tasks, routines: store.notebook.routines)
        if !options.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("空いている時間から選ぶ").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(options.indices, id: \.self) { index in
                            let option = options[index]
                            let slot = ideaWorkSlot(option.gap)
                            let picked = draft.wrappedValue.slot == slot && isDay(draft.wrappedValue, option.day)
                            Button("\(freeDayLabel(option.day)) \(slot.label)") { place(draft, on: option.day, at: slot) }
                                .font(.caption.weight(picked ? .bold : .regular)).monospacedDigit()
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .foregroundStyle(picked ? Color.white : Color.primary)
                                .background(Capsule().fill(picked ? Palette.accent : Color(uiColor: .tertiarySystemFill)))
                                .buttonStyle(.borderless)
                                .accessibilityAddTraits(picked ? .isSelected : [])
                        }
                    }
                }
            }
        }
    }

    private func isDay(_ draft: Draft, _ day: Date) -> Bool {
        let calendar = Calendar.current
        switch draft.when {
        case .today: return calendar.isDateInToday(day)
        case .tomorrow: return calendar.isDateInTomorrow(day)
        case .other: return calendar.isDate(draft.day, inSameDayAs: day)
        case .anytime: return false
        }
    }

    private func place(_ draft: Binding<Draft>, on day: Date, at slot: TimeSlot) {
        let calendar = Calendar.current
        draft.wrappedValue.when = calendar.isDateInToday(day) ? .today : calendar.isDateInTomorrow(day) ? .tomorrow : .other
        draft.wrappedValue.day = day
        draft.wrappedValue.slot = slot
    }

    private func task(from draft: Draft) -> TaskItem {
        let calendar = Calendar.current
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var day: Date?
        switch draft.when {
        case .today: day = Date()
        case .tomorrow: day = calendar.date(byAdding: .day, value: 1, to: Date())
        case .other: day = draft.day
        case .anytime: day = nil
        }
        // The idea's words stay with the task, unless the task already says the same thing.
        var memo = idea.text.trimmingCharacters(in: .whitespacesAndNewlines) == title ? "" : "アイデアから：\n\(idea.text)"
        if !idea.notes.isEmpty { memo += (memo.isEmpty ? "" : "\n") + idea.notes.map { "・\($0.text)" }.joined(separator: "\n") }
        var task = TaskItem(title: title, plannedAt: day, memo: memo)
        if day != nil { task.slot = draft.slot }
        return task
    }

    private func openEditor(_ draft: Draft) {
        let task = task(from: draft)
        detailedDraft = draft.id
        detailedTask = task.id
        detailed = task
    }

    /// Saved from the full editor: that draft is done. Cancelled: it stays in the list.
    private func afterEditor() {
        guard let draftID = detailedDraft, let taskID = detailedTask else { return }
        detailedDraft = nil; detailedTask = nil
        if store.task(taskID) != nil {
            savedInEditor += 1
            withAnimation { drafts.removeAll { $0.id == draftID } }
        }
    }

    private func make() {
        let tasks = ready.map(task(from:))
        if tasks.isEmpty {
            // Everything was written in the full editor; only the idea is left to settle.
            if keepIdea || store.makeTasks(from: idea, [], keepIdea: false) { dismiss() }
            return
        }
        if store.makeTasks(from: idea, tasks, keepIdea: keepIdea) { dismiss() }
    }
}
