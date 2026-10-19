import Foundation

// MARK: - 跟它说话：唯一入口
//
// 三个入口（Siri 语音、App 内输入框、以后可能的手表）都走这一个函数，
// 免得「Siri 说的一个反应、打字说的另一个反应」。
//
// 一次说话做三件事，顺序是有讲究的：
//   ① 小窗在播 → 猫当场抬头看你      ← 这是「实时反馈」唯一能落进小窗的地方
//   ② 回话走通知                     ← 小窗里贴不了字，通知是唯一能把字送到你眼前的通道
//   ③ 有灵动岛就顺手在岛上留一句     ← 没有硬件就静默跳过
//
// ★ 为什么回话不能进小窗：
//   小窗里是一段 mp4，屏幕是系统在放带子，我们插不进手。
//   要让字出现在小窗里，只能把画面改成「自己一帧帧画」——那是另一件事，不在这一版。

enum CatTalk {

    /// 最近一次对话。App 打开时能看见刚才说了什么、它怎么回的。
    struct Turn: Codable {
        var mine: String
        var reply: String
        var at: Date
    }

    private static let key = "still.talk.last"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: SharedStore.suiteName) }

    static func last() -> Turn? {
        guard let d = defaults, let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Turn.self, from: data)
    }

    /// 说一句。返回它的回话。
    @discardableResult
    static func say(_ message: String) -> String {
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = SharedStore.load().catName ?? "还在"
        let reply = CatBrain.reply(to: m, catName: name)

        if let d = defaults,
           let data = try? JSONEncoder().encode(Turn(mine: m, reply: reply, at: Date())) {
            d.set(data, forKey: key)
        }

        // ① 小窗里的猫当场有反应。
        //    失败也不影响后面两步 —— 它在后台被冻着的时候就收不到这一条，
        //    这种时候只能靠通知，不能指望画面。
        onMain { PiPController.shared?.reactToTalk() }

        // ② 回话。
        Notifier.tellReply(reply, catName: name)

        // ③ 灵动岛。没有硬件时 IslandBridge 内部自己会跳过。
        onMain { IslandBridge.shared.speak(reply: reply, catName: name) }

        return reply
    }

    /// 后台被 Siri 唤起时，Intent 跑在哪个线程不保证。
    /// @Published 的状态和 AVPlayer 的切换都得在主线程上做。
    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() }
        else { DispatchQueue.main.async(execute: work) }
    }
}
