import SwiftUI

/// つながり in a task's editor: the tasks before and after it, joined by a line, with a field to add what
/// comes next or what has to happen first. When there is more than one, the つながり can be gathered under a
/// named task, made a project, or undone; each can be undone in turn, and no task is lost.
@MainActor
struct ChainSection: View {
    @EnvironmentObject private var store: TaskStore
    let taskID: UUID
    let onOpen: (TaskItem) -> Void
    /// The task being edited was gathered into a new one or scattered: the editor closes, and the new task
    /// (when there is one) opens instead.
    let onReplaced: (TaskItem?) -> Void
    @State private var next = ""
    @State private var before = ""
    @State private var addingBefore = false
    @State private var naming: Naming?
    @State private var name = ""
    @FocusState private var focus: Field?

    private enum Field { case next, before }
    private enum Naming: Identifiable {
        case gather, project
        var id: Self { self }
    }

    var body: some View {
        let chain = store.chain(containing: taskID)
        Section {
            if addingBefore {
                addRow(text: $before, prompt: "前にやること", field: .before) { add(before: true) }
            } else {
                Button { addingBefore = true; focus = .before } label: {
                    HStack(spacing: 10) {
                        ChainMark(kind: .add)
                        Text("前にやることを足す").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.accent)
                        Text("これより先に必要なこと").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("chainAddBefore")
            }
            ForEach(chain) { member in
                if member.id == taskID {
                    HStack(spacing: 10) {
                        ChainMark(kind: .current)
                        Text(member.title).font(.subheadline.weight(.bold)).lineLimit(2)
                        if chain.count > 1 {
                            Text("このタスク").font(.caption2.weight(.heavy)).foregroundStyle(Palette.accent)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Palette.accent.opacity(0.12), in: Capsule())
                        }
                    }
                } else {
                    Button { onOpen(member) } label: {
                        HStack(spacing: 10) {
                            ChainMark(kind: member.isComplete ? .done : store.notebook.isWaiting(member) ? .waiting : .open)
                            Text(member.title).font(.subheadline).lineLimit(2)
                                .strikethrough(member.isComplete)
                                .foregroundStyle(member.isComplete || store.notebook.isWaiting(member) ? .secondary : .primary)
                            Spacer(minLength: 0)
                            if let day = member.plannedAt {
                                Text(day.shortDay).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            addRow(text: $next, prompt: "次にやること", field: .next) { add(before: false) }
                .accessibilityIdentifier("chainAddNext")
        } header: {
            HStack {
                Text("つながり")
                Spacer()
                if chain.count > 1 { menu }
            }
        } footer: {
            Text("次にやることは、前のタスクが済むまで候補に出ません。済むと「いま」に出ます。").onlyInDemo()
        }
        .alert(naming == .gather ? "ひとまとめにする" : "プロジェクトにする", isPresented: Binding(
            get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField(naming == .gather ? "まとめた名前（例：賃貸の解約）" : "プロジェクトの名前", text: $name)
            Button(naming == .gather ? "まとめる" : "プロジェクトにする") { apply() }
            Button("キャンセル", role: .cancel) { name = "" }
        } message: {
            Text(naming == .gather ? "つながりの順に、子タスクとして並びます。あとで「ばらす」で戻せます。"
                 : "つながりのタスクすべてに、プロジェクトの名前が付きます。到達点や期限はあとから足せます。")
        }
    }

    private var menu: some View {
        Menu {
            Button("ひとまとめにする", systemImage: "list.bullet.indent") { name = ""; naming = .gather }
            Button("プロジェクトにする", systemImage: "flag") {
                name = store.task(taskID)?.project ?? ""
                naming = .project
            }
            Divider()
            Button("このタスクをつながりから外す", systemImage: "scissors") { store.unlink(taskID) }
            Button("つながりをほどく", systemImage: "xmark.circle", role: .destructive) { store.dissolveChain(containing: taskID) }
        } label: {
            Image(systemName: "ellipsis.circle").font(.body)
        }
        .textCase(nil)
        .accessibilityLabel("つながりの操作")
        .accessibilityIdentifier("chainMenu")
    }

    private func addRow(text: Binding<String>, prompt: String, field: Field, submit: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            ChainMark(kind: .add)
            TextField(prompt, text: text)
                .font(.subheadline)
                .submitLabel(.done)
                .focused($focus, equals: field)
                .onSubmit(submit)
            if !text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("足す", action: submit).buttonStyle(.borderless).font(.subheadline.weight(.semibold))
            }
        }
    }

    private func add(before isBefore: Bool) {
        let text = isBefore ? before : next
        guard store.addLinked(text, to: taskID, before: isBefore) else { return }
        if isBefore { before = ""; addingBefore = false } else { next = "" }
    }

    private func apply() {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { name = ""; naming = nil }
        guard !title.isEmpty else { return }
        switch naming {
        case .gather:
            if let parent = store.gatherChain(containing: taskID, title: title) { onReplaced(parent) }
        case .project:
            store.makeProject(ofChainContaining: taskID, named: title)
        case nil:
            break
        }
    }
}

/// The mark at the left of a row in a つながり, on the line that joins them.
struct ChainMark: View {
    enum Kind { case current, open, waiting, done, add }
    let kind: Kind

    var body: some View {
        ZStack {
            switch kind {
            case .current:
                Circle().fill(Palette.accent).frame(width: 13, height: 13)
            case .done:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(Palette.accent)
            case .open:
                Circle().strokeBorder(Palette.accent, lineWidth: 2).frame(width: 13, height: 13)
            case .waiting:
                Circle().strokeBorder(Palette.accent.opacity(0.4), lineWidth: 2).frame(width: 13, height: 13)
            case .add:
                Image(systemName: "plus").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.accent)
            }
        }
        .frame(width: 18)
        .accessibilityHidden(true)
    }
}

/// A line under a task's name in lists: what it waits for, or what comes after it.
@MainActor
struct ChainHint: View {
    @EnvironmentObject private var store: TaskStore
    let task: TaskItem

    var body: some View {
        let book = store.notebook
        if !task.isComplete, let before = book.previous(of: task), !before.isComplete {
            Label("「\(before.title)」のあと", systemImage: "link")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } else if !task.isComplete, let next = book.nextInChain(after: task.id) {
            Label("次：\(next.title)", systemImage: "link")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
