import Foundation
import SwiftUI

@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var notebook = Notebook()
    @Published var error: String?
    @Published private(set) var loadFailed = false
    @Published private(set) var canUndo = false
    private var history: [Notebook] = []
    private let repository: NotebookRepository

    init() {
        var directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ThreeDays", isDirectory: true)
        #if DEBUG
        // Screenshot runs use a throwaway folder so they never touch real data.
        if DemoLaunch.isOn {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("ThreeDays-demo-\(UUID().uuidString)")
        }
        #endif
        repository = NotebookRepository(url: directory.appendingPathComponent("notebook.json"))
        do { notebook = try repository.load() }
        catch { loadFailed = true; self.error = "保存データを開けませんでした。\(error.localizedDescription)" }
        #if DEBUG
        if DemoLaunch.isOn {
            var sample = Notebook.sample(now: Date())
            if DemoLaunch.value("uiOpen") == "focus", let first = sample.tasks.first {
                sample.startTask(first.id)
            }
            notebook = sample
            try? repository.save(sample)
        }
        #endif
    }

    @discardableResult
    func commit(_ update: (inout Notebook) -> Void) -> Bool {
        guard !loadFailed else { error = "読み込みに失敗したデータを保護しています。設定から直前の保存を復旧してください。"; return false }
        var next = notebook
        update(&next)
        guard next != notebook else { return true }
        do {
            try repository.save(next)
            history.append(notebook)
            if history.count > 20 { history.removeFirst() }
            notebook = next; canUndo = !history.isEmpty
            return true
        } catch { self.error = "保存できませんでした。変更は反映していません。\(error.localizedDescription)"; return false }
    }

    func undo() {
        guard let previous = history.last else { return }
        do {
            try repository.save(previous)
            notebook = previous; history.removeLast(); canUndo = !history.isEmpty
        } catch { self.error = error.localizedDescription }
    }

    func task(_ id: UUID) -> TaskItem? { notebook.tasks.first { $0.id == id } }

    func upsert(_ task: TaskItem) -> Bool {
        commit { book in
            if let i = book.tasks.firstIndex(where: { $0.id == task.id }) { book.tasks[i] = task }
            else { book.tasks.append(task) }
        }
    }

    func change(_ id: UUID, _ update: (inout TaskItem) -> Void) {
        commit { book in
            if let i = book.tasks.firstIndex(where: { $0.id == id }) { update(&book.tasks[i]) }
        }
    }

    func complete(_ id: UUID) {
        commit { book in
            guard let i = book.tasks.firstIndex(where: { $0.id == id }) else { return }
            book.tasks[i].completedAt = book.tasks[i].isComplete ? nil : Date()
            if book.activeSession?.taskID == id { book.activeSession = nil }
        }
    }

    func delete(_ id: UUID) {
        commit { book in
            book.tasks.removeAll { $0.id == id }
            if book.activeSession?.taskID == id { book.activeSession = nil }
        }
    }

    func start(_ task: TaskItem) {
        commit { $0.startTask(task.id) }
    }

    func pause(note: String) -> Bool {
        commit { $0.pauseTask(note: note) }
    }

    func finishAction() -> Bool {
        commit { $0.finishAction() }
    }

    func convert(_ idea: Idea, plannedAt: Date?) -> Bool {
        commit { book in
            let lines = idea.text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
            book.tasks.append(TaskItem(title: lines.first ?? idea.text, plannedAt: plannedAt,
                                       memo: lines.dropFirst().joined(separator: "\n"), createdAt: idea.createdAt))
            book.ideas.removeAll { $0.id == idea.id }
        }
    }

    func recover() {
        do {
            notebook = try repository.recoverPrevious(); loadFailed = false
            history = []; canUndo = false
        } catch { self.error = "直前の保存から復旧できませんでした。\(error.localizedDescription)" }
    }

    var canRecoverPrevious: Bool { repository.hasPrevious }

    /// The unreadable file stays on the device; this only lets the person continue or restore a backup.
    func startOver() {
        do {
            try repository.setAsideUnreadable()
            notebook = Notebook(); loadFailed = false
            history = []; canUndo = false
        } catch { self.error = "読めないデータを退避できませんでした。\(error.localizedDescription)" }
    }
}

extension Notebook {
    /// Shared by "サンプルで試す" and the screenshot runs.
    static func sample(now: Date) -> Notebook {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)
        let nextWeek = calendar.date(byAdding: .day, value: 6, to: now)
        return Notebook(tasks: [
            TaskItem(title: "提出書類を送る", plannedAt: now, deadline: now, isMust: true, effort: .light, project: "手続き",
                     memo: "これはサンプルです。", steps: [Step(title: "宛先を確認する"), Step(title: "メールに添付して送る")],
                     createdAt: now.addingTimeInterval(-7200)),
            TaskItem(title: "予約の電話をする", plannedAt: now, scheduledTime: "14:00", effort: .light, createdAt: now.addingTimeInterval(-7000)),
            TaskItem(title: "読みかけの本を読む", effort: .light, resumeNote: "42ページの途中まで", createdAt: now.addingTimeInterval(-6800)),
            TaskItem(title: "提案の下書きをつくる", deadline: tomorrow, effort: .heavy, project: "仕事",
                     steps: [Step(title: "見出しを3つ書く")], createdAt: now.addingTimeInterval(-6600)),
            TaskItem(title: "週末の買い物を考える", plannedAt: tomorrow, createdAt: now.addingTimeInterval(-6400)),
            TaskItem(title: "気になる資料を読む", effort: .medium, createdAt: now.addingTimeInterval(-6200)),
            TaskItem(title: "年末調整の書類をそろえる", deadline: nextWeek, project: "手続き", createdAt: now.addingTimeInterval(-6000))
        ], ideas: [
            Idea(text: "散歩中に聞ける勉強メモを作れそう\nやると決めるまではアイデアに置く。", createdAt: now.addingTimeInterval(-3600)),
            Idea(text: "部屋の模様替え、机を窓側に？", createdAt: now.addingTimeInterval(-86400))
        ])
    }
}

#if DEBUG
/// Launch arguments for CI screenshots only (scripts/simulator-smoke.sh). Compiled out of Release builds.
enum DemoLaunch {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-uiDemo") }
    static func value(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "-" + name), arguments.indices.contains(i + 1) else { return nil }
        return arguments[i + 1]
    }
}
#endif
