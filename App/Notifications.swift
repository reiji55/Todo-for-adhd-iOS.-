import SwiftUI
import UserNotifications

/// Local banners for tasks and routines with a start time. Settings live on this device only.
@MainActor
final class Reminders: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Reminders()
    @Published private(set) var status: UNAuthorizationStatus = .notDetermined
    private var pending: Task<Void, Never>?
    private let center = UNUserNotificationCenter.current()

    enum Key {
        static let enabled = "notify.enabled", lead = "notify.lead", tasks = "notify.tasks"
        static let routines = "notify.routines", deadlines = "notify.deadlines", deadlineHour = "notify.deadlineHour"
    }

    override init() {
        super.init()
        UserDefaults.standard.register(defaults: [Key.enabled: true, Key.lead: 0, Key.tasks: true, Key.routines: true,
                                                  Key.deadlines: true, Key.deadlineHour: 8])
        center.delegate = self
    }

    var options: ReminderOptions {
        let d = UserDefaults.standard
        return ReminderOptions(leadMinutes: d.integer(forKey: Key.lead), tasks: d.bool(forKey: Key.tasks),
                               routines: d.bool(forKey: Key.routines), deadlines: d.bool(forKey: Key.deadlines),
                               deadlineHour: d.integer(forKey: Key.deadlineHour))
    }

    func refreshStatus() async {
        status = await center.notificationSettings().authorizationStatus
    }

    /// Asks once, the first time there is something to announce.
    func requestIfNeeded(for book: Notebook) async {
        await refreshStatus()
        guard status == .notDetermined, UserDefaults.standard.bool(forKey: Key.enabled),
              !ReminderPlan.requests(for: book, now: Date(), options: options, days: 7).isEmpty else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        await refreshStatus()
        reschedule(book)
    }

    /// Rebuilds the next days' banners. Debounced so a burst of edits schedules once.
    func reschedule(_ book: Notebook) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            await self.apply(book)
        }
    }

    private func apply(_ book: Notebook) async {
        let ours = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("horme.") }
        center.removePendingNotificationRequests(withIdentifiers: ours)
        await refreshStatus()
        guard UserDefaults.standard.bool(forKey: Key.enabled),
              status == .authorized || status == .provisional || status == .ephemeral else { return }
        let calendar = Calendar.current
        for plan in ReminderPlan.requests(for: book, now: Date(), options: options) {
            let content = UNMutableNotificationContent()
            content.title = plan.title
            content.body = plan.body
            content.sound = .default
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: plan.date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: plan.id, content: content, trigger: trigger))
        }
    }

    /// Show the banner even while Horme is open; time blindness does not stop when the app is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

@MainActor
struct NotificationSettingsSection: View {
    @EnvironmentObject private var store: TaskStore
    @ObservedObject private var reminders = Reminders.shared
    @AppStorage(Reminders.Key.enabled) private var enabled = true
    @AppStorage(Reminders.Key.lead) private var lead = 0
    @AppStorage(Reminders.Key.tasks) private var tasks = true
    @AppStorage(Reminders.Key.routines) private var routines = true
    @AppStorage(Reminders.Key.deadlines) private var deadlines = true
    @AppStorage(Reminders.Key.deadlineHour) private var deadlineHour = 8
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            Toggle("通知を使う", isOn: $enabled)
            if enabled {
                if reminders.status == .denied {
                    Button("iPhoneの設定で通知を許可する") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                    }
                } else if reminders.status == .notDetermined {
                    Button("通知を許可する") {
                        Task {
                            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                            await reminders.refreshStatus(); reminders.reschedule(store.realNotebook)
                        }
                    }
                }
                Picker("知らせるタイミング", selection: $lead) {
                    Text("始まる時刻").tag(0)
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0)分前").tag($0) }
                }
                Toggle("タスク", isOn: $tasks)
                Toggle("ルーティン", isOn: $routines)
                Toggle("締切の日の朝", isOn: $deadlines)
                if deadlines {
                    Picker("朝の時刻", selection: $deadlineHour) {
                        ForEach(5...11, id: \.self) { Text("\($0):00").tag($0) }
                    }
                }
            }
        } header: { Text("通知") }
        footer: {
            Text("時刻を決めたタスクとルーティンをバナーで知らせます。個別に止めるときは、それぞれの編集画面で「通知」を切ります。睡眠などの「押さえるだけ」の時間は知らせません。")
        }
        .onChange(of: [enabled, tasks, routines, deadlines]) { _, _ in reminders.reschedule(store.realNotebook) }
        .onChange(of: [lead, deadlineHour]) { _, _ in reminders.reschedule(store.realNotebook) }
        .task { await reminders.refreshStatus() }
    }
}
