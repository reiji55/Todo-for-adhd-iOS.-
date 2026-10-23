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
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ThreeDays", isDirectory: true)
        repository = NotebookRepository(url: directory.appendingPathComponent("notebook.json"))
        do { notebook = try repository.load() }
        catch { loadFailed = true; self.error = "保存データを開けませんでした。\(error.localizedDescription)" }
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
