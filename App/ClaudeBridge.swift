import Foundation
import Security
import SwiftUI
import UIKit

/// The link to the Claude bridge (`https://<project>.supabase.co/functions/v1/horme/<key>`), kept in the Keychain
/// because the key in it grants access to the data.
enum BridgeLink {
    private static let service = "io.github.reiji55.threedays.bridge"

    static func load() -> String? {
        var item: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ link: String) -> Bool {
        delete()
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecValueData as String: Data(link.utf8),
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }

    /// Accepts the base link with or without a trailing /sync or /mcp.
    static func normalized(_ text: String) -> String? {
        var link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ["/sync", "/mcp", "/"] where link.hasSuffix(suffix) { link.removeLast(suffix.count) }
        guard let url = URL(string: link), url.scheme == "https", url.host != nil,
              url.pathComponents.contains("horme"), url.lastPathComponent.count >= 24 else { return nil }
        return link
    }
}

enum BridgeError: LocalizedError {
    case status(Int), invalidLink
    var errorDescription: String? {
        switch self {
        case .status(404): return "連携先が見つかりません。URLが正しいか確認してください。"
        case .status(let code): return "連携先がエラーを返しました（\(code)）。少し待ってからもう一度試してください。"
        case .invalidLink: return "連携URLの形が違います。設定手順にある https://…/horme/… のURLを貼ってください。"
        }
    }
}

/// Sends every local record and gets back the merged set. Data is small, so there is no change tracking.
struct BridgeTransport {
    func synchronize(link: String, records: [SyncRecord]) async throws -> [SyncRecord] {
        guard let url = URL(string: link + "/sync") else { throw BridgeError.invalidLink }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["records": records])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw BridgeError.status(status) }
        struct Reply: Decodable { var records: [SyncRecord] }
        // Validate each record the same way as one from iCloud before it can touch local data.
        return try JSONDecoder().decode(Reply.self, from: data).records.map { record in
            try SyncRecord.decode(record.encoded(), expectedID: record.id)
        }
    }
}

@MainActor
struct ClaudeBridgeSection: View {
    @EnvironmentObject private var store: TaskStore
    @State private var link = ""
    @State private var connecting = false
    @State private var confirmDisconnect = false

    var body: some View {
        Section {
            if store.bridgeOn {
                LabeledContent("状態", value: store.isBridgeSyncing ? "同期中…" : store.bridgeSyncedAt.map {
                    "\($0.formatted(date: .omitted, time: .shortened))に同期"
                } ?? "未同期")
                if let error = store.bridgeError { Text(error).font(.caption).foregroundStyle(.red) }
                Button("今すぐ同期", systemImage: "arrow.triangle.2.circlepath") { Task { await store.synchronizeBridge() } }
                    .disabled(store.isBridgeSyncing)
                if let mcp = store.bridgeMCPURL {
                    Button("Claudeのコネクタ用URLをコピー", systemImage: "doc.on.doc") { UIPasteboard.general.string = mcp }
                }
                Button("連携を解除", role: .destructive) { confirmDisconnect = true }
            } else {
                TextField("連携URL（https://…/horme/…）", text: $link)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Button(connecting ? "接続中…" : "接続する") {
                    connecting = true
                    Task { if await store.connectBridge(link) { link = "" }; connecting = false }
                }.disabled(connecting || BridgeLink.normalized(link) == nil)
                if let error = store.bridgeError { Text(error).font(.caption).foregroundStyle(.red) }
            }
        } header: { Text("Claudeとの連携") }
        footer: {
            Text("Claudeがタスク・ルーティン・ボードを読み書きできるようにします。データはSupabaseにも置かれ、iCloudと同じしくみで統合されます。連携URLは鍵を含むので人に渡さないでください。")
        }
        .confirmationDialog("Claudeとの連携を解除しますか？", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("解除する", role: .destructive) { store.disconnectBridge() }
        } message: { Text("この端末からSupabaseへの同期を止めます。Supabaseのデータとこの端末のデータはどちらも残ります。") }
    }
}
