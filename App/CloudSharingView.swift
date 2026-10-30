import SwiftUI
import CloudKit

struct PendingCloudJoin: Identifiable {
    let id = UUID()
    var snapshot: CloudSnapshot
    var openShareAfterJoin: Bool
    var message: String

    init(snapshot: CloudSnapshot, local: Notebook, openShareAfterJoin: Bool) throws {
        self.snapshot = snapshot; self.openShareAfterJoin = openShareAfterJoin
        let remote = try snapshot.replica.materialize()
        let preview = ShareMergePreview(local: local, remote: remote)
        message = "この端末：タスク\(local.tasks.count)件・アイデア\(local.ideas.count)件\n共有先：タスク\(remote.tasks.count)件・アイデア\(remote.ideas.count)件\n統合後：タスク\(preview.combined.tasks.count)件・アイデア\(preview.combined.ideas.count)件\n\n"
        if preview.conflictingTasks + preview.conflictingIdeas > 0 {
            message += "同じデータで内容が異なる\(preview.conflictingTasks + preview.conflictingIdeas)件は、両方を別の項目として残します。\n\n"
        }
        message += "タスク・アイデア・メモ・完了状態を共有します。この端末の内容も共有先へ追加されます。開始前のバックアップを端末に残します。"
    }
}

struct CloudSharingSheet: Identifiable {
    let id = UUID()
    var share: CKShare
    var container: CKContainer
}

@MainActor
struct CloudSharingView: UIViewControllerRepresentable {
    @EnvironmentObject private var store: TaskStore
    let item: CloudSharingSheet
    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: item.share, container: item.container)
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let store: TaskStore
        init(store: TaskStore) { self.store = store }
        func itemTitle(for csc: UICloudSharingController) -> String? { "Hormeのタスクとアイデア" }
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            store.syncError = TaskStore.describe(error)
        }
        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) { store.requestSync() }
        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) { store.sharingStopped() }
    }
}

@MainActor
struct SharingSection: View {
    @EnvironmentObject private var store: TaskStore
    @State private var confirmDisconnect = false
    var body: some View {
        Section {
            if store.connection != nil {
                LabeledContent("接続先", value: store.connection?.isShared == true ? "招待された共有データ" : "自分のiCloud")
                HStack {
                    if store.isSyncing { ProgressView().accessibilityLabel("同期中") }
                    Label(syncStatus, systemImage: store.syncError != nil ? "icloud.slash" : store.hasPendingChanges ? "icloud.and.arrow.up" : "checkmark.icloud")
                }
                if let date = store.lastSyncedAt {
                    LabeledContent("最終同期") { Text(date, format: .dateTime.month().day().hour().minute()).foregroundStyle(.secondary) }
                }
                Button("今すぐ同期", systemImage: "arrow.triangle.2.circlepath") { Task { await store.synchronize() } }
                    .disabled(store.isSyncing || store.loadFailed)
                Button("招待・共有相手を管理", systemImage: "person.badge.plus") { Task { await store.prepareSharing() } }
                    .disabled(store.isPreparingShare || store.loadFailed)
                Button("この端末の同期を解除", role: .destructive) { confirmDisconnect = true }
                    .disabled(store.isPreparingShare || store.loadFailed)
            } else {
                Button("データを共有する", systemImage: "person.2.badge.gearshape") { Task { await store.prepareSharing() } }
                    .disabled(store.isPreparingShare || store.loadFailed)
                Text("招待された端末では、届いたiCloud共有リンクを開いて参加してください。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if store.isPreparingShare { ProgressView("iCloudの共有を確認しています") }
            if let message = store.syncError {
                Text(message).font(.subheadline).foregroundStyle(.secondary).accessibilityLabel("同期のお知らせ。\(message)")
            }
        } header: { Text("端末間の共有") }
        footer: {
            Text("別々のApple Accountでも、招待を承認すると同じタスクとアイデアを使えます。入力は端末へ保存し、通信できるときに同期します。同じ箇所を同時に変更した場合は変更の順序で決まり、同期直前の内容は下のデータ欄から書き出せます。")
        }
        .confirmationDialog("この端末の同期を解除しますか？", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("端末のデータを残して解除", role: .destructive) { store.disconnectSync() }
        } message: { Text("この端末のデータは残ります。送信待ちの変更は同期されなくなります。共有先や他の端末のデータは削除しません。") }
    }

    private var syncStatus: String {
        if store.isSyncing { return "同期中" }
        if store.syncError != nil { return "同期できていません" }
        return store.hasPendingChanges ? "端末に保存済み・送信待ち" : "同期済み"
    }
}

@MainActor
struct ShareJoinAlert: ViewModifier {
    @EnvironmentObject var store: TaskStore
    var enabled = true
    func body(content: Content) -> some View {
        content.alert("データを統合して同期しますか？", isPresented: Binding(
            get: { enabled && store.pendingJoin != nil },
            set: { if !$0 { store.pendingJoin = nil } }
        ), presenting: store.pendingJoin) { pending in
            Button("キャンセル", role: .cancel) { store.pendingJoin = nil }
            Button("統合して同期する") { Task { await store.confirmJoin(pending) } }
        } message: { pending in Text(pending.message) }
    }
}
