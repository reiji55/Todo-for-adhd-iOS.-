import SwiftUI
import UIKit

/// The week as seven rows, Monday to Sunday, with time running left to right as in task-3days.
/// All seven days fit on screen; hours scroll sideways so blocks are wide enough to read.
/// Pull past either end to turn the week. Long-press a block and drag it to another day or time.
@MainActor
struct WeekView: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.refreshClock) private var refreshClock
    @State private var weekStart = WeekView.monday(of: Date())
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    /// The block last tapped in the grid; its row in the list below is emphasized.
    @State private var focusedItem: String?
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
            content(now: max(context.date, refreshClock))
        }
        .background(Palette.paper)
    }

    /// As in task-3days: the week on top, the chosen day's list below it.
    /// Tapping a block picks it out in the list; tapping it there opens it.
    private func content(now: Date) -> some View {
        GeometryReader { geometry in
            let available: CGFloat = geometry.size.height - 40
            let gridHeight: CGFloat = min(584, max(304, available * 0.62))
            VStack(spacing: 0) {
                header(now: now)
                grid(now: now).frame(height: gridHeight)
                Divider()
                dayList
            }
        }
    }

    private func grid(now: Date) -> some View {
        WeekRows(days: days, now: now, selectedDay: selectedDay, highlighted: focusedItem,
                 onSelectItem: { item, day in
                     selectedDay = Calendar.current.startOfDay(for: day)
                     focusedItem = item.id
                 },
                 onSelectDay: { day in
                     selectedDay = Calendar.current.startOfDay(for: day)
                     focusedItem = nil
                 },
                 onTurn: shift)
    }

    private var dayList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                DayList(day: selectedDay, highlighted: focusedItem, onOpen: onOpen, onStart: onStart, onAdd: onAdd)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
            .onChange(of: focusedItem) { _, id in
                guard let id else { return }
                withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
            }
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
                Button("今週") {
                    withAnimation(.snappy) { weekStart = WeekView.monday(of: now) }
                    selectedDay = Calendar.current.startOfDay(for: now); focusedItem = nil
                }.font(.subheadline)
            }
        }
        .padding(.horizontal, 8)
    }

    /// Turning the week keeps the same weekday chosen, so the list below follows the grid.
    private func shift(_ weeks: Int) {
        let calendar = Calendar.current
        withAnimation(.snappy) {
            weekStart = calendar.date(byAdding: .day, value: 7 * weeks, to: weekStart) ?? weekStart
        }
        selectedDay = calendar.date(byAdding: .day, value: 7 * weeks, to: selectedDay) ?? selectedDay
        focusedItem = nil
    }
}

/// Geometry shared by drawing, hit testing and dropping, in the scroll content's coordinates.
struct WeekRowsLayout {
    let hours: ClosedRange<Int>
    let hourWidth: CGFloat
    let rowHeight: CGFloat
    let ruler: CGFloat = 24
    /// A lane before the first hour for items without a time; drag them right to give them one.
    let untimedWidth: CGFloat = 112
    var contentWidth: CGFloat { untimedWidth + CGFloat(max(1, hours.count - 1)) * hourWidth + 8 }
    var height: CGFloat { ruler + rowHeight * 7 }
    func x(minute: Int) -> CGFloat { untimedWidth + CGFloat(minute - hours.lowerBound * 60) / 60 * hourWidth }
    func minute(x: CGFloat) -> Int { hours.lowerBound * 60 + Int(((x - untimedWidth) / hourWidth * 60).rounded()) }
    func y(row: Int) -> CGFloat { ruler + CGFloat(row) * rowHeight }
    func row(y: CGFloat) -> Int { min(6, max(0, Int(floor((y - ruler) / rowHeight)))) }
}

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

@MainActor
struct WeekRows: View {
    @EnvironmentObject private var store: TaskStore
    let days: [Date]
    let now: Date
    let selectedDay: Date
    let highlighted: String?
    let onSelectItem: (AgendaItem, Date) -> Void
    let onSelectDay: (Date) -> Void
    let onTurn: (Int) -> Void

    @State private var drag: DragState?
    @State private var anchor: Int?
    @State private var offset: CGFloat = 0
    @State private var turnArmed = true
    @State private var landing: Landing?
    @State private var edgeScroll: Task<Void, Never>?

    private let dateColumn: CGFloat = 54
    /// Hour anchors for scrolling; the untimed lane is -1.
    private static let untimedAnchor = -1

    enum Landing { case start, end }

    struct Placed: Identifiable {
        var item: AgendaItem
        var row: Int
        var rect: CGRect
        var timed: Bool
        var id: String { item.id }
    }

    /// A block too narrow for its title gets it written small under the day's line, as in task-3days.
    struct NarrowLabel: Identifiable {
        var id: String
        var title: String
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
    }

    struct Placement {
        var blocks: [Placed] = []
        var labels: [NarrowLabel] = []
    }

    /// Below this width a block's title cannot be read inside it.
    static let narrowWidth: CGFloat = 52
    static let labelStrip: CGFloat = 13

    struct Target: Equatable {
        var row: Int
        /// nil drops it into the day's untimed lane.
        var start: Int?
    }

    struct DragState {
        var item: AgendaItem
        var fromRow: Int
        var grab: CGSize
        var size: CGSize
        /// Finger position in the viewport (the visible part of the scroll view).
        var location: CGPoint
        var target: Target?
        var grabPending = false
        var landingRect: CGRect?
    }

    var body: some View {
        let perDay = days.map { Agenda.items(on: $0, tasks: store.notebook.tasks, routines: store.notebook.routines) }
        // Sleep and work blocks are clipped rather than stretching the hours for everything else.
        let hours = Agenda.hourRange(for: perDay.flatMap { $0 }.filter { !$0.isBlock })
        GeometryReader { geometry in
            let rowHeight = max(40, (geometry.size.height - 24) / 7)
            let viewportWidth = geometry.size.width - dateColumn
            // Two-hour columns, sized so a phone shows a whole morning (6:00 to past noon) at once
            // and a wide screen shows the daytime.
            let visibleHours: CGFloat = viewportWidth < 560 ? 6.5 : 12.5
            let layout = WeekRowsLayout(hours: hours, hourWidth: max(40, (viewportWidth / visibleHours).rounded()), rowHeight: rowHeight)
            let placement = place(perDay, layout: layout)
            let placed = placement.blocks
            HStack(alignment: .top, spacing: 0) {
                dateCells(layout: layout, perDay: perDay)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            Color.clear.frame(width: layout.untimedWidth, height: layout.height).id(Self.untimedAnchor)
                            ForEach(Array(hours.lowerBound..<hours.upperBound), id: \.self) { hour in
                                Color.clear.frame(width: layout.hourWidth, height: layout.height).id(hour)
                            }
                            Color.clear.frame(width: 8, height: layout.height)
                        }
                        .scrollTargetLayout()
                        .overlay(alignment: .topLeading) {
                            ZStack(alignment: .topLeading) {
                                WeekRowsBackground(days: days, now: now, layout: layout)
                                if let drag, let origin = placed.first(where: { $0.id == drag.item.id }) {
                                    // Where it came from stays outlined until it lands.
                                    RoundedRectangle(cornerRadius: 7).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                        .foregroundStyle(.secondary)
                                        .frame(width: origin.rect.width, height: origin.rect.height)
                                        .offset(x: origin.rect.minX, y: origin.rect.minY)
                                }
                                if let drag, let target = drag.target { targetPreview(target, drag: drag, layout: layout) }
                                ForEach(placed) { block in
                                    WeekBlock(item: block.item, timed: block.timed, size: block.rect.size, lifted: false,
                                              compact: block.timed && !block.item.isBlock && block.rect.width < Self.narrowWidth,
                                              selected: block.id == highlighted)
                                        .frame(width: block.rect.width, height: block.rect.height)
                                        .offset(x: block.rect.minX, y: block.rect.minY)
                                        .opacity(drag?.item.id == block.id ? 0 : 1)
                                        .zIndex(block.item.isBlock ? 0 : 1)
                                        .onTapGesture { onSelectItem(block.item, days[block.row]) }
                                        .gesture(moveGesture(block, layout: layout, viewportWidth: viewportWidth))
                                        .accessibilityElement(children: .ignore)
                                        .accessibilityLabel("\(block.item.slot?.label ?? "時間なし") \(block.item.title)\(block.item.isDone ? "、完了" : "")")
                                        .accessibilityHint("ダブルタップで下の一覧に出します。長押しして動かすと日時を変えられます。")
                                }
                                ForEach(placement.labels) { label in
                                    Text(label.title).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.tail)
                                        .frame(width: label.width, height: Self.labelStrip, alignment: .leading)
                                        .offset(x: label.x, y: label.y)
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(width: layout.contentWidth, height: layout.height, alignment: .topLeading)
                        }
                        .background(GeometryReader { content in
                            Color.clear.preference(key: ScrollOffsetKey.self, value: -content.frame(in: .named("weekViewport")).minX)
                        })
                    }
                    .scrollPosition(id: $anchor, anchor: .leading)
                    // While a block is held, the finger moves the block, not the hours.
                    .scrollDisabled(drag != nil)
                    .coordinateSpace(name: "weekViewport")
                    .overlay(alignment: .topLeading) { liftedBlock }
                    .onPreferenceChange(ScrollOffsetKey.self) { value in
                        offset = value
                        turnPage(maxOffset: max(0, layout.contentWidth - viewportWidth))
                        if var state = drag {
                            state.target = target(for: state, layout: layout)
                            if state.target != drag?.target { drag?.target = state.target }
                        }
                    }
            }
            .onAppear {
                // Set after the first layout pass; a position set while the scroll view is still sizing is ignored.
                let start = initialAnchor(hours: hours)
                DispatchQueue.main.async { anchor = start }
            }
            .onChange(of: days.first) { _, _ in
                switch landing {
                case .start: anchor = Self.untimedAnchor
                case .end: anchor = hours.upperBound - 1
                case nil: anchor = initialAnchor(hours: hours)
                }
                landing = nil
            }
        }
    }

    /// Every week opens an hour before the current time, so now and what comes next are in view.
    private func initialAnchor(hours: ClosedRange<Int>) -> Int {
        let hour = Calendar.current.component(.hour, from: now) - 1
        return min(max(hours.lowerBound, hour), hours.upperBound - 1)
    }

    /// Pulling past either end turns the week, once per pull.
    private func turnPage(maxOffset: CGFloat) {
        let threshold: CGFloat = 70
        if offset > -5 && offset < maxOffset + 5 { turnArmed = true; return }
        guard turnArmed, drag == nil else { return }
        if offset > maxOffset + threshold {
            turnArmed = false; landing = .start
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onTurn(1)
        } else if offset < -threshold {
            turnArmed = false; landing = .end
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onTurn(-1)
        }
    }

    private func dateCells(layout: WeekRowsLayout, perDay: [[AgendaItem]]) -> some View {
        let calendar = Calendar.current
        return VStack(spacing: 0) {
            Color.clear.frame(height: layout.ruler)
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                let isToday = calendar.isDate(day, inSameDayAs: now)
                let untimed = perDay[index].filter { $0.slot == nil && !$0.isDone }.count
                Button { onSelectDay(day) } label: {
                    VStack(spacing: 2) {
                        Text(day.formatted(.dateTime.weekday(.short))).font(.caption2.weight(.semibold))
                            .foregroundStyle(calendar.isDateInWeekend(day) ? Palette.must : .secondary)
                        Text("\(calendar.component(.day, from: day))")
                            .font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                            .foregroundStyle(isToday ? Color.white : .primary)
                            .frame(width: 34, height: 28)
                            .background { if isToday { Capsule().fill(Color.red) } }
                        if untimed > 0 {
                            Text("未定\(untimed)").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: dateColumn, height: layout.rowHeight)
                    .background {
                        if calendar.isDate(day, inSameDayAs: selectedDay) {
                            RoundedRectangle(cornerRadius: 8).fill(Palette.accent.opacity(0.12)).padding(2)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(day.formatted(.dateTime.month().day().weekday(.wide)))の予定を見る")
            }
        }
        .frame(width: dateColumn)
    }

    // MARK: Layout

    private func place(_ perDay: [[AgendaItem]], layout: WeekRowsLayout) -> Placement {
        var result: [Placed] = []
        var labels: [NarrowLabel] = []
        let lower = layout.hours.lowerBound * 60, upper = layout.hours.upperBound * 60
        for (row, items) in perDay.enumerated() {
            let top = layout.y(row: row) + 3
            let height = layout.rowHeight - 6
            // Untimed items stack in the lane before the first hour; the fourth and later are in the day list.
            let untimed = Array(items.filter { $0.slot == nil }.prefix(3))
            let chip = (height - CGFloat(max(0, untimed.count - 1)) * 3) / CGFloat(max(1, untimed.count))
            for (index, item) in untimed.enumerated() {
                result.append(Placed(item: item, row: row,
                                     rect: CGRect(x: 4, y: top + CGFloat(index) * (chip + 3),
                                                  width: layout.untimedWidth - 10, height: min(chip, 30)),
                                     timed: false))
            }
            // Held time (sleep, work) spans the row behind everything; the rest share it in lanes.
            for item in items where item.isBlock {
                guard let slot = item.slot else { continue }
                let start = max(slot.start, lower), end = min(slot.end, upper)
                guard end > start else { continue }
                result.append(Placed(item: item, row: row,
                                     rect: CGRect(x: layout.x(minute: start), y: top,
                                                  width: max(12, layout.x(minute: end) - layout.x(minute: start)), height: height),
                                     timed: true))
            }
            let timed = items.filter { !$0.isBlock && $0.slot != nil }
            func width(_ item: AgendaItem) -> CGFloat {
                let slot = item.slot!
                let start = max(slot.start, lower), end = min(slot.end, upper)
                return end > start ? max(24, layout.x(minute: end) - layout.x(minute: start) - 2) : 0
            }
            // Rows with a narrow block keep a strip at the bottom for the small titles.
            let narrow = timed.filter { (1..<Self.narrowWidth).contains(width($0)) }
            let blockHeight = height - (narrow.isEmpty ? 0 : Self.labelStrip)
            for (item, lane, lanes) in Self.lanes(timed) {
                let slot = item.slot!
                let start = max(slot.start, lower), end = min(slot.end, upper)
                guard end > start else { continue }
                let laneHeight = blockHeight / CGFloat(lanes)
                result.append(Placed(item: item, row: row,
                                     rect: CGRect(x: layout.x(minute: start) + 1, y: top + CGFloat(lane) * laneHeight,
                                                  width: width(item), height: laneHeight - (lanes > 1 ? 2 : 0)),
                                     timed: true))
            }
            let starts = narrow.map { layout.x(minute: max($0.slot!.start, lower)) + 1 }.sorted()
            for item in narrow.sorted(by: { $0.slot!.start < $1.slot!.start }) {
                let x = layout.x(minute: max(item.slot!.start, lower)) + 1
                // Each title runs until the next narrow block's title, so they never overlap.
                let next = starts.first { $0 > x + 1 } ?? .infinity
                labels.append(NarrowLabel(id: item.id, title: item.title, x: x, y: top + blockHeight,
                                          width: max(18, min(150, next - x - 3))))
            }
        }
        return Placement(blocks: result, labels: labels)
    }

    /// Overlapping items share the row in stacked lanes, as in a calendar.
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

    /// The held block, drawn over the scroll view so it stays under the finger while the hours scroll.
    @ViewBuilder private var liftedBlock: some View {
        if let drag {
            let rect = drag.landingRect
                ?? CGRect(origin: CGPoint(x: drag.location.x - drag.grab.width, y: drag.location.y - drag.grab.height), size: drag.size)
            WeekBlock(item: drag.item, timed: drag.item.slot != nil, size: rect.size, lifted: drag.landingRect == nil)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    private func moveGesture(_ block: Placed, layout: WeekRowsLayout, viewportWidth: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("weekViewport")))
            .onChanged { value in
                guard case .second(true, let finger) = value else { return }
                // Content coordinates to the visible viewport.
                let visible = block.rect.offsetBy(dx: -offset, dy: 0)
                let location = finger?.location ?? CGPoint(x: visible.midX, y: visible.midY)
                if drag == nil {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    var state = DragState(item: block.item, fromRow: block.row,
                                          grab: CGSize(width: location.x - visible.minX, height: location.y - visible.minY),
                                          size: block.rect.size, location: location, target: nil, grabPending: finger == nil)
                    state.target = target(for: state, layout: layout)
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) { drag = state }
                    return
                }
                guard var state = drag, state.landingRect == nil else { return }
                if state.grabPending, let finger {
                    state.grab = CGSize(width: finger.startLocation.x - visible.minX, height: finger.startLocation.y - visible.minY)
                    state.grabPending = false
                }
                state.location = location
                let next = target(for: state, layout: layout)
                // The block follows the finger exactly; only the landing outline animates between slots.
                var follow = Transaction()
                follow.disablesAnimations = true
                withTransaction(follow) { drag?.location = location; drag?.grab = state.grab; drag?.grabPending = state.grabPending }
                if next != state.target {
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(.snappy(duration: 0.14)) { drag?.target = next }
                }
                scrollNearEdges(x: location.x, viewportWidth: viewportWidth, layout: layout)
            }
            .onEnded { _ in drop(layout: layout) }
    }

    /// Holding the block near the left or right edge scrolls an hour at a time to reach hours off screen.
    private func scrollNearEdges(x: CGFloat, viewportWidth: CGFloat, layout: WeekRowsLayout) {
        let direction = x < 36 ? -1 : (x > viewportWidth - 36 ? 1 : 0)
        guard direction != 0 else { edgeScroll?.cancel(); edgeScroll = nil; return }
        guard edgeScroll == nil else { return }
        edgeScroll = Task { @MainActor in
            while !Task.isCancelled, drag != nil {
                let current = anchor ?? layout.hours.lowerBound
                let next = min(layout.hours.upperBound - 1, max(Self.untimedAnchor, current + direction))
                if next == current { break }
                withAnimation(.easeInOut(duration: 0.2)) { anchor = next }
                try? await Task.sleep(for: .milliseconds(260))
            }
            edgeScroll = nil
        }
    }

    private func target(for state: DragState, layout: WeekRowsLayout) -> Target? {
        let point = state.location
        guard point.y >= layout.ruler - 6, point.y <= layout.height + 10 else { return nil }
        let row = layout.row(y: point.y)
        let duration = state.item.slot?.duration ?? 60
        // Timed blocks keep where they were held; an untimed chip starts where the finger is.
        let left = (state.item.slot == nil ? point.x - 8 : point.x - state.grab.width) + offset
        if point.x + offset < layout.untimedWidth - 8 { return Target(row: row, start: nil) }
        let snapped = Int((Double(layout.minute(x: left)) / 15).rounded()) * 15
        let latest = min(24 * 60 - 15, layout.hours.upperBound * 60 - min(duration, 60))
        return Target(row: row, start: min(latest, max(layout.hours.lowerBound * 60, snapped)))
    }

    private func targetRect(_ target: Target, duration: Int, layout: WeekRowsLayout) -> CGRect {
        let top = layout.y(row: target.row) + 3, height = layout.rowHeight - 6
        guard let start = target.start else { return CGRect(x: 4, y: top, width: layout.untimedWidth - 10, height: min(height, 30)) }
        let end = min(start + duration, layout.hours.upperBound * 60)
        return CGRect(x: layout.x(minute: start) + 1, y: top, width: max(24, layout.x(minute: end) - layout.x(minute: start) - 2), height: height)
    }

    private func drop(layout: WeekRowsLayout) {
        edgeScroll?.cancel(); edgeScroll = nil
        guard let state = drag else { return }
        guard let target = state.target else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { drag = nil }
            return
        }
        let duration = state.item.slot?.duration ?? 60
        let slot = target.start.map { TimeSlot(start: $0, duration: duration) }
        let changed = target.row != state.fromRow || slot != state.item.slot
        // First the held block flies into its slot, then the data changes underneath, so nothing jumps back.
        let landing = targetRect(target, duration: duration, layout: layout).offsetBy(dx: -offset, dy: 0)
        withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) { drag?.landingRect = landing }
        if changed { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(240))
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) {
                if changed { store.move(state.item, to: days[target.row], slot: slot) }
                drag = nil
            }
        }
    }

    @ViewBuilder private func targetPreview(_ target: Target, drag: DragState, layout: WeekRowsLayout) -> some View {
        let duration = drag.item.slot?.duration ?? 60
        let rect = targetRect(target, duration: duration, layout: layout)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7).fill(Palette.accent.opacity(0.14))
            RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
        }
        .frame(width: rect.width, height: rect.height)
        .overlay(alignment: .topLeading) {
            if let start = target.start {
                Text(TimeSlot(start: start, duration: duration).label)
                    .font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Palette.accent, in: Capsule()).fixedSize().offset(y: -15)
            }
        }
        .offset(x: rect.minX, y: rect.minY)
    }
}

/// Hour ruler, day rows, the untimed lane and the current time.
@MainActor
private struct WeekRowsBackground: View {
    let days: [Date]
    let now: Date
    let layout: WeekRowsLayout

    var body: some View {
        let calendar = Calendar.current
        ZStack(alignment: .topLeading) {
            ForEach(0..<7, id: \.self) { row in
                let isToday = calendar.isDate(days[row], inSameDayAs: now)
                Rectangle().fill(isToday ? Palette.accent.opacity(0.06) : (row % 2 == 0 ? Color.secondary.opacity(0.035) : .clear))
                    .frame(width: layout.contentWidth, height: layout.rowHeight)
                    .offset(y: layout.y(row: row))
                Rectangle().fill(Color.secondary.opacity(0.15)).frame(width: layout.contentWidth, height: 0.5)
                    .offset(y: layout.y(row: row))
            }
            Rectangle().fill(Color.secondary.opacity(0.06)).frame(width: layout.untimedWidth, height: layout.rowHeight * 7)
                .offset(y: layout.ruler)
            Text("時間なし").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: layout.untimedWidth, alignment: .center).offset(y: 5)
            ForEach(Array(layout.hours), id: \.self) { hour in
                let x = layout.x(minute: hour * 60)
                let major = hour % 2 == 0
                // A line and a label every two hours; the faint line between helps aim a 15-minute drop.
                Rectangle().fill(Color.secondary.opacity(major ? 0.18 : 0.07)).frame(width: 0.5, height: layout.rowHeight * 7)
                    .offset(x: x, y: layout.ruler)
                if major && hour < layout.hours.upperBound {
                    let isNow = currentHour.map { $0 - $0 % 2 } == hour
                    Text("\(hour % 24):00").font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(isNow ? Color.white : .secondary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background { if isNow { Capsule().fill(Color.red) } }
                        .offset(x: x + 3, y: 4)
                }
            }
            if let todayRow = days.firstIndex(where: { calendar.isDate($0, inSameDayAs: now) }), layout.hours.contains(currentHour ?? -1) {
                let x = layout.x(minute: minuteNow)
                // Today shaded up to now, a red line at now, and a dotted line to compare other days.
                Rectangle().fill(Color.secondary.opacity(0.08))
                    .frame(width: max(0, x - layout.untimedWidth), height: layout.rowHeight)
                    .offset(x: layout.untimedWidth, y: layout.y(row: todayRow))
                Path { path in
                    path.move(to: CGPoint(x: x, y: layout.ruler)); path.addLine(to: CGPoint(x: x, y: layout.height))
                }.stroke(Color.red.opacity(0.45), style: StrokeStyle(lineWidth: 0.8, dash: [2, 3]))
                Rectangle().fill(Color.red).frame(width: 2, height: layout.rowHeight)
                    .offset(x: x - 1, y: layout.y(row: todayRow))
                Circle().fill(Color.red).frame(width: 8, height: 8).offset(x: x - 4, y: layout.y(row: todayRow) - 4)
            }
        }
        .frame(width: layout.contentWidth, height: layout.height, alignment: .topLeading)
    }

    private var minuteNow: Int {
        Calendar.current.component(.hour, from: now) * 60 + Calendar.current.component(.minute, from: now)
    }
    private var currentHour: Int? {
        days.contains { Calendar.current.isDate($0, inSameDayAs: now) } ? minuteNow / 60 : nil
    }
}

@MainActor
private struct WeekBlock: View {
    @EnvironmentObject private var store: TaskStore
    let item: AgendaItem
    let timed: Bool
    let size: CGSize
    let lifted: Bool
    /// Too narrow to read: the title is written under the row instead.
    var compact = false
    /// Tapped, and shown in the list below.
    var selected = false

    var body: some View {
        let colorName = store.colorName(forProject: item.project)
        let accent = ProjectColor.color(for: colorName) ?? Palette.accent
        let shape = RoundedRectangle(cornerRadius: 7)
        // Room for a time line, then as many 12pt title lines as fit.
        let showsTime = timed && size.height >= 40 && size.width >= 44 && !item.isBlock
        let titleLines = max(1, Int((size.height - (showsTime ? 16 : 6)) / 15))
        ZStack(alignment: .topLeading) {
            if item.isBlock {
                shape.fill(Color.secondary.opacity(0.08))
                Hatch(spacing: 6).stroke(Color.secondary.opacity(0.25), lineWidth: 1).clipShape(shape)
            } else if item.isEvent {
                // Events read as appointments: a lighter fill with an outline instead of a side bar.
                shape.fill(ProjectColor.tint(for: colorName, amount: 0.16))
                shape.strokeBorder(accent.opacity(0.7), lineWidth: 1.2)
            } else {
                shape.fill(ProjectColor.tint(for: colorName, amount: item.isDone ? 0.18 : 0.32))
                if item.isDone { Hatch(spacing: 6, reversed: true).stroke(accent.opacity(0.45), lineWidth: 1.2).clipShape(shape) }
                Rectangle().fill(accent).frame(width: 3).clipShape(shape)
            }
            if !compact { VStack(alignment: .leading, spacing: 1) {
                if showsTime, let slot = item.slot {
                    // A narrow block keeps the start time only, so the title still has room.
                    Text(size.width >= 80 ? slot.label : slot.startLabel)
                        .font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    if item.isMust { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Palette.must) }
                    if item.isRoutine && !item.isBlock {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    if item.isEvent { Image(systemName: "calendar").font(.system(size: 9)).foregroundStyle(accent) }
                    Text(item.title).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(item.isBlock || item.isDone ? .secondary : .primary)
                        .strikethrough(item.isDone)
                        .lineLimit(titleLines)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, item.isBlock ? 5 : 7).padding(.trailing, 3).padding(.top, 3) }
        }
        .clipShape(shape)
        .overlay { if lifted || selected { shape.strokeBorder(selected ? Palette.accent : accent, lineWidth: selected ? 2.5 : 1.5) } }
        .scaleEffect(lifted ? 1.05 : 1)
        .shadow(color: .black.opacity(lifted ? 0.28 : 0), radius: lifted ? 10 : 0, y: lifted ? 5 : 0)
        .contentShape(shape)
    }
}

/// One day's rows, below or beside the grid.
@MainActor
struct DayList: View {
    @EnvironmentObject private var store: TaskStore
    let day: Date
    var highlighted: String? = nil
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
            ForEach(items) { item in
                let picked = item.id == highlighted
                AgendaRow(item: item, onOpen: onOpen, onStart: onStart)
                    .overlay { if picked { RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.accent, lineWidth: 2.5) } }
                    .shadow(color: picked ? Palette.accent.opacity(0.3) : .clear, radius: 8, y: 3)
                    .scaleEffect(picked ? 1.02 : 1)
                    .animation(.snappy, value: picked)
                    .id(item.id)
            }
            Text("表の帯をタップすると、ここで目立たせます。ここをタップすると編集できます。表で長押しして動かすと日付と時間を変えられます（ルーティンはその日だけ）。左右の端からさらに引くと前後の週に移ります。")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
        }
    }
}
