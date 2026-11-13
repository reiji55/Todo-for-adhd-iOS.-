import MapKit
import SwiftUI

struct ListRoute: Identifiable, Hashable { let id: UUID }

/// The ストック tab: ideas (思いつき) and lists (具体的なもののストック), one at a time. Neither is a
/// plan; each becomes one only when made into a task or an event.
@MainActor
struct StockView: View {
    /// 0: ideas, 1: lists. Remembered, so the tab opens where the person left it.
    @AppStorage("horme.stockMode") private var mode = 0
    @State private var openedList: ListRoute?
    let onEditTask: (TaskItem) -> Void
    let onSort: () -> Void

    var body: some View {
        Group {
            if mode == 0 {
                IdeasView(onEditTask: onEditTask, onSort: onSort)
            } else {
                ListsView { openedList = ListRoute(id: $0) }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("表示", selection: $mode) {
                Text("アイデア").tag(0)
                Text("リスト").tag(1)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("stockMode")
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: 820).frame(maxWidth: .infinity)
            .background(Palette.paper)
        }
        .navigationDestination(item: $openedList) { route in ListPage(listID: route.id).keepsStore() }
        .onAppear {
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-uiStockLists") {
                mode = 1
                if arguments.contains("-uiOpenFirstList"), let first = TaskStore.shared.notebook.lists.first {
                    openedList = ListRoute(id: first.id)
                }
            } else if arguments.contains("-uiTab") {
                mode = 0
            }
            #endif
        }
    }
}

/// Every list, as a card with what is still on it.
@MainActor
struct ListsView: View {
    @EnvironmentObject private var store: TaskStore
    @State private var naming = false
    @State private var newName = ""
    let onOpen: (UUID) -> Void

    var body: some View {
        let book = store.notebook
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if book.lists.isEmpty {
                    ContentUnavailableView {
                        Label("まだリストはありません", systemImage: "list.bullet")
                    } description: {
                        Text("行きたいところ、読みたい本、買うものなど。予定にしたいときだけ、ここからタスクやイベントにします。")
                    } actions: {
                        Button("リストを作る") { naming = true }.buttonStyle(.borderedProminent)
                    }
                }
                ForEach(book.lists) { list in
                    Button { onOpen(list.id) } label: { ListCard(list: list) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("openList-\(list.name)")
                }
            }
            .padding(16).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }
        .background(Palette.paper)
        .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
            ContextAddButton { naming = true }
                .accessibilityLabel("リストを追加")
                .accessibilityIdentifier("addList")
                .padding(.trailing, 20).padding(.bottom, 10)
        }
        .alert("新しいリスト", isPresented: $naming) {
            TextField("名前（例：行きたいところ）", text: $newName)
            Button("追加") {
                if let id = store.addList(newName) { onOpen(id) }
                newName = ""
            }
            Button("キャンセル", role: .cancel) { newName = "" }
        }
    }
}

private struct ListCard: View {
    @EnvironmentObject private var store: TaskStore
    let list: StockList

    var body: some View {
        let open = store.notebook.openItems(in: list.id)
        let planned = open.filter { store.notebook.plan(for: $0.id) != nil }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(list.name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                Spacer()
                Text("\(open.count)件").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            if !open.isEmpty {
                Text(open.prefix(3).map(\.title).joined(separator: "・"))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            if planned > 0 {
                Text("予定あり \(planned)件").font(.caption.weight(.semibold)).foregroundStyle(Palette.accent)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RaisedCardBackground(cornerRadius: 16))
        .contentShape(Rectangle())
    }
}

/// One list: what is on it, a line to add more, and what is done below, folded.
@MainActor
struct ListPage: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    let listID: UUID
    @State private var draft = ""
    @FocusState private var adding: Bool
    @State private var opened: ListItemRouteID?
    @State private var planning: StockList?
    @State private var editingTask: TaskItem?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var showDone = false
    /// Headings folded away.
    @State private var collapsed: Set<String> = []
    /// The heading a thing is being added under, and what is typed.
    @State private var addingTo: String?
    @State private var headingDraft = ""
    @FocusState private var headingFocused: Bool
    @State private var namingHeading = false
    @State private var newHeading = ""

    struct ListItemRouteID: Identifiable { let id: UUID }

    var body: some View {
        Group {
            if let list = store.list(listID) { content(list) }
            else { ContentUnavailableView("このリストはありません", systemImage: "list.bullet") }
        }
        .background(Palette.paper)
        .sheet(item: $opened) { ListItemSheet(itemID: $0.id) }
        .sheet(item: $planning) { QuickAddSheet(day: Date(), list: $0) }
        .sheet(item: $editingTask) { TaskEditor(task: $0, original: store.task($0.id)) }
        .storeErrorAlert()
    }

    private func content(_ list: StockList) -> some View {
        let book = store.notebook
        let open = book.openItems(in: list.id)
        let groups = book.openGroups(in: list.id)
        let loose = groups.first { $0.heading.isEmpty }?.items ?? []
        let headed = groups.filter { !$0.heading.isEmpty }
        let done = book.doneItems(in: list.id)
        let trip = book.tasks.filter { $0.listID == list.id && !$0.isComplete }.min { $0.createdAt < $1.createdAt }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let trip {
                    Button { editingTask = trip } label: { TripRow(task: trip) }.buttonStyle(.plain)
                } else if !open.isEmpty {
                    Button { planning = list } label: {
                        Label("このリストを予定にする", systemImage: "checklist")
                            .font(.subheadline.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("planWholeList")
                }
                VStack(spacing: 0) {
                    ForEach(loose) { item in
                        ListItemRow(item: item, onCheck: { store.setItemDone(item.id, true) }, onOpen: { opened = ListItemRouteID(id: item.id) })
                        Divider().padding(.leading, 52)
                    }
                    HStack(spacing: 12) {
                        Image(systemName: "plus").font(.body.weight(.semibold)).foregroundStyle(Palette.accent)
                            .frame(width: 28)
                        TextField("追加", text: $draft)
                            .focused($adding)
                            .submitLabel(.next)
                            .onSubmit(add)
                            .accessibilityIdentifier("addListItem")
                    }
                    .padding(.horizontal, 12).frame(minHeight: 50)
                }
                .background(RaisedCardBackground(cornerRadius: 16))
                ForEach(headed, id: \.heading) { group in
                    headingCard(group.heading, items: group.items)
                }
                // A heading just named has no things yet: its card waits for the first.
                if let pending = addingTo, !pending.isEmpty, !headed.contains(where: { $0.heading == pending }) {
                    headingCard(pending, items: [])
                }
                Button { namingHeading = true } label: {
                    Label("見出しを足す", systemImage: "plus").font(.subheadline.weight(.bold))
                        .padding(.horizontal, 4).frame(minHeight: 44)
                }
                .buttonStyle(.plain).foregroundStyle(Palette.accent)
                .accessibilityIdentifier("addListHeading")
                if !done.isEmpty {
                    Button { withAnimation(.snappy) { showDone.toggle() } } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.down").rotationEffect(.degrees(showDone ? 180 : 0))
                            Text("済み").font(.subheadline.weight(.bold))
                            Text("\(done.count)件").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                            Spacer()
                        }
                        .foregroundStyle(.primary).padding(.horizontal, 4).frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(showDone ? "展開中" : "折りたたみ")
                    if showDone {
                        VStack(spacing: 0) {
                            ForEach(done) { item in
                                DoneItemRow(item: item) { store.setItemDone(item.id, false) }
                                Divider().padding(.leading, 16)
                            }
                        }
                        .background(RaisedCardBackground(cornerRadius: 16))
                    }
                }
            }
            .padding(16).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(list.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("名前を変える", systemImage: "pencil") { newName = list.name; renaming = true }
                    Button("複製する", systemImage: "plus.square.on.square") { _ = store.duplicateList(list.id) }
                    Button("リストを削除", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("リストの操作")
            }
        }
        .alert("見出し", isPresented: $namingHeading) {
            TextField("例：野菜、上野のあたり、小説", text: $newHeading)
            Button("追加") {
                let name = newHeading.trimmingCharacters(in: .whitespacesAndNewlines)
                newHeading = ""
                guard !name.isEmpty else { return }
                collapsed.remove(name)
                headingDraft = ""
                addingTo = name
                headingFocused = true
            }
            Button("キャンセル", role: .cancel) { newHeading = "" }
        }
        .alert("リストの名前", isPresented: $renaming) {
            TextField("名前", text: $newName)
            Button("保存") { store.renameList(list.id, to: newName) }
            Button("キャンセル", role: .cancel) {}
        }
        .confirmationDialog("「\(list.name)」を削除しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                store.deleteList(list.id)
                dismiss()
            }
        } message: { Text("リストの項目もすべて消えます。作った予定は残ります。") }
    }

    private func add() {
        if store.addItem(draft, to: listID) { draft = "" }
        adding = true
    }

    /// One heading: tap it to fold; its things; a line to add under it.
    private func headingCard(_ heading: String, items: [ListItem]) -> some View {
        let folded = collapsed.contains(heading)
        return VStack(spacing: 0) {
            Button {
                withAnimation(.snappy) {
                    if folded { collapsed.remove(heading) } else { collapsed.insert(heading) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(folded ? -90 : 0))
                    Text(heading).font(.subheadline.weight(.heavy)).foregroundStyle(.primary).lineLimit(1)
                    Text("\(items.count)件").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).frame(minHeight: 44)
                .background(Color(uiColor: .tertiarySystemFill).opacity(0.5),
                            in: UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: folded ? 16 : 0,
                                                       bottomTrailingRadius: folded ? 16 : 0, topTrailingRadius: 16,
                                                       style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(folded ? "折りたたみ" : "展開中")
            if !folded {
                ForEach(items) { item in
                    Divider().padding(.leading, 52)
                    ListItemRow(item: item, onCheck: { store.setItemDone(item.id, true) }, onOpen: { opened = ListItemRouteID(id: item.id) })
                }
                Divider().padding(.leading, 52)
                if addingTo == heading {
                    HStack(spacing: 12) {
                        Image(systemName: "plus").font(.body.weight(.semibold)).foregroundStyle(Palette.accent).frame(width: 28)
                        TextField("\(heading)に追加", text: $headingDraft)
                            .focused($headingFocused)
                            .submitLabel(.next)
                            .onSubmit {
                                if store.addItem(headingDraft, to: listID, under: heading) { headingDraft = "" }
                                headingFocused = true
                            }
                    }
                    .padding(.horizontal, 12).frame(minHeight: 50)
                } else {
                    Button {
                        headingDraft = ""
                        addingTo = heading
                        headingFocused = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus").font(.body.weight(.semibold)).foregroundStyle(Palette.accent).frame(width: 28)
                            Text("\(heading)に追加").foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).frame(minHeight: 50).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(RaisedCardBackground(cornerRadius: 16))
    }
}

/// The trip made from the whole list: its day and how much is checked off.
private struct TripRow: View {
    @EnvironmentObject private var store: TaskStore
    let task: TaskItem

    var body: some View {
        let progress = store.notebook.listProgress(of: task)
        HStack(spacing: 12) {
            Image(systemName: "checklist").font(.title3).foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("予定：\(GuideSummary.place(task))" + (task.slot.map { " \($0.label)" } ?? ""))
                    .font(.caption.weight(.semibold)).foregroundStyle(Palette.accent)
                Text(task.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
            }
            Spacer()
            if let progress {
                Text("\(progress.done)/\(progress.total)").font(.subheadline.weight(.bold)).monospacedDigit()
                    .foregroundStyle(Palette.accent)
            }
        }
        .padding(14)
        .background(Palette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }
}

private struct ListItemRow: View {
    @EnvironmentObject private var store: TaskStore
    let item: ListItem
    let onCheck: () -> Void
    let onOpen: () -> Void

    var body: some View {
        let plan = store.notebook.plan(for: item.id)
        HStack(spacing: 12) {
            Button(action: onCheck) {
                Image(systemName: "circle").font(.title3).foregroundStyle(Palette.accent)
                    .frame(width: 28, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.title)を済みにする")
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.body).foregroundStyle(.primary)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    let marks = details
                    if plan != nil || !marks.isEmpty {
                        HStack(spacing: 8) {
                            if let plan {
                                Text("予定 \(plan.plannedAt.map { $0.shortDay } ?? "いつでも")")
                                    .font(.caption2.weight(.bold)).foregroundStyle(Palette.accent)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Palette.accent.opacity(0.12), in: Capsule())
                            }
                            ForEach(marks, id: \.self) { mark in
                                Image(systemName: mark).font(.caption2).foregroundStyle(.secondary)
                            }
                            if !item.place.isEmpty {
                                Text(item.place).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let latitude = item.latitude, let longitude = item.longitude {
                Button(action: onOpen) { MapThumbnail(latitude: latitude, longitude: longitude, width: 56, height: 56) }
                    .buttonStyle(.plain)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
    }

    /// Small marks for what else the item carries.
    private var details: [String] {
        var marks: [String] = []
        if !item.memo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { marks.append("note.text") }
        if !item.link.isEmpty { marks.append("link") }
        if !item.place.isEmpty { marks.append("mappin") }
        return marks
    }
}

private struct DoneItemRow: View {
    let item: ListItem
    let onRestore: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).strikethrough().foregroundStyle(.secondary)
                if let done = item.doneAt {
                    Text(done.shortDay).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            Spacer()
            Button("戻す", action: onRestore).font(.subheadline.weight(.semibold)).buttonStyle(.borderless)
        }
        .padding(.horizontal, 16).frame(minHeight: 50)
    }
}

/// One thing on a list: its name, memo, link and place, and what can be done with it.
@MainActor
struct ListItemSheet: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    let itemID: UUID
    @State private var draft: ListItem
    @State private var planning: ListItem?
    @State private var editingTask: TaskItem?
    @State private var confirmDelete = false
    @State private var readingPlace = false
    @State private var placeMissing = false

    init(itemID: UUID) {
        self.itemID = itemID
        _draft = State(initialValue: TaskStore.shared.listItem(itemID) ?? ListItem(listID: UUID(), title: ""))
    }

    /// The name and point a map link gave: the name fills the place (and the title when it was only a link).
    private func usePlace(_ found: MapPlace, from url: URL) {
        let bare = draft.title.isEmpty || draft.title == url.host || draft.title.hasPrefix("http")
        if !found.name.isEmpty {
            if draft.place.isEmpty || draft.place.hasPrefix("http") || draft.place == url.host { draft.place = found.name }
            if bare { draft.title = found.name }
        }
        draft.latitude = found.latitude
        draft.longitude = found.longitude
        placeMissing = !found.hasCoordinate && found.name.isEmpty
    }

    var body: some View {
        let current = store.listItem(itemID)
        NavigationStack {
            Form {
                Section {
                    TextField("名前", text: $draft.title, axis: .vertical).font(.headline).lineLimit(1...4)
                    if let list = current.flatMap({ store.list($0.listID) }) {
                        Label(list.name, systemImage: "list.bullet").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Section {
                    HStack {
                        TextField("見出し（任意）", text: $draft.group)
                        let used = store.notebook.headings(in: draft.listID).filter { $0 != draft.group }
                        if !used.isEmpty {
                            Menu {
                                ForEach(used, id: \.self) { heading in Button(heading) { draft.group = heading } }
                            } label: { Image(systemName: "chevron.up.chevron.down") }
                            .accessibilityLabel("使っている見出しから選ぶ")
                        }
                    }
                }
                Section("メモ") {
                    TextField("覚えておきたいこと", text: $draft.memo, axis: .vertical).lineLimit(2...8)
                }
                Section {
                    TextField("リンク（URL）", text: $draft.link)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if let url = ListLinks.web(draft.link) {
                        Link(destination: url) { Label("リンクを開く", systemImage: "safari") }
                    }
                    TextField("場所（店名や住所）", text: $draft.place)
                    if let latitude = draft.latitude, let longitude = draft.longitude {
                        let point = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                        Map(initialPosition: .region(MKCoordinateRegion(center: point, latitudinalMeters: 800, longitudinalMeters: 800)),
                            interactionModes: []) {
                            Marker(draft.place.isEmpty ? draft.title : draft.place, coordinate: point).tint(Palette.accent)
                        }
                        .frame(height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        .id("\(latitude),\(longitude)")
                    }
                    if let url = ListLinks.maps(draft.place, latitude: draft.latitude, longitude: draft.longitude) {
                        Link(destination: url) { Label("地図で開く", systemImage: "map") }
                    }
                    if !draft.hasCoordinate, let url = URL(string: draft.link.trimmingCharacters(in: .whitespacesAndNewlines)),
                       MapLink.isMap(url) {
                        Button {
                            readingPlace = true
                            Task {
                                if let found = await MapResolver.place(for: url) { usePlace(found, from: url) }
                                else { placeMissing = true }
                                readingPlace = false
                            }
                        } label: {
                            Label(readingPlace ? "読み込み中…" : "リンクから場所を読み込む", systemImage: "mappin.and.ellipse")
                        }
                        .disabled(readingPlace)
                        if placeMissing {
                            Text("このリンクからは場所を読み取れませんでした。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let current {
                    Section {
                        if let plan = store.notebook.plan(for: itemID) {
                            Button { editingTask = plan } label: {
                                Label("予定あり：\(GuideSummary.place(plan))" + (plan.slot.map { " \($0.label)" } ?? ""),
                                      systemImage: plan.isEvent ? "calendar" : "checkmark.circle")
                            }
                        } else if !current.isDone {
                            Button("予定にする", systemImage: "calendar.badge.plus") { planning = draft }
                                .accessibilityIdentifier("planListItem")
                        }
                        Button(current.isDone ? "リストに戻す" : "済みにする",
                               systemImage: current.isDone ? "arrow.uturn.backward" : "checkmark") {
                            store.setItemDone(itemID, !current.isDone)
                            dismiss()
                        }
                    }
                    Section {
                        Button("削除", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDismissable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { if store.saveItem(draft) { dismiss() } }
                        .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || current.map { $0 == draft } ?? true)
                }
            }
            .confirmationDialog("「\(draft.title)」を削除しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("削除", role: .destructive) { store.deleteItem(itemID); dismiss() }
            }
        }
        .sheet(item: $planning) { QuickAddSheet(item: $0) }
        .sheet(item: $editingTask) { TaskEditor(task: $0, original: store.task($0.id)) }
        .storeErrorAlert()
    }
}

enum ListLinks {
    /// A web address as written; "example.com" is taken as https.
    static func web(_ text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(" ") else { return nil }
        let full = value.contains("://") ? value : "https://" + value
        guard let url = URL(string: full), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }

    /// The place in Maps: at its point when known, else searched by name.
    static func maps(_ place: String, latitude: Double? = nil, longitude: Double? = nil) -> URL? {
        let value = place.trimmingCharacters(in: .whitespacesAndNewlines)
        var items: [URLQueryItem] = []
        if let latitude, let longitude { items.append(URLQueryItem(name: "ll", value: "\(latitude),\(longitude)")) }
        if !value.isEmpty { items.append(URLQueryItem(name: "q", value: value)) }
        guard !items.isEmpty else { return nil }
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = items
        return components?.url
    }
}

/// Picking a thing from a list to plan, in the add sheet.
@MainActor
struct ListItemPicker: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    let onPick: (ListItem) -> Void

    var body: some View {
        let book = store.notebook
        let lists = book.lists.filter { !book.openItems(in: $0.id).isEmpty }
        NavigationStack {
            List {
                if lists.isEmpty {
                    Text("リストに項目がありません。ストックの「リスト」から足せます。").foregroundStyle(.secondary)
                }
                ForEach(lists) { list in
                    Section(list.name) {
                        ForEach(book.openItems(in: list.id)) { item in
                            Button {
                                onPick(item)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(item.title).foregroundStyle(.primary)
                                    Spacer()
                                    if let plan = book.plan(for: item.id) {
                                        Text("予定 \(plan.plannedAt.map { $0.shortDay } ?? "いつでも")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("リストから").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }
}

/// In a task made from a whole list: the list, checked off right here. When nothing is left the task is
/// done; what was not checked stays on the list for next time.
@MainActor
struct ListChecklistSection: View {
    @EnvironmentObject private var store: TaskStore
    let task: TaskItem
    @State private var draft = ""

    var body: some View {
        if let listID = task.listID, let list = store.list(listID) {
            let book = store.notebook
            let open = book.openItems(in: listID)
            let groups = book.openGroups(in: listID)
            let done = book.doneItems(in: listID).filter { ($0.doneAt ?? .distantPast) >= task.createdAt }
            Section {
                ForEach(groups, id: \.heading) { group in
                    if !group.heading.isEmpty {
                        Text(group.heading).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    }
                    ForEach(group.items) { item in
                        Button { store.setItemDone(item.id, true) } label: {
                            Label { Text(item.title).foregroundStyle(.primary) } icon: {
                                Image(systemName: "circle").foregroundStyle(Palette.accent)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
                ForEach(done) { item in
                    Button { store.setItemDone(item.id, false) } label: {
                        Label { Text(item.title).strikethrough().foregroundStyle(.secondary) } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
                        }
                    }
                    .buttonStyle(.borderless)
                }
                HStack {
                    Image(systemName: "plus").foregroundStyle(Palette.accent)
                    TextField("リストに追加", text: $draft)
                        .submitLabel(.next)
                        .onSubmit { if store.addItem(draft, to: listID) { draft = "" } }
                }
            } header: {
                Text("リスト「\(list.name)」 \(done.count)/\(done.count + open.count)")
            } footer: {
                Text("全部チェックすると、このタスクも完了します。残ったものはリストに残ります。").onlyInDemo()
            }
        }
    }
}

/// In a task or event made from one thing on a list: where it came from, with its link and place.
@MainActor
struct ListSourceSection: View {
    @EnvironmentObject private var store: TaskStore
    let task: TaskItem

    var body: some View {
        if let itemID = task.listItemID, let item = store.listItem(itemID), let list = store.list(item.listID) {
            Section {
                Label("リスト「\(list.name)」から", systemImage: "list.bullet").foregroundStyle(.secondary)
                if let url = ListLinks.web(item.link) {
                    Link(destination: url) { Label("リンクを開く", systemImage: "safari") }
                }
                if let url = ListLinks.maps(item.place, latitude: item.latitude, longitude: item.longitude) {
                    Link(destination: url) { Label(item.place.isEmpty ? "地図で開く" : "地図で開く：\(item.place)", systemImage: "map") }
                }
            }
        }
    }
}
