import Foundation

/// What was being typed and not yet added, kept when the screen it was typed on goes away (another tab, a sheet
/// swiped down, the app closed), and put back when the screen comes again. A draft is let go once it is added, or
/// after a day untouched.
enum Drafts {
    private static let prefix = "horme.draft."
    private static let lifetime: TimeInterval = 24 * 3600

    static func text(_ key: String, now: Date = Date()) -> String {
        let defaults = UserDefaults.standard
        guard let saved = defaults.dictionary(forKey: prefix + key),
              let text = saved["text"] as? String, let at = saved["at"] as? Double else { return "" }
        if now.timeIntervalSince1970 - at > lifetime {
            defaults.removeObject(forKey: prefix + key)
            return ""
        }
        return text
    }

    static func save(_ key: String, _ text: String, now: Date = Date()) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UserDefaults.standard.removeObject(forKey: prefix + key)
        } else {
            UserDefaults.standard.set(["text": text, "at": now.timeIntervalSince1970], forKey: prefix + key)
        }
    }

    static func clear(_ key: String) { UserDefaults.standard.removeObject(forKey: prefix + key) }
}
