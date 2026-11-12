import ActivityKit
import Foundation

/// Keeps いま on the lock screen. The Today screen hands it what its card shows whenever that changes; the
/// lock screen's 済んだ and 次の候補 come back here (run in the app by the system) and move it on.
/// It ends when nothing is left, when the day is closed, or when it is turned off in Settings.
@MainActor
final class NowActivityController {
    static let shared = NowActivityController()
    static let enabledKey = "nowOnLockScreen"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    typealias State = NowActivityAttributes.ContentState
    private var shown: State?

    /// Connects the lock screen's buttons; called once when the app starts.
    static func install() {
        NowActivityActions.finish = { id in shared.finish(id) }
        NowActivityActions.pass = { id in shared.pass(id) }
    }

    /// What the lock screen shows for a pick, worded as the card words it.
    static func state(for pick: NowPick, among picks: [NowPick], store: TaskStore, stretch: FreeStretch?,
                      work: TaskWork?) -> State {
        var working = false
        if case .task(let id) = pick.item.source, work?.taskID == id { working = true }
        var parts: [String] = []
        if let parent = pick.parentID.flatMap({ store.task($0) }) {
            parts.append("↳ \(parent.title)" + (parent.isMust ? " ★" : ""))
        } else if pick.isMust {
            parts.append("★必須")
        }
        if !pick.label.isEmpty { parts.append(pick.label) }
        let context: String
        if working {
            context = ""
        } else if let slot = pick.item.slot, pick.kind == .inSlot || pick.kind == .upcoming {
            context = "\(slot.startLabel)–\(TimeSlot.clock(slot.end))"
        } else if let stretch {
            context = NowView.stretchTitle(stretch) + " · " + NowView.stretchEnd(stretch)
        } else {
            context = ""
        }
        return State(badge: working ? "実行中" : pick.kind == .upcoming ? "次" : "いま",
                     context: context,
                     kicker: parts.joined(separator: " ・ "),
                     kickerIsUrgent: pick.isMust || pick.label.contains("締切"),
                     title: pick.item.title,
                     itemID: pick.item.id,
                     canFinish: !pick.item.isDone,
                     canPass: picks.contains { $0.id != pick.id } && !working,
                     startedAt: working ? work?.startedAt : nil)
    }

    /// Shows this on the lock screen, or takes it away when nil. Starting one needs the app in front;
    /// updating works from the background too.
    func show(_ state: State?) {
        guard Self.enabled, ActivityAuthorizationInfo().areActivitiesEnabled, let state else { end(); return }
        let live = Activity<NowActivityAttributes>.activities.filter { $0.activityState == .active }
        if state == shown, !live.isEmpty { return }
        shown = state
        let content = ActivityContent(state: state, staleDate: nil)
        if let activity = live.first {
            for extra in live.dropFirst() { Task { await extra.end(nil, dismissalPolicy: .immediate) } }
            Task { await activity.update(content) }
        } else {
            _ = try? Activity.request(attributes: NowActivityAttributes(), content: content, pushType: nil)
        }
    }

    func end() {
        shown = nil
        for activity in Activity<NowActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// 済んだ on the lock screen: checks it off (a task, an event, or today's turn of a routine).
    private func finish(_ id: String) {
        let store = TaskStore.shared
        let now = Date()
        if let item = Agenda.items(on: now, tasks: store.notebook.tasks, routines: store.notebook.routines)
            .first(where: { $0.id == id }), !item.isDone {
            store.toggle(item)
        } else if id.hasPrefix("task-"), let uuid = UUID(uuidString: String(id.dropFirst(5))),
                  store.task(uuid)?.isComplete == false {
            store.complete(uuid)
        }
        refresh()
    }

    /// 次の候補 on the lock screen: passes over it, as 入れ替える does on the card.
    private func pass(_ id: String) {
        var passed = PassedOver.load()
        passed.removeAll { $0 == id }
        passed.append(id)
        PassedOver.save(passed)
        refresh()
    }

    /// Works out the next one the way the card does when nothing is picked by hand.
    private func refresh() {
        let store = TaskStore.shared
        let now = Date()
        guard store.closedDay != DayKey.of(now) else { end(); return }
        let book = store.notebook
        let picks = NowPlan.picks(in: book, energy: EnergyMemory.load(now: now), now: now, passed: PassedOver.load(now: now))
        guard let first = picks.first else { end(); return }
        show(Self.state(for: first, among: picks, store: store, stretch: NowPlan.freeStretch(in: book, now: now), work: nil))
    }
}
