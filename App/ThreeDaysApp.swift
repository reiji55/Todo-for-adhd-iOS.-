import SwiftUI

@main
@MainActor
struct ThreeDaysApp: App {
    @UIApplicationDelegateAdaptor(HormeAppDelegate.self) private var appDelegate
    @StateObject private var store = TaskStore.shared
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
}

@MainActor
struct RootView: View {
    enum Tab: Int, CaseIterable {
        case today, week, all, ideas, board
        var title: String { ["今日", "週", "すべて", "アイデア", "ボード"][rawValue] }
        var icon: String { ["sun.max", "calendar", "list.bullet.rectangle", "tray", "book.closed"][rawValue] }
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

    var body: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad {
                tabletNavigation
            } else {
                phoneNavigation
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { activeTaskBar }
        .sheet(item: $editor) { route in TaskEditor(task: route.task, original: route.original) }
        .sheet(item: $routineEditor) { routine in RoutineEditor(routine: routine) }
        .sheet(item: $quickAdd) { route in QuickAddSheet(day: route.day) }
        .sheet(isPresented: $focusOpen) { FocusView() }
        .sheet(isPresented: $settingsOpen) { SettingsView() }
        .sheet(item: $guide) { route in GuideSheet(cardID: route.id) }
        .alert("保存・読み込みのお知らせ", isPresented: Binding(
            get: { selectedTab != Tab.ideas.rawValue && !presenting && store.error != nil },
            set: { if !$0 { store.error = nil } }
        )) { Button("閉じる", role: .cancel) { store.error = nil } } message: { Text(store.error ?? "") }
        .modifier(ShareJoinAlert(enabled: editor == nil && !focusOpen && !settingsOpen))
        .onAppear {
            store.setForeground(phase == .active)
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-horme-settings-preview") { settingsOpen = true }
#endif
        }
        .onChange(of: phase) { _, newPhase in
            store.setForeground(newPhase == .active)
            if newPhase == .active { refreshDate = Date(); Reminders.shared.reschedule(store.notebook) }
            else { store.clearRecentlyDone() }
        }
        // Rows checked off stay visible on the screen they were checked on, and go once the person moves on.
        .onChange(of: selectedTab) { _, _ in store.clearRecentlyDone() }
        .onChange(of: store.notebook) { _, book in Reminders.shared.reschedule(book) }
        .task {
            #if DEBUG
            // Screenshot runs must not be covered by the permission dialog.
            if ProcessInfo.processInfo.arguments.contains("-uiTab") || ProcessInfo.processInfo.arguments.contains("-uiNoPrompt") { return }
            #endif
            await Reminders.shared.requestIfNeeded(for: store.notebook)
            Reminders.shared.reschedule(store.notebook)
        }
        .environment(\.refreshClock, refreshDate)
        .environment(\.openGuide, OpenGuideAction { guide = GuideRoute(id: $0) })
        .onAppear(perform: openTabForScreenshot)
    }

    private var presenting: Bool {
        editor != nil || routineEditor != nil || quickAdd != nil || focusOpen || settingsOpen || guide != nil
    }

    @ViewBuilder private func screen(_ tab: Tab) -> some View {
        switch tab {
        case .today:
            TodayView(onOpen: open, onStart: start, onWeek: { selectedTab = Tab.week.rawValue })
                .floatingAdd { quickAdd = QuickAddRoute(day: nil) }
        case .week:
            // The grid fills the screen, so the button floats over it instead of taking a row.
            WeekView(onOpen: open, onStart: start, onAdd: { quickAdd = QuickAddRoute(day: $0) })
                .overlay(alignment: .bottomTrailing) {
                    FloatingAddButton { quickAdd = QuickAddRoute(day: nil) }.padding(.trailing, 14).padding(.bottom, 10)
                }
        case .all:
            AllTasksView(onOpen: open, onStart: start, onEditRoutine: { routineEditor = $0 })
                .floatingAdd { quickAdd = QuickAddRoute(day: nil) }
        case .ideas:
            IdeasView(onEditTask: edit)
                .floatingAdd { quickAdd = QuickAddRoute(day: nil) }
        case .board:
            GuideBoardView(onEdit: edit, onStart: start)
                .floatingAdd { quickAdd = QuickAddRoute(day: nil) }
        }
    }

    private var tabletNavigation: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
            List(selection: Binding<Int?>(
                get: { selectedTab },
                set: { if let tab = $0 { selectedTab = tab; compactColumn = .detail } }
            )) {
                ForEach(Tab.allCases, id: \.rawValue) { tab in
                    NavigationLink(value: tab.rawValue) { Label(tab.title, systemImage: tab.icon) }
                }
            }
            .navigationTitle("Horme")
            .navigationBarTitleDisplayMode(.inline)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            NavigationStack {
                screen(Tab(rawValue: selectedTab) ?? .today)
                    .navigationTitle((Tab(rawValue: selectedTab) ?? .today).title)
                    .navigationBarTitleDisplayMode(selectedTab == Tab.week.rawValue ? .inline : .automatic)
                    .toolbar { commonToolbar }
            }
            // One stack serves every section; a card pushed on the board must not stay on top of 今日.
            .id(selectedTab)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var phoneNavigation: some View {
        TabView(selection: $selectedTab) {
            ForEach(Tab.allCases, id: \.rawValue) { tab in
                NavigationStack {
                    screen(tab)
                        .navigationTitle(tab == .today ? "Horme" : tab.title)
                        .navigationBarTitleDisplayMode(tab == .week ? .inline : .automatic)
                        .toolbar { commonToolbar }
                }
                .tabItem { Label(tab.title, systemImage: tab.icon) }.tag(tab.rawValue)
            }
        }
    }

    @ViewBuilder private var activeTaskBar: some View {
        if let session = store.notebook.activeSession, let task = store.task(session.taskID) {
            Button { focusOpen = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "play.circle.fill")
                    VStack(alignment: .leading) {
                        Text("取り組み中").font(.caption)
                        Text(task.actionTitle).font(.subheadline.weight(.medium)).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.up")
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
                .foregroundStyle(.white).background(Palette.accent)
            }.accessibilityLabel("取り組み中：\(task.actionTitle)。集中画面を開く")
        }
    }

    @ToolbarContentBuilder private var commonToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { store.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!store.canUndo).accessibilityLabel("直前の操作を取り消す")
        }
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
        #endif
    }

    private func start(_ task: TaskItem) {
        store.start(task)
        if store.notebook.activeSession?.taskID == task.id { focusOpen = true }
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
    @Environment(\.dismiss) private var dismiss
    let cardID: UUID
    var body: some View {
        NavigationStack {
            GuidePager(startID: cardID, cardIDs: [cardID])
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }
}
