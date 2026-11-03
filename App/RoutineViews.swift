import SwiftUI
import Charts

enum ClockMinutes {
    static func date(_ minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: (minutes / 60) % 24, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }
    static func minutes(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
    static let durations = [15, 30, 45, 60, 90, 120, 180, 240, 360, 480, 720]
    static func label(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)分" }
        return minutes % 60 == 0 ? "\(minutes / 60)時間" : "\(minutes / 60)時間\(minutes % 60)分"
    }
}

/// Start time and length, shared by the task and routine editors.
struct TimeSlotFields: View {
    @Binding var slot: TimeSlot?
    /// A time from older data that could not be read as a clock time ("午前").
    var legacyLabel: String = ""
    var onClearLegacy: (() -> Void)? = nil

    var body: some View {
        Toggle("時間を決める", isOn: Binding(
            get: { slot != nil },
            set: { slot = $0 ? (slot ?? TimeSlot(start: nextHalfHour(), duration: 60)) : nil }
        ))
        if let current = slot {
            DatePicker("始まり", selection: Binding(
                get: { ClockMinutes.date(current.start) },
                set: { slot = TimeSlot(start: ClockMinutes.minutes($0), duration: current.duration) }
            ), displayedComponents: .hourAndMinute)
            Picker("長さ", selection: Binding(
                get: { current.duration },
                set: { slot = TimeSlot(start: current.start, duration: $0) }
            )) {
                ForEach(Array(Set(ClockMinutes.durations + [current.duration])).sorted(), id: \.self) {
                    Text(ClockMinutes.label($0)).tag($0)
                }
            }
            Text("\(current.label)（\(ClockMinutes.label(current.duration))）").font(.caption).foregroundStyle(.secondary)
        } else if !legacyLabel.isEmpty {
            HStack {
                Text("以前の時間帯：\(legacyLabel)").foregroundStyle(.secondary)
                Spacer()
                if let onClearLegacy { Button("消す", action: onClearLegacy).buttonStyle(.borderless) }
            }
        }
    }

    private func nextHalfHour() -> Int {
        let now = ClockMinutes.minutes(Date())
        return min(23 * 60 + 30, (now / 30 + 1) * 30)
    }
}

/// Routines as a list. Used in the すべて tab and on the settings page.
@MainActor
struct RoutineList: View {
    @EnvironmentObject private var store: TaskStore
    var search = ""
    /// Routines that come round today are lifted off the page.
    var todayIDs: Set<UUID> = []
    let onEdit: (Routine) -> Void

    var body: some View {
        let routines = store.notebook.routines.filter {
            search.isEmpty || [$0.title, $0.project, $0.memo].joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
        let active = routines.filter { !$0.isPaused }.sorted(by: order)
        let paused = routines.filter(\.isPaused)
        Text("決まった曜日・時間にくり返すもの。今日や週の画面にタスクと同じ形で並びます。")
            .font(.caption).foregroundStyle(.secondary)
        Button { onEdit(Routine(title: "", time: "19:00-20:00")) } label: {
            Label("ルーティンを追加", systemImage: "plus.circle.fill").frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 44)
        }
        if routines.isEmpty {
            ContentUnavailableView(search.isEmpty ? "ルーティンはまだありません" : "見つかりませんでした",
                                   systemImage: "arrow.triangle.2.circlepath",
                                   description: Text("例：平日19:00の勉強、毎朝の薬、睡眠や仕事の時間（押さえるだけ）"))
        }
        ForEach(active) { routine in RoutineRow(routine: routine, raised: todayIDs.contains(routine.id), onEdit: onEdit) }
        if !paused.isEmpty {
            SectionHeading(title: "一時停止中")
            ForEach(paused) { routine in RoutineRow(routine: routine, onEdit: onEdit) }
        }
    }

    private func order(_ a: Routine, _ b: Routine) -> Bool {
        let at = a.slot?.start ?? Int.max, bt = b.slot?.start ?? Int.max
        return at == bt ? a.createdAt < b.createdAt : at < bt
    }
}

@MainActor
struct RoutineRow: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.openGuide) private var openGuide
    let routine: Routine
    var raised = false
    let onEdit: (Routine) -> Void
    var body: some View {
        HStack(spacing: 0) {
            Button { onEdit(routine) } label: {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(ProjectColor.color(for: store.colorName(forProject: routine.project)) ?? Color.secondary.opacity(0.4))
                        .frame(width: 3, height: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(routine.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                        HStack(spacing: 8) {
                            Text(routine.weekdayLabel)
                            if let slot = routine.slot { Text(slot.label).font(.clock) } else { Text("時間なし") }
                            if routine.isBlock { Text("押さえるだけ") }
                            if !routine.project.isEmpty { ProjectTag(name: routine.project) }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if routine.notify && !routine.isBlock && routine.slot != nil {
                        Image(systemName: "bell.fill").font(.caption).foregroundStyle(.secondary).accessibilityLabel("通知あり")
                    }
                }
                .padding(.vertical, 12).padding(.leading, 12)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            if let card = store.linkedCard(forProject: routine.project), let openGuide {
                GuideBookButton(card: card) { openGuide(card.id) }
            }
            // The chevron opens the editor too; the row's own button already says so to VoiceOver.
            Button { onEdit(routine) } label: {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    .frame(width: 22, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHidden(true)
        }
        .padding(.trailing, 8)
        .background {
            if raised { RaisedCardBackground() }
            else { RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .secondarySystemGroupedBackground)) }
        }
        .opacity(routine.isPaused ? 0.55 : 1)
    }
}

/// The routine settings page, reached from 設定.
@MainActor
struct RoutineSettingsView: View {
    @State private var editing: Routine?
    @State private var guide: GuideRoute?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) { RoutineList(onEdit: { editing = $0 }) }.padding(16)
        }
        .background(Palette.paper)
        .navigationTitle("ルーティン").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { RoutineEditor(routine: $0) }
        // Settings is itself a sheet, so a row's book opens the card from here rather than from the root.
        .sheet(item: $guide) { GuideSheet(cardID: $0.id) }
        .environment(\.openGuide, OpenGuideAction { guide = GuideRoute(id: $0) })
    }
}

struct WeekdayPicker: View {
    @Binding var weekdays: [Int]
    private let order = [2, 3, 4, 5, 6, 7, 1]
    private let names = ["日", "月", "火", "水", "木", "金", "土"]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(order, id: \.self) { day in
                    let on = weekdays.contains(day)
                    Button {
                        if on { if weekdays.count > 1 { weekdays.removeAll { $0 == day } } }
                        else { weekdays.append(day); weekdays.sort() }
                    } label: {
                        Text(names[day - 1]).font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(on ? Palette.accent : Color(uiColor: .tertiarySystemFill), in: Circle())
                            .foregroundStyle(on ? Color.white : Color.primary)
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(names[day - 1])曜日").accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            HStack {
                preset("毎日", Array(1...7)); preset("平日", Array(2...6)); preset("土日", [1, 7])
            }
        }.padding(.vertical, 4)
    }
    private func preset(_ title: String, _ days: [Int]) -> some View {
        Button(title) { weekdays = days }.buttonStyle(.bordered).buttonBorderShape(.capsule).font(.caption)
            .tint(Set(weekdays) == Set(days) ? Palette.accent : .secondary)
    }
}

@MainActor
struct RoutineEditor: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    private let initial: Routine
    @State private var routine: Routine
    @State private var showDelete = false
    @State private var confirmDiscard = false
    @State private var guide: GuideRoute?

    init(routine: Routine) {
        initial = routine
        _routine = State(initialValue: routine)
    }

    private var changed: Bool { routine != initial }
    private var trimmedTitle: String { routine.title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var exists: Bool { store.routine(routine.id) != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("ルーティン名（例：TOEICの単語）", text: $routine.title, axis: .vertical).font(.headline).lineLimit(1...3)
                    ProjectPicker(project: $routine.project) { guide = GuideRoute(id: $0.id) }
                    if !routine.isBlock { MilestonePicker(project: routine.project, milestoneID: $routine.milestoneID, kinds: [.count]) }
                } footer: {
                    if routine.milestoneID != nil {
                        Text("済んだ日ごとに、その通過点の回数が1つ進みます。")
                    } else {
                        Text(store.linkedCard(forProject: routine.project) == nil
                             ? "カードのあるプロジェクトを選ぶと、ここや今日の画面の本のマークから、やり方をすぐ開けます。"
                             : "本のマークで、プロジェクトのカードを開けます。閉じると、この画面に戻ります。")
                    }
                }
                Section("くり返す曜日") { WeekdayPicker(weekdays: $routine.weekdays) }
                Section {
                    TimeSlotFields(slot: $routine.slot)
                } header: { Text("時間") }
                footer: { Text("週の画面で長押しして動かすと、その日だけ時間や曜日を変えられます。") }
                Section {
                    Toggle("始まる時刻に通知", isOn: $routine.notify).disabled(routine.isBlock || routine.slot == nil)
                    Toggle("時間を押さえるだけ", isOn: $routine.isBlock)
                } footer: {
                    Text("「押さえるだけ」は睡眠や仕事など、時間を確保しておくもの。週の画面で斜線になり、チェックや通知はしません。")
                }
                Section {
                    Toggle("一時停止", isOn: $routine.isPaused)
                } footer: { Text("止めている間は今日・週の画面に出ません。設定は残ります。") }
                Section("メモ") {
                    TextField("やること、気をつけること", text: $routine.memo, axis: .vertical).lineLimit(2...8)
                }
                if exists && !routine.isBlock {
                    Section {
                        NavigationLink { RoutineLogView(routineID: routine.id) } label: {
                            LabeledContent {
                                Text(RoutineLogView.format(store.routine(routine.id)?.durations.values.reduce(0, +) ?? 0)).monospacedDigit()
                            } label: {
                                Label("計った記録を見る", systemImage: "chart.bar")
                            }
                        }
                    } footer: { Text("今日の画面の▶で計ると、日ごとの時間が残ります。") }
                }
                if exists {
                    Section { Button("このルーティンを削除", role: .destructive) { showDelete = true } }
                }
            }
            .confirmationDialog("このルーティンを削除しますか？", isPresented: $showDelete, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    store.deleteRoutine(routine.id)
                    if !exists { dismiss() }
                }
            } message: { Text("これまでのチェックも消えます。休むだけなら「一時停止」が使えます。") }
            .navigationTitle(exists ? "ルーティンを編集" : "ルーティンを追加").keyboardDismissable().navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { if changed { confirmDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        routine.title = trimmedTitle
                        if routine.isBlock { routine.notify = false }
                        if store.upsertRoutine(routine) { dismiss() }
                    }.disabled(trimmedTitle.isEmpty)
                }
            }
            .interactiveDismissDisabled(changed)
            // Over the editor, so closing the card comes back to what was being written.
            .sheet(item: $guide) { route in GuideSheet(cardID: route.id) }
            .onChange(of: routine.project) { _, project in
                routine.milestoneID = MilestonePicker.fitting(routine.milestoneID, project: project, in: store.notebook)
            }
        }
        .confirmationDialog("編集した内容を破棄しますか？", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("破棄して閉じる", role: .destructive) { dismiss() }
        }
        .storeErrorAlert()
    }
}

/// A routine's timed days: the total, a bar for each recent day, and the list of days with their time.
@MainActor
struct RoutineLogView: View {
    @EnvironmentObject private var store: TaskStore
    let routineID: UUID

    struct Entry { var day: Date; var seconds: Int }

    var body: some View {
        let routine = store.routine(routineID)
        let entries = (routine?.durations ?? [:]).compactMap { key, seconds in DayKey.date(key).map { Entry(day: $0, seconds: seconds) } }
            .sorted { $0.day > $1.day }
        let total = entries.reduce(0) { $0 + $1.seconds }
        List {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("合計").font(.caption).foregroundStyle(.secondary)
                        Text(Self.format(total)).font(.title2.weight(.bold)).monospacedDigit()
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("計った日").font(.caption).foregroundStyle(.secondary)
                        Text("\(entries.count)日").font(.title2.weight(.bold)).monospacedDigit()
                    }
                }
                if !entries.isEmpty {
                    Chart(Array(entries.prefix(30)), id: \.day) { entry in
                        BarMark(x: .value("日", entry.day, unit: .day), y: .value("分", Double(entry.seconds) / 60))
                            .foregroundStyle(Palette.accent)
                    }
                    .chartYAxisLabel("分")
                    .frame(height: 180)
                    .padding(.vertical, 6)
                    .accessibilityLabel("日ごとの時間のグラフ")
                }
            } footer: {
                if entries.count > 30 { Text("グラフは新しい30日分です。") }
            }
            Section("日ごとの記録") {
                if entries.isEmpty {
                    Text("今日の画面でこのルーティンの▶を押して計ると、ここに残ります。").foregroundStyle(.secondary)
                }
                ForEach(entries, id: \.day) { entry in
                    LabeledContent(entry.day.formatted(.dateTime.year().month().day().weekday(.abbreviated))) {
                        Text(Self.format(entry.seconds)).monospacedDigit()
                    }
                }
            }
        }
        .navigationTitle(routine?.title ?? "記録").navigationBarTitleDisplayMode(.inline)
    }

    /// "1時間05分", "25分", "45秒".
    static func format(_ seconds: Int) -> String {
        let minutes = seconds / 60
        if minutes >= 60 { return "\(minutes / 60)時間\(String(format: "%02d", minutes % 60))分" }
        return minutes > 0 ? "\(minutes)分" : "\(seconds)秒"
    }
}
