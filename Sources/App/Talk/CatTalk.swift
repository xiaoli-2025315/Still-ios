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
    ///
    /// ★ 顺序是有讲究的，别调换：
    ///   **先让猫抬头，再去问 AI 要那句回话。**
    ///   抬头是「它听见了」，必须在你说完的那一瞬间发生 —— 等一秒再动，
    ///   你感觉到的就不是「它在听」，是「它愣了一下」。
    ///   而回话本来就要等模型（约 1 秒），这一秒里猫已经在看你了，刚好。
    ///
    /// ★ 为什么是 async：回话要去问真 AI，那一下有网络等待。
    ///   Siri 那边能 await（Intent 的 perform 本身就是异步的），
    ///   界面那边用 Task 包一下，都不影响「抬头」那一帧。
    @discardableResult
    static func say(_ message: String) async -> String {
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = SharedStore.load().catName ?? "还在"

        // ① 小窗里的猫当场有反应。
        //    壳在 → 直接换画面，一秒都不用等。
        //    壳不在 → 也让画面上那一下发生：屋里那块图层和壳是同一个播放器，
        //             下次壳挂上来，接到的正好是「刚抬头」这一下。
        withController { pip in
            if pip.reactToTalk() { return }
            pip.reactRegardless()
        }

        // ② 要一句回话。真 AI 优先；问不到（断网 / 没钥匙 / 模型抽风）
        //    就掉回本地那套 —— 它永远不会不回你。
        let reply = await CatBrain.replyFromCloud(to: m, catName: name)
                    ?? CatBrain.reply(to: m, catName: name)

        if let d = defaults,
           let data = try? JSONEncoder().encode(Turn(mine: m, reply: reply, at: Date())) {
            d.set(data, forKey: key)
        }

        // ③ 回话。
        Notifier.tellReply(reply, catName: name)

        // ④ 灵动岛。没有硬件时 IslandBridge 内部自己会跳过。
        onMain { IslandBridge.shared.speak(reply: reply, catName: name) }

        return reply
    }

    /// 后台被 Siri 唤起时，Intent 跑在哪个线程不保证。
    /// @Published 的状态和 AVPlayer 的切换都得在主线程上做。
    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() }
        else { DispatchQueue.main.async(execute: work) }
    }

    /// 等壳的就位了再动手。
    ///
    /// ★ 冷启动时（App 已经被系统回收）Siri 这一下会先把 App 拉起来，
    ///   而 `PiPController.shared` 是 ContentView.onAppear 才赋值的 ——
    ///   前台回来那一瞬它还是 nil。不重试的话，**第一句话会静默丢掉**，
    ///   表现就是「说了没反应，反而是第二句就好了」，很难归因。
    private static func withController(retries: Int = 8, _ work: @escaping (PiPController) -> Void) {
        let step = {
            if let pip = PiPController.shared { work(pip); return }
            guard retries > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                withController(retries: retries - 1, work)
            }
        }
        if Thread.isMainThread { step() } else { DispatchQueue.main.async(execute: step) }
    }
}
