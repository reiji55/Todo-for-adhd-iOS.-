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
        Task {
            let previous = TaskStore.shared.notebook
            await TaskStore.shared.synchronize()
            completionHandler(TaskStore.shared.syncError == nil
                ? (previous == TaskStore.shared.notebook ? .noData : .newData) : .failed)
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
