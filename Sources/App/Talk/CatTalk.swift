import Foundation
import UIKit

// MARK: - 跟它说话：唯一入口
//
// 三个入口（Siri 语音、App 内输入框、以后可能的手表）都走这一个函数，
// 免得「Siri 说的一个反应、打字说的另一个反应」。
//
// 一次说话做六件事，顺序是有讲究的：
//   ① 小窗在播 → 猫当场抬头看你      ← 这是「实时反馈」唯一能落进小窗的地方
//   ② 头顶垫一句「它听见了…」        ← 等模型的那一秒，画面不能空着
//   ③ 要一句回话（问真 AI，约 1 秒）
//   ④ 回话写到「该显示什么」里        ← 帧泵下一帧就把它画进画面
//   ⑤ 有画面就不弹横幅（v35 起）      ← 见下
//   ⑥ 有灵动岛就顺手在岛上留一句      ← 没有硬件就静默跳过
//
// ★★ ④⑤ 的现状（v35，2026-10-21，别按旧结论行事）：
//
//   v32/v33 的 ④ 是「合成器叠字」，连着两版「点开就闪退」，已废。
//   v34 把 ④ 整个关掉、退回系统播片 —— App 能开了，但小窗里没有字。
//
//   v35 换了条路：**画面不再交给系统播，而是我们自己一帧帧喂**
//   （`LiveFramePump` + `AVSampleBufferDisplayLayer`）。字直接画在帧上，
//   跟画面是同一张图，**没有合成器**。详见 LiveFramePump.swift 文件头。
//
//   ⇒ ⑤ 才敢改成「有画面就不弹横幅」：字已经在画面上了，再弹一条就是重复打扰。
//     但只在**画面真在**的时候省掉（App 在前台 / 小窗在播），
//     否则（Siri 唤起但小窗没跟）通知仍然是唯一能把话递到眼前的东西。

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

        // ② 头顶先垫一句。等模型要一秒，这一秒里画面不能空着。
        //    壳没挂上的时候这句看不见，但也不亏 —— 回话一到就把它换掉。
        SayBubble.shared.say("它听见了…", seconds: 60)

        // ③ 要一句回话。真 AI 优先；问不到（断网 / 没钥匙 / 模型抽风）
        //    就掉回本地那套 —— 它永远不会不回你。
        let reply = await CatBrain.replyFromCloud(to: m, catName: name)
                    ?? CatBrain.reply(to: m, catName: name)

        if let d = defaults,
           let data = try? JSONEncoder().encode(Turn(mine: m, reply: reply, at: Date())) {
            d.set(data, forKey: key)
        }

        // ④ 回话写进「该显示什么」。帧泵下一帧就把它画进画面，
        //    房间和小窗是同一块图层 —— 那边看得见，这边就看得见。
        SayBubble.shared.say(reply)

        // ⑤ 有画面就不弹横幅。
        //
        // ★ 判「有没有画面」，不是一个无脑开关：
        //   · 小窗在播 → 有画面
        //   · App 在前台 → 房间就摆在屏幕上，也有画面
        //   两者都没有（Siri 在后台唤起、小窗这次没跟出来）⇒ 画面不在，
        //   只有通知能把这句话递到他眼前。
        //
        // ★ 实时流没开（退回 v34 播法）时，画面里根本没有字，
        //   那就必须发 —— 否则他什么都收不到。
        let onScreen = Cfg.liveFramePiP
            && ((PiPController.shared?.active ?? false)
                || (UIApplication.shared.applicationState == .active))
        if !onScreen {
            Notifier.tellReply(reply, catName: name)
        }

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
