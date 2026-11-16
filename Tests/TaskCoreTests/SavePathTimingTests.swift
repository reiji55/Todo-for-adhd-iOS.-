import XCTest
@testable import TaskCore

/// How long one edit takes to save, on data about the size of a few months of use. Every tap in the app
/// goes through this on the main thread, so it is what "the app feels slow" is made of. The times are
/// printed (lines starting with TIMING) rather than asserted tightly: machines differ.
final class SavePathTimingTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_790_000_000)

    private func sample() -> Notebook {
        func at(_ minutes: Int) -> Date { epoch.addingTimeInterval(Double(minutes) * 60) }
        let projects = (0..<6).map { p in
            Project(name: "プロジェクト\(p)", goal: "到達点", deadline: at(90_000), milestones: (0..<4).map {
                Milestone(title: "通過点\($0)", kind: .count, target: 5, current: 2, unit: "回", createdAt: at(p))
            }, createdAt: at(p), overview: "概要のメモ")
        }
        let tasks = (0..<400).map { i in
            TaskItem(title: "タスク\(i)", plannedAt: i % 3 == 0 ? nil : at(i * 60), scheduledTime: i % 4 == 0 ? "9:00-10:00" : "",
                     deadline: i % 7 == 0 ? at(i * 90) : nil, isMust: i % 11 == 0, project: i % 2 == 0 ? "プロジェクト\(i % 6)" : "",
                     memo: i % 5 == 0 ? "覚えておきたいことのメモ。少し長めの文章が入っていることもある。" : "",
                     createdAt: at(i), completedAt: i % 2 == 0 ? at(i * 60 + 30) : nil)
        }
        let ideas = (0..<40).map { i in
            Idea(text: "思いつき\(i)", createdAt: at(i), notes: (0..<(i % 4)).map { IdeaNote(text: "足したメモ\($0)", createdAt: at(i + $0)) })
        }
        let cards = (0..<30).map { BoardCard(title: "カード\($0)", purpose: "なぜ", goal: "どうなったら終わり",
                                             detail: "手順1\n手順2\n手順3\n手順4", createdAt: at($0), project: "プロジェクト\($0 % 6)") }
        let routines = (0..<15).map { r in
            Routine(title: "ルーティン\(r)", project: "プロジェクト\(r % 6)", time: "19:00-19:30", createdAt: at(r),
                    doneDays: (0..<120).map { String(format: "2026-%02d-%02d", 1 + $0 / 28, 1 + $0 % 28) },
                    durations: Dictionary(uniqueKeysWithValues: (0..<40).map { (String(format: "2026-%02d-%02d", 1 + $0 / 28, 1 + $0 % 28), 900) }))
        }
        let lists = (0..<8).map { StockList(name: "リスト\($0)", createdAt: at($0)) }
        let items = (0..<120).map { i in
            ListItem(listID: lists[i % 8].id, title: "項目\(i)", place: i % 6 == 0 ? "上野" : "", group: "見出し\(i % 3)",
                     createdAt: at(i), doneAt: i % 4 == 0 ? at(i + 500) : nil,
                     notes: i % 3 == 0 ? [ItemNote(text: "目的のメモ", createdAt: at(i))] : [],
                     links: i % 5 == 0 ? [ItemLink(url: "https://example.com/\(i)", title: "参考資料")] : [])
        }
        return Notebook(tasks: tasks, ideas: ideas, boardCards: cards, routines: routines, projects: projects,
                        lists: lists, listItems: items)
    }

    private func milliseconds(_ runs: Int, _ work: (Int) throws -> Void) rethrows -> Double {
        let start = Date()
        for run in 0..<runs { try work(run) }
        return Date().timeIntervalSince(start) * 1000 / Double(runs)
    }

    func testOneEditOnSyncedDataIsSavedQuickly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = SharedStoreRepository(directory: directory)
        var state = SharedStoreState(notebook: sample())
        state.bridge = true
        try state.startReplicaIfNeeded()
        try repo.save(state)
        state = try repo.load()
        let size = try Data(contentsOf: repo.url).count
        print("TIMING file size: \(size / 1024) KB, records: \(state.replica?.records.count ?? 0)")

        // Checking tasks off, one tap each, as the app's commit does: edit, then save.
        var editOnly = 0.0, saveOnly = 0.0
        let whole = try milliseconds(20) { run in
            var next = state.notebook
            next.toggleTask(next.tasks[run * 2 + 1].id, at: epoch.addingTimeInterval(1_000_000 + Double(run)))
            var changed = state
            let started = Date()
            try changed.edit(next)
            let edited = Date()
            try repo.save(changed)
            editOnly += edited.timeIntervalSince(started) * 1000 / 20
            saveOnly += Date().timeIntervalSince(edited) * 1000 / 20
            state = changed
        }
        print(String(format: "TIMING one edit: %.1f ms (edit %.1f ms, save %.1f ms)", whole, editOnly, saveOnly))

        // A sync that brings nothing new, as happens a second after every edit and every few minutes.
        let records = Array(state.replica!.records.values)
        let quiet = try milliseconds(10) { _ in
            var next = state
            try next.receive(records)
            XCTAssertEqual(next.replica?.records, state.replica?.records)
        }
        print(String(format: "TIMING sync with nothing new: %.1f ms", quiet))

        // What is on disk is what is in memory, and it reads back whole.
        let reloaded = try repo.load()
        XCTAssertEqual(reloaded.replica, state.replica)
        XCTAssertEqual(try reloaded.replica?.materialize(), try state.replica?.materialize())
        XCTAssertEqual(try NotebookCodec.decode(NotebookCodec.encode(reloaded.notebook)),
                       try NotebookCodec.decode(NotebookCodec.encode(state.notebook)))
        XCTAssertEqual(reloaded.notebook.tasks.filter(\.isComplete).count, 200 + 20)
    }
}
