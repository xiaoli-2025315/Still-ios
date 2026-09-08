import Foundation

// MARK: - 本地「猫脑」
//
// 把你说的话翻成它的回话。这是 v0.1 的占位实现：
//   规则匹配（你好 / 吃饭 / 想你 / 名字…）+ 兜底随机一句猫味的话。
// 之后要接真 AI，只换下面这一个函数即可 —— UI / 灵动岛 / Siri 入口都不用动。

enum CatBrain {

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
