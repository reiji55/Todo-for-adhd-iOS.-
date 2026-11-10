import SwiftUI

/// The same short path used from a project's empty next-step card: write one action, then either
/// start it on Today or only add it. The full editor remains available for scheduling and splitting.
@MainActor
struct TaskStepSheet: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    let project: String
    var onStarted: () -> Void = {}
    @State private var title = ""
    @State private var detailed: TaskItem?
    @State private var pendingID: UUID?
    @State private var savedID: UUID?
    @FocusState private var focused: Bool

    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Label(project, systemImage: "flag").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("最初の一手").font(.headline)
                        TextField("最初に何をする？", text: $title, axis: .vertical)
                            .lineLimit(1...4).font(.body.weight(.medium)).focused($focused)
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .secondarySystemGroupedBackground)))
                            .accessibilityIdentifier("projectFirstStep")
                    }
                    Button(action: openEditor) {
                        HStack {
                            Text("詳しく決める").font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color(uiColor: .secondarySystemGroupedBackground)))
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.accent)
                    .accessibilityIdentifier("projectStepDetails")
                    if savedID != nil {
                        Label("タスクは追加済みです", systemImage: "checkmark.circle")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .background(Palette.paper)
            .safeAreaInset(edge: .bottom, spacing: 0) { actions }
            .navigationTitle("一手を追加").navigationBarTitleDisplayMode(.inline)
            .keyboardDismissable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(savedID == nil ? "キャンセル" : "閉じる") { dismiss() }
                }
            }
            .sheet(item: $detailed, onDismiss: afterEditor) { task in
                TaskEditor(task: task, original: store.task(task.id))
            }
        }
        .storeErrorAlert()
    }

    private var actions: some View {
        VStack(spacing: 10) {
            StepActionButton(title: savedID == nil ? "作って始める" : "始める", prominent: true, systemImage: "play.fill") { make(start: true) }
                .disabled(trimmed.isEmpty)
                .accessibilityIdentifier("createProjectTaskAndStart")
            StepActionButton(title: savedID == nil ? "タスクを追加" : "保存", prominent: false) { make(start: false) }
                .disabled(trimmed.isEmpty)
                .accessibilityIdentifier("addProjectTaskOnly")
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 12)
        .background(Palette.paper)
    }

    private func candidate() -> TaskItem? {
        if let savedID {
            guard var saved = store.task(savedID) else {
                store.error = "このタスクは別の端末で削除されました。入力した内容をコピーしてから閉じてください。"
                return nil
            }
            saved.title = trimmed
            return saved
        }
        return TaskItem(title: trimmed, project: project)
    }

    private func openEditor() {
        guard let task = candidate() else { return }
        pendingID = task.id
        detailed = task
    }

    private func afterEditor() {
        guard let pendingID else { return }
        self.pendingID = nil
        if let saved = store.task(pendingID) {
            savedID = saved.id
            title = saved.title
        }
    }

    private func make(start: Bool) {
        guard !trimmed.isEmpty else { return }
        guard let task = candidate() else { return }
        guard store.upsert(task, original: savedID.flatMap { store.task($0) }) else { return }
        // Remember a successful save before starting. A later start failure can be retried without
        // inserting a second task, and full-editor scheduling/memo/children are preserved.
        savedID = task.id
        if start {
            let target = store.notebook.nextChild(of: task.id)?.id ?? task.id
            guard store.requestTaskStart(target) else { return }
            dismiss()
            onStarted()
        } else {
            store.offerUndo("「\(task.title)」を追加しました")
            dismiss()
        }
    }
}

/// Large, predictable actions shared by the two short task-creation paths.
struct StepActionButton: View {
    let title: String
    let prominent: Bool
    var systemImage: String? = nil
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity).frame(minHeight: 48)
            .foregroundStyle(prominent ? Color.white : Palette.accent)
            .background(Capsule().fill(prominent ? Palette.accent : Color(uiColor: .secondarySystemGroupedBackground)))
            .overlay(Capsule().strokeBorder(Palette.accent, lineWidth: prominent ? 0 : 1))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
