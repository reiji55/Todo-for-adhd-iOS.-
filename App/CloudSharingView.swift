import SwiftUI
import CloudKit
import UIKit

struct PendingCloudJoin: Identifiable {
    let id = UUID()
    var snapshot: CloudSnapshot
    var openShareAfterJoin: Bool
    var message: String

    init(snapshot: CloudSnapshot, local: Notebook, openShareAfterJoin: Bool) throws {
        self.snapshot = snapshot; self.openShareAfterJoin = openShareAfterJoin
        let remote = try snapshot.replica.materialize()
        let preview = ShareMergePreview(local: local, remote: remote)
        func counts(_ book: Notebook) -> String {
            "タスク\(book.tasks.count)件・アイデア\(book.ideas.count)件・ボード\(book.boardCards.count)件・ルーティン\(book.routines.count)件"
        }
        message = "この端末：\(counts(local))\n共有先：\(counts(remote))\n統合後：\(counts(preview.combined))\n\n"
        let conflicts = preview.conflictingTasks + preview.conflictingIdeas + preview.conflictingCards + preview.conflictingRoutines
        if conflicts > 0 {
            message += "同じデータで内容が異なる\(conflicts)件は、両方を別の項目として残します。\n\n"
        }
        message += "上記のデータと、メモ・手順・完了状態を共有します。この端末の内容も共有先へ追加されます。開始前のバックアップを端末に残します。"
    }
}

struct CloudSharingSheet: Identifiable {
    let id = UUID()
    var share: CKShare
    var container: CKContainer
}

/// Shows Apple's sharing screen. It is presented directly from UIKit: wrapped in a SwiftUI sheet,
/// UICloudSharingController comes up blank or closes at once, so the invite link never appears.
@MainActor
enum CloudSharingPresenter {
    /// UICloudSharingController holds its delegate weakly; keep it alive while the screen is up.
    private static var delegate: Coordinator?

    static func present(_ item: CloudSharingSheet, store: TaskStore) {
        guard let top = topViewController() else {
            store.syncError = "共有の画面を開けませんでした。設定を閉じて、もう一度お試しください。"
            return
        }
        let controller = UICloudSharingController(share: item.share, container: item.container)
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        let coordinator = Coordinator(store: store)
        delegate = coordinator
        controller.delegate = coordinator
        // iPad shows it as a popover, which needs an anchor or it fails to present.
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let store: TaskStore
        init(store: TaskStore) { self.store = store }
        func itemTitle(for csc: UICloudSharingController) -> String? { "Hormeの共有データ" }
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            Task { @MainActor in store.syncError = TaskStore.describe(error) }
        }
        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            Task { @MainActor in store.requestSync() }
        }
        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            Task { @MainActor in store.sharingStopped() }
        }
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
            Text("別々のApple Accountでも、招待を承認するとタスク・アイデア・ボード・ルーティンを共有できます。入力は端末へ保存し、通信できるときに同期します。同じ箇所を同時に変更した場合は変更の順序で決まり、同期直前の内容は下のデータ欄から書き出せます。")
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
