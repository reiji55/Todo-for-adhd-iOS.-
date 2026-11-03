import SwiftUI
import UIKit

/// The week on iPhone: each day a row of four shelves (morning, midday, evening, night) holding its
/// things as small chips, so the whole week reads at a glance without sideways scrolling. A sheet
/// pulled up from the bottom shows the chosen day and the next one hour by hour; swiping its dates
/// moves a day at a time. Time held for sleep or work only tints the shelves it fills.
@MainActor
struct WeekShelfView: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.refreshClock) private var refreshClock
    @Environment(\.colorScheme) private var scheme
    @State private var weekStart = WeekView.monday(of: Date())
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var sheetOpen = false
    @State private var sheetDrag: CGFloat = 0
    @State private var dayDrag: CGFloat = 0
    @State private var dragAxis: Axis?
    let onOpen: (AgendaItem) -> Void
    let onStart: (TaskItem) -> Void
    let onAdd: (Date) -> Void
    /// The ⊕ menu; with the sheet up, what is added goes on the chosen day.
    let onPick: (AddKind, Date?) -> Void

    /// How much of the sheet shows when it is down: the handle and the top half of its dates.
    static let peekHeight: CGFloat = 44
    private let gutter: CGFloat = 40

    private var days: [Date] {
        (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: weekStart) }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: max(context.date, refreshClock))
        }
        .background(Palette.paper)
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-uiWeekSheetOpen") { sheetOpen = true }
            #endif
        }
    }

    private func content(now: Date) -> some View {
        GeometryReader { geometry in
            let full = geometry.size.height
            let openHeight = max(Self.peekHeight, full - 96)
            let resting = sheetOpen ? openHeight : Self.peekHeight
            let visible = min(openHeight, max(Self.peekHeight, resting - sheetDrag))
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
                .opacity(1 - 0.6 * Double((visible - Self.peekHeight) / max(1, openHeight - Self.peekHeight)))
                // With the sheet up, a tap on the week above it puts the sheet back down.
                if sheetOpen {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { sheetOpen = false } }
                        .accessibilityHidden(true)
                }
                sheet(now: now, width: geometry.size.width, height: openHeight)
                    .frame(height: openHeight, alignment: .top)
                    .offset(y: full - visible)
            }
            .overlay(alignment: .bottomTrailing) {
                FloatingAddButton { onPick($0, sheetOpen ? selectedDay : nil) }
                    .padding(.trailing, 14).padding(.bottom, Self.peekHeight + 10)
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
        }
    }

    /// One day on in the sheet; the shelves follow into the next or previous week when needed.
    private func step(_ days: Int) {
        let calendar = Calendar.current
        guard let day = calendar.date(byAdding: .day, value: days, to: selectedDay) else { return }
        selectedDay = day
        let monday = WeekView.monday(of: day)
        if !calendar.isDate(monday, inSameDayAs: weekStart) { weekStart = monday }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    // MARK: The shelves

    enum Band: Int, CaseIterable {
        case morning, midday, evening, night
        var title: String { ["朝", "昼", "夕", "夜"][rawValue] }
        /// Minutes of the day the band covers.
        var range: Range<Int> { [0..<12 * 60, 12 * 60..<17 * 60, 17 * 60..<20 * 60, 20 * 60..<24 * 60][rawValue] }
        static func of(_ minute: Int) -> Band {
            allCases.first { $0.range.contains(minute) } ?? .night
        }
    }

    private func shelf(now: Date) -> some View {
        let calendar = Calendar.current
        let next = calendar.date(byAdding: .day, value: 1, to: selectedDay) ?? selectedDay
        return VStack(spacing: 4) {
            HStack(spacing: 4) {
                Color.clear.frame(width: gutter, height: 1)
                ForEach(Band.allCases, id: \.rawValue) { band in
                    Text(band.title).font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 6)
            ForEach(days, id: \.self) { day in
                let emphasis: Double = calendar.isDate(day, inSameDayAs: selectedDay) ? 0.5
                    : (calendar.isDate(day, inSameDayAs: next) ? 0.22 : 0)
                ShelfRow(day: day, now: now, gutter: gutter) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        selectedDay = calendar.startOfDay(for: day)
                        sheetOpen = true
                    }
                }
                .overlay {
                    if emphasis > 0 {
                        RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.accent.opacity(emphasis), lineWidth: 1.5)
                            .padding(.leading, gutter + 1).allowsHitTesting(false)
                    }
                }
            }
        }
    }

    // MARK: The sheet

    private func sheet(now: Date, width: CGFloat, height: CGFloat) -> some View {
        let calendar = Calendar.current
        let second = calendar.date(byAdding: .day, value: 1, to: selectedDay) ?? selectedDay
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                Capsule().fill(Color.secondary.opacity(0.45)).frame(width: 38, height: 5).padding(.top, 8)
                dateStrip(width: width, now: now).padding(.top, 6)
            }
            .contentShape(Rectangle())
            .gesture(sheetGesture)
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { sheetOpen.toggle() }
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint(sheetOpen ? "下げると週の棚に戻ります" : "上げると2日分の時間割が開きます")
            .accessibilityAction(named: "次の日") { withAnimation(.snappy) { step(1) } }
            .accessibilityAction(named: "前の日") { withAnimation(.snappy) { step(-1) } }
            SheetDays(days: [selectedDay, second], now: now, gutter: gutter, onOpen: onOpen,
                      onMove: { item, day, slot in store.move(item, to: day, slot: slot) })
                .opacity(sheetOpen || sheetDrag < -10 ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(scheme == .dark ? 0.7 : 0.15), radius: 14, y: -6)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    /// Up and down moves the sheet; sideways moves the days.
    private var sheetGesture: some Gesture {
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
                    let throwDistance = value.predictedEndTranslation.height
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                        sheetOpen = sheetOpen ? throwDistance < 90 : throwDistance < -60
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
    let onSelect: () -> Void

    var body: some View {
        let calendar = Calendar.current
        let items = Agenda.items(on: day, tasks: store.notebook.tasks, routines: store.notebook.routines)
        let held = items.filter(\.isBlock).compactMap(\.slot)
        let today = calendar.isDate(day, inSameDayAs: now)
        let past = calendar.startOfDay(for: day) < calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: day)
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 4) {
                VStack(spacing: 0) {
                    Text("\(calendar.component(.day, from: day))").font(.system(size: 16, weight: .bold, design: .rounded))
                    Text(today ? "今日" : ["日", "月", "火", "水", "木", "金", "土"][weekday - 1])
                        .font(.system(size: 11, weight: today ? .heavy : .semibold))
                }
                .foregroundStyle(today ? Palette.accent : (weekday == 1 ? Color.red.opacity(0.8) : (weekday == 7 ? Color.orange : Color.primary)))
                .frame(width: gutter).padding(.top, 8)
                ForEach(WeekShelfView.Band.allCases, id: \.rawValue) { band in
                    let inBand = items.filter { !$0.isBlock && (($0.slot.map { WeekShelfView.Band.of($0.start) } ?? .morning) == band) }
                    ShelfCell(items: inBand, heldShare: Self.share(of: held, in: band.range))
                }
            }
            .opacity(past ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(calendar.component(.day, from: day))日 \(items.filter { !$0.isBlock }.count)件")
        .accessibilityHint("その日と次の日の時間割を開きます")
    }

    /// How much of a band is held for sleep or work.
    static func share(of held: [TimeSlot], in range: Range<Int>) -> Double {
        let covered = held.reduce(0) { total, slot in
            total + max(0, min(slot.end, range.upperBound) - max(slot.start, range.lowerBound))
        }
        return Double(covered) / Double(range.count)
    }
}

/// A shelf: up to two chips, then how many more.
private struct ShelfCell: View {
    let items: [AgendaItem]
    let heldShare: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(items.prefix(2)) { ShelfChip(item: $0) }
            if items.count > 2 {
                Text("+\(items.count - 2)").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.accent).padding(.leading, 4)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(heldShare >= 0.5 ? Color.primary.opacity(0.045) : Color(uiColor: .secondarySystemGroupedBackground))
        }
    }
}

@MainActor
private struct ShelfChip: View {
    @EnvironmentObject private var store: TaskStore
    let item: AgendaItem

    var body: some View {
        let color = ProjectColor.color(for: store.colorName(forProject: item.project)) ?? Palette.accent
        VStack(alignment: .leading, spacing: 0) {
            if let slot = item.slot {
                Text(slot.startLabel).font(.system(size: 9, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
            }
            Text(item.title).font(.system(size: 11, weight: .bold)).lineLimit(1)
                .strikethrough(item.isDone)
        }
        .padding(.horizontal, 5).padding(.vertical, 3)
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
    @Environment(\.colorScheme) private var scheme
    let days: [Date]
    let now: Date
    let gutter: CGFloat
    let onOpen: (AgendaItem) -> Void
    let onMove: (AgendaItem, Date, TimeSlot) -> Void
    @State private var moving: String?
    @State private var moveOffset: CGSize = .zero

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
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(untimed[index].prefix(2)) { item in
                                Button { onOpen(item) } label: { ShelfChip(item: item) }.buttonStyle(.plain)
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
            }
        }
    }

    /// Today opens just before now; other days at seven.
    private var startHour: Int {
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
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05))
                    .frame(width: column, height: CGFloat(slot.duration) / 60 * hourHeight)
                    .overlay(alignment: .topLeading) {
                        Text("\(item.title) \(slot.label)").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).padding(4)
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
                SheetBlock(item: item, width: width, height: height)
                    .offset(x: CGFloat(lane) * (column / CGFloat(count)), y: CGFloat(slot.start) / 60 * hourHeight)
                    .offset(moving == item.id ? moveOffset : .zero)
                    .scaleEffect(moving == item.id ? 1.04 : 1, anchor: .topLeading)
                    .shadow(color: .black.opacity(moving == item.id ? 0.35 : 0), radius: 10, y: 6)
                    .zIndex(moving == item.id ? 2 : 0)
                    .onTapGesture { onOpen(item) }
                    .gesture(moveGesture(item, slot: slot, index: index, column: column))
            }
        }
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
                var quiet = Transaction()
                quiet.disablesAnimations = true
                withTransaction(quiet) { moveOffset = drag?.translation ?? .zero }
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
        .opacity(item.isDone ? 0.45 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.slot?.label ?? "") \(item.title)\(item.isDone ? " 済み" : "")")
        .accessibilityHint("タップで開く。長押しして動かすと時間や日を変えられます")
    }
}
