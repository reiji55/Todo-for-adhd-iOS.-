import SwiftUI

/// How many of a task's pieces are done, as a ring with the count inside.
struct ProgressRing: View {
    let done: Int
    let total: Int
    var size: CGFloat = 28

    var body: some View {
        let share = total == 0 ? 0 : Double(done) / Double(total)
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.22), lineWidth: 3)
            Circle().trim(from: 0, to: share)
                .stroke(Palette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(done)/\(total)").font(.system(size: size * 0.32, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(done == 0 ? Color.secondary : Palette.accent)
                .minimumScaleFactor(0.6)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(total)件中\(done)件済み")
    }
}

/// When a piece is planned: "今日 14:00", "明日", "11/06". Nothing for a piece without a day.
struct PieceDateChip: View {
    let task: TaskItem

    var body: some View {
        if let day = task.plannedAt {
            let calendar = Calendar.current
            let today = calendar.isDateInToday(day)
            let label = today ? "今日" : calendar.isDateInTomorrow(day) ? "明日" : day.shortDay
            Text([label, task.slot?.startLabel].compactMap { $0 }.joined(separator: " "))
                .font(.caption.weight(today ? .bold : .semibold)).monospacedDigit()
                .foregroundStyle(today ? Palette.accent : Color.primary.opacity(0.75))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 7).fill(today ? Palette.accent.opacity(0.13) : Color(uiColor: .tertiarySystemFill)))
                .fixedSize()
        }
    }
}

/// A task in pieces: its progress, deadline and ★ on top, its pieces inside, each checked off with one
/// tap. Pieces finished while the task goes on stay in the card, struck through. Closed, it shows the
/// next piece only. A tap on the name opens the task; on a piece, that piece.
@MainActor
struct ParentTaskCard: View {
    @EnvironmentObject private var store: TaskStore
    let parent: TaskItem
    var reason: String? = nil
    var startsOpen = false
    var raised = false
    let onOpen: (TaskItem) -> Void
    @State private var open: Bool?
    @State private var adding = ""

    var body: some View {
        let pieces = store.children(of: parent.id)
        let doneCount = pieces.filter(\.isComplete).count
        let isOpen = open ?? startsOpen
        let next = pieces.first { !$0.isComplete }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                RowButton { withAnimation(.snappy) { open = !isOpen } } label: {
                    ProgressRing(done: doneCount, total: pieces.count, size: 30).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(parent.title)。\(pieces.count)件中\(doneCount)件済み")
                .accessibilityHint(isOpen ? "子タスクをたたみます" : "子タスクを広げます")
                RowButton { onOpen(parent) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        if let reason {
                            Text(reason).font(.caption2.weight(.semibold)).foregroundStyle(Palette.accent)
                        }
                        if parent.isMust || parent.deadline != nil || !parent.project.isEmpty {
                            HStack(spacing: 6) {
                                if parent.isMust {
                                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(Palette.must).accessibilityLabel("必須")
                                }
                                if let deadline = parent.deadline, !parent.isComplete {
                                    Text("締切 \(deadline.shortDay)").font(.caption2.weight(.semibold)).foregroundStyle(Palette.must)
                                }
                                if !parent.project.isEmpty { ProjectTag(name: parent.project) }
                            }
                        }
                        Text(parent.title).font(.body.weight(parent.isMust && !parent.isComplete ? .bold : .semibold))
                            .strikethrough(parent.isComplete)
                            .foregroundStyle(parent.isComplete ? Color.secondary : parent.isMust ? Palette.must : Color.primary)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        if !isOpen, let next {
                            HStack(spacing: 6) {
                                Text("次：\(next.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                PieceDateChip(task: next)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                RowButton { withAnimation(.snappy) { open = !isOpen } } label: {
                    Image(systemName: "chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .frame(width: 34, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isOpen ? "たたむ" : "広げる")
            }
            if isOpen {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(pieces) { piece in PieceRow(piece: piece, onOpen: onOpen) }
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.subheadline.weight(.semibold)).frame(width: 30)
                        TextField("子タスクを足す", text: $adding).submitLabel(.done).onSubmit(add)
                    }
                    .foregroundStyle(Palette.accent).font(.subheadline)
                    .frame(minHeight: 44)
                }
                .padding(.leading, 8)
                .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 2) }
                .padding(.leading, 26).padding(.trailing, 8).padding(.bottom, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 5).padding(.leading, 6).padding(.trailing, 2)
        .background {
            if raised { RaisedCardBackground() } else { RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .secondarySystemGroupedBackground)) }
        }
        .overlay(alignment: .leading) {
            if let color = ProjectColor.color(for: store.colorName(forProject: parent.project)) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 12)
            }
        }
        .opacity(parent.isComplete ? 0.55 : 1)
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 14))
        .contextMenu {
            Button(parent.isComplete ? "未完了に戻す" : "完了にする", systemImage: parent.isComplete ? "arrow.uturn.backward" : "checkmark") {
                store.complete(parent.id)
            }
        }
        .swipeToDelete { store.delete(parent.id) }
    }

    private func add() {
        if store.addChild(adding, to: parent.id) { adding = "" }
    }
}

/// One piece inside its task's card: a check, its name, and its day.
@MainActor
private struct PieceRow: View {
    @EnvironmentObject private var store: TaskStore
    let piece: TaskItem
    let onOpen: (TaskItem) -> Void

    var body: some View {
        let done = piece.isComplete
        HStack(spacing: 2) {
            RowButton { store.complete(piece.id) } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle").font(.title3)
                    .foregroundStyle(Palette.accent).frame(width: 40, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(done ? "\(piece.title)を未完了に戻す" : "\(piece.title)を完了")
            RowButton { onOpen(piece) } label: {
                HStack(spacing: 8) {
                    Text(piece.title).font(.subheadline.weight(.medium))
                        .strikethrough(done).foregroundStyle(done ? .secondary : .primary)
                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    if !done { PieceDateChip(task: piece) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .opacity(done ? 0.55 : 1)
        .animation(.easeOut(duration: 0.2), value: done)
    }
}

/// A finished task in pieces, in the list of finished things: the card with its pieces stacked behind it.
/// A tap spreads them out underneath.
@MainActor
struct FinishedFamilyCard: View {
    @EnvironmentObject private var store: TaskStore
    let parent: TaskItem
    let onOpen: (TaskItem) -> Void
    @State private var open = false

    var body: some View {
        let pieces = store.children(of: parent.id)
        VStack(alignment: .leading, spacing: 0) {
            RowButton { withAnimation(.snappy) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Palette.accent)
                        .frame(width: 44, height: 44).opacity(0.6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(parent.title).font(.body.weight(.medium)).strikethrough().foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                        Text("子タスク \(pieces.count)件").font(.caption.weight(.semibold)).foregroundStyle(Palette.accent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let finished = parent.completedAt {
                        Text(finished.shortDay).font(.caption).foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.vertical, 4).padding(.leading, 4).padding(.trailing, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(parent.title)、完了。子タスク\(pieces.count)件")
            .accessibilityHint(open ? "子タスクをたたみます" : "子タスクを広げます")
            if open {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(pieces) { piece in
                        RowButton { onOpen(piece) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill").font(.footnote).foregroundStyle(Palette.accent.opacity(0.6))
                                Text(piece.title).font(.subheadline).strikethrough().foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let day = piece.completedAt ?? piece.plannedAt {
                                    Text(day.shortDay).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 2) }
                .padding(.leading, 26).padding(.trailing, 14).padding(.bottom, 12)
                .transition(.opacity)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        // Closed, the pieces show as cards stacked behind it.
        .background(alignment: .bottom) {
            if !open {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.55))
                        .padding(.horizontal, 14).offset(y: 10)
                    RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.8))
                        .padding(.horizontal, 7).offset(y: 5)
                }
                .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
            }
        }
        .padding(.bottom, open ? 0 : 10)
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 14))
        .contextMenu {
            Button("未完了に戻す", systemImage: "arrow.uturn.backward") { store.complete(parent.id) }
        }
        .swipeToDelete { store.delete(parent.id) }
    }
}
