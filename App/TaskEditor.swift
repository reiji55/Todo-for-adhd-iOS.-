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
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        TextField(task.isEvent ? "予定（例：友達に会う）" : "タスク名", text: $task.title, axis: .vertical)
                            .font(.headline).lineLimit(1...5)
                        if !task.isEvent {
                            // Must-do is a mark on the name, not a setting further down.
                            Button { withAnimation(.snappy) { task.isMust.toggle() } } label: {
                                Image(systemName: task.isMust ? "star.fill" : "star")
                                    .font(.title3).foregroundStyle(task.isMust ? Palette.must : Color.secondary)
                                    .frame(width: 36, height: 36).contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("必須")
                            .accessibilityAddTraits(task.isMust ? .isSelected : [])
                            .accessibilityHint("必須のものは予定日が来たら上段に出ます")
                        }
                    }
                } footer: {
                    if task.isMust { Text("★必須：予定日が来たら上段に表示。日付なしなら今日から表示します。") }
                }
                Section {
                    OptionalDateRow(title: "予定日", date: $task.plannedAt, placeholder: task.isEvent ? "今日" : "未定（いつでも）",
                                    clearable: !task.isEvent)
                    if task.plannedAt != nil {
                        TimeDialRow(slot: $task.slot, placeholder: task.isEvent ? "終日" : "未定")
                        if task.slot == nil && !task.scheduledTime.isEmpty {
                            HStack {
                                Text("以前の時間帯：\(task.scheduledTime)").foregroundStyle(.secondary)
                                Spacer()
                                Button("消す") { task.scheduledTime = "" }.buttonStyle(.borderless)
                            }
                        }
                    }
                    if !task.isEvent {
                        OptionalDateRow(title: "締切", date: $task.deadline)
                    }
                }
                if (task.plannedAt != nil && task.slot != nil) || (!task.isEvent && task.deadline != nil) {
                    Section {
                        Toggle("通知", isOn: $task.notify)
                    } footer: {
                        Text(task.isEvent ? "始まる時刻にバナーで知らせます。タイミングは設定で変えられます。"
                             : "始まる時刻と締切の日の朝にバナーで知らせます。タイミングは設定で変えられます。")
                    }
                }
                if !task.isEvent {
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
                }
                Section {
                    TextField(task.isEvent ? "場所や持ち物など" : "このタスクについて覚えておきたいこと", text: $task.memo, axis: .vertical).lineLimit(3...12)
                    if let card = store.linkedCard(for: task) {
                        Button { guide = GuideRoute(id: card.id) } label: {
                            Label("ボードのやり方：\(card.title)", systemImage: "book.closed")
                        }
                    }
                } header: { Text("メモ") }
                footer: {
                    Text(store.linkedCard(for: task) == nil
                         ? "繰り返し使う手順は、ボードのカードに書いてプロジェクトで結ぶと、どのタスクからも開けます。"
                         : "手順はボードのカードにあります。このタスクだけのことはメモへ。")
                }
                if !task.isEvent {
                Section {
                    TextField("AIに頼みたいこと", text: $task.handoff, axis: .vertical).lineLimit(2...8)
                    if !task.handoff.isEmpty {
                        ShareLink(item: "\(task.title)\n\n\(task.handoff)") {
                            Label("引き継ぎを共有", systemImage: "square.and.arrow.up")
                        }
                    }
                } header: { Text("AIへの引き継ぎ") }
                footer: { Text("内容を保存して共有できます。AIへの自動送信はありません。") }
                }
                Section("任意の属性") {
                    ProjectPicker(project: $task.project) { guide = GuideRoute(id: $0.id) }
                    if !task.isEvent { MilestonePicker(project: task.project, milestoneID: $task.milestoneID) }
                    if !task.isEvent {
                        Picker("取り組む負荷", selection: $task.effort) {
                            ForEach(Effort.allCases) { Text($0.label).tag($0) }
                        }
                    }
                    if !task.isEvent, task.suggestionDeferredUntil.map({ $0 > Date() }) == true {
                        Button("候補の「あとで」を解除") { task.suggestionDeferredUntil = nil }
                    }
                }
                if store.task(task.id) != nil {
                    Section { Button(task.isEvent ? "このイベントを削除" : "このタスクを削除", role: .destructive) { showDelete = true } }
                }
            }
            .navigationTitle("\(task.isEvent ? "イベント" : "タスク")を\(store.task(task.id) == nil ? "追加" : "編集")").keyboardDismissable()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { if changed { confirmDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        // An event is a happening on a day, not a to-do: no must or deadline.
                        if task.isEvent {
                            task.isMust = false; task.deadline = nil
                            if task.plannedAt == nil { task.plannedAt = Date() }
                        }
                        task.steps = task.steps.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        addStep()
                        if store.upsert(task, original: original) { dismiss() }
                    }.disabled(task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog(task.isEvent ? "このイベントを削除しますか？" : "このタスクを削除しますか？", isPresented: $showDelete, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    store.delete(task.id)
                    if store.task(task.id) == nil { dismiss() }
                }
            }
            // A swipe down must not silently drop what was typed.
            .interactiveDismissDisabled(changed)
            .sheet(item: $guide) { route in GuideSheet(cardID: route.id) }
            // A checkpoint belongs to one project; moving the task to another one lets go of it.
            .onChange(of: task.project) { _, project in
                task.milestoneID = MilestonePicker.fitting(task.milestoneID, project: project, in: store.notebook)
            }
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
                        // A pomodoro-style dial: time spent against the task's planned length (one pomodoro if none).
                        // Finishing and stopping sit right beside it, where the eyes already are.
                        HStack(spacing: 12) {
                            ElapsedTimer(start: session.startedAt, minutes: plannedMinutes(task.slot), size: 60)
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let elapsed = context.date.timeIntervalSince(session.startedAt)
                                let planned = plannedMinutes(task.slot)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("経過").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Text(ElapsedTimer.clock(elapsed)).font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                                    if elapsed >= Double(planned * 60) {
                                        Text("予定の\(planned)分を\(Int(elapsed / 60) - planned)分こえています")
                                            .font(.caption.weight(.semibold)).foregroundStyle(.red)
                                    } else {
                                        Text(task.slot == nil ? "目安 \(planned)分" : "予定 \(planned)分")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .accessibilityElement(children: .combine)
                            Spacer(minLength: 0)
                            FocusRoundButton(title: "中断", systemImage: "pause.fill", prominent: false) {
                                if store.pause(note: note) { dismiss() }
                            }
                            .accessibilityHint("ここで手を止めて一覧へ戻ります。続きのメモは残ります")
                            FocusRoundButton(title: "完了", systemImage: "checkmark", prominent: true) {
                                finish(task, session: session)
                            }
                            .accessibilityLabel(session.stepID == nil ? "タスクを完了" : "この一手を完了")
                        }
                        if let card = store.linkedCard(for: task) {
                            // The method is what people forget mid-task; keep it one tap away.
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 12) {
                                    if !card.goal.isEmpty { Text("ゴール：\(card.goal)").font(.subheadline.weight(.medium)) }
                                    if !card.detail.isEmpty { Text(card.detail).textSelection(.enabled) }
                                    if card.isBlank { Text("このカードにはまだ何も書いていません。").foregroundStyle(.secondary) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                            } label: { Label("やり方：\(card.title)", systemImage: "book.closed") }
                        }
                        if !task.memo.isEmpty {
                            DisclosureGroup("メモ") { Text(task.memo).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8) }
                        }
                        // Last, and quiet: only needed when stopping partway.
                        VStack(alignment: .leading, spacing: 6) {
                            Text("続きのメモ（任意）").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            TextField("どこまで進んだ？ 次はどこから？", text: $note, axis: .vertical)
                                .lineLimit(2...8).padding(12).background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .padding(.top, 8)
                    }.padding(24)
                }
                .navigationTitle("今やるひとつ").keyboardDismissable().navigationBarTitleDisplayMode(.inline)
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

/// A round button beside the focus timer, its word under it.
private struct FocusRoundButton: View {
    let title: String
    let systemImage: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.title3.weight(.bold))
                    .foregroundStyle(prominent ? Color.white : Palette.accent)
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(prominent ? Palette.accent : Palette.accent.opacity(0.14)))
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(prominent ? Palette.accent : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
