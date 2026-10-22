import Foundation

public struct TaskImport {
    public var tasks: [TaskItem]
    public var warnings: [String]
}

/// Reads the existing task-3days tasks.txt format without contacting its server.
public enum TaskTextImporter {
    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> TaskImport {
        var result = TaskImport(tasks: [], warnings: [])
        var day: Date?
        var validSection = false
        var index: Int?
        for (offset, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("//") { continue }
            if line.hasPrefix("# ") {
                index = nil
                let key = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if key == "いつでも" || key.lowercased() == "anytime" {
                    day = nil; validSection = true
                } else {
                    let fields = key.split(separator: "-").compactMap { Int($0) }
                    if fields.count == 3 {
                        var c = DateComponents()
                        c.year = fields[0]; c.month = fields[1]; c.day = fields[2]; c.hour = 12
                        let date = calendar.date(from: c)
                        if let date,
                           calendar.component(.year, from: date) == fields[0],
                           calendar.component(.month, from: date) == fields[1],
                           calendar.component(.day, from: date) == fields[2] {
                            day = date; validSection = true
                        } else { validSection = false }
                    } else { validSection = false }
                    if !validSection { result.warnings.append("\(offset + 1)行目：日付を読み取れませんでした。") }
                }
                continue
            }
            if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
                index = nil
                guard validSection else {
                    result.warnings.append("\(offset + 1)行目：日付の見出しがないため取り込みませんでした。")
                    continue
                }
                let body = String(line.dropFirst(6))
                let fields = body.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                let hasFields = fields.count >= 4
                let title = hasFields ? fields.dropFirst(3).joined(separator: " | ") : body
                guard !title.trimmingCharacters(in: .whitespaces).isEmpty else {
                    result.warnings.append("\(offset + 1)行目：タイトルが空です。")
                    continue
                }
                func value(_ text: String) -> String { text == "-" ? "" : text }
                result.tasks.append(TaskItem(
                    title: title, plannedAt: day,
                    scheduledTime: hasFields ? value(fields[0]) : "",
                    kind: hasFields ? value(fields[1]) : "",
                    project: hasFields ? value(fields[2]) : "",
                    createdAt: now.addingTimeInterval(Double(offset)),
                    completedAt: line.hasPrefix("- [ ] ") ? nil : now
                ))
                index = result.tasks.count - 1
                continue
            }
            guard let i = index else {
                result.warnings.append("\(offset + 1)行目：読み取れない行があります。")
                continue
            }
            if line.hasPrefix("memo:") {
                let note = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                result.tasks[i].memo += (result.tasks[i].memo.isEmpty ? "" : "\n") + note
            } else if line.hasPrefix("next:") || line.hasPrefix("引き継ぎ:") {
                let note = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                result.tasks[i].handoff += (result.tasks[i].handoff.isEmpty ? "" : "\n") + note
            } else if line == "must: 1" {
                result.tasks[i].isMust = true
            } else {
                result.warnings.append("\(offset + 1)行目：対応していない補足行です。")
            }
        }
        return result
    }

    public static func merge(_ incoming: [TaskItem], into existing: [TaskItem], calendar: Calendar = .current) -> [TaskItem] {
        func signature(_ task: TaskItem) -> String {
            let day = task.plannedAt.map { String(calendar.startOfDay(for: $0).timeIntervalSince1970) } ?? "anytime"
            return [day, task.scheduledTime, task.project, task.title].joined(separator: "\u{001F}")
        }
        var seen = Set(existing.map(signature))
        var merged = existing
        for task in incoming where seen.insert(signature(task)).inserted { merged.append(task) }
        return merged
    }
}
