import SwiftUI

@main
@MainActor
struct ThreeDaysApp: App {
    @UIApplicationDelegateAdaptor(HormeAppDelegate.self) private var appDelegate
    @StateObject private var store = TaskStore.shared
    init() { NowActivityController.install() }
    var body: some Scene {
        WindowGroup { RootView().environmentObject(store).tint(Palette.accent) }
    }
}

enum Palette {
    static let accent = Color("AccentColor")
    static let must = Color("MustColor")
    static let paper = Color(uiColor: .systemGroupedBackground)
}

extension Date {
    var shortDay: String { formatted(.dateTime.month(.twoDigits).day(.twoDigits)) }
}

struct TaskRoute: Identifiable {
    var task: TaskItem
    var original: TaskItem?
    var id: UUID { task.id }
}

struct QuickAddRoute: Identifiable {
    let id = UUID()
    var day: Date?
    var kind: AddKind = .task
}

private struct SelectedTabKey: EnvironmentKey { static let defaultValue = 2 }
extension EnvironmentValues {
    /// The tab in front (RootView.Tab's raw value).
    var selectedTab: Int {
        get { self[SelectedTabKey.self] }
        set { self[SelectedTabKey.self] = newValue }
    }
}

@MainActor
struct RootView: View {
    /// 今日 sits in the middle, where the thumb rests; the app always opens on it.
    enum Tab: Int, CaseIterable {
        case all, week, today, ideas, board
        var title: String { ["すべて", "週", "今日", "ストック", "ボード"][rawValue] }
        var icon: String { ["square.3.layers.3d", "calendar", "sun.max", "lightbulb", "rectangle.split.2x2"][rawValue] }
    }
    @EnvironmentObject private var store: TaskStore
    @Environment(\.scenePhase) private var phase
    @State private var selectedTab = Tab.today.rawValue
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var compactColumn: NavigationSplitViewColumn = .detail
    @State private var editor: TaskRoute?
    @State private var routineEditor: Routine?
    @State private var quickAdd: QuickAddRoute?
    @State private var focusOpen = false
    @State private var settingsOpen = false
    @State private var guide: GuideRoute?
    @State private var refreshDate = Date()
    @State private var keyboardShown = false
    /// The sprout that opens the app; shown once, at a cold start.
    @State private var splashing = true
    /// 振り分け, over everything: deciding an idea can open a project in the ボード tab behind it.
    @State private var sorting = false
    /// Bumped when a tab is left, so coming back to it shows its main screen rather than what was pushed.
    @State private var stackResets: [Int: Int] = [:]

    var body: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad {
                tabletNavigation
            } else {
                phoneNavigation
            }
        }
        // iPhone: Horme's own tab bar, with 今日 raised in the middle, and above it the task in progress.
        // Each tab keeps room for them (see phoneNavigation), since the tab view does not pass this space on.
        // They step aside for the keyboard.
        .overlay(alignment: .bottom) {
            if isPhone && !keyboardShown {
                VStack(spacing: 0) {
                    activeTaskBar
                    HormeTabBar(selection: $selectedTab)
                }
            }
        }
        .overlay(alignment: .bottom) { undoToast }
        .overlay {
            if splashing {
                LaunchSplash { withAnimation(.easeOut(duration: 0.15)) { splashing = false } }
                    .transition(.opacity)
            }
        }
        // ▶ on a routine row starts its timer and opens its focus screen.
        .environment(\.startRoutine, StartRoutineAction { startRoutine($0) })
        .animation(.snappy, value: store.undoOffer)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardShown = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardShown = false }
        .sheet(item: $editor) { route in TaskEditor(task: route.task, original: route.original) }
        .sheet(item: $routineEditor) { routine in RoutineEditor(routine: routine) }
        .sheet(item: $quickAdd) { route in
            switch route.kind {
            case .task: QuickAddSheet(day: route.day)
            case .event: QuickAddSheet(day: route.day, isEvent: true)
            case .routine: RoutineEditor(routine: Routine(title: "", time: "19:00-20:00"))
            case .idea: IdeaQuickSheet()
            }
        }
        .sheet(isPresented: $focusOpen) { RoutineFocusView() }
        .fullScreenCover(isPresented: $sorting) {
            SortIdeasView(ideaIDs: SortIdeasView.order(store.notebook.ideas, now: Date()),
                          onShowToday: { selectedTab = Tab.today.rawValue })
        }
        .sheet(isPresented: $settingsOpen) { SettingsView() }
        .sheet(item: $guide) { route in GuideSheet(cardID: route.id) }
        .alert("保存・読み込みのお知らせ", isPresented: Binding(
            get: { !presenting && store.error != nil },
            set: { if !$0 { store.error = nil } }
        )) { Button("閉じる", role: .cancel) { store.error = nil } } message: { Text(store.error ?? "") }
        .modifier(ShareJoinAlert(enabled: editor == nil && !focusOpen && !settingsOpen))
        // Widgets open horme://add/task or /idea; the Control Center buttons leave a request instead.
        .onOpenURL { url in if let link = QuickAddLink(url: url) { openQuickAdd(link) } }
        .onReceive(NotificationCenter.default.publisher(for: QuickAddLink.requested)) { _ in takeQuickAddRequest() }
        .onAppear {
            store.setForeground(phase == .active)
            takeQuickAddRequest()
            store.takeSharedItems()
            store.publishListNames()
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-horme-settings-preview") { settingsOpen = true }
#endif
        }
        .onChange(of: phase) { _, newPhase in
            store.setForeground(newPhase == .active)
            if newPhase == .active {
                refreshDate = Date(); Reminders.shared.reschedule(store.realNotebook)
                takeQuickAddRequest()
                store.takeSharedItems()
                store.publishListNames()
            }
            else { store.clearRecentlyDone() }
        }
        .onChange(of: store.notebook.lists) { _, _ in store.publishListNames() }
        .onChange(of: store.projectToOpen) { _, key in
            if key != nil { selectedTab = Tab.board.rawValue; compactColumn = .detail }
        }
        .onChange(of: store.taskStartRequest) { _, request in
            guard request != nil else { return }
            // The originating creation sheets dismiss themselves. Only the idea-sorting cover
            // must step aside here so the explicitly requested task can appear on Today.
            sorting = false
            store.projectToOpen = nil
            selectedTab = Tab.today.rawValue
            compactColumn = .detail
        }
        // Rows checked off stay visible on the screen they were checked on, and go once the person moves on.
        .onChange(of: selectedTab) { _, _ in store.clearRecentlyDone() }
        // Planned from the saved data, so demo mode never replaces real reminders.
        .onChange(of: store.notebook) { _, _ in Reminders.shared.reschedule(store.realNotebook) }
        // 今日を終える quiets the rest of today's reminders; 再開する brings them back.
        .onChange(of: store.closedDay) { _, _ in Reminders.shared.reschedule(store.realNotebook) }
        .task {
            #if DEBUG
            // Screenshot runs must not be covered by the permission dialog.
            let arguments = ProcessInfo.processInfo.arguments
            if ["-uiTab", "-uiNoPrompt", "-horme-settings-preview"].contains(where: arguments.contains) { return }
            #endif
            await Reminders.shared.requestIfNeeded(for: store.realNotebook)
            Reminders.shared.reschedule(store.realNotebook)
        }
        .environment(\.refreshClock, refreshDate)
        .environment(\.openGuide, OpenGuideAction { guide = GuideRoute(id: $0) })
        .onAppear(perform: openTabForScreenshot)
#if DEBUG
        .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-uiDark") ? .dark : nil)
#endif
    }

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom != .pad }

    private var presenting: Bool {
        editor != nil || routineEditor != nil || quickAdd != nil || focusOpen || settingsOpen || guide != nil || sorting
    }

    private func takeQuickAddRequest() {
        guard let raw = UserDefaults.standard.string(forKey: QuickAddLink.pendingKey) else { return }
        UserDefaults.standard.removeObject(forKey: QuickAddLink.pendingKey)
        if let link = QuickAddLink(rawValue: raw) { openQuickAdd(link) }
    }

    /// Something to write down from a widget: close whatever sheet is open, then show the add screen.
    private func openQuickAdd(_ link: QuickAddLink) {
        let route = QuickAddRoute(day: nil, kind: link == .task ? .task : .idea)
        guard presenting else { quickAdd = route; return }
        editor = nil; routineEditor = nil; quickAdd = nil; focusOpen = false; settingsOpen = false; guide = nil; sorting = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { quickAdd = route }
    }

    @ViewBuilder private func screen(_ tab: Tab) -> some View {
        switch tab {
        case .today:
            // One thing to do now; the full timetable (the Today screen as it was) is a tap away.
            NowView(onOpen: open, onWeek: { selectedTab = Tab.week.rawValue },
                    onAdd: { quickAdd = QuickAddRoute(day: nil, kind: $0) })
                .floatingAdd { quickAdd = QuickAddRoute(day: nil, kind: $0) }
        case .week:
            // The grid fills the screen, so the button floats over it instead of taking a row.
            if isPhone {
                // iPhone: the week as shelves, with two days hour by hour in a sheet pulled up from below.
                WeekShelfView(onOpen: open, onAdd: { quickAdd = QuickAddRoute(day: $0) },
                              onPick: { quickAdd = QuickAddRoute(day: $1, kind: $0) })
            } else {
                WeekView(onOpen: open, onAdd: { quickAdd = QuickAddRoute(day: $0) })
                    .overlay(alignment: .bottomTrailing) {
                        FloatingAddButton { quickAdd = QuickAddRoute(day: nil, kind: $0) }
                            .padding(.trailing, 20).padding(.bottom, 10)
                    }
            }
        case .all:
            AllTasksView(onOpen: open, onEditRoutine: { routineEditor = $0 })
                .floatingAdd { quickAdd = QuickAddRoute(day: nil, kind: $0) }
        case .ideas:
            // Ideas and the board have their own way to add, so the ⊕ would only confuse there.
            StockView(onEditTask: edit, onSort: { sorting = true })
        case .board:
            GuideBoardView(onEdit: edit)
        }
    }

    private var tabletNavigation: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
            List(selection: Binding<Int?>(
                get: { selectedTab },
                set: { if let tab = $0 { selectedTab = tab; compactColumn = .detail } }
            )) {
                ForEach(Tab.allCases, id: \.rawValue) { tab in
                    NavigationLink(value: tab.rawValue) { Label { Text(tab.title) } icon: { HormeTabGlyph(tab: tab) } }
                }
            }
            .navigationTitle("Horme")
            .navigationBarTitleDisplayMode(.inline)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            NavigationStack {
                screen(Tab(rawValue: selectedTab) ?? .today)
                    .navigationTitle((Tab(rawValue: selectedTab) ?? .today).title)
                    .navigationBarTitleDisplayMode(selectedTab == Tab.week.rawValue || selectedTab == Tab.today.rawValue ? .inline : .automatic)
                    .toolbar { commonToolbar }
                    .safeAreaInset(edge: .top, spacing: 0) { demoBar }
                    .safeAreaInset(edge: .bottom, spacing: 0) { activeTaskBar }
            }
            // One stack serves every section; a card pushed on the board must not stay on top of 今日.
            .id(selectedTab)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var phoneNavigation: some View {
        TabView(selection: $selectedTab) {
            ForEach(Tab.allCases, id: \.rawValue) { tab in
                // The tab's page stays the same view; only the stack inside it is replaced to go back to its
                // main screen. (An id on the page itself gave every page the same id, which iOS 17's tab
                // container cannot lay out.)
                ZStack {
                    NavigationStack {
                        screen(tab)
                            .navigationTitle(tab == .today ? "Horme" : tab.title)
                            .navigationBarTitleDisplayMode(tab == .week || tab == .today ? .inline : .automatic)
                            .toolbar { commonToolbar }
                            .toolbar(.hidden, for: .tabBar)
                            // The demo notice sits under the title bar, inside the screen, so no button is covered.
                            .safeAreaInset(edge: .top, spacing: 0) { demoBar }
                            .safeAreaInset(edge: .bottom, spacing: 0) {
                                Color.clear.frame(height: HormeTabBar.height + (store.routineRun != nil ? Self.activeBarHeight : 0))
                            }
                    }
                    .toolbar(.hidden, for: .tabBar)
                    // 今日 keeps its screen (a task may be running on its card) and closes the timetable itself.
                    .id(tab == .today ? 0 : stackResets[tab.rawValue, default: 0])
                }
                .toolbar(.hidden, for: .tabBar)
                .tag(tab.rawValue)
            }
        }
        .environment(\.selectedTab, selectedTab)
        .onChange(of: selectedTab) { old, _ in
            if old != Tab.today.rawValue { stackResets[old, default: 0] += 1 }
        }
    }

    static let activeBarHeight: CGFloat = 56

    /// The routine being timed, above the tab bar; a tap reopens its focus screen.
    @ViewBuilder private var activeTaskBar: some View {
        if let run = store.routineRun, let routine = store.routine(run.routineID) {
            Button { focusOpen = true } label: {
                HStack(spacing: 12) {
                    ElapsedTimer(start: run.startedAt, minutes: plannedMinutes(routine.slot), size: 28, tint: .white)
                    VStack(alignment: .leading) {
                        Text("取り組み中").font(.caption)
                        Text(routine.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.up")
                }
                .padding(.horizontal, 20).frame(height: Self.activeBarHeight)
                .foregroundStyle(.white).background(Palette.accent)
            }.accessibilityLabel("取り組み中：\(routine.title)。集中画面を開く")
        }
    }

    /// Always visible in demo mode, so samples are never mistaken for real data.
    @ViewBuilder private var demoBar: some View {
        if store.isDemo {
            HStack(spacing: 8) {
                Image(systemName: "theatermasks")
                Text("デモモード中・本物のデータは変わりません").lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Button("終える") { store.endDemo() }.fontWeight(.semibold)
            }
            .font(.footnote).foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(Color.orange)
        }
    }

    /// Offered for a few seconds after deleting, moving or bulk changes; no permanent undo button.
    @ViewBuilder private var undoToast: some View {
        if let offer = store.undoOffer {
            HStack(spacing: 12) {
                Text(offer.message).font(.subheadline).lineLimit(2)
                Spacer(minLength: 4)
                Button("取り消す") { store.undo() }.font(.subheadline.weight(.bold))
                Button { store.dismissUndo() } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                    .accessibilityLabel("閉じる")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)
            // Above the tab bar and its raised 今日 button on iPhone; iPad has a sidebar instead.
            .padding(.bottom, UIDevice.current.userInterfaceIdiom == .pad ? 20 : 84)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ToolbarContentBuilder private var commonToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if store.connection != nil && (store.hasPendingChanges || store.syncError != nil) {
                Button { settingsOpen = true } label: { Image(systemName: store.syncError == nil ? "icloud.and.arrow.up" : "icloud.slash") }
                    .accessibilityLabel("同期状況を確認")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { settingsOpen = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("設定とデータ")
        }
    }

    private func edit(_ task: TaskItem) { editor = TaskRoute(task: task, original: store.task(task.id)) }

    private func open(_ item: AgendaItem) {
        switch item.source {
        case .task(let id): if let task = store.task(id) { edit(task) }
        case .routine(let id, _): routineEditor = store.routine(id)
        }
    }

    private func openTabForScreenshot() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let i = arguments.firstIndex(of: "-uiTab"), arguments.indices.contains(i + 1), let tab = Int(arguments[i + 1]) {
            selectedTab = tab
        }
        // The editor of a routine that has a project, to capture the project picker and its book.
        if arguments.contains("-uiOpenRoutine") {
            routineEditor = store.notebook.routines.first { !$0.project.isEmpty && !$0.isBlock }
        }
        if arguments.contains("-uiQuickAdd") { quickAdd = QuickAddRoute(day: nil, kind: .task) }
        if arguments.contains("-uiSortIdeas") { sorting = true }
        // Demo mode, as started from settings, to exercise leaving the app while it shows.
        if arguments.contains("-uiDemo") { store.startDemo() }
        // A task in pieces, to capture its editor.
        if arguments.contains("-uiOpenTask") {
            let tasks = store.notebook.tasks.filter { !$0.isComplete && !$0.isEvent }
            if let task = tasks.filter({ store.hasChildren($0.id) }).max(by: { store.children(of: $0.id).count < store.children(of: $1.id).count })
                ?? tasks.first(where: { $0.plannedAt != nil }) {
                edit(task)
            }
        }
        if arguments.contains("-uiFocus"),
           let item = Agenda.items(on: Date(), tasks: [], routines: store.notebook.routines).first(where: { !$0.isBlock && !$0.isDone }) {
            startRoutine(item)
        }
        #endif
    }

    /// Starts a routine's timer (unless it is already running) and opens its focus screen.
    private func startRoutine(_ item: AgendaItem) {
        if !store.isTiming(item) { store.startRoutineTimer(item) }
        focusOpen = true
    }
}

@MainActor
private struct StoreErrorAlert: ViewModifier {
    @EnvironmentObject var store: TaskStore
    func body(content: Content) -> some View {
        content.alert("保存・読み込みのお知らせ", isPresented: Binding(
            get: { store.error != nil }, set: { if !$0 { store.error = nil } }
        )) { Button("閉じる", role: .cancel) { store.error = nil } } message: { Text(store.error ?? "") }
    }
}

extension View {
    @MainActor func storeErrorAlert() -> some View { modifier(StoreErrorAlert()) }
}

private struct RefreshClockKey: EnvironmentKey { static let defaultValue = Date() }
extension EnvironmentValues {
    var refreshClock: Date {
        get { self[RefreshClockKey.self] }
        set { self[RefreshClockKey.self] = newValue }
    }
}

@MainActor
struct SectionHeading: View {
    let title: String
    var subtitle: String? = nil
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).foregroundStyle(color)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }.padding(.top, 10)
    }
}

/// A board card opened from a task, over whatever screen the person was on.
@MainActor
struct GuideSheet: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    let cardID: UUID
    /// The other cards of the same project, to swipe through.
    private var siblings: [UUID] {
        guard let card = store.card(cardID), !ProjectBook.key(card.project).isEmpty else { return [cardID] }
        return store.projectCards(ProjectBook.key(card.project)).map(\.id)
    }
    var body: some View {
        NavigationStack {
            GuidePager(startID: cardID, cardIDs: siblings)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }
}

/// The iPhone tab bar: four plain tabs around a raised, round 今日 in the middle. The round button has
/// the soft, lit-from-the-top-left look of the timeline panel; it fills with green while 今日 is open.
@MainActor
struct HormeTabBar: View {
    /// Height above the home indicator; screens keep this much room at the bottom.
    static let height: CGFloat = 56
    @Binding var selection: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(RootView.Tab.allCases, id: \.rawValue) { tab in
                if tab == .today { todayButton } else { item(tab) }
            }
        }
        .padding(.horizontal, 6).padding(.top, 6).padding(.bottom, 2)
        .background(alignment: .top) {
            Rectangle().fill(RaisedPanel.fill(scheme))
                .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.08), radius: 8, y: -3)
                .ignoresSafeArea(edges: .bottom)
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func item(_ tab: RootView.Tab) -> some View {
        let selected = selection == tab.rawValue
        return Button { selection = tab.rawValue } label: {
            VStack(spacing: 3) {
                HormeTabGlyph(tab: tab)
                    .font(.system(size: 21, weight: selected ? .semibold : .regular)).frame(height: 26)
                Text(tab.title).font(.system(size: 10, weight: selected ? .bold : .medium))
            }
            .foregroundStyle(selected ? Palette.accent : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var todayButton: some View {
        let selected = selection == RootView.Tab.today.rawValue
        let dark = scheme == .dark
        return Button { selection = RootView.Tab.today.rawValue } label: {
            VStack(spacing: 3) {
                ZStack {
                    Circle().fill(selected ? Palette.accent : RaisedPanel.fill(scheme))
                        .shadow(color: dark ? .black.opacity(0.7) : Color(red: 0.36, green: 0.42, blue: 0.48).opacity(selected ? 0.45 : 0.4),
                                radius: 8, x: 4, y: 5)
                        .shadow(color: dark ? Color.white.opacity(0.08) : .white, radius: 7, x: -4, y: -4)
                        .overlay(Circle().strokeBorder(LinearGradient(colors: [Color.white.opacity(dark ? 0.15 : 0.7), Color.white.opacity(0)],
                                                                      startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
                    Image(systemName: selected ? "sun.max.fill" : "sun.max").font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : Palette.accent)
                }
                .frame(width: 60, height: 60)
                Text("今日").font(.system(size: 10, weight: .bold)).foregroundStyle(selected ? Palette.accent : Color.secondary)
            }
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity)
            // The whole button answers, the raised top of the circle included…
            .contentShape(Rectangle())
            // …while the bar keeps its height; the circle rises above it instead of making it taller.
            .frame(height: 48, alignment: .bottom)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("今日")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(.snappy(duration: 0.2), value: selected)
    }
}

/// The reference board glyph: one full left column and two right-hand panels.
/// Only the glyph changes; the existing raised tab housing and hit area stay intact.
private struct BoardTabIcon: View {
    var body: some View {
        GeometryReader { g in
            ZStack {
                RoundedRectangle(cornerRadius: 2).stroke(lineWidth: 1.7)
                Path { p in
                    p.move(to: CGPoint(x: g.size.width / 2, y: 0))
                    p.addLine(to: CGPoint(x: g.size.width / 2, y: g.size.height))
                    p.move(to: CGPoint(x: g.size.width / 2, y: g.size.height / 2))
                    p.addLine(to: CGPoint(x: g.size.width, y: g.size.height / 2))
                }.stroke(lineWidth: 1.5)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct HormeTabGlyph: View {
    let tab: RootView.Tab
    var body: some View {
        Group {
            switch tab {
            case .week: CalendarTabIcon().frame(width: 23, height: 22)
            case .board: BoardTabIcon().frame(width: 23, height: 22)
            default: Image(systemName: tab.icon)
            }
        }
    }
}

/// Empty calendar outline and binding rings, matching the user's tab reference.
private struct CalendarTabIcon: View {
    var body: some View {
        GeometryReader { g in
            ZStack {
                RoundedRectangle(cornerRadius: 2).stroke(lineWidth: 1.7)
                    .frame(height: g.size.height - 3).offset(y: 1.5)
                Path { p in
                    for x in [g.size.width * 0.28, g.size.width * 0.72] {
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x, y: 6))
                    }
                    p.move(to: CGPoint(x: 0, y: 8))
                    p.addLine(to: CGPoint(x: g.size.width, y: 8))
                }.stroke(style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
            }
        }
        .accessibilityHidden(true)
    }
}
