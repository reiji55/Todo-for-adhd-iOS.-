import Foundation

/// Bundles of sticky notes: notes of the same kind held together under one label. A note's `bundle` is the
/// label; notes with the same label are one bundle, so naming a bundle as another joins the two.
public extension Notebook {
    /// The bundles there are, each label once, the notes in the order they were written.
    var ideaBundles: [(label: String, ideas: [Idea])] {
        var order: [String] = []
        var byLabel: [String: [Idea]] = [:]
        for idea in ideas.sorted(by: { $0.createdAt < $1.createdAt }) {
            let label = idea.bundle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            if byLabel[label] == nil { order.append(label) }
            byLabel[label, default: []].append(idea)
        }
        return order.map { ($0, byLabel[$0] ?? []) }
    }

    /// Puts the notes in the bundle with this label (made when there is none). An empty label takes them out.
    mutating func bundleIdeas(_ ids: [UUID], label: String) {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        for i in ideas.indices where ids.contains(ideas[i].id) && ideas[i].bundle != name { ideas[i].bundle = name }
    }

    /// A new label for every note in a bundle. Empty unties it: the notes go back to the wall one by one.
    mutating func renameBundle(_ label: String, to newLabel: String) {
        let old = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.isEmpty else { return }
        bundleIdeas(ideas.filter { $0.bundle.trimmingCharacters(in: .whitespacesAndNewlines) == old }.map(\.id), label: newLabel)
    }
}
