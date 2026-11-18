import SwiftUI

/// "パッケージから足す": the パッケージ there are, each with what it holds; picking one puts it in.
@MainActor
struct PackageMenu: View {
    @EnvironmentObject private var store: TaskStore
    var title = "パッケージから足す"
    let onPick: (TaskPackage) -> Void

    var body: some View {
        Menu {
            ForEach(store.notebook.packages) { package in
                Button { onPick(package) } label: {
                    Text(package.name)
                    Text(package.cleanItems.joined(separator: "・"))
                }
            }
        } label: {
            Label(title, systemImage: "shippingbox").font(.subheadline.weight(.semibold))
        }
        .accessibilityIdentifier("addFromPackage")
    }
}

/// An event's 関連タスク: what has to be done for it, each an ordinary task, due on the event's day unless given
/// a deadline of its own. Checking the event off leaves them as they are.
@MainActor
struct RelatedTasksSection: View {
    @EnvironmentObject private var store: TaskStore
    let eventID: UUID
    let onOpen: (TaskItem) -> Void
    @State private var draft = ""

    var body: some View {
        let related = store.notebook.relatedTasks(of: eventID)
        Section {
            ForEach(related) { task in
                Button { onOpen(task) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: task.isComplete ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(Palette.accent.opacity(task.isComplete ? 0.6 : 1))
                        Text(task.title).strikethrough(task.isComplete)
                            .foregroundStyle(task.isComplete ? Color.secondary : Color.primary).lineLimit(2)
                        Spacer(minLength: 0)
                        Text(task.isComplete ? "済" : task.plannedAt?.shortDay ?? "未定")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.borderless)
            }
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.accent).frame(width: 20)
                TextField("関連タスクを足す", text: $draft).font(.subheadline).submitLabel(.done).onSubmit(add)
                if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("足す", action: add).buttonStyle(.borderless).font(.subheadline.weight(.semibold))
                }
            }
            .accessibilityIdentifier("addRelatedTask")
            if !store.notebook.packages.isEmpty {
                PackageMenu(title: "パッケージから関連タスクを足す") { store.applyPackage($0.id, to: eventID) }
            }
        } header: {
            Text(related.isEmpty ? "関連タスク" : "関連タスク \(related.filter(\.isComplete).count)/\(related.count)")
        } footer: {
            Text("関連タスクの締切は、イベントの日になります。イベントに済みを付けても、関連タスクはそのままです。").onlyInDemo()
        }
    }

    private func add() {
        if store.addRelated(draft, to: eventID) { draft = "" }
    }
}

/// 設定 › パッケージ: each one's name and what it holds, written over, reordered or removed.
@MainActor
struct PackagesView: View {
    @EnvironmentObject private var store: TaskStore

    var body: some View {
        List {
            if store.notebook.packages.isEmpty {
                Text("子タスクに分けたタスクを開き、「この分け方をパッケージに保存」で作れます。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(store.notebook.packages) { package in
                NavigationLink { PackageEditor(package: package) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(package.name).font(.body.weight(.semibold))
                        Text(package.cleanItems.joined(separator: "・")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets { store.deletePackage(store.notebook.packages[index].id) }
            }
        }
        .navigationTitle("パッケージ")
        .navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
private struct PackageEditor: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    @State var package: TaskPackage
    @State private var newItem = ""

    var body: some View {
        Form {
            Section("名前") { TextField("名前", text: $package.name) }
            Section {
                ForEach(package.items.indices, id: \.self) { index in
                    TextField("子タスク", text: $package.items[index])
                }
                .onDelete { package.items.remove(atOffsets: $0) }
                .onMove { package.items.move(fromOffsets: $0, toOffset: $1) }
                HStack {
                    Image(systemName: "plus").foregroundStyle(Palette.accent)
                    TextField("足す", text: $newItem).submitLabel(.done).onSubmit {
                        let text = newItem.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { package.items.append(text) }
                        newItem = ""
                    }
                }
            } header: {
                HStack { Text("中身"); Spacer(); EditButton().font(.caption) }
            }
            Section {
                Button("このパッケージを削除", role: .destructive) {
                    store.deletePackage(package.id)
                    dismiss()
                }
            }
        }
        .navigationTitle(package.name.isEmpty ? "パッケージ" : package.name)
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDismissable()
        .onDisappear { store.updatePackage(package) }
    }
}
