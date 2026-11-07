import UIKit
import CloudKit

@MainActor
final class HormeAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if TaskStore.shared.connection != nil { application.registerForRemoteNotifications() }
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        if session.role == .windowApplication { configuration.delegateClass = HormeSceneDelegate.self }
        return configuration
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo)?.containerIdentifier == CloudSyncTransport.containerID else {
            completionHandler(.noData); return
        }
        // The system gives a woken app about thirty seconds; going over gets it terminated, which shows
        // as a crash. The sync stops at 25 seconds and the answer goes back exactly once.
        let previous = TaskStore.shared.notebook
        let answer = FetchAnswer(completionHandler)
        let work = Task {
            await TaskStore.shared.synchronize()
            answer.send(TaskStore.shared.syncError == nil ? (previous == TaskStore.shared.notebook ? .noData : .newData) : .failed)
        }
        Task {
            try? await Task.sleep(for: .seconds(25))
            guard !answer.sent else { return }
            work.cancel()
            answer.send(previous == TaskStore.shared.notebook ? .noData : .newData)
        }
    }
}

@MainActor
final class HormeSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        // Cold launch via a share URL does not necessarily call the warm-launch callback.
        if let metadata = options.cloudKitShareMetadata { receive(metadata) }
    }
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        receive(metadata)
    }
    private func receive(_ metadata: CKShare.Metadata) {
        Task { await TaskStore.shared.acceptInvitation(metadata) }
    }
}

/// Hands a background fetch its result once, whichever comes first: the sync or the time limit.
@MainActor
private final class FetchAnswer {
    private var handler: ((UIBackgroundFetchResult) -> Void)?
    init(_ handler: @escaping (UIBackgroundFetchResult) -> Void) { self.handler = handler }
    var sent: Bool { handler == nil }
    func send(_ result: UIBackgroundFetchResult) {
        handler?(result)
        handler = nil
    }
}
