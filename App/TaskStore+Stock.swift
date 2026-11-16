import SwiftUI

/// The store's actions on what is kept for later: ideas (思いつき) and lists (具体的なもののストック).
extension TaskStore {
    func deleteIdea(_ id: UUID) {
        if commit({ $0.ideas.removeAll { $0.id == id } }) { offerUndo("付箋をはがしました") }
    }

    func convert(_ idea: Idea, plannedAt: Date?) -> Bool {
        guard notebook.ideas.contains(where: { $0.id == idea.id }), task(idea.id) == nil else {
            error = "このアイデアはすでに削除またはタスク化されています。最新の一覧を確認してください。"
            return false
        }
        return commit { $0.convertIdea(idea.id, plannedAt: plannedAt) }
    }

    func makeTasks(from idea: Idea, _ drafts: [TaskItem], keepIdea: Bool) -> Bool {
        guard notebook.ideas.contains(where: { $0.id == idea.id }) else {
            error = "このアイデアはすでに削除またはタスク化されています。最新の一覧を確認してください。"
            return false
        }
        return commit { $0.makeTasks(fromIdea: idea.id, drafts, keepIdea: keepIdea) }
    }

    func saveIdea(_ idea: Idea) -> Bool {
        guard notebook.ideas.contains(where: { $0.id == idea.id }) else {
            error = "このアイデアは別の端末で削除またはタスク化されました。入力した内容をコピーしてから閉じてください。"
            return false
        }
        return commit { book in
            if let index = book.ideas.firstIndex(where: { $0.id == idea.id }) {
                book.ideas[index].text = idea.text
                book.ideas[index].touchedAt = Date()
            }
        }
    }

    func idea(_ id: UUID) -> Idea? { notebook.ideas.first { $0.id == id } }

    /// Opening an idea warms it. Once an hour is enough; every glance need not be a change to sync.
    func touchIdea(_ id: UUID) {
        guard let idea = idea(id), Date().timeIntervalSince(idea.lastTouched) > 3600 else { return }
        commit { book in
            if let index = book.ideas.firstIndex(where: { $0.id == id }) { book.ideas[index].touchedAt = Date() }
        }
    }

    /// A line added to an idea (メモ). It warms the idea, and lets it become fully warm.
    func addIdeaNote(_ text: String, to id: UUID) -> Bool {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return false }
        guard idea(id) != nil else {
            error = "このアイデアは別の端末で削除またはタスク化されました。"
            return false
        }
        return commit { book in
            guard let index = book.ideas.firstIndex(where: { $0.id == id }) else { return }
            book.ideas[index].notes.append(IdeaNote(text: line))
            book.ideas[index].touchedAt = Date()
        }
    }

    func deleteIdeaNote(_ noteID: UUID, from id: UUID) {
        commit { book in
            guard let index = book.ideas.firstIndex(where: { $0.id == id }) else { return }
            book.ideas[index].notes.removeAll { $0.id == noteID }
        }
    }

    // MARK: Lists

    func list(_ id: UUID) -> StockList? { notebook.list(id) }

    func listItem(_ id: UUID) -> ListItem? { notebook.listItem(id) }

    @discardableResult
    func addList(_ name: String) -> UUID? {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let list = StockList(name: text)
        return commit({ $0.lists.append(list) }) ? list.id : nil
    }

    func renameList(_ id: UUID, to name: String) {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        commit { book in
            if let i = book.lists.firstIndex(where: { $0.id == id }) {
                book.lists[i].name = text
                book.lists[i].updatedAt = Date()
            }
        }
    }

    func deleteList(_ id: UUID) {
        guard let list = list(id) else { return }
        if commit({ $0.removeList(id) }) { offerUndo("リスト「\(list.name)」を削除しました") }
    }

    @discardableResult
    func duplicateList(_ id: UUID) -> UUID? {
        guard let list = list(id) else { return nil }
        var copy: UUID?
        let saved = commit { copy = $0.duplicateList(id, name: "\(list.name)のコピー") }
        return saved ? copy : nil
    }

    @discardableResult
    func addItem(_ title: String, to listID: UUID, under heading: String = "") -> Bool {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        guard list(listID) != nil else { error = "このリストは別の端末で削除されました。"; return false }
        let group = heading.trimmingCharacters(in: .whitespacesAndNewlines)
        return commit { $0.listItems.append(ListItem(listID: listID, title: text, group: group)) }
    }

    /// Saves the text of a thing on a list, leaving whether it is done as it now is.
    func saveItem(_ item: ListItem) -> Bool {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        guard listItem(item.id) != nil else {
            error = "この項目は別の端末で削除されました。入力した内容をコピーしてから閉じてください。"
            return false
        }
        return commit { book in
            guard let i = book.listItems.firstIndex(where: { $0.id == item.id }) else { return }
            let before = book.listItems[i]
            book.listItems[i].title = title
            // Empty notes and links are left out; a link keeps its name.
            book.listItems[i].notes = item.notes.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            book.listItems[i].links = item.links.compactMap { link in
                let url = link.url.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { return nil }
                return ItemLink(id: link.id, url: url, title: link.title.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            book.listItems[i].place = item.place.trimmingCharacters(in: .whitespacesAndNewlines)
            book.listItems[i].group = item.group.trimmingCharacters(in: .whitespacesAndNewlines)
            book.listItems[i].latitude = item.latitude
            book.listItems[i].longitude = item.longitude
            if book.listItems[i] != before { book.listItems[i].updatedAt = Date() }
        }
    }

    /// Checks a thing off its list or puts it back. A trip made from the list that this finishes is
    /// struck through in place, like any task just done.
    func setItemDone(_ id: UUID, _ done: Bool) {
        let before = notebook
        guard commit({ $0.setItemDone(id, done) }) else { return }
        keepInPlace(tasksFinishedSince: before)
    }

    func deleteItem(_ id: UUID) {
        guard let item = listItem(id) else { return }
        let saved = commit { book in
            book.listItems.removeAll { $0.id == id }
            if let i = book.lists.firstIndex(where: { $0.id == item.listID }) { book.lists[i].updatedAt = Date() }
        }
        if saved { offerUndo("「\(item.title)」を削除しました") }
    }

    /// What was shared into Horme from other apps since it last came to the front, put on its lists.
    /// If saving fails, it goes back to the inbox for next time.
    func takeSharedItems() {
        guard !isDemo, !loadFailed else { return }
        let entries = ListInbox.take().filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !entries.isEmpty else { return }
        let saved = commit { book in
            for entry in entries where !book.listItems.contains(where: { $0.id == entry.id }) {
                var listID = entry.listID.flatMap { id in book.lists.contains { $0.id == id } ? id : nil }
                if listID == nil {
                    let name = entry.newListName.isEmpty ? "共有から" : entry.newListName
                    if let existing = book.lists.first(where: { $0.name == name }) {
                        listID = existing.id
                    } else {
                        let list = StockList(name: name, createdAt: entry.createdAt)
                        book.lists.append(list)
                        listID = list.id
                    }
                }
                guard let listID else { continue }
                book.listItems.append(ListItem(id: entry.id, listID: listID, title: entry.title, memo: entry.memo,
                                               link: entry.link, place: entry.place, createdAt: entry.createdAt,
                                               latitude: entry.latitude, longitude: entry.longitude))
            }
        }
        if saved { offerUndo("共有から\(entries.count)件をリストに入れました") }
        else { for entry in entries { _ = ListInbox.add(entry) } }
    }

    /// Lets the share sheet offer the lists there are.
    func publishListNames() {
        ListInbox.publish(realNotebook.lists.map { ListInbox.ListName(id: $0.id, name: $0.name) })
    }

    func moveIdea(_ ideaID: UUID, toList listID: UUID) -> Bool {
        guard idea(ideaID) != nil else {
            error = "このアイデアはすでに削除またはタスク化されています。最新の一覧を確認してください。"
            return false
        }
        var moved = false
        let saved = commit { moved = $0.moveIdea(ideaID, toList: listID) }
        if saved && moved, let list = list(listID) { offerUndo("リスト「\(list.name)」に移しました") }
        return saved && moved
    }
}
