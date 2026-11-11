import Foundation
import Security

/// Things shared into Horme from other apps (Maps, Safari, Amazon), waiting to be put on a list.
///
/// The share extension cannot open the app's saved data, so the two meet in one keychain item in a group both
/// may use: the app leaves the names of its lists there, the extension leaves what was shared, and the app takes
/// it in the next time it comes to the front. Nothing here leaves the device.
enum ListInbox {
    struct ListName: Codable, Identifiable, Equatable, Hashable {
        var id: UUID
        var name: String
    }

    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        /// The list to put it on; when nil, a new list named `newListName`.
        var listID: UUID?
        var newListName = ""
        var title: String
        var memo = ""
        var link = ""
        var place = ""
        var createdAt = Date()
    }

    struct Contents: Codable, Equatable {
        var lists: [ListName] = []
        var entries: [Entry] = []
    }

    private static let service = "io.github.reiji55.threedays.inbox"
    private static let account = "inbox"

    /// The shared keychain group, as written into Info.plist at build time (team prefix included).
    private static var group: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "HormeInboxGroup") as? String,
              !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }

    private static func query() -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        if let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }

    static func read() -> Contents {
        var request = query()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let contents = try? decoder.decode(Contents.self, from: data) else { return Contents() }
        return contents
    }

    @discardableResult
    static func write(_ contents: Contents) -> Bool {
        guard let data = try? encoder.encode(contents) else { return false }
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query() as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query()
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    /// The app: tell the share sheet which lists there are. Written only when they changed.
    static func publish(_ lists: [ListName]) {
        var contents = read()
        guard contents.lists != lists else { return }
        contents.lists = lists
        write(contents)
    }

    /// The share extension: leave one shared thing for the app.
    static func add(_ entry: Entry) -> Bool {
        var contents = read()
        contents.entries.append(entry)
        return write(contents)
    }

    /// The app: take what was shared, leaving the inbox empty.
    static func take() -> [Entry] {
        var contents = read()
        guard !contents.entries.isEmpty else { return [] }
        let entries = contents.entries
        contents.entries = []
        return write(contents) ? entries : []
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }()
}

/// What a shared page or place becomes on a list: its name, link and (for a map) place.
enum SharedContent {
    /// Hosts whose links are places on a map.
    static func isMap(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host.contains("maps.apple") || host.hasPrefix("maps.google") || host == "maps.app.goo.gl"
            || (host.hasSuffix("google.com") && url.path.hasPrefix("/maps")) || (host == "goo.gl" && url.path.hasPrefix("/maps"))
    }

    /// A name for the shared thing: the text without its link, else the place a map link names, else the site.
    static func title(text: String, url: URL?) -> String {
        var cleaned = text
        if let url { cleaned = cleaned.replacingOccurrences(of: url.absoluteString, with: "") }
        let lines = cleaned.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("http://") && !$0.hasPrefix("https://") }
        if let first = lines.first { return String(first.prefix(120)) }
        if let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let name = components.queryItems?.first(where: { $0.name == "q" || $0.name == "name" })?.value, !name.isEmpty {
            return name
        }
        return url?.host ?? ""
    }
}
