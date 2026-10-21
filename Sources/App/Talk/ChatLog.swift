import Foundation

/// 完整的对话记录，存在手机里。
///
/// ★ 以前 iOS 这边只留「最后一句」—— 关掉页面就翻不到了。
///   安卓那边一直是存着全部（最多 300 轮），「聊天记录」那一页就是读它。
///   这一版补上：说过的每一轮都进这里，Siri 说的、通知里说的也算。
enum ChatLog {

    struct Row: Codable, Identifiable {
        var id: String = UUID().uuidString
        var you: String
        var cat: String
        var at: Date = Date()
    }

    private static let key = "still.chat.log"
    private static let max = 300

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: SharedStore.suiteName) ?? UserDefaults.standard
    }

    static func all() -> [Row] {
        guard let d = defaults, let data = d.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Row].self, from: data)) ?? []
    }

    static func add(you: String, cat: String) {
        let y = you.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !y.isEmpty else { return }
        var rows = all()
        rows.append(Row(you: y, cat: cat))
        if rows.count > max { rows.removeFirst(rows.count - max) }
        guard let d = defaults, let data = try? JSONEncoder().encode(rows) else { return }
        d.set(data, forKey: key)
    }

    static func clear() {
        defaults?.removeObject(forKey: key)
    }
}
