import SwiftUI
import UIKit

/// The week as one screen, Monday to Sunday, like the task-3days timetable. Long-press a block and
/// drag it to another day or time; everything else reads the same data, so the move shows up everywhere.
@MainActor
struct WeekView: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.refreshClock) private var refreshClock
    @State private var weekStart = WeekView.monday(of: Date())
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var dayListOpen = false
    let onOpen: (AgendaItem) -> Void
    let onStart: (TaskItem) -> Void
    let onAdd: (Date) -> Void

    static func monday(of date: Date) -> Date {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    private var days: [Date] {
        (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: weekStart) }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = max(context.date, refreshClock)
            GeometryReader { geometry in
                // On a wide iPad the chosen day's list sits beside the grid; on iPhone it opens as a sheet.
                let wide = geometry.size.width >= 900
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        header(now: now)
                        WeekGrid(days: days, now: now, selectedDay: selectedDay, onOpen: onOpen) { day in
                            selectedDay = day
                            if !wide { dayListOpen = true }
                        }
                        .padding(.horizontal, 4)
                    }
                    if wide {
                        Divider()
                        ScrollView { DayList(day: selectedDay, onOpen: onOpen, onStart: onStart, onAdd: onAdd).padding(16) }
                            .frame(width: 340)
                    }
                }
            }
        }
        .background(Palette.paper)
        .sheet(isPresented: $dayListOpen) {
            NavigationStack {
                ScrollView { DayList(day: selectedDay, onOpen: onOpen, onStart: onStart, onAdd: onAdd).padding(16) }
                    .background(Palette.paper)
                    .navigationTitle(selectedDay.formatted(.dateTime.month().day().weekday(.wide)))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dayListOpen = false } } }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func header(now: Date) -> some View {
        let last = days.last ?? weekStart
        let isThisWeek = Calendar.current.isDate(weekStart, inSameDayAs: WeekView.monday(of: now))
        return HStack(spacing: 4) {
            Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 40) }
                .accessibilityLabel("前の週")
            Text("\(weekStart.formatted(.dateTime.month().day())) – \(last.formatted(.dateTime.month().day()))")
                .font(.subheadline.weight(.semibold)).monospacedDigit()
            Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 40) }
                .accessibilityLabel("次の週")
            Spacer()
            if !isThisWeek {
                Button("今週") { withAnimation(.snappy) { weekStart = WeekView.monday(of: now) } }.font(.subheadline)
            }
        }
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
            if abs(value.translation.width) > abs(value.translation.height) { shift(value.translation.width < 0 ? 1 : -1) }
        })
    }

    private func shift(_ weeks: Int) {
        withAnimation(.snappy) {
            weekStart = Calendar.current.date(byAdding: .day, value: 7 * weeks, to: weekStart) ?? weekStart
        }
    }
}

/// Geometry shared by drawing, hit testing and dropping.
struct WeekLayout {
    let size: CGSize
    let hours: ClosedRange<Int>
    let stripRows: Int
    let gutter: CGFloat = 26
    let header: CGFloat = 40
    var strip: CGFloat { CGFloat(max(1, stripRows)) * 18 + 6 }
    var columnWidth: CGFloat { (size.width - gutter) / 7 }
    var timelineTop: CGFloat { header + strip }
    var hourHeight: CGFloat { max(12, (size.height - timelineTop - 6) / CGFloat(max(1, hours.count - 1))) }
    func x(day: Int) -> CGFloat { gutter + CGFloat(day) * columnWidth }
    func y(minute: Int) -> CGFloat { timelineTop + CGFloat(minute - hours.lowerBound * 60) / 60 * hourHeight }
    func minute(y: CGFloat) -> Int { hours.lowerBound * 60 + Int(((y - timelineTop) / hourHeight * 60).rounded()) }
    func day(x: CGFloat) -> Int { min(6, max(0, Int(floor((x - gutter) / columnWidth)))) }
}

@MainActor
struct WeekGrid: View {
    @EnvironmentObject private var store: TaskStore
    let days: [Date]
    let now: Date
    let selectedDay: Date
    let onOpen: (AgendaItem) -> Void
    let onSelectDay: (Date) -> Void
    @State private var drag: DragState?

    struct Placed: Identifiable {
        var item: AgendaItem
        var day: Int
        var rect: CGRect
        var timed: Bool
        var id: String { item.id }
    }

    struct Target: Equatable {
        var day: Int
        /// nil drops it into the day's "時間なし" strip.
        var start: Int?
    }

    struct DragState {
        var item: AgendaItem
        var fromDay: Int
        var grab: CGSize
        var size: CGSize
        var location: CGPoint
        var target: Target?
        /// The hold is recognized before the finger position arrives; the grab point is fixed on the first update.
        var grabPending = false
    }

    var body: some View {
        let perDay = days.map { Agenda.items(on: $0, tasks: store.notebook.tasks, routines: store.notebook.routines) }
        // Sleep and work blocks are clipped rather than allowed to stretch the hours for everything else.
        let hours = Agenda.hourRange(for: perDay.flatMap { $0 }.filter { !$0.isBlock })
        let stripRows = min(3, perDay.map { $0.filter { $0.slot == nil }.count }.max() ?? 0)
        GeometryReader { geometry in
            let layout = WeekLayout(size: geometry.size, hours: hours, stripRows: stripRows)
            let placed = place(perDay, layout: layout)
            ZStack(alignment: .topLeading) {
                WeekBackground(days: days, now: now, selectedDay: selectedDay, layout: layout, onSelectDay: onSelectDay)
                if let drag {
                    // Where it came from stays outlined until it lands.
                    if let origin = placed.first(where: { $0.id == drag.item.id }) {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(.secondary).frame(width: origin.rect.width, height: origin.rect.height)
                            .offset(x: origin.rect.minX, y: origin.rect.minY)
                    }
                    if let target = drag.target { targetPreview(target, drag: drag, layout: layout) }
                }
                ForEach(placed) { block in
                    let lifted = drag?.item.id == block.id
                    let origin = lifted ? CGPoint(x: drag!.location.x - drag!.grab.width, y: drag!.location.y - drag!.grab.height)
                                        : block.rect.origin
                    WeekBlock(item: block.item, timed: block.timed, height: block.rect.height, lifted: lifted)
                        .frame(width: lifted ? drag!.size.width : block.rect.width, height: lifted ? drag!.size.height : block.rect.height)
                        .offset(x: origin.x, y: origin.y)
                        .zIndex(lifted ? 10 : block.item.isBlock ? 0 : 1)
                        .onTapGesture { onOpen(block.item) }
                        .gesture(moveGesture(block, layout: layout))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(block.item.slot?.label ?? "時間なし") \(block.item.title)\(block.item.isDone ? "、完了" : "")")
                        .accessibilityHint("ダブルタップで開きます。長押しして動かすと日時を変えられます。")
                }
            }
            .coordinateSpace(name: "week")
        }
    }

    // MARK: Layout

    private func place(_ perDay: [[AgendaItem]], layout: WeekLayout) -> [Placed] {
        var result: [Placed] = []
        let lower = layout.hours.lowerBound * 60, upper = layout.hours.upperBound * 60
        for (day, items) in perDay.enumerated() {
            let x = layout.x(day: day)
            let width = layout.columnWidth
            // Untimed items stack in the strip under the date; more than three collapse into the last row.
            for (row, item) in items.filter({ $0.slot == nil }).prefix(3).enumerated() {
                result.append(Placed(item: item, day: day,
                                     rect: CGRect(x: x + 1.5, y: layout.header + 3 + CGFloat(row) * 18, width: width - 3, height: 16),
                                     timed: false))
            }
            // Held time (sleep, work) spans the column behind everything; the rest share it in lanes.
            for item in items where item.isBlock {
                guard let slot = item.slot else { continue }
                let top = max(slot.start, lower), bottom = min(slot.end, upper)
                guard bottom > top else { continue }
                result.append(Placed(item: item, day: day,
                                     rect: CGRect(x: x + 1, y: layout.y(minute: top), width: width - 2,
                                                  height: max(10, layout.y(minute: bottom) - layout.y(minute: top))),
                                     timed: true))
            }
            let timed = items.filter { !$0.isBlock && $0.slot != nil }
            for (item, lane, lanes) in Self.lanes(timed) {
                let slot = item.slot!
                let top = max(slot.start, lower), bottom = min(slot.end, upper)
                guard bottom > top else { continue }
                let laneWidth = (width - 2) / CGFloat(lanes)
                result.append(Placed(item: item, day: day,
                                     rect: CGRect(x: x + 1 + CGFloat(lane) * laneWidth, y: layout.y(minute: top) + 0.5,
                                                  width: laneWidth - 1, height: max(14, layout.y(minute: bottom) - layout.y(minute: top) - 1)),
                                     timed: true))
            }
        }
        return result
    }

    /// Overlapping items share the column side by side, as in a calendar.
    static func lanes(_ items: [AgendaItem]) -> [(AgendaItem, Int, Int)] {
        let sorted = items.sorted { ($0.slot!.start, $0.id) < ($1.slot!.start, $1.id) }
        var result: [(AgendaItem, Int, Int)] = []
        var cluster: [(AgendaItem, Int)] = []
        var laneEnds: [Int] = []
        var clusterEnd = Int.min
        func flush() {
            result += cluster.map { ($0.0, $0.1, max(1, laneEnds.count)) }
            cluster = []; laneEnds = []
        }
        for item in sorted {
            let slot = item.slot!
            if slot.start >= clusterEnd { flush() }
            if let lane = laneEnds.firstIndex(where: { $0 <= slot.start }) {
                laneEnds[lane] = slot.end; cluster.append((item, lane))
            } else {
                laneEnds.append(slot.end); cluster.append((item, laneEnds.count - 1))
            }
            clusterEnd = max(clusterEnd, slot.end)
        }
        flush()
        return result
    }

    // MARK: Moving

    private func moveGesture(_ block: Placed, layout: WeekLayout) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("week")))
            .onChanged { value in
                guard case .second(true, let finger) = value else { return }
                let location = finger?.location ?? CGPoint(x: block.rect.midX, y: block.rect.midY)
                if drag == nil {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    let grab = CGSize(width: location.x - block.rect.minX, height: location.y - block.rect.minY)
                    var state = DragState(item: block.item, fromDay: block.day, grab: grab, size: block.rect.size,
                                          location: location, target: nil, grabPending: finger == nil)
                    state.target = target(for: state, layout: layout)
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) { drag = state }
                    return
                }
                guard var state = drag else { return }
                if state.grabPending, let finger {
                    state.grab = CGSize(width: finger.startLocation.x - block.rect.minX, height: finger.startLocation.y - block.rect.minY)
                    state.grabPending = false
                    drag?.grab = state.grab; drag?.grabPending = false
                }
                state.location = location
                let next = target(for: state, layout: layout)
                // The block follows the finger exactly; only the landing outline animates between slots.
                var follow = Transaction()
                follow.disablesAnimations = true
                withTransaction(follow) { drag?.location = location }
                if next != state.target {
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(.snappy(duration: 0.14)) { drag?.target = next }
                }
            }
            .onEnded { _ in drop() }
    }

    private func target(for state: DragState, layout: WeekLayout) -> Target? {
        let point = state.location
        guard point.y >= layout.header - 4, point.x >= layout.gutter - 8, point.x <= layout.size.width + 8 else { return nil }
        let day = layout.day(x: point.x)
        if point.y < layout.timelineTop { return Target(day: day, start: nil) }
        let duration = state.item.slot?.duration ?? 60
        // Timed blocks keep where they were held; an untimed chip starts where the finger is.
        let top = state.item.slot == nil ? point.y - 6 : point.y - state.grab.height
        let raw = layout.minute(y: top)
        let snapped = Int((Double(raw) / 15).rounded()) * 15
        let latest = min(24 * 60 - 15, layout.hours.upperBound * 60 - min(duration, 60))
        return Target(day: day, start: min(latest, max(layout.hours.lowerBound * 60, snapped)))
    }

    private func drop() {
        guard let state = drag else { return }
        guard let target = state.target else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { drag = nil }
            return
        }
        let slot = target.start.map { TimeSlot(start: $0, duration: state.item.slot?.duration ?? 60) }
        let changed = target.day != state.fromDay || slot != state.item.slot
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            if changed { store.move(state.item, to: days[target.day], slot: slot) }
            drag = nil
        }
        if changed { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }

    @ViewBuilder private func targetPreview(_ target: Target, drag: DragState, layout: WeekLayout) -> some View {
        let x = layout.x(day: target.day) + 1
        if let start = target.start {
            let duration = drag.item.slot?.duration ?? 60
            let y = layout.y(minute: start)
            let height = max(14, layout.y(minute: min(start + duration, layout.hours.upperBound * 60)) - y)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Palette.accent.opacity(0.14))
                RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
            .frame(width: layout.columnWidth - 2, height: height)
            .overlay(alignment: .topLeading) {
                Text(TimeSlot(start: start, duration: duration).label).font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit().foregroundStyle(.white).padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Palette.accent, in: Capsule()).fixedSize().offset(y: -16)
            }
            .offset(x: x, y: y)
        } else {
            RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                .frame(width: layout.columnWidth - 2, height: layout.strip - 4)
                .offset(x: x, y: layout.header + 2)
        }
    }
}

/// Day headers, hour lines, the "時間なし" strip and the current time.
@MainActor
private struct WeekBackground: View {
    let days: [Date]
    let now: Date
    let selectedDay: Date
    let layout: WeekLayout
    let onSelectDay: (Date) -> Void

    var body: some View {
        let calendar = Calendar.current
        ZStack(alignment: .topLeading) {
            // Hour lines and labels. Labels every two hours when rows are short.
            let step = layout.hourHeight < 22 ? 2 : 1
            ForEach(Array(layout.hours), id: \.self) { hour in
                let y = layout.y(minute: hour * 60)
                Rectangle().fill(Color.secondary.opacity(hour % step == 0 ? 0.22 : 0.1))
                    .frame(width: layout.size.width - layout.gutter, height: 0.5)
                    .offset(x: layout.gutter, y: y)
                if hour % step == 0 && hour < layout.hours.upperBound {
                    Text("\(hour)").font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.secondary).frame(width: layout.gutter - 4, alignment: .trailing)
                        .offset(x: 0, y: y - 6)
                }
            }
            Text("時間なし").font(.system(size: 8)).foregroundStyle(.secondary)
                .frame(width: layout.gutter, alignment: .center).offset(y: layout.header + 4)
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                let x = layout.x(day: index)
                let isToday = calendar.isDate(day, inSameDayAs: now)
                // How far today has come, shaded from the top to now, as in task-3days.
                if isToday {
                    let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
                    let y = min(max(layout.y(minute: minute), layout.timelineTop), layout.size.height)
                    Rectangle().fill(Color.secondary.opacity(0.08))
                        .frame(width: layout.columnWidth, height: max(0, y - layout.timelineTop))
                        .offset(x: x, y: layout.timelineTop)
                }
                Rectangle().fill(Color.secondary.opacity(0.15)).frame(width: 0.5, height: layout.size.height - layout.header)
                    .offset(x: x, y: layout.header)
                Rectangle().fill(Color.secondary.opacity(0.05)).frame(width: layout.columnWidth, height: layout.strip)
                    .offset(x: x, y: layout.header)
                Button { onSelectDay(day) } label: {
                    VStack(spacing: 1) {
                        Text(day.formatted(.dateTime.weekday(.narrow))).font(.caption2)
                            .foregroundStyle(calendar.isDateInWeekend(day) ? Palette.must : .secondary)
                        // The bare number: the localized "26日" does not fit a narrow column.
                        Text("\(calendar.component(.day, from: day))").font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(isToday ? Color.white : .primary)
                            .frame(width: 26, height: 22)
                            .background { if isToday { Capsule().fill(Color.red) } }
                    }
                    .frame(width: layout.columnWidth, height: layout.header)
                    .background {
                        if calendar.isDate(day, inSameDayAs: selectedDay) {
                            RoundedRectangle(cornerRadius: 8).fill(Palette.accent.opacity(0.12)).padding(2)
                        }
                    }
                }
                .buttonStyle(.plain)
                .offset(x: x)
                .accessibilityLabel("\(day.formatted(.dateTime.month().day().weekday(.wide)))の予定を見る")
            }
            if let todayIndex = days.firstIndex(where: { calendar.isDate($0, inSameDayAs: now) }) {
                let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
                if layout.hours.contains(minute / 60) {
                    let y = layout.y(minute: minute)
                    // Dotted across the week to compare the same time on other days.
                    Path { path in
                        path.move(to: CGPoint(x: layout.gutter, y: y)); path.addLine(to: CGPoint(x: layout.size.width, y: y))
                    }.stroke(Color.red.opacity(0.45), style: StrokeStyle(lineWidth: 0.8, dash: [2, 3]))
                    Rectangle().fill(Color.red).frame(width: layout.columnWidth, height: 1.5)
                        .offset(x: layout.x(day: todayIndex), y: y - 0.75)
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                        .offset(x: layout.x(day: todayIndex) - 3.5, y: y - 3.5)
                }
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
    }
}

@MainActor
private struct WeekBlock: View {
    @EnvironmentObject private var store: TaskStore
    let item: AgendaItem
    let timed: Bool
    let height: CGFloat
    let lifted: Bool

    var body: some View {
        let colorName = store.colorName(forProject: item.project)
        let accent = ProjectColor.color(for: colorName) ?? Palette.accent
        let shape = RoundedRectangle(cornerRadius: timed ? 6 : 4)
        ZStack(alignment: .topLeading) {
            if item.isBlock {
                shape.fill(Color.secondary.opacity(0.08))
                Hatch(spacing: 5).stroke(Color.secondary.opacity(0.28), lineWidth: 1).clipShape(shape)
            } else {
                shape.fill(ProjectColor.tint(for: colorName, amount: item.isDone ? 0.18 : 0.3))
                if item.isDone { Hatch(spacing: 5, reversed: true).stroke(accent.opacity(0.45), lineWidth: 1.2).clipShape(shape) }
                Rectangle().fill(accent).frame(width: 2.5).clipShape(shape)
            }
            VStack(alignment: .leading, spacing: 0) {
                if timed && height >= 30, let slot = item.slot {
                    Text(slot.startLabel).font(.system(size: 9, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 1) {
                    if item.isMust { Image(systemName: "star.fill").font(.system(size: 7)).foregroundStyle(Palette.must) }
                    if item.isRoutine && !item.isBlock {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 7)).foregroundStyle(.secondary)
                    }
                    Text(item.title).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(item.isBlock || item.isDone ? .secondary : .primary)
                        .strikethrough(item.isDone)
                        .lineLimit(timed ? max(1, Int((height - (height >= 30 ? 12 : 0)) / 12)) : 1)
                }
            }
            .padding(.leading, item.isBlock ? 3 : 5).padding(.trailing, 2).padding(.top, 2)
        }
        .clipShape(shape)
        .overlay { if lifted { shape.strokeBorder(accent, lineWidth: 1.5) } }
        .scaleEffect(lifted ? 1.06 : 1)
        .shadow(color: .black.opacity(lifted ? 0.28 : 0), radius: lifted ? 10 : 0, y: lifted ? 5 : 0)
        .contentShape(shape)
    }
}

/// One day's rows, below or beside the grid.
@MainActor
struct DayList: View {
    @EnvironmentObject private var store: TaskStore
    let day: Date
    let onOpen: (AgendaItem) -> Void
    let onStart: (TaskItem) -> Void
    let onAdd: (Date) -> Void

    var body: some View {
        let items = Agenda.items(on: day, tasks: store.notebook.tasks, routines: store.notebook.routines)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(day.formatted(.dateTime.month().day().weekday(.wide))).font(.headline)
                Spacer()
                Button { onAdd(day) } label: { Label("この日に追加", systemImage: "plus") }.font(.subheadline)
            }
            if items.isEmpty {
                Text("この日の予定はありません。").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(items) { item in AgendaRow(item: item, onOpen: onOpen, onStart: onStart) }
            Text("週の表で長押しして動かすと、日付と時間を変えられます。ルーティンはその日だけ動きます。")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
        }
    }
}
