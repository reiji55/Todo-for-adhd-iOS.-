import XCTest
@testable import TaskCore

final class ProjectNextTaskTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))! }

    func testProjectSelectionUsesExistingDeadlinePriorityWithoutChangingDates() {
        let other = TaskItem(title: "Other", deadline: now, project: "Other")
        let someday = TaskItem(title: "Someday", project: "Study")
        let due = TaskItem(title: "Due", deadline: now, project: "Study")
        let book = Notebook(tasks: [other, someday, due])
        XCTAssertEqual(ProjectBook.nextTask(ProjectBook.key("Study"), in: book, now: now, calendar: calendar)?.id, due.id)
        XCTAssertNil(book.tasks.last?.plannedAt)
        XCTAssertNil(book.tasks.last?.lastStartedAt)
    }

    func testParentOffersItsNextIncompleteChildEvenWhenChildHasNoProjectText() {
        let parent = TaskItem(title: "Proposal", deadline: now, project: "Work")
        let done = TaskItem(title: "Outline", completedAt: now, parentID: parent.id, rank: 0)
        let next = TaskItem(title: "Draft", parentID: parent.id, rank: 1)
        let book = Notebook(tasks: [parent, done, next])
        XCTAssertEqual(ProjectBook.nextTask(ProjectBook.key("Work"), in: book, now: now, calendar: calendar)?.id, next.id)
    }

    func testFutureDaysAndFixedTimesAreNotOfferedAsImmediateWork() {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        let futureDay = TaskItem(title: "Tomorrow", plannedAt: tomorrow, deadline: now, project: "Work")
        let futureTime = TaskItem(title: "Later today", plannedAt: now, scheduledTime: "18:00-19:00", deadline: now, project: "Work")
        let book = Notebook(tasks: [futureDay, futureTime])
        XCTAssertNil(ProjectBook.nextTask(ProjectBook.key("Work"), in: book, now: now, calendar: calendar))
    }

    func testEventsCompletedAndDeferredTasksDoNotHideAnActionableTask() {
        let event = TaskItem(title: "Appointment", plannedAt: now, project: "Work", isEvent: true)
        let done = TaskItem(title: "Done", project: "Work", completedAt: now)
        var deferred = TaskItem(title: "Deferred", project: "Work")
        deferred.suggestionDeferredUntil = now.addingTimeInterval(3600)
        let task = TaskItem(title: "Available", effort: .heavy, project: "Work")
        let book = Notebook(tasks: [event, done, deferred, task])
        XCTAssertEqual(ProjectBook.nextTask(ProjectBook.key("Work"), in: book, now: now, calendar: calendar)?.id, task.id)
    }
}
