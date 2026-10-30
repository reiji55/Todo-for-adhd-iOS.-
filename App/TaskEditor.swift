import SwiftUI

@MainActor
struct TaskEditor: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    @State var task: TaskItem
    /// The saved task when editing began, for merging with changes synced from other devices meanwhile.
    let original: TaskItem?
    @State private var newStep = ""
    @State private var showDelete = false
    @State private var confirmDiscard = false
    @State private var guide: GuideRoute?
    /// What the form showed when it opened, to tell whether anything was typed.
    private let initial: TaskItem

    init(task: TaskItem, original: TaskItem?) {
        self.original = original
        initial = task
        _task = State(initialValue: task)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("タスク名", text: $task.title, axis: .vertical)
                        .font(.headline).lineLimit(1...5)
                    Toggle("必須にする", isOn: $task.isMust).tint(Palette.must)
                } footer: {
                    Text("必須は予定日が来たら上段に表示。日付なしなら今日から表示します。")
                }
                Section("いつやるか") {
                    Toggle("予定日を決める", isOn: Binding(
                        get: { task.plannedAt != nil }, set: { task.plannedAt = $0 ? (task.plannedAt ?? Date()) : nil }
                    ))
                    if task.plannedAt != nil {
                        DatePicker("予定日", selection: Binding(
                            get: { task.plannedAt ?? Date() }, set: { task.plannedAt = $0 }
                        ), displayedComponents: .date)
                        HStack {
                            Button("今日") { task.plannedAt = Date() }
                            Spacer()
                            Button("明日") { task.plannedAt = Calendar.current.date(byAdding: .day, value: 1, to: Date()) }
                        }.buttonStyle(.borderless)
                    }
                    if task.plannedAt != nil {
                        TimeSlotFields(slot: $task.slot, legacyLabel: task.scheduledTime) { task.scheduledTime = "" }
                    }
                }
                Section {
                    Toggle("締切がある", isOn: Binding(
                        get: { task.deadline != nil }, set: { task.deadline = $0 ? (task.deadline ?? Date()) : nil }
                    ))
                    if task.deadline != nil {
                        DatePicker("締切日", selection: Binding(
                            get: { task.deadline ?? Date() }, set: { task.deadline = $0 }
                        ), displayedComponents: .date)
                    }
                } footer: { Text("予定日を変えても締切は変わりません。締切日になったら必ず上段に表示します。") }
                if (task.plannedAt != nil && task.slot != nil) || task.deadline != nil {
                    Section {
                        Toggle("通知", isOn: $task.notify)
                    } footer: { Text("始まる時刻と締切の日の朝にバナーで知らせます。タイミングは設定で変えられます。") }
                }
                Section {
                    ForEach($task.steps) { $step in
                        HStack {
                            Button { step.isDone.toggle() } label: {
                                Image(systemName: step.isDone ? "checkmark.circle.fill" : "circle").frame(width: 36, height: 44)
                            }.buttonStyle(.borderless).accessibilityLabel(step.isDone ? "工程を未完了に戻す" : "工程を完了")
                            TextField("次にすること", text: $step.title, axis: .vertical)
                                .strikethrough(step.isDone)
                        }
                    }.onDelete { task.steps.remove(atOffsets: $0) }
                        .onMove { task.steps.move(fromOffsets: $0, toOffset: $1) }
                    HStack {
                        TextField("一手を足す（任意）", text: $newStep).onSubmit(addStep)
                        Button(action: addStep) { Image(systemName: "plus.circle").frame(width: 44, height: 44) }
                            .buttonStyle(.borderless).disabled(newStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel("工程を追加")
                    }
                } header: { HStack { Text("次の一手・工程"); Spacer(); EditButton().font(.caption) } }
                footer: { Text("未完了の先頭を次の一手として表示。空のままでも、タスク名からすぐに始められます。") }
                Section("続きに戻るためのメモ") {
                    TextField("どこまで進んだ？", text: $task.resumeNote, axis: .vertical).lineLimit(2...6)
                }
                Section {
                    TextField("このタスクについて覚えておきたいこと", text: $task.memo, axis: .vertical).lineLimit(3...12)
                    if let card = store.linkedCard(for: task) {
                        Button { guide = GuideRoute(id: card.id) } label: {
                            Label("ボードのやり方：\(card.title)", systemImage: "book")
                        }
                    }
                } header: { Text("メモ") }
                footer: {
                    Text(store.linkedCard(for: task) == nil
                         ? "繰り返し使う手順は、ボードのカードに書いてプロジェクトで結ぶと、どのタスクからも開けます。"
                         : "手順はボードのカードにあります。このタスクだけのことはメモへ。")
                }
                Section {
                    TextField("AIに頼みたいこと", text: $task.handoff, axis: .vertical).lineLimit(2...8)
                    if !task.handoff.isEmpty {
                        ShareLink(item: "\(task.title)\n\n\(task.handoff)") {
                            Label("引き継ぎを共有", systemImage: "square.and.arrow.up")
                        }
                    }
                } header: { Text("AIへの引き継ぎ") }
                footer: { Text("内容を保存して共有できます。AIへの自動送信はありません。") }
                Section("任意の属性") {
                    HStack {
                        TextField("プロジェクト", text: $task.project)
                        if !store.notebook.boardCards.isEmpty {
                            Menu {
                                ForEach(store.notebook.boardCards) { card in
                                    Button(card.title) { task.project = card.title }
                                }
                            } label: { Image(systemName: "book").frame(width: 44, height: 44) }
                                .accessibilityLabel("ボードのカードから選ぶ")
                        }
                    }
                    Picker("取り組む負荷", selection: $task.effort) {
                        ForEach(Effort.allCases) { Text($0.label).tag($0) }
                    }
                    if task.suggestionDeferredUntil.map({ $0 > Date() }) == true {
                        Button("候補の「あとで」を解除") { task.suggestionDeferredUntil = nil }
                    }
                }
                if store.task(task.id) != nil {
                    Section { Button("このタスクを削除", role: .destructive) { showDelete = true } }
                }
            }
            .navigationTitle(store.task(task.id) == nil ? "タスクを追加" : "タスクを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { if changed { confirmDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        task.steps = task.steps.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        addStep()
                        if store.upsert(task, original: original) { dismiss() }
                    }.disabled(task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("このタスクを削除しますか？", isPresented: $showDelete, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    store.delete(task.id)
                    if store.task(task.id) == nil { dismiss() }
                }
            }
            // A swipe down must not silently drop what was typed.
            .interactiveDismissDisabled(changed)
            .sheet(item: $guide) { route in GuideSheet(cardID: route.id) }
        }
        .confirmationDialog("編集した内容を破棄しますか？", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("破棄して閉じる", role: .destructive) { dismiss() }
        }
        .storeErrorAlert()
    }
    private var changed: Bool { task != initial || !newStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func addStep() {
        let title = newStep.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        task.steps.append(Step(title: title)); newStep = ""
    }
}

@MainActor
struct FocusView: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var note = ""
    @State private var lastLoadedID: UUID?
    @State private var followUp: TaskItem?

    var body: some View {
        NavigationStack {
            if let session = store.notebook.activeSession, let task = store.task(session.taskID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text(task.title).font(.subheadline).foregroundStyle(.secondary)
                        Text(actionTitle(task, session: session)).font(.largeTitle.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text("経過 \(max(0, Int(context.date.timeIntervalSince(session.startedAt) / 60)))分")
                                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if let card = store.linkedCard(for: task) {
                            // The method is what people forget mid-task; keep it one tap away.
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 12) {
                                    if !card.goal.isEmpty { Text("ゴール：\(card.goal)").font(.subheadline.weight(.medium)) }
                                    if !card.detail.isEmpty { Text(card.detail).textSelection(.enabled) }
                                    if card.isBlank { Text("このカードにはまだ何も書いていません。").foregroundStyle(.secondary) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                            } label: { Label("やり方：\(card.title)", systemImage: "book") }
                        }
                        if !task.memo.isEmpty {
                            DisclosureGroup("メモ") { Text(task.memo).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8) }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("続きのメモ（任意）").font(.headline)
                            TextField("どこまで進んだ？ 次はどこから？", text: $note, axis: .vertical)
                                .lineLimit(3...8).padding().background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
                            Text("別のタスクに移っても、このメモは残ります。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button { finish(task, session: session) } label: {
                            Label(session.stepID == nil ? "タスクを完了" : "この一手を完了", systemImage: "checkmark")
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                        Button {
                            if store.pause(note: note) { dismiss() }
                        } label: { Text("ここで中断する").frame(maxWidth: .infinity).padding(.vertical, 8) }
                            .buttonStyle(.bordered).controlSize(.large)
                    }.padding(24)
                }
                .navigationTitle("今やるひとつ").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("一覧へ") { dismiss() } } }
                .onAppear { loadNote(task) }
                .onChange(of: session.taskID) { _, _ in loadNote(task) }
            } else {
                ContentUnavailableView("取り組み中のタスクはありません", systemImage: "checkmark.circle")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
            }
        }
        .confirmationDialog(followUp?.nextStep == nil ? "工程がすべて終わりました" : "一手が終わりました", isPresented: Binding(
            get: { followUp != nil }, set: { if !$0 { followUp = nil } }
        ), titleVisibility: .visible, presenting: followUp) { task in
            if let next = task.nextStep {
                Button("続けて「\(next.title)」へ") { store.start(task) }
            } else {
                Button("タスクを完了にする") { store.complete(task.id); dismiss() }
            }
            Button("ここで一区切り", role: .cancel) { dismiss() }
        }
        // Saving once on leaving keeps the undo history free of one entry per keystroke.
        .onDisappear(perform: saveNote)
        .onChange(of: phase) { _, newPhase in if newPhase != .active { saveNote() } }
        .storeErrorAlert()
    }
    private func finish(_ task: TaskItem, session: Session) {
        guard store.finishAction() else { return }
        note = ""
        // A finished step asks what comes next instead of closing silently; a finished task just closes.
        if session.stepID != nil, let updated = store.task(task.id), !updated.isComplete { followUp = updated }
        else { dismiss() }
    }

    private func saveNote() {
        guard let id = lastLoadedID, store.notebook.activeSession?.taskID == id,
              let task = store.task(id), note != task.resumeNote else { return }
        store.change(id) { $0.resumeNote = note }
    }
    private func loadNote(_ task: TaskItem) { note = task.resumeNote; lastLoadedID = task.id }
    private func actionTitle(_ task: TaskItem, session: Session) -> String {
        task.steps.first(where: { $0.id == session.stepID })?.title ?? task.title
    }
}
