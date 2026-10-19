import Foundation

// MARK: - 「猫脑」
//
// 把你说的话翻成它的回话。两条路：
//
//   ① replyFromCloud —— 真 AI（台子上的模型）。**优先走它。**
//   ② reply          —— 本地那套规则匹配。**只在①拿不到时才用**，
//                       不是因为它好，是因为它一定能给出一句。
//
// ★ 为什么留着②：断网、台子没钥匙、模型抽风，这些随时会发生。
//   对一个「它要一直在」的东西，**不回话比回错话严重得多** ——
//   你不知道它是没听见还是不在了。所以①失败必须静默掉到②，
//   一句「（蹭了蹭你）」也比什么都不出现好。

enum CatBrain {

    /// 真 AI 住在哪儿。台子地址，跟网页壳用的是同一个。
    ///
    /// ★ https 是必须的不是讲究：iOS 默认不许 App 连 http。
    private static let cloudURL = URL(
        string: "https://still-ui-design.app.workbuddy.host/api/cat/chat")!

    /// 等多久算「没等到」。
    ///
    /// 实测模型回一句约 1 秒；给到 8 秒是为了地铁、电梯这种弱网也能等到，
    /// 再长就不等了 —— Siri 那边你举着手机干等，比回一句普通的更难熬。
    private static let cloudTimeout: TimeInterval = 8

    /// 问真 AI。**拿不到就返回 nil**（不是抛错）—— 调用方自己掉回本地那套。
    static func replyFromCloud(to message: String, catName: String) async -> String? {
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else { return nil }

        let payload: [String: Any] = ["msg": m, "history": []]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        var req = URLRequest(url: cloudURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = cloudTimeout
        req.httpBody = body

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            // 不是 2xx 就当没问到 —— 台子 500 / 网关拦了 / 钥匙没插，都走这条路。
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["ok"] as? Bool == true,
                  let text = json["reply"] as? String else { return nil }
            let r = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return r.isEmpty ? nil : r
        } catch {
            // 断网 / 超时 / 证书问题，一律当「这次没问到」，不惊动任何人。
            return nil
        }
    }

    /// 本地那套：规则匹配（你好 / 吃饭 / 想你 / 名字…）+ 兜底随机一句猫味的话。
    /// message：你对它说的话；catName：它现在叫什么（用于「我叫 XX」这类回话）
    static func reply(to message: String, catName: String) -> String {
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = m.lowercased()

        if m.isEmpty { return "（它歪着头看你）" }

        if s.contains("在吗") || s.contains("在哪") || s.contains("你哪")
            || s.contains("在么") || s.contains("zaina") {
            return "（尾巴尖动了动）我一直都在呀"
        }
        if s.contains("你好") || s.contains("hi") || s.contains("hello")
            || s.contains("嗨") || s.contains("在吗") {
            return "喵～（用脑袋蹭了蹭屏幕）"
        }
        if s.contains("吃饭") || s.contains("饿") || s.contains("吃吗") {
            return "（盯着你）你吃的时候，也分我一口"
        }
        if s.contains("睡") || s.contains("困") || s.contains("累") || s.contains("休息") {
            return "（打了个哈欠）我刚眯了一会儿"
        }
        if s.contains("想你") || s.contains("喜欢") || s.contains("爱") || s.contains("想我") {
            return "（踩了你两下）我也是"
        }
        if s.contains("名字") || s.contains("叫什么") || s.contains("称呼") {
            return "我叫\(catName)。记住啦"
        }
        if s.contains("回家") || s.contains("接你") {
            return "（小跑着过来了）"
        }

        // 兜底：随机一句猫味的话
        let pool = [
            "（伸了个懒腰）",
            "（蹭了蹭你）",
            "喵～",
            "（在屏幕上留下一个爪印）",
            "（歪头看你）",
            "（翻了个身，肚皮朝上）"
        ]
        return pool[Int.random(in: 0..<pool.count)]
    }
}
