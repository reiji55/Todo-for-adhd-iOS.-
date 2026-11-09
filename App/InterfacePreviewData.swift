#if DEBUG
import Foundation

/// Deterministic in-memory data for UI interaction tests and actual simulator screenshots.
/// Enabled only by an explicit Debug launch argument, never a production-data operation.
@MainActor
enum InterfacePreviewData {
    static func notebook(_ scenario: String, now: Date = Date()) -> Notebook {
        let calendar = Calendar.current
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let ongoing = TimeSlot(start: max(0, minute - 5), duration: 30).label
        let later = TimeSlot(start: min(23 * 60, minute + 90), duration: 30).label
        let parent = TaskItem(title: "案内メールを送る", deadline: now, isMust: true, project: "仕事", createdAt: now.addingTimeInterval(-1000))
        let titles = ["本文を下書きする", "送信先をそろえる", "PDFを用意する", "宛先と添付を確認する"]
        let children = (0..<10).map { i in
            TaskItem(title: i < titles.count ? titles[i] : "確認項目 \(i + 1)",
                     effort: .medium, project: "仕事", memo: i == 3 ? "添付は共有フォルダの最新版。" : "",
                     createdAt: now.addingTimeInterval(Double(-900 + i)), completedAt: i < 3 ? now : nil,
                     parentID: parent.id, rank: i,
                     continuationNote: i == 3 && scenario == "memo" ? "宛先は確認済み。次はPDFの差し替え。" : "")
        }
        let event = TaskItem(title: scenario == "event" ? "打ち合わせ" : "歯医者の予約", plannedAt: now,
                             scheduledTime: scenario == "event" ? ongoing : later,
                             memo: "保険証を持参する", createdAt: now, isEvent: true)
        let routine = Routine(title: "読書", memo: "寝る前に30分", time: scenario == "routine" ? ongoing : later,
                              createdAt: now, resumeNote: "42ページから")
        var tasks = [parent] + children + [event, TaskItem(title: "洗濯物をたたむ", createdAt: now)]
        if scenario == "event" || scenario == "routine" { tasks.removeAll { $0.id == parent.id || $0.parentID == parent.id } }
        for offset in [-2, -1, 1, 2] {
            tasks.append(TaskItem(title: "\(DaySwitcher.name(for: offset))の予定",
                                  plannedAt: calendar.date(byAdding: .day, value: offset, to: now),
                                  scheduledTime: "13:00-14:00", memo: "予定の持ち物を確認する", createdAt: now, isEvent: true))
        }
        return Notebook(tasks: tasks, routines: [routine])
    }
}
#endif
