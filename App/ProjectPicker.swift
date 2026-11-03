import SwiftUI

/// The project of a task or routine, picked with a tap: a board card, a name already in use, or a new
/// name typed once. When the project has a board card, the book beside it opens the card's やり方 over
/// the editor, so whatever was typed is still there when it closes.
@MainActor
struct ProjectPicker: View {
    @EnvironmentObject private var store: TaskStore
    @Binding var project: String
    let onOpenCard: (BoardCard) -> Void
    @State private var typing = false
    @FocusState private var focused: Bool

    /// The menu item that switches to typing; never a real project name.
    private static let typeTag = "\u{1}type"

    var body: some View {
        let cards = store.notebook.boardCards
        let card = BoardLink.card(forProject: project, in: cards)
        HStack(spacing: 4) {
            if typing {
                TextField("プロジェクト名", text: $project)
                    .focused($focused).submitLabel(.done)
                    .onSubmit { typing = false }
                    .task { focused = true }
            } else {
                Picker("プロジェクト", selection: selection) { options(cards) }.pickerStyle(.menu)
            }
            if let card { GuideBookButton(card: card) { onOpenCard(card) } }
        }
        // Back to the menu once the name is written; only after the field really had the keyboard.
        .onChange(of: focused) { was, now in if was && !now { typing = false } }
    }

    private var selection: Binding<String> {
        Binding(get: { project }, set: { value in
            if value == Self.typeTag { typing = true } else { project = value }
        })
    }

    @ViewBuilder private func options(_ cards: [BoardCard]) -> some View {
        let loose = BoardLink.looseProjects(tasks: store.notebook.tasks, routines: store.notebook.routines, cards: cards)
        let listed = Set(cards.map(\.title) + loose)
        Text("なし").tag("")
        // A name typed here but not saved yet, or an older one that only partly matches a card.
        if !project.isEmpty && !listed.contains(project) { Text(project).tag(project) }
        if !cards.isEmpty {
            Section("ボードのカード") { ForEach(cards) { Text($0.title).tag($0.title) } }
        }
        if !loose.isEmpty {
            Section("ボードにないプロジェクト") { ForEach(loose, id: \.self) { Text($0).tag($0) } }
        }
        Section { Label("名前を入力する…", systemImage: "keyboard").tag(Self.typeTag) }
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
