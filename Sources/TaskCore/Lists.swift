import Foundation

/// A list of concrete things kept for later: places to go, books to read, things to buy. It is stock, not
/// a plan: nothing in it shows on Today until it is made into a task or an event. One kind of list serves
/// every use; an item may carry a memo, a link and a place.
public struct StockList: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.createdAt = createdAt
    }
}

public struct ListItem: Codable, Identifiable, Equatable {
    public var id: UUID
    public var listID: UUID
    public var title: String
    public var memo: String
    /// A web address, as written.
    public var link: String
    /// A place name or address, opened in Maps.
    public var place: String
    /// An optional heading it is listed under (a dish or aisle, an area, a genre). Empty: none.
    public var group: String
    public var createdAt: Date
    /// When it was checked off, or when the plan made from it was done. Done items are the list's history
    /// (行った・読んだ・買った); they can be put back.
    public var doneAt: Date?
    /// Where the place is, when a map link said: drawn as a small map on the list.
    public var latitude: Double?
    public var longitude: Double?

    public init(id: UUID = UUID(), listID: UUID, title: String, memo: String = "", link: String = "", place: String = "",
                group: String = "", createdAt: Date = Date(), doneAt: Date? = nil,
                latitude: Double? = nil, longitude: Double? = nil) {
        self.id = id; self.listID = listID; self.title = title; self.memo = memo; self.link = link; self.place = place
        self.group = group; self.createdAt = createdAt; self.doneAt = doneAt
        self.latitude = latitude; self.longitude = longitude
    }

    public var hasCoordinate: Bool { latitude != nil && longitude != nil }

    public var isDone: Bool { doneAt != nil }

    enum CodingKeys: String, CodingKey { case id, listID, title, memo, link, place, group, createdAt, doneAt, latitude, longitude }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) throws -> String { try c.decodeIfPresent(String.self, forKey: key) ?? "" }
        self.init(id: try c.decode(UUID.self, forKey: .id), listID: try c.decode(UUID.self, forKey: .listID),
                  title: try c.decode(String.self, forKey: .title), memo: try text(.memo), link: try text(.link),
                  place: try text(.place), group: try text(.group), createdAt: try c.decode(Date.self, forKey: .createdAt),
                  doneAt: try c.decodeIfPresent(Date.self, forKey: .doneAt),
                  latitude: try c.decodeIfPresent(Double.self, forKey: .latitude),
                  longitude: try c.decodeIfPresent(Double.self, forKey: .longitude))
    }
}

public extension Notebook {
    func list(_ id: UUID) -> StockList? { lists.first { $0.id == id } }

    func listItem(_ id: UUID) -> ListItem? { listItems.first { $0.id == id } }

    /// What is still on the list, oldest first.
    func openItems(in listID: UUID) -> [ListItem] {
        listItems.filter { $0.listID == listID && !$0.isDone }
            .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }

    /// What is still on the list under its headings: those without one first, then each heading in the order
    /// its first open item was added.
    func openGroups(in listID: UUID) -> [(heading: String, items: [ListItem])] {
        var order: [String] = []
        var byHeading: [String: [ListItem]] = [:]
        for item in openItems(in: listID) {
            let heading = item.group.trimmingCharacters(in: .whitespacesAndNewlines)
            if byHeading[heading] == nil { order.append(heading) }
            byHeading[heading, default: []].append(item)
        }
        let ordered = order.filter(\.isEmpty) + order.filter { !$0.isEmpty }
        return ordered.map { ($0, byHeading[$0] ?? []) }
    }

    /// The headings used on a list, open or done, in the order they first appear.
    func headings(in listID: UUID) -> [String] {
        var seen = Set<String>()
        return listItems.filter { $0.listID == listID }
            .sorted { $0.createdAt < $1.createdAt }
            .map { $0.group.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The list's history, latest first.
    func doneItems(in listID: UUID) -> [ListItem] {
        listItems.filter { $0.listID == listID && $0.isDone }
            .sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
    }

    /// The open task or event made from an item, the earliest planned first.
    func plan(for itemID: UUID) -> TaskItem? {
        tasks.filter { $0.listItemID == itemID && !$0.isComplete }
            .min { ($0.plannedAt ?? .distantFuture) < ($1.plannedAt ?? .distantFuture) }
    }

    /// For a task made from a whole list: the things checked off since it was made, of all it covers
    /// (those plus what is still open). Nil for other tasks, or when the list is gone.
    func listProgress(of task: TaskItem) -> (done: Int, total: Int)? {
        guard let listID = task.listID, list(listID) != nil else { return nil }
        let open = listItems.filter { $0.listID == listID && !$0.isDone }.count
        let done = listItems.filter { item in
            item.listID == listID && (item.doneAt.map { $0 >= task.createdAt } ?? false)
        }.count
        return (done, done + open)
    }

    /// Checks a thing off its list, or puts it back. A task made from the whole list is done when the last
    /// open thing is checked off, and opens again if that check is undone.
    mutating func setItemDone(_ id: UUID, _ done: Bool, at now: Date = Date()) {
        guard let i = listItems.firstIndex(where: { $0.id == id }), listItems[i].isDone != done else { return }
        let listID = listItems[i].listID
        let previous = listItems[i].doneAt
        listItems[i].doneAt = done ? now : nil
        if done {
            guard !listItems.contains(where: { $0.listID == listID && !$0.isDone }) else { return }
            for k in tasks.indices where tasks[k].listID == listID && tasks[k].completedAt == nil && tasks[k].createdAt <= now {
                tasks[k].completedAt = now
                tasks[k].continuationNote = ""
            }
        } else if let previous {
            for k in tasks.indices where tasks[k].listID == listID && tasks[k].completedAt == previous {
                tasks[k].completedAt = nil
            }
        }
    }

    /// After tasks were checked off or reopened: a thing a task was made from follows it into the list's
    /// history, and comes back if that is undone.
    mutating func settleListItems(after before: [TaskItem]) {
        let previous = Dictionary(before.map { ($0.id, $0.completedAt) }, uniquingKeysWith: { first, _ in first })
        for task in tasks {
            guard let itemID = task.listItemID, let i = listItems.firstIndex(where: { $0.id == itemID }),
                  let old = previous[task.id], old != task.completedAt else { continue }
            if let finished = task.completedAt {
                if listItems[i].doneAt == nil { listItems[i].doneAt = finished }
            } else if let old, listItems[i].doneAt == old {
                listItems[i].doneAt = nil
            }
        }
    }

    /// A list and everything on it. Tasks made from it stay, without the link.
    mutating func removeList(_ id: UUID) {
        lists.removeAll { $0.id == id }
        listItems.removeAll { $0.listID == id }
    }

    /// A copy of a list with what is still open on it.
    @discardableResult
    mutating func duplicateList(_ id: UUID, name: String, at now: Date = Date()) -> UUID? {
        guard list(id) != nil else { return nil }
        let copy = StockList(name: name, createdAt: now)
        lists.append(copy)
        for (index, item) in openItems(in: id).enumerated() {
            listItems.append(ListItem(listID: copy.id, title: item.title, memo: item.memo, link: item.link, place: item.place,
                                      group: item.group, createdAt: now.addingTimeInterval(Double(index) / 1000)))
        }
        return copy.id
    }

    /// An idea that has become something concrete moves onto a list: its text names the item, its added
    /// lines become the memo, and the idea is gone.
    mutating func moveIdea(_ id: UUID, toList listID: UUID, at now: Date = Date()) -> Bool {
        guard let idea = ideas.first(where: { $0.id == id }), list(listID) != nil,
              !listItems.contains(where: { $0.id == id }) else { return false }
        listItems.append(ListItem(id: idea.id, listID: listID, title: idea.text,
                                  memo: idea.notes.map(\.text).joined(separator: "\n"), createdAt: now))
        ideas.removeAll { $0.id == id }
        return true
    }
}
