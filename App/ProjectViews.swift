import SwiftUI

struct ProjectRoute: Hashable, Identifiable {
    let key: String
    var id: String { key }
}

enum ProjectText {
    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// "3/5回", "420/450点", "タスク 2/6", "済み".
    static func value(_ milestone: Milestone, in book: Notebook) -> String {
        let value = ProjectBook.value(of: milestone, in: book)
        let target = ProjectBook.target(of: milestone, in: book)
        switch milestone.kind {
        case .check: return milestone.isDone ? "済み" : "まだ"
        case .count: return "\(number(value))/\(number(target))\(milestone.unit.isEmpty ? "回" : milestone.unit)"
        case .number: return "\(number(value))/\(number(target))\(milestone.unit)"
        case .tasks: return "タスク \(number(value))/\(number(target))"
        }
    }

    /// For the camps on the mountain: "3/5", "420/450", "済".
    static func short(_ milestone: Milestone, in book: Notebook) -> String {
        switch milestone.kind {
        case .check: return milestone.isDone ? "済" : ""
        default:
            return "\(number(ProjectBook.value(of: milestone, in: book)))/\(number(ProjectBook.target(of: milestone, in: book)))"
        }
    }

    /// "12/14"
    static func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: date)
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }

    /// "12/14（日）"
    static func dayWithWeekday(_ date: Date) -> String {
        let names = ["日", "月", "火", "水", "木", "金", "土"]
        let weekday = Calendar.current.component(.weekday, from: date)
        return "\(day(date))（\(names[(weekday - 1) % 7])）"
    }

    /// "あと41日", "今日まで", "3日過ぎ"
    static func remaining(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if days == 0 { return "今日まで" }
        return days > 0 ? "あと\(days)日" : "\(-days)日過ぎ"
    }
}

extension BoardCard {
    /// A card in a project takes the project's color, so the folder, its cards and its tasks read as one.
    var colorName: String { project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? title : project }
}

// MARK: - Folders on the board

/// A checkpoint as a dot: filled with a check once reached, otherwise a ring filled as far as it has come.
struct MilestoneDot: View {
    let progress: Double
    let color: Color
    var size: CGFloat = 18
    var body: some View {
        ZStack {
            if progress >= 1 {
                Circle().fill(color)
                Image(systemName: "checkmark").font(.system(size: size * 0.48, weight: .heavy)).foregroundStyle(.black.opacity(0.7))
            } else {
                Circle().stroke(color.opacity(0.3), lineWidth: size * 0.17)
                Circle().trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: size * 0.17, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: size, height: size)
    }
}

/// The way as a line of dots ending in a flag.
struct MilestoneTrack: View {
    let progresses: [Double]
    let color: Color
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(progresses.enumerated()), id: \.offset) { _, progress in
                MilestoneDot(progress: progress, color: color)
                Capsule().fill(progress >= 1 ? color : Color.primary.opacity(0.18)).frame(height: 3).frame(maxWidth: .infinity)
            }
            Image(systemName: "flag.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(color.opacity(0.85))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("通過点 \(progresses.filter { $0 >= 1 }.count)/\(progresses.count)")
    }
}

/// One project as a folder: its name on the tab, its cards peeking out of the top, and on the front
/// the goal, the way and the next checkpoint.
@MainActor
struct ProjectFolder: View {
    @EnvironmentObject private var store: TaskStore
    let entry: ProjectBook.Entry
    /// Set on the board, where a card peeking out of the folder opens that card.
    var onOpenCard: ((BoardCard) -> Void)? = nil

    var body: some View {
        let cards = store.projectCards(entry.key)
        let face = ProjectColor.tint(for: entry.name)
        let route = ProjectRoute(key: entry.key)
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                HStack(spacing: -22) {
                    ForEach(Array(cards.prefix(3).enumerated()), id: \.element.id) { index, card in
                        Button { onOpenCard?(card) } label: {
                            Text(card.title).font(.system(size: 11, weight: .bold)).lineLimit(2).multilineTextAlignment(.leading)
                                .padding(.horizontal, 8).padding(.top, 6)
                                .frame(width: 96, height: 52, alignment: .topLeading)
                                .background(ProjectColor.tint(for: entry.name, amount: 0.62), in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .disabled(onOpenCard == nil)
                        .rotationEffect(.degrees([-3.0, 2.0, -1.0][index]))
                        .accessibilityLabel("カード「\(card.title)」を開く")
                    }
                }
                .padding(.leading, 136)
                .offset(y: 16)
                NavigationLink(value: route) {
                    Text(entry.name.count > 12 ? String(entry.name.prefix(11)) + "…" : entry.name)
                        .font(.system(size: 15, weight: .heavy)).lineLimit(1).fixedSize()
                        .padding(.horizontal, 14).frame(height: 32)
                        .frame(minWidth: 120, alignment: .leading)
                        .background(face, in: UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("openProjectTab-\(entry.key)")
            }
            .frame(height: cards.isEmpty ? 32 : 48, alignment: .bottomLeading)
            .zIndex(0)
            NavigationLink(value: route) {
                front
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(face, in: UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18, topTrailingRadius: 18))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("openProject-\(entry.key)")
            .shadow(color: .black.opacity(0.18), radius: 6, y: -2)
            .zIndex(1)
        }
    }

    @ViewBuilder private var front: some View {
        let book = store.notebook
        let color = ProjectColor.color(for: entry.name) ?? Palette.accent
        let routines = ProjectBook.routines(entry.key, in: book).filter { !$0.isPaused && !$0.isBlock }
        let open = ProjectBook.tasks(entry.key, in: book).filter { !$0.isComplete }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(goalLine(routines: routines)).font(.footnote).foregroundStyle(.primary.opacity(0.85)).lineLimit(1)
                Spacer(minLength: 4)
                if let deadline = entry.project?.deadline {
                    Text("\(ProjectText.day(deadline)) \(ProjectText.remaining(deadline))")
                        .font(.caption.weight(.bold)).foregroundStyle(color)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.black.opacity(0.18), in: Capsule())
                }
            }
            if let project = entry.project, !project.milestones.isEmpty {
                MilestoneTrack(progresses: project.milestones.map { ProjectBook.progress(of: $0, in: book) }, color: color)
                HStack {
                    if let next = ProjectBook.next(of: project, in: book) {
                        Text("次：\(next.title) \(ProjectText.value(next, in: book))").lineLimit(1)
                    } else {
                        Text("通過点をすべて越えました")
                    }
                    Spacer(minLength: 6)
                    Text("通過点 \(project.milestones.filter { ProjectBook.isReached($0, in: book) }.count)/\(project.milestones.count)")
                        .foregroundStyle(.secondary)
                }
                .font(.footnote.weight(.semibold)).foregroundStyle(color)
            } else if !routines.isEmpty {
                RecentDays(routines: routines, color: color)
                Text("ルーティン この7日で\(RecentDays.count(routines))回").font(.footnote.weight(.semibold)).foregroundStyle(color)
            } else {
                let today = open.filter { $0.plannedAt.map(Calendar.current.isDateInToday) == true }.count
                Text("未完了 \(open.count)件 ・ 今日 \(today)件").font(.footnote.weight(.semibold)).foregroundStyle(color)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func goalLine(routines: [Routine]) -> String {
        if let goal = entry.project?.goal.trimmingCharacters(in: .whitespacesAndNewlines), !goal.isEmpty { return goal }
        if let routine = routines.first {
            return "続けるもの ・ \(routine.weekdayLabel)\(routine.slot.map { " \($0.startLabel)" } ?? "")"
        }
        let cards = store.projectCards(entry.key).count
        return "到達点なし ・ \(cards == 0 ? "カードなし" : "カード\(cards)枚")"
    }
}

/// The last seven days, filled where one of the routines was done.
struct RecentDays: View {
    let routines: [Routine]
    let color: Color

    static func keys(now: Date = Date()) -> [String] {
        (0..<7).reversed().compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: now) }.map { DayKey.of($0) }
    }

    static func count(_ routines: [Routine], now: Date = Date()) -> Int {
        let done = Set(routines.flatMap(\.doneDays))
        return keys(now: now).filter(done.contains).count
    }

    var body: some View {
        let done = Set(routines.flatMap(\.doneDays))
        let names = ["日", "月", "火", "水", "木", "金", "土"]
        HStack(spacing: 0) {
            ForEach(Array(Self.keys().enumerated()), id: \.element) { index, key in
                let isToday = index == 6
                VStack(spacing: 2) {
                    Circle()
                        .fill(done.contains(key) ? color : Color.clear)
                        .overlay(Circle().strokeBorder(done.contains(key) ? Color.clear : Color.primary.opacity(isToday ? 0.7 : 0.25),
                                                       style: StrokeStyle(lineWidth: 2, dash: isToday ? [3, 2] : [])))
                        .frame(width: 16, height: 16)
                    Text(isToday ? "今日" : DayKey.date(key).map { names[Calendar.current.component(.weekday, from: $0) - 1] } ?? "")
                        .font(.system(size: 10, weight: isToday ? .bold : .regular)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("この7日で\(Self.count(routines))回")
    }
}

/// The projects side of the board.
@MainActor
struct ProjectFolderList: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    let entries: [ProjectBook.Entry]
    let searching: Bool
    let onOpenCard: (BoardCard) -> Void

    var body: some View {
        if entries.isEmpty {
            if searching {
                ContentUnavailableView.search
            } else {
                ContentUnavailableView("プロジェクトはまだありません", systemImage: "flag",
                                       description: Text("右下の＋から作るか、タスクやルーティンにプロジェクト名を付けると、ここにまとまります。"))
            }
        } else if sizeClass == .regular {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16)], spacing: 14) {
                ForEach(entries) { folder($0) }
            }
        } else {
            VStack(spacing: 10) { ForEach(entries) { folder($0) } }
        }
    }

    private func folder(_ entry: ProjectBook.Entry) -> some View {
        ProjectFolder(entry: entry, onOpenCard: onOpenCard)
            .contextMenu {
                Button("プロジェクトを外す", systemImage: "folder.badge.minus", role: .destructive) { store.deleteProject(entry.key) }
            }
    }
}

// MARK: - The mountain

/// The way up, in a 390 × 440 drawing: from the foot on the left, zigzagging to the summit.
enum MountainRoute {
    static let size = CGSize(width: 390, height: 440)
    static let points: [CGPoint] = [
        CGPoint(x: 40, y: 420), CGPoint(x: 150, y: 392), CGPoint(x: 90, y: 350), CGPoint(x: 170, y: 318),
        CGPoint(x: 130, y: 282), CGPoint(x: 205, y: 250), CGPoint(x: 178, y: 212), CGPoint(x: 238, y: 180),
        CGPoint(x: 222, y: 150), CGPoint(x: 255, y: 116)
    ]
    static let summit = CGPoint(x: 255, y: 116)

    /// The point a share of the way up, measured along the path (as `trim` measures it).
    static func point(at fraction: Double) -> CGPoint {
        let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        var remaining = lengths.reduce(0, +) * min(max(fraction, 0), 1)
        for (index, length) in lengths.enumerated() {
            if remaining <= length {
                let a = points[index], b = points[index + 1], t = length == 0 ? 0 : remaining / length
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            remaining -= length
        }
        return points[points.count - 1]
    }
}

/// A shape drawn from points in the 390 × 440 drawing, stretched to its frame.
struct SketchShape: Shape {
    let points: [CGPoint]
    var closed = true
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / MountainRoute.size.width, sy = rect.height / MountainRoute.size.height
        var path = Path()
        for (index, point) in points.enumerated() {
            let p = CGPoint(x: rect.minX + point.x * sx, y: rect.minY + point.y * sy)
            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        if closed { path.closeSubpath() }
        return path
    }
}

struct MountainCamp: Identifiable {
    let id: UUID
    let label: String
    let progress: Double
}

/// The mountain with the way, the camps (checkpoints), the summit (the goal) and where the person is.
/// The way is drawn up to there as `drawn` goes from 0 to 1.
struct MountainScene: View {
    let camps: [MountainCamp]
    let progress: Double
    let color: Color
    let drawn: Double
    let markerShown: Bool

    var body: some View {
        GeometryReader { geometry in
            let sx = geometry.size.width / MountainRoute.size.width
            let sy = min(geometry.size.height / MountainRoute.size.height, sx * 1.3)
            let height = MountainRoute.size.height * sy
            let place = { (p: CGPoint) in CGPoint(x: p.x * sx, y: p.y * sy) }
            ZStack(alignment: .topLeading) {
                SketchShape(points: [CGPoint(x: 0, y: 300), CGPoint(x: 60, y: 232), CGPoint(x: 120, y: 262), CGPoint(x: 190, y: 172),
                                     CGPoint(x: 260, y: 242), CGPoint(x: 330, y: 192), CGPoint(x: 390, y: 232), CGPoint(x: 390, y: 440),
                                     CGPoint(x: 0, y: 440)])
                    .fill(Self.farRange)
                SketchShape(points: [CGPoint(x: 0, y: 440), CGPoint(x: 0, y: 392), CGPoint(x: 70, y: 332), CGPoint(x: 130, y: 302),
                                     CGPoint(x: 180, y: 232), CGPoint(x: 230, y: 150), CGPoint(x: 255, y: 110), CGPoint(x: 280, y: 150),
                                     CGPoint(x: 330, y: 232), CGPoint(x: 390, y: 292), CGPoint(x: 390, y: 440)])
                    .fill(Self.mountain)
                SketchShape(points: [CGPoint(x: 230, y: 150), CGPoint(x: 255, y: 110), CGPoint(x: 280, y: 150), CGPoint(x: 268, y: 146),
                                     CGPoint(x: 256, y: 158), CGPoint(x: 244, y: 146)])
                    .fill(Self.snow)
                SketchShape(points: [CGPoint(x: 0, y: 440), CGPoint(x: 0, y: 412), CGPoint(x: 90, y: 382), CGPoint(x: 200, y: 402),
                                     CGPoint(x: 300, y: 386), CGPoint(x: 390, y: 406), CGPoint(x: 390, y: 440)])
                    .fill(Self.ground)
                SketchShape(points: MountainRoute.points, closed: false)
                    .stroke(color.opacity(0.4), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: [4, 6]))
                SketchShape(points: MountainRoute.points, closed: false)
                    .trim(from: 0, to: drawn * progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                summitFlag.position(place(CGPoint(x: MountainRoute.summit.x + 9, y: MountainRoute.summit.y - 16)))
                ForEach(Array(camps.enumerated()), id: \.element.id) { index, camp in
                    let point = place(MountainRoute.point(at: Double(index + 1) / Double(camps.count + 1)))
                    MilestoneDot(progress: camp.progress, color: color, size: 14)
                        .background(Circle().fill(Self.mountain))
                        .position(point)
                    if camps.count <= 6 {
                        let right = index % 2 == 0
                        Text(camp.label).font(.system(size: 11, weight: .bold)).lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(camp.progress >= 1 ? Color.secondary : color)
                            .frame(width: 150, alignment: right ? .leading : .trailing)
                            .position(x: point.x + (right ? 89 : -89), y: point.y)
                    }
                }
                Group {
                    Circle().fill(Palette.accent.opacity(0.25)).frame(width: 26, height: 26)
                    Circle().fill(Palette.accent).frame(width: 13, height: 13)
                        .overlay(Circle().stroke(Self.sky, lineWidth: 2))
                }
                .position(place(MountainRoute.point(at: progress)))
                .opacity(markerShown ? 1 : 0)
            }
            .frame(width: geometry.size.width, height: height)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("山の道のり。いまは\(Int((progress * 100).rounded()))%の高さ")
    }

    private var summitFlag: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(color).frame(width: 2.5, height: 30)
            FlagShape().fill(color).frame(width: 18, height: 12).offset(x: 2.5)
        }
        .frame(width: 22, height: 30, alignment: .topLeading)
    }

    static let sky = adaptive(light: 0xE4EAF0, dark: 0x0B0C10)
    static let ground = adaptive(light: 0xD2DAE3, dark: 0x262A30)
    static let farRange = adaptive(light: 0xC7D0DA, dark: 0x14161A)
    static let mountain = adaptive(light: 0xADB8C5, dark: 0x1D2026)
    static let snow = adaptive(light: 0xF7F9FB, dark: 0x30343C)

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
                           blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
        })
    }
}

struct FlagShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: rect.origin)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.22, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - The project page

/// Fades a section in from a little below as it scrolls into view. Only on the way in, and not at all
/// when the person has asked for less motion.
private struct RevealOnScroll: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.scrollTransition(.animated(.easeOut(duration: 0.7)).threshold(.visible(0.12))) { view, phase in
                view.opacity(phase.value > 0 ? 0 : 1).offset(y: phase.value > 0 ? 28 : 0)
            }
        }
    }
}

extension View {
    fileprivate func revealOnScroll() -> some View { modifier(RevealOnScroll()) }
}

/// A project opens on its mountain: the way grows to where the person is. Swiping down brings in the
/// way as a list of checkpoints, the tasks, the cards and the routines.
@MainActor
struct ProjectPage: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var key: String
    let onEdit: (TaskItem) -> Void
    @State private var editingProject: Project?
    @State private var editingMilestone: MilestoneRoute?
    @State private var editingRoutine: Routine?
    @State private var newCard: BoardCard?
    @State private var openedCard: GuideRoute?
    @State private var drawn = 0.0
    @State private var markerShown = false
    @State private var bob = false
    @State private var animated = false
    @State private var pastHero = false
    @State private var addingStep = false

    struct MilestoneRoute: Identifiable {
        let milestone: Milestone
        let isNew: Bool
        var id: UUID { milestone.id }
    }

    init(key: String, onEdit: @escaping (TaskItem) -> Void) {
        _key = State(initialValue: key)
        self.onEdit = onEdit
    }

    var body: some View {
        Group {
            if let entry = store.projectEntry(key) {
                page(entry)
            } else {
                ContentUnavailableView("このプロジェクトはありません", systemImage: "flag")
                    .onAppear { DispatchQueue.main.async { dismiss() } }
            }
        }
        .navigationTitle(pastHero ? (store.projectEntry(key)?.name ?? "") : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(pastHero ? .automatic : .hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("編集") {
                    if let entry = store.projectEntry(key) { editingProject = entry.project ?? Project(name: entry.name) }
                }
            }
        }
        .sheet(item: $editingProject) { project in
            ProjectEditor(project: project, originalKey: key, onSaved: { key = $0 })
        }
        .sheet(item: $editingMilestone) { route in
            MilestoneEditor(milestone: route.milestone, key: key, isNew: route.isNew)
        }
        .sheet(item: $editingRoutine) { RoutineEditor(routine: $0) }
        .sheet(item: $newCard) { GuideCardEditor(card: $0) }
        .sheet(isPresented: $addingStep) {
            if let entry = store.projectEntry(key) { TaskStepSheet(project: entry.name) }
        }
        .onChange(of: store.taskStartRequest) { _, request in
            if request != nil { addingStep = false }
        }
        .navigationDestination(item: $openedCard) { route in
            GuidePager(startID: route.id, cardIDs: store.projectCards(key).map(\.id)).keepsStore()
        }
    }

    private func page(_ entry: ProjectBook.Entry) -> some View {
        let book = store.notebook
        let color = ProjectColor.color(for: entry.name) ?? Palette.accent
        let progress = ProjectBook.progress(of: entry.key, in: book)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero(entry, color: color, progress: progress) {
                        withAnimation(.easeInOut(duration: 0.6)) { proxy.scrollTo("content", anchor: .top) }
                    }
                    // The creation undo offer floats above the tabs. Keep the next action above it
                    // while the mountain gives up the space, rather than covering a newly made project.
                    .padding(.bottom, store.undoOffer == nil ? 0 : (dynamicTypeSize.isAccessibilitySize ? 150 : 100))
                    .containerRelativeFrame(.vertical) { height, _ in
                        max(height, dynamicTypeSize.isAccessibilitySize ? 900 : 480)
                    }
                    // The scroll view runs under the bar, so the mountain is past once its foot is above the bar.
                    .onGeometryChange(for: Bool.self) { $0.frame(in: .global).maxY < 150 } action: { past in
                        if past != pastHero { pastHero = past }
                    }
                    VStack(alignment: .leading, spacing: 26) {
                        header(entry, color: color).id("content").revealOnScroll()
                        way(entry, color: color).revealOnScroll()
                        tasks(entry).revealOnScroll()
                        cards(entry).revealOnScroll()
                        routines(entry).revealOnScroll()
                        if let origin = entry.project?.origin, !origin.isEmpty { originNote(origin).revealOnScroll() }
                    }
                    .padding(.horizontal, 16).padding(.top, 22).padding(.bottom, 40)
                    .frame(maxWidth: 760).frame(maxWidth: .infinity)
                    // Rows link back to the project's cards; here the cards are already on the page.
                    .environment(\.openGuide, nil)
                }
            }
            .background((pastHero ? Palette.paper : MountainScene.sky).ignoresSafeArea())
            .onAppear {
                #if DEBUG
                // For the screenshot of the way below the mountain.
                if ProcessInfo.processInfo.arguments.contains("-uiProjectWay") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { proxy.scrollTo("content", anchor: .top) }
                }
                #endif
            }
        }
        .onAppear(perform: startAnimation)
    }

    /// The way grows once, when the page first opens; then the marker and the share appear.
    private func startAnimation() {
        guard !animated else { return }
        animated = true
        if reduceMotion {
            drawn = 1; markerShown = true
            return
        }
        withAnimation(.timingCurve(0.25, 0.7, 0.25, 1, duration: 1.8).delay(0.4)) { drawn = 1 }
        withAnimation(.easeOut(duration: 0.6).delay(2.1)) { markerShown = true }
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true).delay(2.6)) { bob = true }
    }

    private func hero(_ entry: ProjectBook.Entry, color: Color, progress: Double?, onHint: @escaping () -> Void) -> some View {
        let book = store.notebook
        let milestones = entry.project?.milestones ?? []
        let camps = milestones.map { MountainCamp(id: $0.id, label: "\($0.title) \(ProjectText.short($0, in: book))",
                                                  progress: ProjectBook.progress(of: $0, in: book)) }
        let next = entry.project.flatMap { ProjectBook.next(of: $0, in: book) }
        return VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Circle().fill(color).frame(width: 12, height: 12)
                        Text(entry.name).font(.system(size: 30, weight: .heavy)).lineLimit(2).minimumScaleFactor(0.7)
                    }
                    Text(summitLine(entry)).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 12)
                if let progress {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(Int((progress * 100).rounded()))").font(.system(size: 42, weight: .black, design: .rounded))
                            + Text("%").font(.system(size: 20, weight: .black, design: .rounded))
                        Text("いまの高さ").font(.caption2).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(color)
                    .opacity(markerShown ? 1 : 0)
                }
            }
            .padding(.horizontal, 20).padding(.top, 8)
            MountainScene(camps: camps, progress: progress ?? 0, color: color, drawn: drawn, markerShown: markerShown)
                .frame(maxHeight: .infinity)
            VStack(spacing: 10) {
                Group {
                    if let next {
                        Text("次のキャンプ：\(next.title) \(ProjectText.value(next, in: book))")
                    } else if milestones.isEmpty {
                        Text("通過点を足すと、山を登っていけます")
                    } else {
                        Text("通過点をすべて越えました。頂上はすぐそこ")
                    }
                }
                .font(.footnote.weight(.bold)).foregroundStyle(color).lineLimit(1).padding(.horizontal, 20)
                .accessibilityIdentifier("projectNextCampSummary")
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    nextStep(entry, now: context.date)
                }
                .padding(.horizontal, 16)
                Button(action: onHint) {
                    VStack(spacing: 2) {
                        Text("スワイプで道のりへ").font(.caption)
                        Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold))
                    }
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 160, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(y: bob ? 6 : 0)
                .opacity(markerShown ? 1 : 0)
            }
            .padding(.top, 12).padding(.bottom, 10)
            .frame(maxWidth: .infinity)
            .background(MountainScene.ground)
        }
        .background(MountainScene.sky)
    }

    /// The project supplies context; ordinary task work still runs in Today's existing card.
    private func nextStep(_ entry: ProjectBook.Entry, now: Date) -> some View {
        let next = ProjectBook.nextTask(entry.key, in: store.notebook, now: now)
        let open = ProjectBook.tasks(entry.key, in: store.notebook).filter { !$0.isComplete && !$0.isEvent }
        let scheduled = open.flatMap { task in
            store.hasChildren(task.id) ? store.children(of: task.id).filter { !$0.isComplete } : [task]
        }.sorted { ($0.plannedAt ?? .distantFuture, $0.createdAt) < ($1.plannedAt ?? .distantFuture, $1.createdAt) }.first
        return VStack(alignment: .leading, spacing: 9) {
            Text(next == nil && scheduled != nil ? "予定しているタスク" : "次の一手")
                .font(.caption.weight(.bold)).foregroundStyle(Palette.accent)
            if let task = next ?? scheduled {
                Button { onEdit(task) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(task.title).font(.headline).foregroundStyle(.primary)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        if !task.continuationNote.isEmpty {
                            Text("前回の続き：\(task.continuationNote)")
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                        if next == nil {
                            Text(GuideSummary.place(task) + (task.slot.map { " · \($0.label)" } ?? ""))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if next != nil {
                    Button {
                        _ = store.requestTaskStart(task.id)
                    } label: {
                        Label("始める", systemImage: "play.fill")
                            .font(.body.weight(.bold)).frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(.white).background(Palette.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("startProjectNextTask")
                } else {
                    Button("内容を見る") { onEdit(task) }
                        .font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                }
            } else {
                Button { addingStep = true } label: {
                    Label("最初の一手を追加", systemImage: "plus")
                        .font(.body.weight(.bold)).frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(.white).background(Palette.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("addProjectFirstStep")
            }
        }
        .padding(14).frame(maxWidth: 620, alignment: .leading)
        .background(RaisedCardBackground(cornerRadius: 20))
        .frame(maxWidth: .infinity)
    }

    private func summitLine(_ entry: ProjectBook.Entry) -> String {
        var parts: [String] = []
        if let goal = entry.project?.goal, !goal.isEmpty { parts.append("頂上：\(goal)") }
        if let deadline = entry.project?.deadline { parts.append(ProjectText.remaining(deadline)) }
        return parts.isEmpty ? "到達点は「編集」から書けます" : parts.joined(separator: " ・ ")
    }

    // MARK: Sections

    private func header(_ entry: ProjectBook.Entry, color: Color) -> some View {
        let book = store.notebook
        let milestones = entry.project?.milestones ?? []
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 12, height: 12)
                Text(entry.name).font(.system(size: 26, weight: .heavy))
            }
            if let goal = entry.project?.goal, !goal.isEmpty {
                Label(goal, systemImage: "flag").font(.headline).foregroundStyle(.primary)
            } else {
                Button("到達点を書く", systemImage: "flag") { editingProject = entry.project ?? Project(name: entry.name) }
                    .font(.subheadline.weight(.semibold))
            }
            HStack(spacing: 8) {
                if let deadline = entry.project?.deadline {
                    Text("\(ProjectText.dayWithWeekday(deadline))まで \(ProjectText.remaining(deadline))")
                        .font(.footnote.weight(.bold)).foregroundStyle(color)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(color.opacity(0.14), in: Capsule())
                }
                if !milestones.isEmpty {
                    Text("通過点 \(milestones.filter { ProjectBook.isReached($0, in: book) }.count)/\(milestones.count)")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                }
            }
            overviewBox(entry)
        }
        .padding(.horizontal, 4)
    }

    /// What the project is for and how it goes, in the person's own words. A tap opens the editor.
    private func overviewBox(_ entry: ProjectBook.Entry) -> some View {
        let overview = entry.project?.overview.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Button { editingProject = entry.project ?? Project(name: entry.name) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("概要").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                }
                if overview.isEmpty {
                    Text("何のためのプロジェクトか、どう進めるかを書いておけます").foregroundStyle(.secondary)
                } else {
                    Text(overview).foregroundStyle(.primary).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.subheadline)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if overview.isEmpty {
                    RoundedRectangle(cornerRadius: 14).strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                } else {
                    RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .secondarySystemGroupedBackground))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(overview.isEmpty ? "概要を書く" : "概要：\(overview)")
        .accessibilityHint("プロジェクトの編集画面を開きます")
    }

    private func sectionTitle(_ title: String, add: String? = nil, action: @escaping () -> Void = {}) -> some View {
        HStack {
            Text(title).font(.title3.weight(.heavy))
            Spacer()
            if let add {
                Button(action: action) {
                    Label(add, systemImage: "plus").font(.footnote.weight(.bold))
                        .padding(.horizontal, 12).frame(minHeight: 36)
                        .background(Palette.accent.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain).foregroundStyle(Palette.accent)
            }
        }
        .padding(.horizontal, 4)
    }

    private func way(_ entry: ProjectBook.Entry, color: Color) -> some View {
        let milestones = entry.project?.milestones ?? []
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("道のり", add: "通過点") { editingMilestone = MilestoneRoute(milestone: Milestone(title: "", kind: .count, target: 5, unit: "回"), isNew: true) }
            VStack(alignment: .leading, spacing: 0) {
                if milestones.isEmpty {
                    Text("通過点を足すと、ここに道のりができます。回数・数値・チェック・タスクの数で数えられます。")
                        .font(.subheadline).foregroundStyle(.secondary).padding(.bottom, 16).padding(.leading, 6)
                }
                ForEach(Array(milestones.enumerated()), id: \.element.id) { index, milestone in
                    MilestoneStation(milestone: milestone, projectKey: entry.key, color: color,
                                     onEdit: { editingMilestone = MilestoneRoute(milestone: milestone, isNew: false) },
                                     onMove: { store.moveMilestone(milestone.id, in: entry.key, by: $0) },
                                     canMoveUp: index > 0, canMoveDown: index < milestones.count - 1)
                }
                GoalStation(entry: entry, color: color)
            }
            .padding(.vertical, 16).padding(.leading, 8).padding(.trailing, 14)
            .background { RaisedPanel() }
        }
    }

    private func tasks(_ entry: ProjectBook.Entry) -> some View {
        // Checked off here a moment ago: kept in place, struck through, until the person moves on.
        let open = ProjectBook.tasks(entry.key, in: store.notebook)
            .filter { !$0.isComplete || store.recentlyDone.contains(AgendaItem(task: $0).id) }
            .sorted { ($0.plannedAt ?? .distantFuture, $0.createdAt) < ($1.plannedAt ?? .distantFuture, $1.createdAt) }
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("近いうちにやること", add: "タスク") { addingStep = true }
            if open.isEmpty {
                Text("まだタスクはありません。").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
            ForEach(open.prefix(6)) { task in
                if store.hasChildren(task.id) {
                    // A task in pieces counts once for its checkpoint, when all its pieces are done.
                    ParentTaskCard(parent: task, raised: true, onOpen: onEdit)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(GuideSummary.place(task)).font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.leading, 6)
                        AgendaRow(item: AgendaItem(task: task), style: .raised, onOpen: { _ in onEdit(task) })
                    }
                }
            }
            if open.count > 6 {
                Text("ほか\(open.count - 6)件は「すべて」に").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }
    }

    private func cards(_ entry: ProjectBook.Entry) -> some View {
        let cards = store.projectCards(entry.key)
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("カード", add: "カード") { newCard = BoardCard(title: "", project: entry.name) }
            if cards.isEmpty {
                Text("やり方や概要を書いたカードを入れておけます。").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 4)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(cards) { card in
                            Button { openedCard = GuideRoute(id: card.id) } label: {
                                VStack(alignment: .leading) {
                                    Text(card.isBlank ? "まだ空" : (card.detail.isEmpty ? "目的・ゴール" : "やり方"))
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Spacer(minLength: 4)
                                    Text(card.title).font(.subheadline.weight(.bold)).lineLimit(2).multilineTextAlignment(.leading)
                                }
                                .padding(12)
                                .frame(width: 128, height: 84, alignment: .topLeading)
                                .background(ProjectColor.tint(for: entry.name), in: RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    @ViewBuilder private func routines(_ entry: ProjectBook.Entry) -> some View {
        let routines = ProjectBook.routines(entry.key, in: store.notebook)
        if !routines.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("ルーティン")
                ForEach(routines) { routine in RoutineRow(routine: routine) { editingRoutine = $0 } }
            }
        }
    }

    private func originNote(_ origin: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("きっかけのアイデア")
            Text(origin).font(.subheadline.weight(.bold)).foregroundStyle(Color(red: 0.16, green: 0.11, blue: 0.02))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(red: 1, green: 0.78, blue: 0.35),
                            in: UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6, bottomTrailingRadius: 20, topTrailingRadius: 6))
        }
    }
}

/// One checkpoint on the way: its mark on the rail, and how far it has come in its own way of counting.
@MainActor
struct MilestoneStation: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.colorScheme) private var scheme
    let milestone: Milestone
    let projectKey: String
    let color: Color
    let onEdit: () -> Void
    let onMove: (Int) -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool
    @State private var confirmDelete = false

    var body: some View {
        let book = store.notebook
        let progress = ProjectBook.progress(of: milestone, in: book)
        let reached = progress >= 1
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .top) {
                Rectangle().fill(reached ? color : color.opacity(0.22)).frame(width: 3).padding(.top, 12).frame(maxHeight: .infinity)
                Button {
                    if milestone.kind == .check { store.advanceMilestone(milestone.id, in: projectKey) } else { onEdit() }
                } label: {
                    MilestoneDot(progress: progress, color: color, size: 24)
                        .background(Circle().fill(RaisedPanel.fill(scheme)))
                        .frame(width: 44, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(milestone.kind == .check ? (milestone.isDone ? "済みの印を外す" : "済みにする") : "\(milestone.title)を編集")
            }
            .frame(width: 40)
            VStack(alignment: .leading, spacing: 6) {
                Button(action: onEdit) {
                    Text(milestone.title).font(.subheadline.weight(.bold))
                        .foregroundStyle(reached ? Color.secondary : Color.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                detail(book: book, progress: progress)
                if let due = milestone.dueDate, !reached {
                    Text("目安 \(ProjectText.day(due))").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4).padding(.bottom, 18)
        }
        .fixedSize(horizontal: false, vertical: true)
        .contextMenu {
            Button("編集", systemImage: "pencil", action: onEdit)
            if canMoveUp { Button("上へ", systemImage: "arrow.up") { onMove(-1) } }
            if canMoveDown { Button("下へ", systemImage: "arrow.down") { onMove(1) } }
            Button("消す", systemImage: "trash", role: .destructive) { store.deleteMilestone(milestone.id, in: projectKey) }
        }
    }

    @ViewBuilder private func detail(book: Notebook, progress: Double) -> some View {
        let value = ProjectBook.value(of: milestone, in: book)
        let target = ProjectBook.target(of: milestone, in: book)
        switch milestone.kind {
        case .check:
            Text(milestone.isDone ? "チェック ・ 済み" : "チェック ・ 印をタップで済みに").font(.caption).foregroundStyle(.secondary)
        case .count:
            HStack(spacing: 10) {
                if target <= 10 {
                    HStack(spacing: 5) {
                        ForEach(0..<Int(target), id: \.self) { index in
                            Circle()
                                .fill(Double(index) < value ? color : Color.clear)
                                .overlay(Circle().strokeBorder(Double(index) < value ? Color.clear : color.opacity(0.4), lineWidth: 2))
                                .frame(width: 14, height: 14)
                        }
                    }
                    .accessibilityHidden(true)
                } else {
                    ProgressView(value: progress).tint(color).frame(maxWidth: 140)
                }
                Text(ProjectText.value(milestone, in: book)).font(.footnote.weight(.bold)).foregroundStyle(color).monospacedDigit()
                Spacer(minLength: 4)
                Button { store.advanceMilestone(milestone.id, in: projectKey) } label: {
                    Text("＋1").font(.subheadline.weight(.heavy))
                        .foregroundStyle(.black.opacity(0.8))
                        .padding(.horizontal, 16).frame(minHeight: 44)
                        .background(color, in: Capsule())
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.increase, trigger: value)
                .accessibilityLabel("\(milestone.title)に1回足す")
            }
        case .number:
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        ProgressView(value: progress).tint(color)
                        Text(ProjectText.value(milestone, in: book)).font(.footnote.weight(.bold)).foregroundStyle(color).monospacedDigit()
                    }
                    Text(store.isDemo ? "数値 ・ タップで今の値を入れる" : "数値").font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        case .tasks:
            let linked = book.tasks.filter { $0.milestoneID == milestone.id }
                .sorted { ($0.isComplete ? 1 : 0, $0.createdAt) < ($1.isComplete ? 1 : 0, $1.createdAt) }
            VStack(alignment: .leading, spacing: 6) {
                Text(linked.isEmpty ? "タスクで数える ・ タスクの編集画面でこの通過点を選ぶと数に入ります"
                     : "タスクで数える ・ \(ProjectText.number(value))/\(ProjectText.number(target))")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(linked.prefix(3)) { task in
                    let pieces = store.children(of: task.id)
                    // A task in pieces is checked off through its pieces; here it shows how far it has come.
                    Button { if pieces.isEmpty { store.toggle(AgendaItem(task: task)) } } label: {
                        HStack(spacing: 8) {
                            if pieces.isEmpty {
                                Image(systemName: task.isComplete ? "checkmark.circle.fill" : "circle").foregroundStyle(Palette.accent)
                            } else {
                                ProgressRing(done: pieces.filter(\.isComplete).count, total: pieces.count, size: 20)
                            }
                            Text(task.title).font(.subheadline).strikethrough(task.isComplete)
                                .foregroundStyle(task.isComplete ? Color.secondary : Color.primary).lineLimit(1)
                            Spacer(minLength: 0)
                            if !pieces.isEmpty && !task.isComplete {
                                Text("子タスク \(pieces.filter(\.isComplete).count)/\(pieces.count)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(minHeight: 32).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if linked.count > 3 { Text("ほか\(linked.count - 3)件").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

/// The end of the way: the goal, with its deadline.
@MainActor
struct GoalStation: View {
    let entry: ProjectBook.Entry
    let color: Color
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "flag.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(Circle().fill(color.opacity(0.16)))
                .overlay(Circle().strokeBorder(color, lineWidth: 2))
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                let goal = entry.project?.goal ?? ""
                Text(goal.isEmpty ? "到達点（まだ書いていない）" : goal).font(.headline).foregroundStyle(goal.isEmpty ? Color.secondary : color)
                if let deadline = entry.project?.deadline {
                    Text("\(ProjectText.dayWithWeekday(deadline)) ・ \(ProjectText.remaining(deadline))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Editors

@MainActor
struct ProjectEditor: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    @State private var project: Project
    @State private var hasDeadline: Bool
    @State private var confirmDelete = false
    /// Nil for a new project.
    let originalKey: String?
    var onSaved: (String) -> Void = { _ in }

    init(project: Project, originalKey: String?, onSaved: @escaping (String) -> Void = { _ in }) {
        _project = State(initialValue: project)
        _hasDeadline = State(initialValue: project.deadline != nil)
        self.originalKey = originalKey
        self.onSaved = onSaved
    }

    private var trimmedName: String { project.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Another saved project already has this name; two records for one name would split it.
    private var collides: Bool {
        let key = ProjectBook.key(trimmedName)
        return key != originalKey && store.notebook.projects.contains { ProjectBook.key($0.name) == key && $0.id != project.id }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名前（例：TOEIC）", text: $project.name).font(.headline)
                } header: { Text("プロジェクト") } footer: {
                    if collides { Text("同じ名前のプロジェクトがあります。").foregroundStyle(.red) }
                    else if originalKey != nil { Text("名前を変えると、このプロジェクトのタスク・ルーティン・カードもそろって変わります。") }
                }
                Section {
                    TextField("例：本番で500点", text: $project.goal, axis: .vertical).lineLimit(1...4)
                } header: { Text("到達点") } footer: { Text("山の頂上に出ます。").onlyInDemo() }
                Section {
                    TextField("何のためのプロジェクトか、どう進めるか", text: $project.overview, axis: .vertical).lineLimit(3...12)
                } header: { Text("概要") } footer: { Text("プロジェクトのページの上に出ます。").onlyInDemo() }
                Section {
                    Toggle("期限を決める", isOn: $hasDeadline.animation())
                    if hasDeadline {
                        DatePicker("期限", selection: Binding(get: { project.deadline ?? Date() }, set: { project.deadline = $0 }),
                                   displayedComponents: .date)
                    }
                }
                if let originalKey, store.projectEntry(originalKey) != nil {
                    Section {
                        Button("プロジェクトを外す", role: .destructive) { confirmDelete = true }
                    } footer: { Text("タスク・ルーティン・カードは残ります。プロジェクト名と通過点だけが外れます。直後なら取り消せます。") }
                }
            }
            .navigationTitle(originalKey == nil ? "プロジェクトを作る" : "プロジェクトを編集").navigationBarTitleDisplayMode(.inline)
            .keyboardDismissable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(originalKey == nil ? "追加" : "保存", action: save).disabled(trimmedName.isEmpty || collides)
                }
            }
            .confirmationDialog("このプロジェクトを外しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("外す", role: .destructive) {
                    if let originalKey { store.deleteProject(originalKey) }
                    dismiss()
                }
            }
        }
        .storeErrorAlert()
    }

    private func save() {
        project.name = trimmedName
        project.goal = project.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        project.deadline = hasDeadline ? (project.deadline ?? Date()) : nil
        if store.saveProject(project, renaming: originalKey) {
            onSaved(ProjectBook.key(project.name))
            dismiss()
        }
    }
}

@MainActor
struct MilestoneEditor: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    @State private var milestone: Milestone
    @State private var hasDue: Bool
    @State private var confirmDelete = false
    let key: String
    let isNew: Bool

    init(milestone: Milestone, key: String, isNew: Bool) {
        _milestone = State(initialValue: milestone)
        _hasDue = State(initialValue: milestone.dueDate != nil)
        self.key = key; self.isNew = isNew
    }

    private var trimmedTitle: String { milestone.title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section("通過点の名前") {
                    TextField("例：予想問題を5回解く", text: $milestone.title, axis: .vertical).lineLimit(1...3)
                }
                Section("数え方") {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(Milestone.Kind.allCases) { kind in kindTile(kind) }
                    }
                    .padding(.vertical, 4)
                }
                kindFields
                Section {
                    Toggle("目安の日を決める", isOn: $hasDue.animation())
                    if hasDue {
                        DatePicker("目安の日", selection: Binding(get: { milestone.dueDate ?? Date() }, set: { milestone.dueDate = $0 }),
                                   displayedComponents: .date)
                    }
                } footer: { Text("通過点は道のりの順に並びます。並べ替えは道のりで長押し。").onlyInDemo() }
                if !isNew {
                    Section { Button("この通過点を消す", role: .destructive) { confirmDelete = true } }
                }
            }
            .navigationTitle(isNew ? "通過点を足す" : "通過点を編集").navigationBarTitleDisplayMode(.inline)
            .keyboardDismissable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(isNew ? "追加" : "保存", action: save).disabled(trimmedTitle.isEmpty) }
            }
            .confirmationDialog("この通過点を消しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("消す", role: .destructive) {
                    store.deleteMilestone(milestone.id, in: key)
                    dismiss()
                }
            } message: { Text("つないだタスクやルーティンは残ります。") }
        }
        .storeErrorAlert()
    }

    private func kindTile(_ kind: Milestone.Kind) -> some View {
        let selected = milestone.kind == kind
        return Button {
            withAnimation(.snappy) {
                milestone.kind = kind
                if kind == .count, milestone.unit.isEmpty { milestone.unit = "回" }
                if kind == .count || kind == .number, milestone.target <= 1 { milestone.target = kind == .count ? 5 : 100 }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.label).font(.subheadline.weight(.bold)).foregroundStyle(selected ? Palette.accent : Color.primary)
                Text(kind.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Palette.accent.opacity(0.12) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Palette.accent : Color.secondary.opacity(0.3), lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var kindFields: some View {
        let book = store.notebook
        switch milestone.kind {
        case .check:
            Section { Toggle("できた", isOn: $milestone.isDone) }
        case .count:
            Section {
                Stepper(value: $milestone.target, in: 1...999, step: 1) {
                    LabeledContent("目標", value: "\(ProjectText.number(milestone.target)) \(milestone.unit)")
                }
                Stepper(value: $milestone.current, in: 0...9999, step: 1) {
                    LabeledContent("手で足した回数", value: ProjectText.number(milestone.current))
                }
                TextField("単位（回・本など）", text: $milestone.unit)
            } footer: {
                let total = ProjectText.number(ProjectBook.value(of: milestone, in: book))
                Text(store.isDemo ? "道のりの＋1で増えます。つないだタスクやルーティンが済むと、そのぶんも数えます（いま合わせて\(total)）。"
                                  : "つないだタスク・ルーティンの分も含めて いま\(total)")
            }
        case .number:
            Section {
                LabeledContent("目標") {
                    TextField("450", value: $milestone.target, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
                LabeledContent("いまの値") {
                    TextField("0", value: $milestone.current, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
                TextField("単位（点・kg など）", text: $milestone.unit)
            } footer: { Text("模試の点数や体重など、目標の値に近づけていくもの。").onlyInDemo() }
        case .tasks:
            Section {
                LabeledContent("いま", value: ProjectText.value(milestone, in: book))
            } footer: { Text("タスクの編集画面で、この通過点を選ぶと数に入ります。済んだタスクの割合が進み具合になります。").onlyInDemo() }
        }
    }

    private func save() {
        milestone.title = trimmedTitle
        milestone.dueDate = hasDue ? (milestone.dueDate ?? Date()) : nil
        if milestone.kind == .count || milestone.kind == .number { milestone.target = max(milestone.target, 1) }
        if store.saveMilestone(milestone, in: key) { dismiss() }
    }
}

/// Which checkpoint of its project a task or routine counts toward.
@MainActor
struct MilestonePicker: View {
    @EnvironmentObject private var store: TaskStore
    let project: String
    @Binding var milestoneID: UUID?
    var kinds: Set<Milestone.Kind> = [.count, .tasks]

    var body: some View {
        let options = (store.savedProject(ProjectBook.key(project))?.milestones ?? []).filter { kinds.contains($0.kind) }
        if !options.isEmpty {
            Picker("通過点", selection: $milestoneID) {
                Text("なし").tag(UUID?.none)
                ForEach(options) { milestone in
                    Text("\(milestone.title)（\(milestone.kind.label)）").tag(Optional(milestone.id))
                }
            }
            .pickerStyle(.menu)
        }
    }

    /// Clears a checkpoint that does not belong to the (new) project.
    static func fitting(_ id: UUID?, project: String, in book: Notebook) -> UUID? {
        guard let id else { return nil }
        let milestones = ProjectBook.project(named: project, in: book)?.milestones ?? []
        return milestones.contains { $0.id == id } ? id : nil
    }
}

/// An idea that turned out to be bigger than a task becomes a project of its own.
@MainActor
struct IdeaToProjectSheet: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    let idea: Idea
    @State private var name: String
    @State private var goal = ""
    @State private var hasDeadline = false
    @State private var deadline = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
    @State private var overviewCard: Bool
    @State private var keepIdea = false

    init(idea: Idea) {
        self.idea = idea
        let first = IdeaToTasksSheet.lines(of: idea.text).first ?? idea.text
        _name = State(initialValue: String(first.prefix(24)))
        _overviewCard = State(initialValue: !idea.notes.isEmpty || idea.text.count > 24)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section("元のアイデア") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(idea.text).font(.subheadline.weight(.bold))
                        ForEach(idea.notes) { note in Text("・\(note.text)").font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    TextField("名前", text: $name).font(.headline)
                        .accessibilityIdentifier("ideaProjectName")
                    TextField("到達点（任意）例：10本作って通勤中に回す", text: $goal, axis: .vertical).lineLimit(1...3)
                    Toggle("期限を決める", isOn: $hasDeadline.animation())
                    if hasDeadline { DatePicker("期限", selection: $deadline, displayedComponents: .date) }
                } header: { Text("プロジェクト") } footer: {
                    if store.savedProject(ProjectBook.key(trimmedName)) != nil {
                        Text("同じ名前のプロジェクトがあります。作ると、そちらにまとまります。")
                    }
                }
                Section {
                    Toggle("付箋の中身を「概要」カードにする", isOn: $overviewCard)
                    Toggle("アイデアを残す", isOn: $keepIdea)
                } footer: {
                    Text("付箋は「きっかけのアイデア」としてプロジェクトのページに残ります。どこかのプロジェクトの一歩なら、「タスクにする」でプロジェクトを選べます。").onlyInDemo()
                }
            }
            .navigationTitle("プロジェクトにする").navigationBarTitleDisplayMode(.inline)
            .keyboardDismissable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加", action: make).disabled(trimmedName.isEmpty)
                        .accessibilityIdentifier("addIdeaProject")
                }
            }
        }
        .storeErrorAlert()
    }

    private func make() {
        let project = Project(name: trimmedName, goal: goal.trimmingCharacters(in: .whitespacesAndNewlines),
                              deadline: hasDeadline ? deadline : nil, origin: idea.text)
        if store.makeProject(project, from: idea, overviewCard: overviewCard, keepIdea: keepIdea) {
            store.offerUndo("プロジェクト「\(project.name)」を作りました")
            store.projectToOpen = ProjectBook.key(project.name)
            dismiss()
        }
    }
}
