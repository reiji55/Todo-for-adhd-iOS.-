import SwiftUI

/// Editing one task or event. A task can be split into pieces (子タスク) here: each piece has its own
/// day and time and is checked off on its own, and the task keeps only its deadline and ★. A piece
/// opened by itself shows which task it belongs to and has only its day, time and notes.
@MainActor
struct TaskEditor: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    @State var task: TaskItem
    /// The saved task when editing began, for merging with changes synced from other devices meanwhile.
    let original: TaskItem?
    /// The task's pieces as being edited, saved together with it.
    @State private var pieces: [TaskItem]
    @State private var removedPieces: Set<UUID> = []
    @State private var newPiece = ""
    @State private var timing: PieceRef?
    @State private var showDelete = false
    @State private var confirmDiscard = false
    @State private var guide: GuideRoute?
    /// What the form showed when it opened, to tell whether anything was typed.
    private let initial: TaskItem
    private let initialPieces: [TaskItem]

    init(task: TaskItem, original: TaskItem?) {
        self.original = original
        initial = task
        _task = State(initialValue: task)
        let saved = TaskStore.shared.children(of: task.id)
        initialPieces = saved
        _pieces = State(initialValue: saved)
    }

    private var isPiece: Bool { task.parentID != nil }
    private var isWhole: Bool { !pieces.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                if isPiece, let parent = task.parentID.flatMap({ store.task($0) }) {
                    Section {
                        Label("「\(parent.title)」の子タスク", systemImage: "arrow.turn.down.right")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Section {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        TextField(task.isEvent ? "予定（例：友達に会う）" : "タスク名", text: $task.title, axis: .vertical)
                            .font(.headline).lineLimit(1...5)
                        if !task.isEvent && !isPiece {
                            // Must-do is a mark on the name, not a setting further down.
                            Button { withAnimation(.snappy) { task.isMust.toggle() } } label: {
                                Image(systemName: task.isMust ? "star.fill" : "star")
                                    .font(.title3).foregroundStyle(task.isMust ? Palette.must : Color.secondary)
                                    .frame(width: 36, height: 36).contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("必須")
                            .accessibilityAddTraits(task.isMust ? .isSelected : [])
                            .accessibilityHint("落とせないものの印です。時間割の下の「必須」にまとまり、候補で先に出ます")
                        }
                    }
                } footer: {
                    if task.isMust && !isPiece { Text("★必須：落とせないものの印。今日の上段には出さず、時間割の下の「必須」にまとめます。締切の日が来たら上段に出ます。").onlyInDemo() }
                }
                Section {
                    if isWhole {
                        HStack {
                            Text("予定日")
                            Spacer()
                            Text("子タスクごと").foregroundStyle(.secondary)
                        }
                    } else {
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
                    }
                    if !task.isEvent && !isPiece {
                        OptionalDateRow(title: "締切", date: $task.deadline)
                    }
                }
                if !task.isEvent && !isPiece { piecesSection }
                if (!isWhole && task.plannedAt != nil && task.slot != nil) || (!task.isEvent && task.deadline != nil) {
                    Section {
                        Toggle("通知", isOn: $task.notify)
                    } footer: {
                        Text(task.isEvent ? "始まる時刻にバナーで知らせます。タイミングは設定で変えられます。"
                             : "始まる時刻と締切の日の朝にバナーで知らせます。タイミングは設定で変えられます。")
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
                    if !isPiece {
                        Text(store.linkedCard(for: task) == nil
                             ? "繰り返し使う手順は、ボードのカードに書いてプロジェクトで結ぶと、どのタスクからも開けます。"
                             : "手順はボードのカードにあります。このタスクだけのことはメモへ。")
                    }
                }
                if !task.isEvent && !task.continuationNote.isEmpty {
                    Section {
                        TextField("次はどこから？", text: $task.continuationNote, axis: .vertical).lineLimit(2...6)
                    } header: { Text("前回の続き") }
                    footer: { Text("この一時メモは、タスクを完了すると削除されます。") }
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
                footer: { Text("内容を保存して共有できます。AIへの自動送信はありません。").onlyInDemo() }
                }
                if !isPiece || (!task.isEvent && !isWhole) {
                    Section("任意の属性") {
                        // A piece belongs to its task's project and checkpoint.
                        if !isPiece {
                            ProjectPicker(project: $task.project) { guide = GuideRoute(id: $0.id) }
                            if !task.isEvent { MilestonePicker(project: task.project, milestoneID: $task.milestoneID) }
                        }
                        if !task.isEvent && !isWhole {
                            Picker("取り組む負荷", selection: $task.effort) {
                                ForEach(Effort.allCases) { Text($0.label).tag($0) }
                            }
                        }
                        if !task.isEvent, task.suggestionDeferredUntil.map({ $0 > Date() }) == true {
                            Button("候補の「あとで」を解除") { task.suggestionDeferredUntil = nil }
                        }
                    }
                }
                if store.task(task.id) != nil {
                    Section {
                        Button(task.isEvent ? "このイベントを削除" : isWhole ? "このタスクと子タスクを削除" : "このタスクを削除",
                               role: .destructive) { showDelete = true }
                    }
                }
            }
            .navigationTitle("\(task.isEvent ? "イベント" : isPiece ? "子タスク" : "タスク")を\(store.task(task.id) == nil ? "追加" : "編集")")
            .keyboardDismissable()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { if changed { confirmDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(store.task(task.id) == nil ? "追加" : "保存", action: save).disabled(task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog(task.isEvent ? "このイベントを削除しますか？" : isWhole ? "このタスクと子タスクをすべて削除しますか？" : "このタスクを削除しますか？",
                                isPresented: $showDelete, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    store.delete(task.id)
                    if store.task(task.id) == nil { dismiss() }
                }
            }
            // A swipe down must not silently drop what was typed.
            .interactiveDismissDisabled(changed)
            .sheet(item: $guide) { route in GuideSheet(cardID: route.id) }
            .sheet(item: $timing) { ref in
                PieceWhenSheet(piece: Binding(
                    get: { pieces.first { $0.id == ref.id } ?? TaskItem(title: "") },
                    set: { edited in if let i = pieces.firstIndex(where: { $0.id == ref.id }) { pieces[i] = edited } }
                ))
            }
            // A checkpoint belongs to one project; moving the task to another one lets go of it.
            .onChange(of: task.project) { _, project in
                task.milestoneID = MilestonePicker.fitting(task.milestoneID, project: project, in: store.notebook)
            }
            .onChange(of: task.plannedAt) { _, day in if day == nil { task.scheduledTime = "" } }
        }
        .confirmationDialog("編集した内容を破棄しますか？", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("破棄して閉じる", role: .destructive) { dismiss() }
        }
        .storeErrorAlert()
    }

    /// The pieces: checked off with one tap, named in place, each with its own day.
    private var piecesSection: some View {
        Section {
            ForEach($pieces) { $piece in
                HStack(spacing: 6) {
                    Button { piece.completedAt = piece.isComplete ? nil : Date() } label: {
                        Image(systemName: piece.isComplete ? "checkmark.circle.fill" : "circle").font(.title3)
                            .foregroundStyle(Palette.accent).frame(width: 36, height: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(piece.isComplete ? "\(piece.title)を未完了に戻す" : "\(piece.title)を完了")
                    TextField("子タスク", text: $piece.title, axis: .vertical)
                        .strikethrough(piece.isComplete).foregroundStyle(piece.isComplete ? .secondary : .primary)
                    Button { timing = PieceRef(id: piece.id) } label: {
                        Group {
                            if piece.plannedAt == nil {
                                Text("日付 未定").font(.caption).foregroundStyle(.secondary)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(Color(uiColor: .tertiarySystemFill)))
                            } else {
                                PieceDateChip(task: piece)
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("\(piece.title)の日付と時間")
                }
                // The line between pieces starts under their names, as in the rest of the form.
                .alignmentGuide(.listRowSeparatorLeading) { _ in 42 }
            }
            .onDelete { offsets in
                for index in offsets where initialPieces.contains(where: { $0.id == pieces[index].id }) {
                    removedPieces.insert(pieces[index].id)
                }
                pieces.remove(atOffsets: offsets)
            }
            .onMove { pieces.move(fromOffsets: $0, toOffset: $1) }
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.accent).frame(width: 36)
                TextField(isWhole ? "子タスクを足す" : "子タスクに分ける", text: $newPiece).submitLabel(.done).onSubmit(addPiece)
                if !newPiece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("足す", action: addPiece).buttonStyle(.borderless).fontWeight(.semibold)
                }
            }
        } header: {
            HStack {
                Text(isWhole ? "子タスク \(pieces.filter(\.isComplete).count)/\(pieces.count)" : "子タスク")
                Spacer()
                if pieces.count > 1 { EditButton().font(.caption) }
            }
        } footer: {
            if !isWhole {
                Text("分けると、1つずつ日付を決めてチェックできます。今の予定日と時間は最初の子タスクに移ります。").onlyInDemo()
            }
        }
    }

    private var changed: Bool {
        task != initial || pieces != initialPieces || !removedPieces.isEmpty
            || !newPiece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addPiece() {
        let title = newPiece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var piece = TaskItem(title: title, project: task.project, parentID: task.id, rank: pieces.count)
        // The first piece takes over the task's day and time, as it will when saved.
        if pieces.isEmpty, let day = task.plannedAt {
            piece.plannedAt = day
            piece.scheduledTime = task.scheduledTime
        }
        withAnimation(.snappy) { pieces.append(piece) }
        newPiece = ""
    }

    private func save() {
        addPiece()
        task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // An event is a happening on a day, not a to-do: no must or deadline.
        if task.isEvent {
            task.isMust = false; task.deadline = nil
            if task.plannedAt == nil { task.plannedAt = Date() }
        }
        if task.isEvent || isPiece {
            if store.upsert(task, original: original) { dismiss() }
            return
        }
        // A piece left without a name is dropped.
        let blank = pieces.filter { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.id)
        let kept = pieces.filter { !blank.contains($0.id) }.map { piece -> TaskItem in
            var trimmed = piece
            trimmed.title = piece.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed
        }
        let gone = removedPieces.union(blank.filter { id in initialPieces.contains { $0.id == id } })
        let originals = Dictionary(uniqueKeysWithValues: initialPieces.map { ($0.id, $0) })
        if store.saveFamily(task, original: original, children: kept, originals: originals, removed: gone) { dismiss() }
    }
}

private struct PieceRef: Identifiable { let id: UUID }

/// The day and time of one piece, picked as for any task.
private struct PieceWhenSheet: View {
    @Binding var piece: TaskItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    OptionalDateRow(title: "日付", date: $piece.plannedAt, placeholder: "未定（いつでも）")
                    if piece.plannedAt != nil { TimeDialRow(slot: $piece.slot) }
                }
            }
            .navigationTitle(piece.title.isEmpty ? "子タスクの日付" : piece.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("決める") { dismiss() } } }
            .onChange(of: piece.plannedAt) { _, day in if day == nil { piece.scheduledTime = "" } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A routine being done now: its timer with 中断 and 完了 beside it, where it was left off last time,
/// its method, and a note for next time.
@MainActor
struct RoutineFocusView: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var note = ""
    @State private var routineID: UUID?

    var body: some View {
        NavigationStack {
            if let run = store.routineRun, let routine = store.routine(run.routineID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("ルーティン・\(routine.weekdayLabel)\(routine.slot.map { " \($0.startLabel)" } ?? "")",
                                  systemImage: "arrow.triangle.2.circlepath")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text(routine.title).font(.largeTitle.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // A pomodoro-style dial: time spent against the routine's planned length (one pomodoro if none).
                        HStack(spacing: 12) {
                            ElapsedTimer(start: run.startedAt, minutes: plannedMinutes(routine.slot), size: 60)
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let elapsed = context.date.timeIntervalSince(run.startedAt)
                                let planned = plannedMinutes(routine.slot)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("経過").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Text(ElapsedTimer.clock(elapsed)).font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                                    if elapsed >= Double(planned * 60) {
                                        Text("予定の\(planned)分を\(Int(elapsed / 60) - planned)分こえています")
                                            .font(.caption.weight(.semibold)).foregroundStyle(.red)
                                    } else {
                                        Text(routine.slot == nil ? "目安 \(planned)分" : "予定 \(planned)分")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .accessibilityElement(children: .combine)
                            Spacer(minLength: 0)
                            FocusRoundButton(title: "中断", systemImage: "pause.fill", prominent: false) {
                                saveNote()
                                store.cancelRoutineTimer()
                                dismiss()
                            }
                            .accessibilityHint("完了にせず、ここで手を止めます。続きのメモは次の回に出ます")
                            FocusRoundButton(title: "完了", systemImage: "checkmark", prominent: true) {
                                saveNote()
                                store.finishRoutineTimer()
                                dismiss()
                            }
                        }
                        if !routine.resumeNote.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("前回の続き").font(.caption.weight(.bold)).foregroundStyle(Palette.accent)
                                Text(routine.resumeNote).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(14)
                            .background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                        }
                        if let card = store.linkedCard(forProject: routine.project) {
                            // The method is what people forget mid-way; keep it one tap away.
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 12) {
                                    if !card.goal.isEmpty { Text("ゴール：\(card.goal)").font(.subheadline.weight(.medium)) }
                                    if !card.detail.isEmpty { Text(card.detail).textSelection(.enabled) }
                                    if card.isBlank { Text("このカードにはまだ何も書いていません。").foregroundStyle(.secondary) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                            } label: { Label("やり方：\(card.title)", systemImage: "book.closed") }
                        }
                        if !routine.memo.isEmpty {
                            DisclosureGroup("メモ") { Text(routine.memo).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8) }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("次回への続きのメモ（任意）").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            TextField("どこまで進んだ？ 次はどこから？", text: $note, axis: .vertical)
                                .lineLimit(2...8).padding(12).background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .padding(.top, 8)
                    }.padding(24)
                }
                .navigationTitle("今やるひとつ").keyboardDismissable().navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("一覧へ") { saveNote(); dismiss() } } }
                .onAppear { routineID = routine.id }
            } else {
                ContentUnavailableView("取り組み中のルーティンはありません", systemImage: "checkmark.circle")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
            }
        }
        // Saving once on leaving keeps the undo history free of one entry per keystroke.
        .onDisappear(perform: saveNote)
        .onChange(of: phase) { _, newPhase in if newPhase != .active { saveNote() } }
        .storeErrorAlert()
    }

    private func saveNote() {
        guard let routineID, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.saveRoutineNote(routineID, note: note)
        note = ""
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
