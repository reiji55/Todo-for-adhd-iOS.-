import Foundation

/// A list of concrete things kept for later: places to go, books to read, things to buy. It is stock, not
/// a plan: nothing in it shows on Today until it is made into a task or an event. One kind of list serves
/// every use; an item may carry notes, links and a place.
public struct StockList: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    /// When the list itself last changed (renamed, or a thing on it removed). What its things say about
    /// themselves is read from them: see `Notebook.lastChange(of:)`.
    public var updatedAt: Date?

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// A web address kept with a thing on a list, with an optional name (参考資料、問い合わせ先、会話のリンク…).
public struct ItemLink: Codable, Identifiable, Equatable {
    public var id: UUID
    public var url: String
    public var title: String

    public init(id: UUID = UUID(), url: String, title: String = "") {
        self.id = id; self.url = url; self.title = title
    }

    enum CodingKeys: String, CodingKey { case id, url, title }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
    }

    /// What it is called on screen: its name, else the address without its scheme.
    public var label: String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return address.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    }
}

/// A note kept with a thing on a list: its purpose, steps, how it went, anything. As many as wanted, each
/// written on its own day; they can be added after the thing is done.
public struct ItemNote: Codable, Identifiable, Equatable {
    public var id: UUID
    public var text: String
    public var createdAt: Date

    public init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id; self.text = text; self.createdAt = createdAt
    }
}

public struct ListItem: Codable, Identifiable, Equatable {
    public var id: UUID
    public var listID: UUID
    public var title: String
    /// Notes, in the order they were written.
    public var notes: [ItemNote]
    /// Web addresses, in the order they were added.
    public var links: [ItemLink]
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
    /// When it was last written to or checked; nil means only when it was added.
    public var updatedAt: Date?

    /// `memo` and `link` are what a thing carried before it could have several: each becomes the first.
    public init(id: UUID = UUID(), listID: UUID, title: String, memo: String = "", link: String = "", place: String = "",
                group: String = "", createdAt: Date = Date(), doneAt: Date? = nil,
                latitude: Double? = nil, longitude: Double? = nil,
                notes: [ItemNote] = [], links: [ItemLink] = [], updatedAt: Date? = nil) {
        self.id = id; self.listID = listID; self.title = title; self.place = place
        self.group = group; self.createdAt = createdAt; self.doneAt = doneAt
        self.latitude = latitude; self.longitude = longitude; self.updatedAt = updatedAt
        let memoText = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = link.trimmingCharacters(in: .whitespacesAndNewlines)
        // The first of each takes the item's own id, so the same old record always reads the same way.
        self.notes = (memoText.isEmpty ? [] : [ItemNote(id: id, text: memo, createdAt: createdAt)]) + notes
        self.links = (address.isEmpty ? [] : [ItemLink(id: id, url: address)]) + links
    }

    public var hasCoordinate: Bool { latitude != nil && longitude != nil }

    public var isDone: Bool { doneAt != nil }

    /// Every note, one after another: what a thing carried before it could have several.
    public var memo: String {
        notes.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The first web address.
    public var link: String { links.first?.url ?? "" }

    /// The last time anything about it changed.
    public var lastChange: Date {
        max(updatedAt ?? createdAt, doneAt ?? createdAt, notes.map(\.createdAt).max() ?? createdAt, createdAt)
    }

    enum CodingKeys: String, CodingKey {
        case id, listID, title, memo, link, notes, links, place, group, createdAt, doneAt, latitude, longitude, updatedAt
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) throws -> String { try c.decodeIfPresent(String.self, forKey: key) ?? "" }
        let notes = try c.decodeIfPresent([ItemNote].self, forKey: .notes)
        let links = try c.decodeIfPresent([ItemLink].self, forKey: .links)
        // Written before notes and links: the single memo and link become the first of each.
        self.init(id: try c.decode(UUID.self, forKey: .id), listID: try c.decode(UUID.self, forKey: .listID),
                  title: try c.decode(String.self, forKey: .title),
                  memo: notes == nil ? try text(.memo) : "", link: links == nil ? try text(.link) : "",
                  place: try text(.place), group: try text(.group), createdAt: try c.decode(Date.self, forKey: .createdAt),
                  doneAt: try c.decodeIfPresent(Date.self, forKey: .doneAt),
                  latitude: try c.decodeIfPresent(Double.self, forKey: .latitude),
                  longitude: try c.decodeIfPresent(Double.self, forKey: .longitude),
                  notes: notes ?? [], links: links ?? [],
                  updatedAt: try c.decodeIfPresent(Date.self, forKey: .updatedAt))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(listID, forKey: .listID)
        try c.encode(title, forKey: .title)
        try c.encode(notes, forKey: .notes)
        try c.encode(links, forKey: .links)
        // The single memo and link are still written, for older versions of the app.
        try c.encode(memo, forKey: .memo)
        try c.encode(link, forKey: .link)
        try c.encode(place, forKey: .place)
        try c.encode(group, forKey: .group)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(doneAt, forKey: .doneAt)
        try c.encodeIfPresent(latitude, forKey: .latitude)
        try c.encodeIfPresent(longitude, forKey: .longitude)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }
}

public extension Notebook {
    func list(_ id: UUID) -> StockList? { lists.first { $0.id == id } }

    func listItem(_ id: UUID) -> ListItem? { listItems.first { $0.id == id } }

    /// The last day anything on a list changed: a thing added, written to, checked off or removed.
    func lastChange(of listID: UUID) -> Date? {
        guard let list = list(listID) else { return nil }
        let items = listItems.filter { $0.listID == listID }.map(\.lastChange)
        return ([list.updatedAt ?? list.createdAt, list.createdAt] + items).max()
    }

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
        listItems[i].updatedAt = now
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
            listItems.append(ListItem(listID: copy.id, title: item.title, place: item.place, group: item.group,
                                      createdAt: now.addingTimeInterval(Double(index) / 1000),
                                      latitude: item.latitude, longitude: item.longitude,
                                      notes: item.notes, links: item.links))
        }
        return copy.id
    }

    /// An idea that has become something concrete moves onto a list: its text names the item, its added
    /// lines become its notes, and the idea is gone.
    mutating func moveIdea(_ id: UUID, toList listID: UUID, at now: Date = Date()) -> Bool {
        guard let idea = ideas.first(where: { $0.id == id }), list(listID) != nil,
              !listItems.contains(where: { $0.id == id }) else { return false }
        listItems.append(ListItem(id: idea.id, listID: listID, title: idea.text, createdAt: now,
                                  notes: idea.notes.map { ItemNote(id: $0.id, text: $0.text, createdAt: $0.createdAt) }))
        ideas.removeAll { $0.id == id }
        return true
    }
}
