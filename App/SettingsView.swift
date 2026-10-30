import SwiftUI
import UniformTypeIdentifiers

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    @State private var exporter = false
    @State private var importer = false
    @State private var document = BackupDocument()
    @State private var importedBook: Notebook?
    @State private var importedTasks: TaskImport?
    @State private var importedCards: [BoardCard]?
    @State private var importSummary = ""
    @State private var confirmImport = false
    @State private var showDemoConfirm = false
    @State private var showStartOver = false
    @State private var localError: String?

    var body: some View {
        NavigationStack {
            Form {
                SharingSection()
                NotificationSettingsSection()
                Section {
                    NavigationLink { RoutineSettingsView() } label: {
                        LabeledContent("ルーティン", value: "\(store.notebook.routines.filter { !$0.isPaused }.count)件")
                    }
                } footer: { Text("くり返しの予定。「すべて」の画面からも開けます。") }
                Section("優先づけのルール") {
                    Label("必須・今日までの締切は上段に常時表示", systemImage: "pin")
                    Text("候補は最大3件。明日が締切 → 今日の予定 → 中断した続き → それ以外の順に並びます。同じ優先度の中で、選んだ調子に近い負荷を先に出します。")
                    Text("「候補から1時間外す」は提案にだけ反映。全件一覧や必須タスクは隠しません。未来の予定はその日に候補へ入ります。")
                    Text("やる日は予定、締切は期限です。予定日を動かしても締切は動きません。")
                }.font(.subheadline)
                Section {
                    Button("バックアップを書き出す", systemImage: "square.and.arrow.up") {
                        do { document = BackupDocument(data: try NotebookCodec.encode(store.notebook)); exporter = true }
                        catch { localError = error.localizedDescription }
                    }.disabled(store.loadFailed)
                    Button("ファイルを読み込む", systemImage: "square.and.arrow.down") { importer = true }
                        .disabled(store.loadFailed)
                    if store.hasSharingBackup {
                        Button("共有開始前のバックアップを書き出す") { exportSafetyBackup(beforeSharing: true) }
                    }
                    if store.hasSyncBackup {
                        Button("同期直前のバックアップを書き出す") { exportSafetyBackup(beforeSharing: false) }
                    }
                    Text("このアプリのJSONバックアップ、または3日間タスクの tasks.txt・board.json を選べます。tasks.txt と board.json は重複を避けて追加します。")
                        .font(.caption).foregroundStyle(.secondary)
                    if store.loadFailed {
                        if store.canRecoverPrevious {
                            Button("直前の保存から復旧する") { store.recover() }
                        }
                        Button("読めないデータを残して空から始める", role: .destructive) { showStartOver = true }
                        Text("読めないデータは削除せず端末内に残します。空にしたあと、バックアップを読み込んで戻せます。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("データ") }
                footer: { Text("端末に自動保存します。共有を設定すると他の端末と同期します。同期中にバックアップで置き換えると、共有先にも変更が反映されます。アプリを削除する前にはバックアップを書き出してください。") }
                Section {
                    Button("サンプルで試す") { showDemoConfirm = true }
                        .disabled(store.loadFailed || !store.notebook.isEmpty)
                } footer: { Text("初期状態が空のときだけ使えます。サンプルは自由に編集・削除できます。") }
                Section("この版について") {
                    Text("Horme · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    Text("タスクとルーティン、週の時間割、通知、やり方を書き溜めるボードを備えた版です。Claudeとの自動連携はまだ含めていません。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("設定とデータ").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
            .sheet(item: $store.sharingSheet) { item in CloudSharingView(item: item) }
            .modifier(ShareJoinAlert())
            .confirmationDialog("空の状態から始めますか？", isPresented: $showStartOver, titleVisibility: .visible) {
                Button("空から始める", role: .destructive) { store.startOver() }
            } message: { Text("読めないデータは端末内に残したまま、新しく保存を始めます。") }
            .fileExporter(isPresented: $exporter, document: document, contentType: .json, defaultFilename: "3days-backup") { result in
                if case .failure(let error) = result { localError = error.localizedDescription }
            }
            .fileImporter(isPresented: $importer, allowedContentTypes: [.json, .plainText]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    importedBook = nil; importedTasks = nil; importedCards = nil
                    if url.pathExtension.lowercased() == "json", BoardImporter.isBoardFile(data) {
                        let parsed = try BoardImporter.parse(data)
                        guard !parsed.cards.isEmpty else { throw NotebookError.invalidData }
                        importedCards = parsed.cards
                        let added = BoardImporter.merge(parsed.cards, into: store.notebook.boardCards).count - store.notebook.boardCards.count
                        importSummary = "ボードにカードを\(added)件追加します。同じ見出しのカードはそのまま残します。"
                        if parsed.skipped > 0 { importSummary += "\n\n見出しのないカード\(parsed.skipped)件は取り込みません。" }
                    } else if url.pathExtension.lowercased() == "json" {
                        let book = try NotebookCodec.decode(data)
                        importedBook = book
                        importSummary = "現在の内容を、バックアップのタスク\(book.tasks.count)件・アイデア\(book.ideas.count)件・ボードのカード\(book.boardCards.count)件・ルーティン\(book.routines.count)件に置き換えます。直前の内容は取り消し操作で戻せます。"
                        if store.connection != nil { importSummary += "\n\nこの置き換えと削除は、共有している他の端末にも反映されます。" }
                    } else {
                        guard let text = String(data: data, encoding: .utf8) else { throw NotebookError.invalidData }
                        let parsed = TaskTextImporter.parse(text)
                        guard !parsed.tasks.isEmpty else { throw NotebookError.invalidData }
                        importedTasks = parsed
                        let merged = TaskTextImporter.merge(parsed.tasks, into: store.notebook.tasks)
                        importSummary = "新しいタスクを\(merged.count - store.notebook.tasks.count)件追加します。既存のタスクは変更しません。"
                        if !parsed.warnings.isEmpty {
                            importSummary += "\n\n読み取れない行：\(parsed.warnings.count)件\n" + parsed.warnings.prefix(5).joined(separator: "\n")
                        }
                    }
                    confirmImport = true
                } catch { localError = error.localizedDescription }
            }
            .alert("取り込み内容の確認", isPresented: $confirmImport) {
                Button("キャンセル", role: .cancel) { importedBook = nil; importedTasks = nil; importedCards = nil }
                Button(importedBook == nil ? "追加する" : "置き換える", role: importedBook == nil ? nil : .destructive) {
                    if let book = importedBook { store.commit { $0 = book } }
                    else if let cards = importedCards {
                        store.commit { $0.boardCards = BoardImporter.merge(cards, into: $0.boardCards) }
                    }
                    else if let tasks = importedTasks?.tasks {
                        store.commit { $0.tasks = TaskTextImporter.merge(tasks, into: $0.tasks) }
                    }
                    importedBook = nil; importedTasks = nil; importedCards = nil
                }
            } message: { Text(importSummary) }
            .alert("サンプルを追加します", isPresented: $showDemoConfirm) {
                Button("キャンセル", role: .cancel) {}
                Button("追加") { addDemo() }
            } message: { Text("必須、締切、続きのメモ、アイデア、ボードのカードを試せるサンプルです。") }
            .alert("読み込み・書き出しのお知らせ", isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) {
                Button("閉じる", role: .cancel) { localError = nil }
            } message: { Text(localError ?? "") }
        }.storeErrorAlert()
    }
    private func exportSafetyBackup(beforeSharing: Bool) {
        do { document = BackupDocument(data: try store.backupData(beforeSharing: beforeSharing)); exporter = true }
        catch { localError = error.localizedDescription }
    }
    private func addDemo() {
        let now = Date()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)
        store.commit { book in
            guard book.isEmpty else { return }
            book.tasks = [
                TaskItem(title: "提出書類を送る", plannedAt: now, deadline: now, isMust: true,
                         effort: .light, memo: "これはサンプルです。", steps: [Step(title: "宛先を確認する"), Step(title: "メールに添付して送る")]),
                TaskItem(title: "読みかけの本を読む", effort: .light, resumeNote: "42ページの途中まで"),
                TaskItem(title: "提案の下書きをつくる", deadline: tomorrow, effort: .heavy, steps: [Step(title: "見出しを3つ書く")]),
                TaskItem(title: "週末の買い物を考える", plannedAt: tomorrow),
                TaskItem(title: "気になる資料を読む", effort: .medium),
                TaskItem(title: "予約の電話をする（14時から受付）", plannedAt: now, scheduledTime: "14:00-14:15", effort: .light)
            ]
            book.routines = [
                Routine(title: "部屋をリセットする", project: "部屋のリセット", time: "21:00-21:15", createdAt: now),
                Routine(title: "睡眠", time: "0:00-7:00", notify: false, isBlock: true, createdAt: now)
            ]
            book.boardCards = [
                BoardCard(title: "部屋のリセット",
                          purpose: "散らかった机が目に入ると、始める前に気力が削られるため。",
                          goal: "机の上に、いま使う物しかない状態。",
                          detail: "これはサンプルです。\n\n1. タイマーを15分にする\n2. 床の物を1か所に集める\n3. 机の上を「戻す・捨てる・保留」に分ける\n4. 保留は箱に入れて、今日は考えない\n\n▸ 15分で止める。全部やろうとしない")
            ]
            book.ideas = [Idea(text: "散歩中に聞ける勉強メモを作れそう\nやると決めるまではアイデアに置く。")]
        }
    }
}
