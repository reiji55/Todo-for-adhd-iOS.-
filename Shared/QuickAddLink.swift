import AppIntents
import Foundation

/// What a widget or control asks Horme to open: the add screen for a task or an idea.
/// Compiled into both the app and the widget extension, so both sides agree on the links.
enum QuickAddLink: String, CaseIterable {
    case task, idea

    static let scheme = "horme"
    /// Left by a control's intent for the app to pick up when it comes to the front.
    static let pendingKey = "horme.pendingQuickAdd"
    static let requested = Notification.Name("horme.quickAddRequested")

    var url: URL { URL(string: "\(Self.scheme)://add/\(rawValue)")! }

    init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == "add", let link = QuickAddLink(rawValue: url.lastPathComponent) else {
            return nil
        }
        self = link
    }

    var title: String {
        switch self {
        case .task: return "タスクを書く"
        case .idea: return "アイデアを書く"
        }
    }
    var shortTitle: String {
        switch self {
        case .task: return "タスク"
        case .idea: return "アイデア"
        }
    }
    var detail: String {
        switch self {
        case .task: return "今日・明日・いつでも"
        case .idea: return "思いついたまま"
        }
    }
    var symbol: String {
        switch self {
        case .task: return "checkmark.circle"
        case .idea: return "lightbulb"
        }
    }

    /// Runs inside the app (the intents open it first): remember the request and tell the screen.
    func request() {
        UserDefaults.standard.set(rawValue, forKey: Self.pendingKey)
        NotificationCenter.default.post(name: Self.requested, object: nil)
    }
}

/// Used by the Control Center and lock screen buttons; also available in Shortcuts and the Action button.
struct OpenTaskQuickAddIntent: AppIntent {
    static var title: LocalizedStringResource = "タスクを書く画面を開く"
    static var description = IntentDescription("Hormeを開いて、タスクを書く画面を出します。")
    static var openAppWhenRun = true
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        QuickAddLink.task.request()
        return .result()
    }
}

struct OpenIdeaQuickAddIntent: AppIntent {
    static var title: LocalizedStringResource = "アイデアを書く画面を開く"
    static var description = IntentDescription("Hormeを開いて、アイデアを書き留める画面を出します。")
    static var openAppWhenRun = true
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        QuickAddLink.idea.request()
        return .result()
    }
}
