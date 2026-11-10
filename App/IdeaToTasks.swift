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
    /// The project every task made here goes into: an idea often becomes a step of something bigger.
    @State private var project = ""
    @State private var detailsOpen = false
    @State private var guide: GuideRoute?
    /// A draft opened in the full editor, and how many were saved from there.
    @State private var detailed: TaskItem?
    @State private var detailedDraft: UUID?
    @State private var detailedTask: UUID?
    @State private var savedTaskIDs: [UUID] = []
    @State private var startError: String?
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
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    originNote
                    VStack(alignment: .leading, spacing: 10) {
                        Text(drafts.count > 1 ? "作るタスク" : "最初の一手").font(.headline)
                        ForEach($drafts) { $draft in titleRow($draft) }
                        if drafts.isEmpty, !savedTaskIDs.isEmpty {
                            Label("\(savedTaskIDs.count)件のタスクを追加しました", systemImage: "checkmark.circle")
                                .font(.subheadline).foregroundStyle(Palette.accent)
                        }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Button { withAnimation(.snappy) { detailsOpen.toggle() } } label: {
                            HStack {
                                Text("詳しく決める").font(.subheadline.weight(.semibold))
                                Spacer()
                                Image(systemName: "chevron.down").font(.footnote.weight(.semibold))
                                    .rotationEffect(.degrees(detailsOpen ? 180 : 0))
                            }
                            .frame(minHeight: 24).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).foregroundStyle(Palette.accent)
                        .accessibilityIdentifier("ideaTaskDetails")
                        .accessibilityValue(detailsOpen ? "開いています" : "閉じています")
                        if detailsOpen { advancedOptions }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color(uiColor: .secondarySystemGroupedBackground)))
                }
                .padding(20)
            }
            .background(Palette.paper)
            .safeAreaInset(edge: .bottom, spacing: 0) { actions }
            .navigationTitle("タスクにする").keyboardDismissable().navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(savedTaskIDs.isEmpty ? "キャンセル" : "閉じる") { dismiss() }
                }
            }
            .sheet(item: $detailed, onDismiss: afterEditor) { task in TaskEditor(task: task, original: nil) }
            .sheet(item: $guide) { route in GuideSheet(cardID: route.id) }
        }
        .alert("開始できません", isPresented: Binding(
            get: { startError != nil }, set: { if !$0 { startError = nil } }
        )) { Button("閉じる", role: .cancel) { startError = nil } } message: { Text(startError ?? "") }
        .storeErrorAlert()
    }

    private var originNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("元のアイデア").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(idea.text).font(.body.weight(.semibold)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14).fill(StickyColor.palette[0].paper))
                .foregroundStyle(StickyColor.palette[0].ink)
        }
    }

    private func titleRow(_ draft: Binding<Draft>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                TextField("最初に何をする？", text: draft.title, axis: .vertical).font(.body.weight(.medium))
                    .lineLimit(1...3).focused($focused, equals: draft.wrappedValue.id)
                    .accessibilityIdentifier("ideaFirstStep")
                if drafts.count > 1 {
                    Button { withAnimation { drafts.removeAll { $0.id == draft.wrappedValue.id } } } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless).accessibilityLabel("このタスクをやめる")
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .secondarySystemGroupedBackground)))
            if draft.wrappedValue.when != .anytime {
                Text(placementLabel(draft.wrappedValue)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func placementLabel(_ draft: Draft) -> String {
        let day: String
        switch draft.when {
        case .today: day = "今日"
        case .tomorrow: day = "明日"
        case .other: day = draft.day.formatted(.dateTime.month(.defaultDigits).day())
        case .anytime: day = "いつでも"
        }
        return day + (draft.slot.map { " · \($0.label)" } ?? "")
    }

    private var advancedOptions: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach($drafts) { $draft in draftOptions($draft) }
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
            Divider()
            ProjectPicker(project: $project) { guide = GuideRoute(id: $0.id) }
            Toggle("アイデアを残す", isOn: $keepIdea)
            Text(keepIdea ? "付箋を残し、あとで続きのタスクも作れます。" : "追加すると付箋は一覧から外れます。元の内容もタスクに引き継ぎます。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.top, 14)
    }

    private func draftOptions(_ draft: Binding<Draft>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if drafts.count > 1 { Text(draft.wrappedValue.title).font(.subheadline.weight(.semibold)) }
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
            Button("締切・子タスクなども決める", systemImage: "square.and.pencil") { openEditor(draft.wrappedValue) }
                .font(.subheadline).buttonStyle(.borderless)
                .disabled(draft.wrappedValue.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.vertical, 4)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Text(ready.count > 1 ? "\(ready.count)件を追加して、最初のタスクを始めます。" : "元のアイデアやメモも引き継ぎます。")
                .font(.footnote).foregroundStyle(.secondary)
            StepActionButton(title: ready.isEmpty ? "始める" : "作って始める", prominent: true, systemImage: "play.fill") { make(start: true) }
                .disabled(ready.isEmpty && savedTaskIDs.isEmpty)
                .accessibilityIdentifier("createIdeaTaskAndStart")
            StepActionButton(title: ready.isEmpty ? "閉じる" : "タスクを追加", prominent: false) { make(start: false) }
                .disabled(ready.isEmpty && savedTaskIDs.isEmpty)
                .accessibilityIdentifier("addIdeaTaskOnly")
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 12)
        .background(Palette.paper)
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
        task.project = project.trimmingCharacters(in: .whitespacesAndNewlines)
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
            savedTaskIDs.append(taskID)
            withAnimation { drafts.removeAll { $0.id == draftID } }
        }
    }

    private func make(start: Bool) {
        var tasks = ready.map(task(from:))
        // Notebook.makeTasks gives the first replacement the idea's stable identity. Assign that
        // identity before saving as well, so routing and retries refer to the record actually saved.
        // If an unrelated task already owns that ID, core keeps the draft's fresh identity instead.
        if !keepIdea, !tasks.isEmpty, store.task(idea.id) == nil {
            tasks[0].id = idea.id
        }
        let firstID = tasks.first?.id ?? savedTaskIDs.first
        if !tasks.isEmpty {
            guard store.makeTasks(from: idea, tasks, keepIdea: keepIdea) else { return }
            savedTaskIDs.append(contentsOf: tasks.map(\.id))
            drafts = []
        } else if !keepIdea, store.idea(idea.id) != nil {
            guard store.makeTasks(from: idea, [], keepIdea: false) else { return }
        }
        if start, let firstID {
            let target = store.notebook.nextChild(of: firstID)?.id ?? firstID
            guard store.requestTaskStart(target) else {
                // This nested form owns the failure. Parent alerts must not dismiss the saved form.
                startError = store.error ?? "タスクを開始できませんでした。保存したタスクを確認してください。"
                store.error = nil
                return
            }
        }
        dismiss()
    }
}
