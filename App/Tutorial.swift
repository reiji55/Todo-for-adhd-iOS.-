import SwiftUI

/// The guided first run: in demo mode, a card under the title bar says what to try next, the place to try it
/// glows, and the step moves on by itself once it has been done (or with 次へ). It starts by itself the first
/// time Horme opens with nothing in it, picks up where it was left if Horme was closed half way, and スキップ ends
/// it at once, demo and all.
@MainActor
final class Tutorial: ObservableObject {
    static let shared = Tutorial()

    enum Step: Int, CaseIterable {
        case add, now, timetable, week, pieces, idea, list, project, finish

        var tab: RootView.Tab {
            switch self {
            case .add, .now, .timetable, .finish: return .today
            case .week: return .week
            case .pieces: return .all
            case .idea, .list: return .ideas
            case .project: return .board
            }
        }

        /// What glows once the person is on the step's tab.
        var spot: Spot? {
            switch self {
            case .add: return .addButton
            case .now: return .nowCard
            case .timetable: return .timetableLink
            default: return nil
            }
        }

        var title: String {
            switch self {
            case .add: return "⊕ からタスクを足す"
            case .now: return "「いま」の1つに取りかかる"
            case .timetable: return "今日の時間割を見る"
            case .week: return "週の画面で予定を動かす"
            case .pieces: return "大きいことは小さく分ける"
            case .idea: return "思いつきはアイデアに"
            case .list: return "具体的なものはリストに"
            case .project: return "目標はプロジェクトに"
            case .finish: return "これで一通りです"
            }
        }

        var detail: String {
            switch self {
            case .add: return "右下の ⊕ をタップして、やることを1つ書いてみましょう。タイトルだけで足せます。"
            case .now: return "「いま」には、次にやることが1つだけ出ます。「始める」を押して、終わったら完了にしてみましょう。"
            case .timetable: return "「今日の流れ」をタップすると、一日の予定と空き時間が時間割で見えます。"
            case .week: return "下の「週」を開いて、予定を長押しし、別の日や時間帯へ動かしてみましょう。"
            case .pieces: return "「すべて」でタスクを開き、「子タスクに分ける」に書いてみましょう。何から始めるかがはっきりします。"
            case .idea: return "「ストック」のアイデアに、思いついたことを書き留めましょう。やると決めたらタスクにできます。"
            case .list: return "ストックの「リスト」で右下の ＋ からリストを作り、項目を1つ足してみましょう。買う物や行きたい所をためておけます。"
            case .project: return "「ボード」の右下の ＋ からプロジェクトを作ってみましょう。目標までの道のりが山で見えます。"
            case .finish: return "「はじめる」で、ここで試した内容は消えて、まっさらな状態から始まります。もう少し触りたいときは、このまま続けられます。"
            }
        }
    }

    enum Spot: Hashable {
        case addButton, nowCard, timetableLink
        case tab(RootView.Tab)
    }

    /// Things the screens tell the tutorial about; changes to the data it sees for itself.
    enum Event { case timetableOpened, projectOpened }

    /// The step shown, nil while the tutorial is not running.
    @Published private(set) var step: Step?
    /// A moment of "できました" before the next step comes.
    @Published private(set) var done = false

    private var baseline = Counts()
    private static let stepKey = "horme.tutorial.step"
    private static let finishedKey = "horme.tutorial.finished"

    var isRunning: Bool { step != nil }

    /// What glows on the screen now: the tab to go to, or, on that tab, the place to try.
    func spot(on tab: Int) -> Spot? {
        guard let step, !done, step != .finish else { return nil }
        return tab == step.tab.rawValue ? step.spot : .tab(step.tab)
    }

    /// The first time Horme opens with nothing in it, or when it was closed half way through.
    func startIfNeeded(store: TaskStore) {
        let defaults = UserDefaults.standard
        #if DEBUG
        // For the screenshot of the first step.
        if ProcessInfo.processInfo.arguments.contains("-uiTutorial") { begin(at: .add, store: store); return }
        #endif
        guard !isRunning, !defaults.bool(forKey: Self.finishedKey), !store.loadFailed else { return }
        // Tests and screenshots start Horme with their own arguments and their own data.
        guard !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-ui") }) else { return }
        guard store.realNotebook.isEmpty else {
            // Someone who already has their own things does not need the samples.
            defaults.set(true, forKey: Self.finishedKey)
            return
        }
        let saved = Step(rawValue: defaults.integer(forKey: Self.stepKey)) ?? .add
        begin(at: saved, store: store)
    }

    /// From the start, from 設定.
    func restart(store: TaskStore) {
        UserDefaults.standard.set(false, forKey: Self.finishedKey)
        begin(at: .add, store: store)
    }

    private func begin(at first: Step, store: TaskStore) {
        // Empty, not the samples: a sample event or routine at this hour would hold the いま card.
        if store.isDemo { store.endDemo() }
        store.startDemo(samples: false)
        show(first, book: store.notebook)
    }

    /// スキップ, or demo mode ended another way: the tutorial is over and does not come back by itself.
    func stop(store: TaskStore) {
        guard isRunning else { return }
        finish()
        store.endDemo()
    }

    /// はじめる on the last card: the samples go and the person's own Horme starts.
    func complete(store: TaskStore) {
        finish()
        store.endDemo()
    }

    /// もう少し触る: the card goes; demo mode stays until it is ended as usual.
    func keepPlaying() { finish() }

    /// 次へ, for a step the person would rather not try.
    func next(book: Notebook) {
        guard let step, let following = Step(rawValue: step.rawValue + 1) else { return }
        show(following, book: book)
    }

    /// Demo mode was ended from its own bar or from 設定.
    func demoEnded() {
        if isRunning { finish() }
    }

    func report(_ event: Event) {
        switch (step, event) {
        case (.timetable?, .timetableOpened), (.project?, .projectOpened): markDone()
        default: break
        }
    }

    /// Every change to the data: does it show the step was done?
    func notebookChanged(_ book: Notebook) {
        guard let step, !done else { return }
        let now = Counts(book)
        let achieved: Bool
        switch step {
        case .add: achieved = now.tasks > baseline.tasks
        case .now: achieved = now.completed > baseline.completed
        case .week: achieved = now.moved(from: baseline)
        case .pieces: achieved = now.pieces > baseline.pieces
        case .idea: achieved = now.ideas > baseline.ideas
        case .list: achieved = now.items > baseline.items
        case .project: achieved = now.projects > baseline.projects
        case .timetable, .finish: achieved = false
        }
        if achieved { markDone() } else { baseline.keepUp(with: now, during: step) }
    }

    private func markDone() {
        guard let step, !done else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.snappy) { done = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            guard let self, self.step == step, self.done else { return }
            guard let following = Step(rawValue: step.rawValue + 1) else { self.finish(); return }
            self.show(following, book: TaskStore.shared.notebook)
        }
    }

    private func show(_ next: Step, book: Notebook) {
        baseline = Counts(book)
        UserDefaults.standard.set(next.rawValue, forKey: Self.stepKey)
        withAnimation(.snappy) {
            done = false
            step = next
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.finishedKey)
        UserDefaults.standard.removeObject(forKey: Self.stepKey)
        withAnimation(.snappy) {
            step = nil
            done = false
        }
    }

    /// What a step looks for, counted when it begins.
    private struct Counts {
        var tasks = 0, completed = 0, pieces = 0, ideas = 0, items = 0, projects = 0
        /// Each task's day and time, to see one moved.
        var places: [UUID: String] = [:]

        init() {}
        init(_ book: Notebook) {
            tasks = book.tasks.count
            completed = book.tasks.filter(\.isComplete).count
            pieces = book.tasks.filter { $0.parentID != nil }.count
            ideas = book.ideas.count
            items = book.listItems.count
            projects = book.projects.count
            places = Dictionary(uniqueKeysWithValues: book.tasks.map { ($0.id, Self.place($0)) })
        }

        static func place(_ task: TaskItem) -> String {
            "\(task.plannedAt.map { DayKey.of($0) } ?? "-") \(task.scheduledTime)"
        }

        /// A task that was already there now has another day or time.
        func moved(from before: Counts) -> Bool {
            places.contains { id, place in before.places[id].map { $0 != place } ?? false }
        }

        /// Things removed along the way (a deleted task, an idea made into a task) lower the counts the step
        /// is waiting to see rise.
        mutating func keepUp(with now: Counts, during step: Step) {
            tasks = min(tasks, now.tasks); completed = min(completed, now.completed); pieces = min(pieces, now.pieces)
            ideas = min(ideas, now.ideas); items = min(items, now.items); projects = min(projects, now.projects)
            if step == .week {
                // A task added during the step is not a move.
                for (id, place) in now.places where places[id] == nil { places[id] = place }
            }
        }
    }
}

/// The card under the title bar while the tutorial runs, in place of the demo-mode bar.
@MainActor
struct TutorialCard: View {
    @EnvironmentObject private var store: TaskStore
    @ObservedObject var tutorial = Tutorial.shared
    let step: Tutorial.Step

    var body: some View {
        let total = Tutorial.Step.allCases.count - 1
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(step == .finish ? "チュートリアル" : "チュートリアル \(step.rawValue + 1)/\(total)")
                    .font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 4)
                if step != .finish {
                    Button("スキップ") { tutorial.stop(store: store) }
                        .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
                        .accessibilityHint("チュートリアルとデモモードを終えます")
                        .accessibilityIdentifier("tutorialSkip")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if tutorial.done {
                    Image(systemName: "checkmark.circle.fill").transition(.scale.combined(with: .opacity))
                }
                Text(tutorial.done ? "できました" : step.title).font(.subheadline.weight(.heavy))
            }
            .foregroundStyle(.white)
            if !tutorial.done {
                Text(step.detail).font(.caption).foregroundStyle(.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                Text("（チュートリアルのデータは保存されません）").font(.caption2).foregroundStyle(.white.opacity(0.7))
                HStack(spacing: 10) {
                    if step == .finish {
                        Button { tutorial.keepPlaying() } label: {
                            Text("もう少し触る").font(.caption.weight(.semibold)).padding(.horizontal, 12).frame(minHeight: 32)
                        }
                        .foregroundStyle(.white)
                        Spacer(minLength: 0)
                        Button { tutorial.complete(store: store) } label: {
                            Text("はじめる").font(.caption.weight(.heavy)).padding(.horizontal, 16).frame(minHeight: 32)
                                .background(Color.white, in: Capsule())
                        }
                        .foregroundStyle(Palette.accent)
                        .accessibilityIdentifier("tutorialBegin")
                    } else {
                        // Progress, as dots.
                        HStack(spacing: 4) {
                            ForEach(0..<total, id: \.self) { index in
                                Circle().fill(Color.white.opacity(index <= step.rawValue ? 0.95 : 0.35)).frame(width: 5, height: 5)
                            }
                        }
                        .accessibilityHidden(true)
                        Spacer(minLength: 0)
                        Button { tutorial.next(book: store.notebook) } label: {
                            Text("次へ").font(.caption.weight(.bold)).padding(.horizontal, 14).frame(minHeight: 30)
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.7)))
                        }
                        .foregroundStyle(.white)
                        .accessibilityHint("この手順を飛ばします")
                        .accessibilityIdentifier("tutorialNext")
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
        .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tutorialCard")
    }
}

/// A glowing ring around the place the tutorial points at.
private struct TutorialSpotRing: ViewModifier {
    @ObservedObject private var tutorial = Tutorial.shared
    @Environment(\.selectedTab) private var selectedTab
    let spot: Tutorial.Spot
    var cornerRadius: CGFloat = 16
    /// Round things (the 今日 button, ⊕) get a round ring that follows their outline.
    var circle = false
    /// The tab in front, for views outside the tabs (the tab bar), where the environment does not say.
    var tab: Int?
    @State private var pulse = false

    func body(content: Content) -> some View {
        let lit = tutorial.spot(on: tab ?? selectedTab) == spot
        content.overlay {
            if lit {
                Group {
                    if circle { Circle().strokeBorder(Palette.accent, lineWidth: 3) }
                    else { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Palette.accent, lineWidth: 3) }
                }
                    .padding(-5)
                    .scaleEffect(pulse ? 1.04 : 0.98)
                    .opacity(pulse ? 0.45 : 1)
                    .shadow(color: Palette.accent.opacity(0.5), radius: 6)
                    .allowsHitTesting(false)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
                    }
                    .onDisappear { pulse = false }
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    func tutorialSpot(_ spot: Tutorial.Spot, cornerRadius: CGFloat = 16, circle: Bool = false, tab: Int? = nil) -> some View {
        modifier(TutorialSpotRing(spot: spot, cornerRadius: cornerRadius, circle: circle, tab: tab))
    }
}
