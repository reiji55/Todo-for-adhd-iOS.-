import ActivityKit
import AppIntents
import Foundation

/// The いま card on the lock screen and in the Dynamic Island, as a Live Activity. The app starts it and
/// keeps it up to date; its two buttons run in the app (see NowActivityActions).
struct NowActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// いま, 次 or 実行中.
        var badge: String
        /// When it is: "12:00–13:00" or "空き時間 · 19:00まで". Empty while it is being worked on.
        var context: String
        /// The task it is a piece of and why it is here ("↳ 提出書類を送る ★ ・ 今日が締切").
        var kicker: String
        /// The kicker speaks of a deadline or ★, shown in the must color.
        var kickerIsUrgent: Bool
        var title: String
        /// The agenda item's id ("task-…" or "routine-…-day").
        var itemID: String
        var canFinish: Bool
        var canPass: Bool
        /// Set while the task is being worked on: the lock screen counts up from it.
        var startedAt: Date?
    }
}

/// What the lock screen's buttons do. The app sets these when it starts; the system runs the intents in
/// the app, so in the widget extension they are never called.
@MainActor
enum NowActivityActions {
    static var finish: @MainActor (String) async -> Void = { _ in }
    static var pass: @MainActor (String) async -> Void = { _ in }
}

struct FinishNowIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "いまのものを済みにする"
    static var isDiscoverable = false
    @Parameter(title: "項目") var itemID: String

    init() {}
    init(itemID: String) { self.itemID = itemID }

    @MainActor
    func perform() async throws -> some IntentResult {
        await NowActivityActions.finish(itemID)
        return .result()
    }
}

struct PassNowIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "いまのものを次の候補に替える"
    static var isDiscoverable = false
    @Parameter(title: "項目") var itemID: String

    init() {}
    init(itemID: String) { self.itemID = itemID }

    @MainActor
    func perform() async throws -> some IntentResult {
        await NowActivityActions.pass(itemID)
        return .result()
    }
}
