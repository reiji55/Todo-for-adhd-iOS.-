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
                LockScreenSection()
                if Edition.full { ClaudeBridgeSection() }
                Section {
                    NavigationLink { RoutineSettingsView() } label: {
                        LabeledContent("ルーティン", value: "\(store.notebook.routines.filter { !$0.isPaused }.count)件")
                    }
                } footer: { Text("くり返しの予定。「すべて」の画面からも開けます。") }
                Section {
                    NavigationLink { PackagesView() } label: {
                        LabeledContent("パッケージ", value: "\(store.notebook.packages.count)件")
                    }
                } footer: { Text("決まった子タスクのセット。子タスクに分けたタスクから保存し、ほかのタスクやイベントにまとめて足せます。") }
                // Backups as files are for the full edition; everyone else keeps their data in iCloud. Recovering
                // from an unreadable save is for everyone.
                if Edition.full || store.loadBroken {
                Section {
                    if Edition.full {
                        Button("バックアップを書き出す", systemImage: "square.and.arrow.up") {
                            do { document = BackupDocument(data: try NotebookCodec.encode(store.realNotebook)); exporter = true }
                            catch { localError = error.localizedDescription }
                        }.disabled(store.loadFailed)
                        Button("バックアップを読み込む", systemImage: "square.and.arrow.down") { importer = true }
                            .disabled(store.loadFailed || store.isDemo)
                        if store.hasSharingBackup {
                            Button("共有開始前のバックアップを書き出す") { exportSafetyBackup(beforeSharing: true) }
                        }
                        if store.hasSyncBackup {
                            Button("同期直前のバックアップを書き出す") { exportSafetyBackup(beforeSharing: false) }
                        }
                    }
                    if store.loadBroken {
                        if store.canRecoverPrevious {
                            Button("直前の保存から復旧する") { store.recover() }
                        }
                        Button("読めないデータを残して空から始める", role: .destructive) { showStartOver = true }
                        Text("読めないデータは削除せず端末内に残します。空にしたあと、バックアップを読み込んで戻せます。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("データ") }
                footer: { Text("端末に自動保存します。同期中にバックアップで置き換えると、同期先にも反映されます。") }
                }
                Section {
                    Button("チュートリアルをはじめる", systemImage: "graduationcap") {
                        Tutorial.shared.restart(store: store)
                        dismiss()
                    }
                    .disabled(store.loadFailed || Tutorial.shared.isRunning)
                    .accessibilityIdentifier("startTutorial")
                    if store.isDemo {
                        Button("デモモードを終える", systemImage: "stop.circle") { store.endDemo() }
                    } else {
                        Button("デモモードで自由に触る", systemImage: "play.circle") { showDemoConfirm = true }
                            .disabled(store.loadFailed)
                    }
                } header: { Text("使い方") }
                footer: {
                    Text("サンプルのデータで、案内に沿って操作を試せます。本物のデータには触れず、同期と通知も止まります。終えるか、アプリを閉じると元に戻ります。")
                }
                Section {
                    NavigationLink { FeedbackView() } label: {
                        Label("ご意見・不具合の報告", systemImage: "envelope")
                    }
                    .accessibilityIdentifier("openFeedback")
                } footer: { Text("困ったことや、あったらいいなと思うことを、開発者に直接送れます。") }
                Section("この版について") {
                    Text("Horme · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    Text(Edition.full ? "フル機能版（Claude連携・バックアップつき）" : "タスク・アイデア・リスト・プロジェクトを、思いつきから完了までひとつの場所で。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .background(CloudSharingAnchor().frame(width: 0, height: 0))
            .navigationTitle("設定とデータ").keyboardDismissable().navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
            .onChange(of: store.sharingSheet?.id) { _, id in
                guard id != nil, let item = store.sharingSheet else { return }
                store.sharingSheet = nil
                CloudSharingPresenter.present(item, store: store)
            }
            .modifier(ShareJoinAlert())
            .confirmationDialog("空の状態から始めますか？", isPresented: $showStartOver, titleVisibility: .visible) {
                Button("空から始める", role: .destructive) { store.startOver() }
            } message: { Text("読めないデータは端末内に残したまま、新しく保存を始めます。") }
            .fileExporter(isPresented: $exporter, document: document, contentType: .json, defaultFilename: "3days-backup") { result in
                if case .failure(let error) = result { localError = error.localizedDescription }
            }
            .fileImporter(isPresented: $importer, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    importedBook = nil
                    let book = try NotebookCodec.decode(data)
                    importedBook = book
                    // Everything is replaced, so everything is counted: lists and projects too.
                    importSummary = "現在の内容を、バックアップのタスク\(book.tasks.count)件・アイデア\(book.ideas.count)件・ボードのカード\(book.boardCards.count)件・ルーティン\(book.routines.count)件・プロジェクト\(book.projects.count)件・リスト\(book.lists.count)件（項目\(book.listItems.count)件）に置き換えます。直前の内容は取り消し操作で戻せます。"
                    if store.connection != nil { importSummary += "\n\nこの置き換えと削除は、同期している他の端末にも反映されます。" }
                    if store.bridgeOn { importSummary += "\n\nこの置き換えと削除は、Claudeとの連携先にも反映されます。" }
                    confirmImport = true
                } catch { localError = error.localizedDescription }
            }
            .alert("取り込み内容の確認", isPresented: $confirmImport) {
                Button("キャンセル", role: .cancel) { importedBook = nil }
                Button("置き換える", role: .destructive) {
                    if let book = importedBook, store.commit({ $0 = book }) { store.offerUndo("バックアップの内容に置き換えました") }
                    importedBook = nil
                }
            } message: { Text(importSummary) }
            .alert("デモモードを始めますか？", isPresented: $showDemoConfirm) {
                Button("キャンセル", role: .cancel) {}
                Button("始める") { store.startDemo(); dismiss() }
            } message: { Text("サンプルのデータに切り替わります。本物のデータはそのまま残り、デモを終えるかアプリを終了すると戻ります。") }
            .alert("読み込み・書き出しのお知らせ", isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) {
                Button("閉じる", role: .cancel) { localError = nil }
            } message: { Text(localError ?? "") }
        }.storeErrorAlert()
    }
    private func exportSafetyBackup(beforeSharing: Bool) {
        do { document = BackupDocument(data: try store.backupData(beforeSharing: beforeSharing)); exporter = true }
        catch { localError = error.localizedDescription }
    }
}

/// いま on the lock screen, above the notifications.
@MainActor
private struct LockScreenSection: View {
    @AppStorage(NowActivityController.enabledKey) private var enabled = true

    var body: some View {
        Section {
            Toggle("ロック画面に「いま」を出す", isOn: $enabled)
                .onChange(of: enabled) { _, on in if !on { NowActivityController.shared.end() } }
        } footer: {
            Text("通知の上に「いま」のカードを出します。iPhoneの決まりで12時間ほどで消え、今日の画面を開くと出し直します。")
        }
    }
}
