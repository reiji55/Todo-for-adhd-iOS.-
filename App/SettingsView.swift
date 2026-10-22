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
    @State private var importSummary = ""
    @State private var confirmImport = false
    @State private var showDemoConfirm = false
    @State private var localError: String?

    var body: some View {
        NavigationStack {
            Form {
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
                    Text("このアプリのJSONバックアップ、または3日間タスクの tasks.txt を選べます。tasks.txt は重複を避けて追加します。")
                        .font(.caption).foregroundStyle(.secondary)
                    if store.loadFailed {
                        Button("直前の保存から復旧する") { store.recover() }
                    }
                } header: { Text("データ") }
                footer: { Text("端末に自動保存します。現在の版は端末間同期・カレンダー連携には対応していません。アプリを削除する前にはバックアップを書き出してください。") }
                Section {
                    Button("サンプルで試す") { showDemoConfirm = true }
                        .disabled(store.loadFailed || !store.notebook.tasks.isEmpty || !store.notebook.ideas.isEmpty)
                } footer: { Text("初期状態が空のときだけ使えます。サンプルは自由に編集・削除できます。") }
                Section("この版について") {
                    Text("3日間タスク · ネイティブ試作 0.1")
                    Text("タスクの追加・整理・着手と再開を中心にした版です。週のカレンダー表示、独立したガイド、通知、AI自動連携はこの版には含めていません。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("設定とデータ").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
            .fileExporter(isPresented: $exporter, document: document, contentType: .json, defaultFilename: "3days-backup") { result in
                if case .failure(let error) = result { localError = error.localizedDescription }
            }
            .fileImporter(isPresented: $importer, allowedContentTypes: [.json, .plainText]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    importedBook = nil; importedTasks = nil
                    if url.pathExtension.lowercased() == "json" {
                        let book = try NotebookCodec.decode(data)
                        importedBook = book
                        importSummary = "現在の内容を、バックアップのタスク\(book.tasks.count)件・アイデア\(book.ideas.count)件に置き換えます。直前の内容は取り消し操作で戻せます。"
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
                Button("キャンセル", role: .cancel) { importedBook = nil; importedTasks = nil }
                Button(importedBook == nil ? "追加する" : "置き換える", role: importedBook == nil ? nil : .destructive) {
                    if let book = importedBook { store.commit { $0 = book } }
                    else if let tasks = importedTasks?.tasks {
                        store.commit { $0.tasks = TaskTextImporter.merge(tasks, into: $0.tasks) }
                    }
                    importedBook = nil; importedTasks = nil
                }
            } message: { Text(importSummary) }
            .alert("サンプルを追加します", isPresented: $showDemoConfirm) {
                Button("キャンセル", role: .cancel) {}
                Button("追加") { addDemo() }
            } message: { Text("必須、締切、続きのメモ、アイデアを試せるサンプルです。") }
            .alert("読み込み・書き出しのお知らせ", isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) {
                Button("閉じる", role: .cancel) { localError = nil }
            } message: { Text(localError ?? "") }
        }.storeErrorAlert()
    }
    private func addDemo() {
        let now = Date()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)
        store.commit { book in
            guard book.tasks.isEmpty, book.ideas.isEmpty else { return }
            book.tasks = [
                TaskItem(title: "提出書類を送る", plannedAt: now, deadline: now, isMust: true,
                         effort: .light, memo: "これはサンプルです。", steps: [Step(title: "宛先を確認する"), Step(title: "メールに添付して送る")]),
                TaskItem(title: "予約の電話をする", plannedAt: now, effort: .light),
                TaskItem(title: "読みかけの本を読む", effort: .light, resumeNote: "42ページの途中まで"),
                TaskItem(title: "提案の下書きをつくる", deadline: tomorrow, effort: .heavy, steps: [Step(title: "見出しを3つ書く")]),
                TaskItem(title: "週末の買い物を考える", plannedAt: tomorrow),
                TaskItem(title: "気になる資料を読む", effort: .medium)
            ]
            book.ideas = [Idea(text: "散歩中に聞ける勉強メモを作れそう\nやると決めるまではアイデアに置く。")]
        }
    }
}
