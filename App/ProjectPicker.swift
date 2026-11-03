import SwiftUI

/// The project of a task, routine or card, picked with a tap: a project already there, or a new name typed
/// once. When the project has cards, the book beside it opens them over the editor, so whatever was typed
/// is still there when it closes.
@MainActor
struct ProjectPicker: View {
    @EnvironmentObject private var store: TaskStore
    @Binding var project: String
    var onOpenCard: ((BoardCard) -> Void)? = nil
    @State private var typing = false
    @FocusState private var focused: Bool

    /// The menu item that switches to typing; never a real project name.
    private static let typeTag = "\u{1}type"

    var body: some View {
        let card = store.linkedCard(forProject: project)
        HStack(spacing: 4) {
            if typing {
                TextField("プロジェクト名", text: $project)
                    .focused($focused).submitLabel(.done)
                    .onSubmit { typing = false }
                    .task { focused = true }
            } else {
                Picker("プロジェクト", selection: selection) { options }.pickerStyle(.menu)
            }
            if let card, let onOpenCard { GuideBookButton(card: card) { onOpenCard(card) } }
        }
        // Back to the menu once the name is written; only after the field really had the keyboard.
        .onChange(of: focused) { was, now in if was && !now { typing = false } }
    }

    private var selection: Binding<String> {
        Binding(get: { project }, set: { value in
            if value == Self.typeTag { typing = true } else { project = value }
        })
    }

    @ViewBuilder private var options: some View {
        let names = store.projectEntries.map(\.name)
        Text("なし").tag("")
        // A name typed here but not saved yet, or one spelled differently from its project.
        if !project.isEmpty && !names.contains(project) { Text(project).tag(project) }
        if !names.isEmpty {
            Section("プロジェクト") { ForEach(names, id: \.self) { Text($0).tag($0) } }
        }
        Section { Label("新しい名前を入力する…", systemImage: "keyboard").tag(Self.typeTag) }
    }
}

/// The book that opens a project's board card: the same mark as the ボード tab, in the card's color.
/// (The bookmark is already the mark of a task's 続きのメモ.)
struct GuideBookButton: View {
    let card: BoardCard
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "book.closed").font(.subheadline.weight(.semibold))
                .foregroundStyle(ProjectColor.color(for: card.title) ?? Palette.accent)
                .frame(width: 40, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("やり方を開く（\(card.title)）")
    }
}
