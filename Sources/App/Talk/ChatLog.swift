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
        /// ★ 2026-11-24：这条属于哪个会话（角色 id / g:群号）。老记录没有 ⇒ 默认 ""，谁都看得到。
        var ch: String = ""
        /// ★ 2026-11-24：群聊里这句是谁说的。
        var sp: String = ""
    }

    private static let key = "still.chat.log"
    /// ★ 2026-11-18：本地「清空」的时刻。台子上不删（那是永久档案），
    ///   只是从这一刻往前的不再往回拉 —— 否则清完一进页面又全回来，成了假清空。
    private static let clearedKey = "still.chat.cleared"
    private static let max = 300

    private static var defaults: UserDefaults? {
        // ★ 用 standard，不用 App Group：这份记录只有 App 自己要看，
        //   而自签重签后 App Group 有时会丢 —— 丢了记录就无声没了。
        UserDefaults.standard
    }

    static func all() -> [Row] {
        guard let d = defaults, let data = d.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Row].self, from: data)) ?? []
    }

    static func add(you: String, cat: String) {
        add(ch: "", sp: "", you: you, cat: cat)
    }

    /// ★ 2026-11-24：分会话记一轮（单聊带角色 id，群聊带 g: 会话号 + 说话人）。
    static func add(ch: String, sp: String = "", you: String, cat: String) {
        let y = you.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !y.isEmpty else { return }
        var rows = all()
        rows.append(Row(you: y, cat: cat, ch: ch, sp: sp))
        if rows.count > max { rows.removeFirst(rows.count - max) }
        guard let d = defaults, let data = try? JSONEncoder().encode(rows) else { return }
        d.set(data, forKey: key)
    }

    /// ★ 2026-11-24：只取某个会话的记录（老记录 ch="" 也带上，不凭空消失）。
    static func all(ch: String) -> [Row] {
        all().filter { $0.ch.isEmpty || $0.ch == ch }
    }

    /// 这台手机「清到」哪一刻。nil 表示从来没清过，台子的历史照常往回拉。
    static var 清到: Date? {
        guard let d = defaults,
              let t = d.object(forKey: clearedKey) as? Double, t > 0 else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    static func clear() {
        defaults?.removeObject(forKey: key)
        defaults?.set(Date().timeIntervalSince1970, forKey: clearedKey)
    }

    /// ★ 2026-11-18（第三档·永久全存）：把台子上那份永不淘汰的档案并进本地。
    ///
    /// 台子的钟和手机的钟不是同一个，同一条两边差几百毫秒，所以**不能**拿时间精确比对
    /// —— 那样每次进页面都会多出一份重复的。这里按
    /// 「你说的一样 + 它回的一样 + 时间相差不到 5 秒」判成同一条。
    /// 宁可少并（漏掉的下一轮还会再来），绝不重复显示。
    ///
    /// 本地仍然只留最近 300 轮；台子那边才是永久档案，手机不用背几万条。
    /// 返回真正并进去几条；0 表示本地本来就有、台子也没有更新的。
    @discardableResult
    static func merge(_ 外来: [(at: Date, you: String, cat: String)]) -> Int {
        guard !外来.isEmpty else { return 0 }
        var rows = all()
        var 新增 = 0
        let 底线 = 清到          // 清空之前的一律不要，否则「清空」形同虚设
        for r in 外来 {
            if let c = 底线, r.at <= c { continue }
            let 有 = rows.contains {
                abs($0.at.timeIntervalSince(r.at)) < 5 && $0.you == r.you && $0.cat == r.cat
            }
            if 有 { continue }
            rows.append(Row(you: r.you, cat: r.cat, at: r.at))
            新增 += 1
        }
        guard 新增 > 0 else { return 0 }
        rows.sort { $0.at < $1.at }
        if rows.count > max { rows.removeFirst(rows.count - max) }
        guard let d = defaults, let data = try? JSONEncoder().encode(rows) else { return 0 }
        d.set(data, forKey: key)
        return 新增
    }
}
