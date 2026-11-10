import Foundation

public extension ProjectBook {
    /// The same actionable work offered by Today, limited to one project's tasks. A future fixed
    /// appointment remains in the schedule; it is not turned into an immediate start suggestion.
    static func nextTask(_ projectKey: String, in book: Notebook, now: Date = Date(),
                         calendar: Calendar = .current) -> TaskItem? {
        let roots = Set(book.tasks.filter { $0.parentID == nil && key($0.project) == projectKey }.map(\.id))
        var scoped = book
        scoped.tasks = book.tasks.filter { roots.contains($0.id) || $0.parentID.map(roots.contains) == true }
        scoped.routines = []
        for pick in NowPlan.picks(in: scoped, energy: .any, now: now, calendar: calendar) where pick.kind != .upcoming {
            guard case .task(let id) = pick.item.source,
                  let task = scoped.tasks.first(where: { $0.id == id }),
                  !task.isComplete, !task.isEvent, !scoped.hasChildren(id) else { continue }
            if let day = task.plannedAt {
                if calendar.startOfDay(for: day) > calendar.startOfDay(for: now) { continue }
                if calendar.isDate(day, inSameDayAs: now), let slot = task.slot {
                    let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
                    if slot.start > minute { continue }
                }
            }
            return task
        }
        return nil
    }
}
