import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Horme" in the share sheet: a page, a product or a place from another app goes onto one of the lists in
/// ストック. It is left in the shared inbox, and the app puts it on the list the next time it opens.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel()
        let host = UIHostingController(rootView: ShareForm(model: model,
                                                           onCancel: { [weak self] in self?.finish(cancelled: true) },
                                                           onAdd: { [weak self] in self?.finish(cancelled: false) }))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        Task { await model.load(from: items) }
    }

    private func finish(cancelled: Bool) {
        if cancelled {
            extensionContext?.cancelRequest(withError: NSError(domain: "Horme", code: NSUserCancelledError))
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}

@MainActor
final class ShareModel: ObservableObject {
    @Published var title = ""
    @Published var memo = ""
    @Published var link = ""
    @Published var place = ""
    /// Where the place is, when its map link said.
    @Published var latitude: Double?
    @Published var longitude: Double?
    /// The list chosen; nil means a new one named `newListName`.
    @Published var listID: UUID?
    @Published var newListName = ""
    @Published var loading = true
    @Published var failed = false
    let lists: [ListInbox.ListName]
    private static let lastListKey = "horme.share.lastList"

    init() {
        lists = ListInbox.read().lists
        let last = UserDefaults.standard.string(forKey: Self.lastListKey).flatMap(UUID.init(uuidString:))
        listID = lists.first { $0.id == last }?.id ?? lists.first?.id
    }

    var canAdd: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (listID != nil || !newListName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func load(from items: [NSExtensionItem]) async {
        var text = items.compactMap { $0.attributedContentText?.string }.joined(separator: "\n")
        var url: URL?
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            if url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) {
                url = (item as? URL) ?? (item as? String).flatMap(URL.init(string:))
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) as? String {
                text += "\n" + item
            }
        }
        // A link inside shared text (Amazon, Google Maps) counts as the link.
        if url == nil, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
           let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            url = match.url
        }
        title = SharedContent.title(text: text, url: url)
        link = url?.absoluteString ?? ""
        if let url, MapLink.isMap(url) {
            place = title
            // A short Google Maps link names nothing until followed: follow it for the name and the point.
            if let found = await MapResolver.place(for: url) {
                let bare = title.isEmpty || title == url.host || title.hasPrefix("http")
                if !found.name.isEmpty {
                    if bare { title = found.name }
                    place = found.name
                } else if bare {
                    place = ""
                }
                latitude = found.latitude; longitude = found.longitude
            }
        }
        loading = false
    }

    func save() -> Bool {
        let entry = ListInbox.Entry(listID: listID, newListName: newListName.trimmingCharacters(in: .whitespacesAndNewlines),
                                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                    memo: memo, link: link.trimmingCharacters(in: .whitespacesAndNewlines),
                                    place: place.trimmingCharacters(in: .whitespacesAndNewlines),
                                    latitude: latitude, longitude: longitude)
        guard ListInbox.add(entry) else { failed = true; return false }
        if let listID { UserDefaults.standard.set(listID.uuidString, forKey: Self.lastListKey) }
        return true
    }
}

struct ShareForm: View {
    @ObservedObject var model: ShareModel
    let onCancel: () -> Void
    let onAdd: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名前", text: $model.title, axis: .vertical).font(.headline).lineLimit(1...4)
                }
                Section("リスト") {
                    Picker("リスト", selection: $model.listID) {
                        ForEach(model.lists) { Text($0.name).tag(Optional($0.id)) }
                        Text("新しいリスト").tag(UUID?.none)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    if model.listID == nil {
                        TextField("新しいリストの名前（例：行きたいところ）", text: $model.newListName)
                    }
                }
                Section {
                    TextField("メモ", text: $model.memo, axis: .vertical).lineLimit(1...5)
                    TextField("リンク（URL）", text: $model.link)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("場所（店名や住所）", text: $model.place)
                } footer: {
                    if model.failed {
                        Text("保存できませんでした。Hormeを一度開いてから、もう一度お試しください。").foregroundStyle(.red)
                    } else {
                        Text("次にHormeを開いたとき、リストに入ります。")
                    }
                }
            }
            .disabled(model.loading)
            .navigationTitle("Hormeのリストへ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加") { if model.save() { onAdd() } }.disabled(!model.canAdd)
                }
            }
        }
        .tint(Color(red: 0.2, green: 0.37, blue: 0.34))
    }
}
