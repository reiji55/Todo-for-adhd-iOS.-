import SwiftUI
import UIKit

/// The week on iPhone: each day a row of four shelves (morning, midday, evening, night) holding its
/// things as small chips, so the whole week reads at a glance without sideways scrolling. A sheet
/// pulled up from the bottom shows the chosen day and the next one hour by hour; swiping its dates
/// moves a day at a time. Time held for sleep or work only tints the shelves it fills.
///
/// A chip tapped on the shelves opens the sheet at its hour; a shelf with three or more opens a small
/// balloon listing them all. A chip held and dragged goes to another day or time of day; the exact
/// time is set afterwards in the sheet.
@MainActor
struct WeekShelfView: View {
    /// Down (only the dates peek out), half up, or all the way up over the title bar.
    enum Detent { case peek, half, full }

    /// Where the sheet's hours should scroll to, and the block to point out there.
    struct SheetFocus: Equatable {
        let id = UUID()
        var minute: Int?
        var itemID: String?
    }

    struct ShelfTarget: Equatable {
        var day: Date
        var band: Band
    }

    /// A chip held and carried over the shelves.
    struct Carry: Equatable {
        var item: AgendaItem
        var fromDay: Date
        var location: CGPoint
        var target: ShelfTarget?
    }

    @EnvironmentObject private var store: TaskStore
    @Environment(\.refreshClock) private var refreshClock
    @Environment(\.colorScheme) private var scheme
    @State private var weekStart = WeekView.monday(of: Date())
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var detent: Detent = .peek
    @State private var sheetDrag: CGFloat = 0
    @State private var dayDrag: CGFloat = 0
    @State private var dragAxis: Axis?
    @State private var focus: SheetFocus?
    @State private var carry: Carry?
    @State private var rowFrames: [Date: CGRect] = [:]
    let onOpen: (AgendaItem) -> Void
    let onAdd: (Date) -> Void
    /// The ⊕ menu; with the sheet up, what is added goes on the chosen day.
    let onPick: (AddKind, Date?) -> Void

    /// How much of the sheet shows when it is down: the handle and the top half of its dates.
    static let peekHeight: CGFloat = 44
    static let space = "weekShelf"
    private let gutter: CGFloat = 40

    private var days: [Date] {
        (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: weekStart) }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: max(context.date, refreshClock))
        }
        .background(Palette.paper)
        // All the way up, the sheet takes the title bar's place too.
        .toolbar(detent == .full ? .hidden : .visible, for: .navigationBar)
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-uiWeekSheetOpen") { detent = .half }
            if ProcessInfo.processInfo.arguments.contains("-uiWeekSheetFull") { detent = .full }
            #endif
        }
    }

    private func height(_ detent: Detent, full: CGFloat) -> CGFloat {
        switch detent {
        case .peek: return Self.peekHeight
        case .half: return max(Self.peekHeight, full - 96)
        case .full: return max(Self.peekHeight, full - 6)
        }
    }

    private func content(now: Date) -> some View {
        GeometryReader { geometry in
            let full = geometry.size.height
            let top = height(.full, full: full)
            let half = height(.half, full: full)
            let visible = min(top, max(Self.peekHeight, height(detent, full: full) - sheetDrag))
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    header(now: now)
                    ScrollView {
                        shelf(now: now)
                            .padding(.horizontal, 8)
                            .padding(.bottom, Self.peekHeight + 76)
                            .frame(maxWidth: 760).frame(maxWidth: .infinity)
                    }
                }
                .opacity(1 - 0.6 * min(1, Double((visible - Self.peekHeight) / max(1, half - Self.peekHeight))))
                // With the sheet up, a tap on the week above it puts the sheet back down.
                if detent != .peek {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { detent = .peek } }
                        .accessibilityHidden(true)
                }
                sheet(now: now, width: geometry.size.width, full: full)
                    .frame(height: top, alignment: .top)
                    .offset(y: full - visible)
            }
            .overlay(alignment: .bottomTrailing) {
                FloatingAddButton { onPick($0, detent == .peek ? nil : selectedDay) }
                    .padding(.trailing, 20).padding(.bottom, Self.peekHeight + 10)
            }
            .clipped()
        }
    }

    // MARK: Header and week

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
                    withAnimation(.snappy) {
                        weekStart = WeekView.monday(of: now)
                        selectedDay = Calendar.current.startOfDay(for: now)
                        focus = nil
                    }
                }.font(.subheadline)
            }
        }
        .padding(.horizontal, 8)
    }

    private func shift(_ weeks: Int) {
        let calendar = Calendar.current
        withAnimation(.snappy) {
            weekStart = calendar.date(byAdding: .day, value: 7 * weeks, to: weekStart) ?? weekStart
            selectedDay = calendar.date(byAdding: .day, value: 7 * weeks, to: selectedDay) ?? selectedDay
            focus = nil
        }
    }

    /// One day on in the sheet; the shelves follow into the next or previous week when needed.
    private func step(_ days: Int) {
        let calendar = Calendar.current
        guard let day = calendar.date(byAdding: .day, value: days, to: selectedDay) else { return }
        selectedDay = day
        focus = nil
        let monday = WeekView.monday(of: day)
        if !calendar.isDate(monday, inSameDayAs: weekStart) { weekStart = monday }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    // MARK: The shelves

    enum Band: Int, CaseIterable {
        case morning, midday, evening, night
        var title: String { ["AM1", "AM2", "PM1", "PM2"][rawValue] }
        /// The column heading: the first band also holds things without a time.
        var heading: String { self == .morning ? "AM1/時間未定" : title }
        /// Minutes of the day the band covers: six hours each, within the day.
        var range: Range<Int> { [0..<6 * 60, 6 * 60..<12 * 60, 12 * 60..<18 * 60, 18 * 60..<24 * 60][rawValue] }
        /// Where a thing moved into this band from another one lands, until a time is picked in the sheet.
        var usualStart: Int { [5 * 60, 9 * 60, 13 * 60, 19 * 60][rawValue] }
        static func of(_ minute: Int) -> Band {
            allCases.first { $0.range.contains(minute) } ?? .night
        }
        /// Things without a time sit with the first band.
        static func of(_ item: AgendaItem) -> Band { item.slot.map { of($0.start) } ?? .morning }
    }

    /// The time a carried thing gets on its new shelf: unchanged within the same time of day, else
    /// the usual start of the new one. Things without a time stay so on the first shelf.
    static func landing(_ item: AgendaItem, in band: Band) -> TimeSlot? {
        guard let slot = item.slot else {
            return band == .morning ? nil : TimeSlot(start: band.usualStart, duration: 60)
        }
        if Band.of(slot.start) == band { return slot }
        return TimeSlot(start: min(band.usualStart, 24 * 60 - slot.duration), duration: slot.duration)
    }

    private func shelf(now: Date) -> some View {
        let calendar = Calendar.current
        return VStack(spacing: 4) {
            HStack(spacing: 4) {
                Color.clear.frame(width: gutter, height: 1)
                ForEach(Band.allCases, id: \.rawValue) { band in
                    Text(band.heading).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.6).frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 6)
            ForEach(days, id: \.self) { day in
                // Only today is outlined: tapping a day already brings it up in the sheet below.
                let isToday = calendar.isDate(day, inSameDayAs: now)
                let target = carry?.target.flatMap { calendar.isDate($0.day, inSameDayAs: day) ? $0.band : nil }
                ShelfRow(day: day, now: now, gutter: gutter, targetBand: target, carrying: carry?.item.id,
                         onSelect: { select(day) },
                         onFocus: { band, item in focusOn(day: day, band: band, item: item) },
                         onCarry: { item, location in carried(item, from: day, to: location) },
                         onDrop: dropped)
                .overlay {
                    if isToday {
                        RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.7), lineWidth: 3.5)
                            .padding(.leading, gutter + 2).allowsHitTesting(false)
                    }
                }
                .background {
                    GeometryReader { row in
                        Color.clear.preference(key: ShelfRowFrames.self, value: [day: row.frame(in: .named(Self.space))])
                    }
                }
            }
        }
        .onPreferenceChange(ShelfRowFrames.self) { rowFrames = $0 }
        .overlay(alignment: .topLeading) { liftedChip }
        .coordinateSpace(name: Self.space)
    }

    private var cellWidth: CGFloat {
        guard let frame = rowFrames.values.first else { return 80 }
        return (frame.width - gutter - 16) / 4
    }

    /// The carried chip, above the finger, with the day and time it would land on.
    @ViewBuilder private var liftedChip: some View {
        if let carry {
            VStack(alignment: .leading, spacing: 3) {
                if let target = carry.target {
                    let landing = Self.landing(carry.item, in: target.band)
                    Text("\(target.day.formatted(.dateTime.month(.defaultDigits).day())) \(landing?.startLabel ?? "時間なし")")
                        .font(.system(size: 10, weight: .bold)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Palette.accent, in: Capsule())
                }
                ShelfChip(item: carry.item)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 6))
                    .frame(width: cellWidth + 10)
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
            }
            .fixedSize()
            .position(x: carry.location.x, y: carry.location.y - 36)
            .allowsHitTesting(false)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }

    private func target(at point: CGPoint) -> ShelfTarget? {
        let rows = rowFrames.sorted { $0.value.minY < $1.value.minY }
        guard let last = rows.last else { return nil }
        let row = rows.first { point.y <= $0.value.maxY + 2 } ?? last
        let width = (row.value.width - gutter - 16) / 4
        let column = Int(((point.x - row.value.minX - gutter - 4) / (width + 4)).rounded(.down))
        return ShelfTarget(day: row.key, band: Band(rawValue: min(3, max(0, column))) ?? .morning)
    }

    private func carried(_ item: AgendaItem, from day: Date, to location: CGPoint) {
        let target = target(at: location)
        guard carry != nil else {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) {
                carry = Carry(item: item, fromDay: day, location: location, target: target)
            }
            return
        }
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) { carry?.location = location }
        if target != carry?.target {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.snappy(duration: 0.14)) { carry?.target = target }
        }
    }

    private func dropped() {
        guard let carry else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { self.carry = nil }
        guard let target = carry.target else { return }
        let sameDay = Calendar.current.isDate(target.day, inSameDayAs: carry.fromDay)
        guard !sameDay || target.band != Band.of(carry.item) else { return }
        let slot = Self.landing(carry.item, in: target.band)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        store.move(carry.item, to: target.day, slot: slot)
        store.offerUndo("「\(carry.item.title)」を\(target.day.formatted(.dateTime.month(.defaultDigits).day())) \(slot?.startLabel ?? target.band.title)へ")
    }

    private func select(_ day: Date) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            selectedDay = Calendar.current.startOfDay(for: day)
            focus = nil
            if detent == .peek { detent = .half }
        }
    }

    /// The sheet opens on the day, scrolled to the thing tapped (or to the time of day), and points it out.
    private func focusOn(day: Date, band: Band, item: AgendaItem?) {
        let items = Agenda.items(on: day, tasks: store.notebook.tasks, routines: store.notebook.routines)
        let first = items.filter { !$0.isBlock && Band.of($0) == band }.compactMap(\.slot).map(\.start).min()
        // A thing without a time is in the row at the top of the sheet; the hours open as usual.
        let minute: Int? = item != nil ? item?.slot?.start : (first ?? band.usualStart)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            selectedDay = Calendar.current.startOfDay(for: day)
            if detent == .peek { detent = .half }
            focus = SheetFocus(minute: minute, itemID: item?.id)
        }
    }

    // MARK: The sheet

    private func sheet(now: Date, width: CGFloat, full: CGFloat) -> some View {
        let calendar = Calendar.current
        let second = calendar.date(byAdding: .day, value: 1, to: selectedDay) ?? selectedDay
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                Capsule().fill(Color.secondary.opacity(0.45)).frame(width: 38, height: 5).padding(.top, 8)
                dateStrip(width: width, now: now).padding(.top, 6)
            }
            .contentShape(Rectangle())
            .gesture(sheetGesture(full: full))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { detent = detent == .peek ? .half : .peek }
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint(detent == .peek ? "上げると2日分の時間割が開きます" : "下げると週の棚に戻ります")
            .accessibilityAction(named: "次の日") { withAnimation(.snappy) { step(1) } }
            .accessibilityAction(named: "前の日") { withAnimation(.snappy) { step(-1) } }
            .accessibilityAction(named: "大きく広げる") { withAnimation(.snappy) { detent = .full } }
            SheetDays(days: [selectedDay, second], now: now, gutter: gutter, focus: focus, onOpen: onOpen,
                      onMove: { item, day, slot in store.move(item, to: day, slot: slot) })
                .opacity(detent != .peek || sheetDrag < -10 ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(scheme == .dark ? 0.7 : 0.15), radius: 14, y: -6)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    /// Up and down moves the sheet between its three stops; sideways moves the days.
    private func sheetGesture(full: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if dragAxis == nil {
                    dragAxis = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                }
                var quiet = Transaction()
                quiet.disablesAnimations = true
                withTransaction(quiet) {
                    if dragAxis == .vertical { sheetDrag = value.translation.height } else { dayDrag = value.translation.width }
                }
            }
            .onEnded { value in
                if dragAxis == .vertical {
                    let target = Self.stop(after: value, from: detent, heights: { height($0, full: full) })
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                        detent = target
                        sheetDrag = 0
                    }
                } else {
                    let throwDistance = value.predictedEndTranslation.width
                    withAnimation(.snappy(duration: 0.28)) {
                        if throwDistance < -60 { step(1) } else if throwDistance > 60 { step(-1) }
                        dayDrag = 0
                    }
                }
                dragAxis = nil
            }
    }

    /// Where the sheet settles when let go, by how hard it was thrown: a strong flick goes all the way
    /// (up to the top, or down to the dates), a light one goes one stop on from where it is, and a
    /// slow drag stays at the stop nearest to where it was left.
    static func stop(after value: DragGesture.Value, from detent: Detent, heights: (Detent) -> CGFloat) -> Detent {
        let stops: [Detent] = [.peek, .half, .full]
        let lowest = heights(.peek), highest = heights(.full)
        let position = min(highest, max(lowest, heights(detent) - value.translation.height))
        let speed = value.velocity.height
        if speed < -1600 { return .full }
        if speed > 1600 { return .peek }
        if speed < -250 { return stops.first { heights($0) > position + 1 } ?? .full }
        if speed > 250 { return stops.last { heights($0) < position - 1 } ?? .peek }
        return stops.min { abs(heights($0) - position) < abs(heights($1) - position) } ?? detent
    }

    /// The two dates over their columns, large; the days either side peek in faintly at the edges,
    /// and seven short bars below say where in the week they are.
    private func dateStrip(width: CGFloat, now: Date) -> some View {
        let calendar = Calendar.current
        let column = (width - gutter - 18) / 2
        let centers = [gutter + column / 2, gutter + column + 6 + column / 2]
        let shown = [-1, 0, 1, 2].compactMap { calendar.date(byAdding: .day, value: $0, to: selectedDay) }
        return ZStack(alignment: .topLeading) {
            ForEach(Array(shown.enumerated()), id: \.element) { index, day in
                let side = index == 0 || index == 3
                let x = side ? (index == 0 ? 10 : width - 10) : centers[index - 1]
                DateLabel(day: day, now: now, faint: side)
                    .position(x: x + dayDrag * (side ? 0.6 : 1), y: 22)
                    .opacity(side ? 0.2 : 1)
            }
            WeekTicks(day: selectedDay)
                .frame(width: 92, height: 4)
                .position(x: width / 2, y: 56)
        }
        .frame(width: width, height: 64)
        .clipped()
    }
}

private struct ShelfRowFrames: PreferenceKey {
    static let defaultValue: [Date: CGRect] = [:]
    static func reduce(value: inout [Date: CGRect], nextValue: () -> [Date: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// A date in the sheet: the number large and rounded, the weekday beside it, 今日 marked.
private struct DateLabel: View {
    let day: Date
    let now: Date
    var faint = false

    var body: some View {
        let calendar = Calendar.current
        let today = calendar.isDate(day, inSameDayAs: now)
        let weekday = ["日", "月", "火", "水", "木", "金", "土"][calendar.component(.weekday, from: day) - 1]
        HStack(alignment: .top, spacing: 5) {
            Text("\(calendar.component(.day, from: day))")
                .font(.system(size: faint ? 30 : 40, weight: .heavy, design: .rounded)).monospacedDigit()
                .foregroundStyle(today ? Palette.accent : Color.primary)
            if !faint {
                VStack(alignment: .leading, spacing: 2) {
                    Text(weekday).font(.system(size: 13, weight: .heavy)).foregroundStyle(today ? Palette.accent : Color.secondary)
                    if today {
                        Text("今日").font(.system(size: 10, weight: .heavy)).foregroundStyle(Color(uiColor: .systemBackground))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Palette.accent, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                .padding(.top, 6)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(calendar.component(.month, from: day))月\(calendar.component(.day, from: day))日 \(weekday)曜日\(today ? " 今日" : "")")
    }
}

/// Seven short bars for the week of the chosen day; the two days shown are joined and lit.
private struct WeekTicks: View {
    let day: Date
    var body: some View {
        let calendar = Calendar.current
        let monday = WeekView.monday(of: day)
        let index = calendar.dateComponents([.day], from: monday, to: calendar.startOfDay(for: day)).day ?? 0
        HStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { i in
                Capsule().fill(i == index || i == index + 1 ? Palette.accent : Color.secondary.opacity(0.3))
            }
        }
        .accessibilityHidden(true)
    }
}

/// One day across the four shelves.
@MainActor
private struct ShelfRow: View {
    @EnvironmentObject private var store: TaskStore
    let day: Date
    let now: Date
    let gutter: CGFloat
    /// The shelf a carried chip would land on, when it is in this row.
    let targetBand: WeekShelfView.Band?
    let carrying: String?
    let onSelect: () -> Void
    let onFocus: (WeekShelfView.Band, AgendaItem?) -> Void
    let onCarry: (AgendaItem, CGPoint) -> Void
    let onDrop: () -> Void

    var body: some View {
        let calendar = Calendar.current
        let items = Agenda.items(on: day, tasks: store.notebook.tasks, routines: store.notebook.routines)
        let held = items.filter { $0.isBlock && $0.slot != nil }
        let today = calendar.isDate(day, inSameDayAs: now)
        let past = calendar.startOfDay(for: day) < calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: day)
        HStack(alignment: .top, spacing: 4) {
            Button(action: onSelect) {
                VStack(spacing: 0) {
                    Text("\(calendar.component(.day, from: day))").font(.system(size: 16, weight: .bold, design: .rounded))
                    Text(today ? "今日" : ["日", "月", "火", "水", "木", "金", "土"][weekday - 1])
                        .font(.system(size: 11, weight: today ? .heavy : .semibold))
                }
                .foregroundStyle(today ? Palette.accent : (weekday == 1 ? Color.red.opacity(0.8) : (weekday == 7 ? Color.orange : Color.primary)))
                .frame(width: gutter).padding(.top, 8)
                .frame(maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(calendar.component(.day, from: day))日 \(items.filter { !$0.isBlock }.count)件")
            .accessibilityHint("その日と次の日の時間割を開きます")
            ForEach(WeekShelfView.Band.allCases, id: \.rawValue) { band in
                ShelfCell(day: day, band: band,
                          items: items.filter { !$0.isBlock && WeekShelfView.Band.of($0) == band },
                          heldSpans: Self.spans(of: held, in: band.range),
                          isTarget: targetBand == band, carrying: carrying,
                          onFocus: { onFocus(band, $0) }, onCarry: onCarry, onDrop: onDrop)
            }
        }
        .opacity(past ? 0.55 : 1)
    }

    /// A part of a band held for sleep or work: its name, and where it lies as fractions of the band's
    /// width from left (its start) to right.
    struct HeldSpan {
        let name: String
        let span: ClosedRange<Double>
        /// Wide enough to carry its name.
        var named: Bool { span.upperBound - span.lowerBound >= 0.3 }
    }

    static func spans(of held: [AgendaItem], in range: Range<Int>) -> [HeldSpan] {
        let length = Double(range.count)
        return held.compactMap { item in
            guard let slot = item.slot else { return nil }
            let start = max(slot.start, range.lowerBound), end = min(slot.end, range.upperBound)
            guard end > start else { return nil }
            return HeldSpan(name: item.title,
                            span: Double(start - range.lowerBound) / length...Double(end - range.lowerBound) / length)
        }
    }
}

/// A shelf: up to two chips, then how many more. A tap on a chip opens the sheet at it; a shelf with
/// more than two opens a balloon with all of them. A chip held and dragged is carried to another shelf.
@MainActor
private struct ShelfCell: View {
    let day: Date
    let band: WeekShelfView.Band
    let items: [AgendaItem]
    /// Where the shelf's time is held for sleep or work, hatched under its chips at that place in the band
    /// and named at its lower left when there is room (not when "+N" needs that corner).
    let heldSpans: [ShelfRow.HeldSpan]
    let isTarget: Bool
    let carrying: String?
    let onFocus: (AgendaItem?) -> Void
    let onCarry: (AgendaItem, CGPoint) -> Void
    let onDrop: () -> Void
    @State private var showAll = false
    @GestureState private var holding = false

    var body: some View {
        let crowded = items.count > 2
        VStack(alignment: .leading, spacing: 3) {
            ForEach(items.prefix(2)) { item in
                ShelfChip(item: item)
                    .opacity(carrying == item.id ? 0.25 : 1)
                    .contentShape(Rectangle())
                    .onTapGesture { if crowded { showAll = true } else { onFocus(item) } }
                    .gesture(carryGesture(item))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(item.slot?.startLabel ?? "時間なし") \(item.title)")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("時間割で見る。長押しして動かすと日や時間帯を変えられます")
            }
            if crowded {
                Text("+\(items.count - 2)").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.accent).padding(.leading, 4)
                    .accessibilityLabel("ほか\(items.count - 2)件。すべて見る")
                    .accessibilityAddTraits(.isButton)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .secondarySystemGroupedBackground))
                .overlay {
                    GeometryReader { box in
                        ForEach(Array(heldSpans.enumerated()), id: \.offset) { _, held in
                            let width = box.size.width * (held.span.upperBound - held.span.lowerBound)
                            HeldFill(cornerRadius: 0)
                                .frame(width: width, height: box.size.height)
                                .offset(x: box.size.width * held.span.lowerBound)
                            // With three or more chips, "+N" sits where the name would go.
                            if held.named && items.count <= 2 {
                                Text(held.name).font(.system(size: 8.5, weight: .bold)).foregroundStyle(HeldFill.label)
                                    .lineLimit(1).truncationMode(.tail)
                                    .frame(width: max(0, width - 8), alignment: .leading)
                                    .offset(x: box.size.width * held.span.lowerBound + 4, y: box.size.height - 14)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
        }
        .overlay {
            if isTarget {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.accent, lineWidth: 2.5).allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if crowded { showAll = true } else { onFocus(nil) } }
        .onChange(of: holding) { _, now in if !now { onDrop() } }
        .popover(isPresented: $showAll) {
            BandBalloon(day: day, band: band, items: items) { item in
                showAll = false
                onFocus(item)
            }
            .presentationCompactAdaptation(.popover)
        }
    }

    private func carryGesture(_ item: AgendaItem) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(WeekShelfView.space)))
            .updating($holding) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }
            .onChanged { value in
                guard case .second(true, let drag) = value, let drag else { return }
                onCarry(item, drag.location)
            }
    }
}

/// Everything on one shelf, in a small balloon that grows out of it.
@MainActor
private struct BandBalloon: View {
    let day: Date
    let band: WeekShelfView.Band
    let items: [AgendaItem]
    let onPick: (AgendaItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(day.formatted(.dateTime.month(.defaultDigits).day().weekday(.abbreviated))) \(band.title)")
                .font(.caption.weight(.bold)).foregroundStyle(.secondary)
            ForEach(items) { item in
                Button { onPick(item) } label: { ShelfChip(item: item, roomy: true) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item.slot?.startLabel ?? "時間なし") \(item.title)")
            }
        }
        .padding(12)
        .frame(width: 230)
    }
}

/// A thing on a shelf: its start time and name, tinted in its project's color; outlined for an event,
/// dashed when it has no time yet. Today's shelves on the いま screen use it too.
@MainActor
struct ShelfChip: View {
    @EnvironmentObject private var store: TaskStore
    let item: AgendaItem
    /// In the balloon there is room for the whole title on one line.
    var roomy = false
    /// Lines the name may take.
    var lines = 1

    var body: some View {
        let color = ProjectColor.color(for: store.colorName(forProject: item.project)) ?? Palette.accent
        VStack(alignment: .leading, spacing: 0) {
            if let slot = item.slot {
                Text(roomy ? slot.label : slot.startLabel).font(.system(size: roomy ? 10 : 9, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
            }
            Text(item.title).font(.system(size: roomy ? 13 : 11, weight: .bold)).lineLimit(lines)
                .strikethrough(item.isDone)
        }
        .padding(.horizontal, roomy ? 8 : 5).padding(.vertical, roomy ? 5 : 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(item.isEvent ? color : Color.primary)
        .background {
            if item.isEvent {
                RoundedRectangle(cornerRadius: 6).strokeBorder(color, lineWidth: 1.2)
            } else if item.slot == nil {
                RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            } else {
                RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.28))
            }
        }
        .opacity(item.isDone ? 0.5 : 1)
    }
}

// MARK: - The two days in the sheet

/// Two days side by side, hour by hour. Tap a block to open it; hold it and drag to another time,
/// or across to the other day.
@MainActor
private struct SheetDays: View {
    @EnvironmentObject private var store: TaskStore
    let days: [Date]
    let now: Date
    let gutter: CGFloat
    let focus: WeekShelfView.SheetFocus?
    let onOpen: (AgendaItem) -> Void
    let onMove: (AgendaItem, Date, TimeSlot) -> Void
    @State private var moving: String?
    @State private var moveOffset: CGSize = .zero
    /// The block just pointed at from the shelves, outlined for a moment.
    @State private var flash: String?

    private let hourHeight: CGFloat = 36

    var body: some View {
        let perDay = days.map { Agenda.items(on: $0, tasks: store.notebook.tasks, routines: store.notebook.routines) }
        let untimed = perDay.map { $0.filter { $0.slot == nil && !$0.isBlock } }
        VStack(spacing: 0) {
            if untimed.contains(where: { !$0.isEmpty }) {
                HStack(alignment: .top, spacing: 6) {
                    Text("時間なし").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: gutter - 6, alignment: .leading)
                    ForEach(0..<2, id: \.self) { index in
                        // The one pointed at from the shelves comes first, so it is never hidden in +N.
                        let pointed = untimed[index].filter { $0.id == flash }
                        let list = pointed + untimed[index].filter { $0.id != flash }
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(list.prefix(2)) { item in
                                Button { onOpen(item) } label: { ShelfChip(item: item) }.buttonStyle(.plain)
                                    .overlay {
                                        if flash == item.id {
                                            RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary, lineWidth: 2).allowsHitTesting(false)
                                        }
                                    }
                            }
                            if untimed[index].count > 2 {
                                Text("+\(untimed[index].count - 2)").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.accent)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 6)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    GeometryReader { geometry in
                        let column = (geometry.size.width - gutter - 18) / 2
                        ZStack(alignment: .topLeading) {
                            ForEach(0..<25, id: \.self) { hour in
                                Rectangle().fill(Color.secondary.opacity(hour % 3 == 0 ? 0.22 : 0.1)).frame(height: 1)
                                    .padding(.leading, gutter - 4)
                                    .offset(y: CGFloat(hour) * hourHeight)
                                if hour % 3 == 0 && hour < 24 {
                                    Text("\(hour)時").font(.system(size: 10)).foregroundStyle(.secondary)
                                        .offset(x: 8, y: CGFloat(hour) * hourHeight - 6)
                                }
                            }
                            ForEach(0..<2, id: \.self) { index in
                                dayColumn(perDay[index], day: days[index], index: index, column: column)
                                    .frame(width: column, height: hourHeight * 24, alignment: .topLeading)
                                    .offset(x: gutter + CGFloat(index) * (column + 6))
                                    .zIndex(perDay[index].contains(where: { $0.id == moving }) ? 1 : 0)
                            }
                        }
                    }
                    .frame(height: hourHeight * 24 + 8)
                    .background(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { hour in Color.clear.frame(height: hourHeight).id(hour) }
                        }
                    }
                    .padding(.top, 8).padding(.bottom, 120)
                }
                .onAppear { proxy.scrollTo(startHour, anchor: .top) }
                .onChange(of: days.first) { _, _ in withAnimation(.snappy) { proxy.scrollTo(startHour, anchor: .top) } }
                .onChange(of: focus) { _, focus in
                    withAnimation(.snappy) { proxy.scrollTo(startHour, anchor: .top) }
                    guard let id = focus?.itemID else { return }
                    withAnimation(.easeOut(duration: 0.2)) { flash = id }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        if flash == id { withAnimation(.easeOut(duration: 0.4)) { flash = nil } }
                    }
                }
            }
        }
    }

    /// The hour the thing pointed at sits under; else, today just before now and other days at seven.
    private var startHour: Int {
        if let minute = focus?.minute { return max(0, min(18, minute / 60 - 1)) }
        let calendar = Calendar.current
        guard let first = days.first, calendar.isDate(first, inSameDayAs: now) else { return 7 }
        return max(0, min(18, calendar.component(.hour, from: now) - 1))
    }

    private func dayColumn(_ items: [AgendaItem], day: Date, index: Int, column: CGFloat) -> some View {
        let calendar = Calendar.current
        let held = items.filter { $0.isBlock && $0.slot != nil }
        let timed = items.filter { !$0.isBlock && $0.slot != nil }
        let lanes = WeekRows.lanes(timed).map { LanePlaced(item: $0.0, lane: $0.1, count: $0.2) }
        return ZStack(alignment: .topLeading) {
            ForEach(held) { item in
                let slot = item.slot!
                HeldFill(cornerRadius: 8)
                    .frame(width: column, height: CGFloat(slot.duration) / 60 * hourHeight)
                    .overlay(alignment: .topLeading) {
                        Text("\(item.title) \(slot.label)").font(.system(size: 10, weight: .bold)).foregroundStyle(HeldFill.label)
                            .lineLimit(1).padding(5)
                    }
                    .offset(y: CGFloat(slot.start) / 60 * hourHeight)
                    .allowsHitTesting(false)
            }
            if calendar.isDate(day, inSameDayAs: now) {
                let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
                Rectangle().fill(Color.red).frame(width: column, height: 2)
                    .overlay(alignment: .leading) { Circle().fill(Color.red).frame(width: 8, height: 8).offset(x: -4) }
                    .offset(y: CGFloat(minute) / 60 * hourHeight - 1)
                    .allowsHitTesting(false)
            }
            ForEach(lanes) { placed in
                let item = placed.item, lane = placed.lane, count = placed.count
                let slot = item.slot!
                let width = column / CGFloat(count) - 2
                let height = max(CGFloat(slot.duration) / 60 * hourHeight - 2, 22)
                let isMoving = moving == item.id
                SheetBlock(item: item, width: width, height: height, highlighted: flash == item.id)
                    .overlay(alignment: .topTrailing) {
                        // Where it would land, while it is held.
                        if isMoving {
                            Text(TimeSlot(start: landingStart(slot), duration: slot.duration).startLabel)
                                .font(.system(size: 11, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Palette.accent, in: Capsule())
                                .offset(x: 4, y: -12)
                        }
                    }
                    .offset(x: CGFloat(lane) * (column / CGFloat(count)), y: CGFloat(slot.start) / 60 * hourHeight)
                    .offset(isMoving ? moveOffset : .zero)
                    .scaleEffect(isMoving ? 1.04 : 1, anchor: .topLeading)
                    .shadow(color: .black.opacity(isMoving ? 0.35 : 0), radius: 10, y: 6)
                    .zIndex(isMoving ? 2 : 0)
                    .onTapGesture { onOpen(item) }
                    .gesture(moveGesture(item, slot: slot, index: index, column: column))
            }
        }
    }

    private func landingStart(_ slot: TimeSlot) -> Int {
        let minutes = Int((moveOffset.height / hourHeight * 60 / 15).rounded()) * 15
        return min(max(0, slot.start + minutes), 24 * 60 - slot.duration)
    }

    /// Hold, then drag: up and down in quarter hours, sideways to the other day.
    private func moveGesture(_ item: AgendaItem, slot: TimeSlot, index: Int, column: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if moving != item.id {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) { moving = item.id }
                }
                let before = landingStart(slot)
                var quiet = Transaction()
                quiet.disablesAnimations = true
                withTransaction(quiet) { moveOffset = drag?.translation ?? .zero }
                if landingStart(slot) != before { UISelectionFeedbackGenerator().selectionChanged() }
            }
            .onEnded { value in
                defer {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { moving = nil; moveOffset = .zero }
                }
                guard case .second(true, let drag) = value, let drag else { return }
                let minutes = Int((drag.translation.height / hourHeight * 60 / 15).rounded()) * 15
                let start = min(max(0, slot.start + minutes), 24 * 60 - slot.duration)
                let across = Int((drag.translation.width / (column + 6)).rounded())
                let target = min(max(0, index + across), days.count - 1)
                guard start != slot.start || target != index else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onMove(item, days[target], TimeSlot(start: start, duration: slot.duration))
            }
    }
}

private struct LanePlaced: Identifiable {
    let item: AgendaItem
    let lane: Int
    let count: Int
    var id: String { item.id }
}

/// A block in the sheet: filled in its project's color, outlined for an event, faded once done.
@MainActor
private struct SheetBlock: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.colorScheme) private var scheme
    let item: AgendaItem
    let width: CGFloat
    let height: CGFloat
    var highlighted = false

    var body: some View {
        let color = ProjectColor.color(for: store.colorName(forProject: item.project)) ?? Palette.accent
        let ink = item.isEvent ? color : (scheme == .dark ? Color.black.opacity(0.85) : Color.white)
        VStack(alignment: .leading, spacing: 1) {
            Text(item.title).font(.system(size: 12, weight: .bold)).lineLimit(height > 40 ? 2 : 1)
                .strikethrough(item.isDone)
            if height >= 36, let slot = item.slot {
                Text(slot.label).font(.system(size: 10, weight: .semibold)).monospacedDigit().opacity(0.8)
            }
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .frame(width: width, height: height, alignment: .topLeading)
        .background {
            if item.isEvent {
                RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color, lineWidth: 1.5))
            } else {
                RoundedRectangle(cornerRadius: 8).fill(color)
            }
        }
        .overlay {
            if highlighted {
                RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary, lineWidth: 2.5).padding(-3)
            }
        }
        .scaleEffect(highlighted ? 1.04 : 1)
        .opacity(item.isDone ? 0.45 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.slot?.label ?? "") \(item.title)\(item.isDone ? " 済み" : "")")
        .accessibilityHint("タップで開く。長押しして動かすと時間や日を変えられます")
    }
}
