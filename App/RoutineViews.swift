import SwiftUI

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
        ForEach(active) { routine in RoutineRow(routine: routine, onEdit: onEdit) }
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
    let routine: Routine
    let onEdit: (Routine) -> Void
    var body: some View {
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
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            .opacity(routine.isPaused ? 0.55 : 1)
        }.buttonStyle(.plain)
    }
}

/// The routine settings page, reached from 設定.
@MainActor
struct RoutineSettingsView: View {
    @State private var editing: Routine?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) { RoutineList(onEdit: { editing = $0 }) }.padding(16)
        }
        .background(Palette.paper)
        .navigationTitle("ルーティン").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { RoutineEditor(routine: $0) }
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
                    HStack {
                        TextField("プロジェクト", text: $routine.project)
                        if !store.notebook.boardCards.isEmpty {
                            Menu {
                                ForEach(store.notebook.boardCards) { card in Button(card.title) { routine.project = card.title } }
                            } label: { Image(systemName: "book").frame(width: 44, height: 44) }
                                .accessibilityLabel("ボードのカードから選ぶ")
                        }
                    }
                } footer: { Text("ボードのカードと同じプロジェクトにすると、やり方をすぐ開けます。") }
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
            .navigationTitle(exists ? "ルーティンを編集" : "ルーティンを追加").navigationBarTitleDisplayMode(.inline)
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
        }
        .confirmationDialog("編集した内容を破棄しますか？", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("破棄して閉じる", role: .destructive) { dismiss() }
        }
        .storeErrorAlert()
    }
}
