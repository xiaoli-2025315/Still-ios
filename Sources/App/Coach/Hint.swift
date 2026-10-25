import Foundation
import UIKit

// MARK: - 隐性能力发现的「唯一闸门」
//
// 跟安卓 `com.still.app.hint.Hint` 是同一套规则（他那句话：「安卓改完 iOS 也要一样改」）。
//
// ★★ 三条硬的：
//  1. **所有线索必须从这一个门过**，谁都不许自己判断。
//     这是唯一能防住"以后越加越多、到处弹"的地方。
//  2. **没有票据演不出来**。`能不能演()` 通过才发一张一次性 `票`，
//     `演()` 只收票 —— 业务代码自己造不出票（构造器是 fileprivate），
//     ⇒ 想绕过闸门直接弹，编译期就过不去。
//  3. **配额是全局的**：「动作 3 次/天」是**一天总共演 3 次**，
//     不是每个玩法各 3 次（十个玩法各 3 次 = 30 次，那是轰炸）。
//
// ★ 出任何岔子一律**少提示**。宁可它不演，也不能变成骚扰。

enum HintKind: String {
    case 文字        // 它开口说一句话（占"一天一条"的额度）
    case 动作        // 它自己演一个动作，一个字都不说
    case 彩蛋        // 稀有动作，7–10 天一次
    case 痕迹        // 空页面写成的痕迹（常驻，不占额度）
}

/// 能被"发现"的玩法。★ 想加新玩法必须先在这里加一项 ——
/// 用枚举（不许传字符串）就是为了堵死"随手加一句提示"这条路。
enum HintPlay: String, CaseIterable {
    case 拎起来, 拖走, 摸头, 长按, 打字
}

/// 演完之后的结果。★ 由 `报()` 唯一写入。
enum HintResult: String {
    case 没接住      // 演了 5 秒他没反应 ⇒ 冷却 3 天
    case 做了半步    // 他动了但没做完 ⇒ 正信号，不算失败
    case 发现了      // 做完了 ⇒ 这个玩法从此永久沉默
}

/// 一次性票据。**没有它演不出来。**
struct HintTicket {
    fileprivate let nonce: UInt64
    private var used = false

    fileprivate init(_ n: UInt64) { nonce = n }

    /// 用掉，只能用一次。
    mutating func 用掉() -> Bool {
        if used { return false }
        used = true
        return true
    }
}

/// 当下的处境（调用方如实填）。
struct HintMoment {
    var 有活在跑 = false      // 生成 / 下载 / 抠像 —— 有进度在跑一律不许打扰
    var 在打字 = false        // 键盘弹着
    var 夜里 = false          // 23:00–08:00 且不是他自己主动打开的
    var 首见 = false          // 刚装好，还没过新手期
}

enum Hint {

    /// 总开关。出事了能一键全停（不留这个口子，真出问题只能发版）。
    static var 全都别演 = false

    private static let SP = "still_hint"
    private static var 演着呢 = false
    private static var 计数: UInt64 = 0

    // ───────────────────────────── 闸门

    /// 这一步能不能演。**返回 nil 就是不许演**，调用方什么都不许干。
    static func 能不能演(_ k: HintKind, _ p: HintPlay?, _ m: HintMoment) -> HintTicket? {
        if 全都别演 { return nil }
        let d = UserDefaults.standard

        // ① 环境类硬性禁止
        if m.在打字 { return nil }                       // 抢焦点最招人烦
        if m.有活在跑 { return nil }                     // 他已有明确目标
        if m.夜里 { return nil }                         // 深夜安静优先
        // ★ 新手期只禁"文字"。动作类允许首见演一次 ——
        //   最该让他看见"这猫会动"的时刻，恰恰就是第一次见面。
        if m.首见 && k != .动作 { return nil }

        let 现在墙 = Date().timeIntervalSince1970

        // ② 时钟被改回去了 ⇒ 静默一整天（防止靠改时间刷线索）
        let 见过最大 = d.double(forKey: "墙_最大")
        if 见过最大 > 0 && 现在墙 < 见过最大 - 300 {
            d.set(现在墙 + 86400, forKey: "静默到")
            return nil
        }
        if 现在墙 > 见过最大 { d.set(现在墙, forKey: "墙_最大") }

        // ③ 全局静默期（任一条线索演过之后，歇 4 小时）
        let 静默到 = d.double(forKey: "静默到")
        if 静默到 > 0 && 现在墙 < 静默到 { return nil }

        // ④ 同一时刻只能演一个（全局并发锁）
        if k != .痕迹 && 演着呢 { return nil }

        // ⑤ 这个玩法已经会了 ⇒ 永不再提（"说过一次就永远闭嘴"）
        if let p, d.bool(forKey: "会了_" + p.rawValue) { return nil }

        if k == .痕迹 { 计数 += 1; return HintTicket(计数) }   // 痕迹常驻，不占额度

        switch k {
        case .文字:
            // 一天 1 条、一周 2 条、一生 4 条；两条之间至少隔 4 小时
            if 今天(d, "文字") >= 1 { return nil }
            if 距上次(d, "上次文字") < 4 * 3600 { return nil }
            if 本周(d, "文字本周") >= 2 { return nil }
            if d.integer(forKey: "文字一生") >= 4 { return nil }
        case .动作:
            // ★ 全局共享：一天总共 3 次，两次至少隔 2 小时
            if 今天(d, "动作") >= 3 { return nil }
            if 距上次(d, "上次动作") < 2 * 3600 { return nil }
        case .彩蛋:
            if 距上次(d, "上次彩蛋") < 7 * 86400 { return nil }
        case .痕迹:
            break
        }

        // ⑥ 同一个玩法最多提醒 3 回（不是"一生只有 1 次" ——
        //    他可能被别的事打断错过了，1 次太狠且没法补救）
        if let p, d.integer(forKey: "提醒过_" + p.rawValue) >= 3 { return nil }

        计数 += 1
        return HintTicket(计数)
    }

    /// 真正开演。只有拿着票才演得出来。
    @discardableResult
    static func 演(_ t: inout HintTicket) -> Bool {
        if !t.用掉() { return false }
        演着呢 = true
        return true
    }

    /// 演完了（或演砸了）都要调一次，把"演出位"还回来。
    static func 演完了() { 演着呢 = false }

    // ───────────────────────────── 汇报

    /// 汇报结果。**这是唯一能把"他学会了"记下来的地方。**
    static func 报(_ p: HintPlay, _ r: HintResult) {
        let d = UserDefaults.standard
        let 现在 = Date().timeIntervalSince1970

        if r == .发现了 {
            d.set(true, forKey: "会了_" + p.rawValue)          // ★★ 学会就永远闭嘴
        } else if r == .没接住 {
            // 没接住：冷却 3 天（不是永久放弃，也不是明天再来）
            d.set(现在 + 3 * 86400, forKey: "冷却到_" + p.rawValue)
        }
        // 做了半步 = 正信号，不惩罚，只记一次
        let n = d.integer(forKey: "提醒过_" + p.rawValue)
        d.set(n + 1, forKey: "提醒过_" + p.rawValue)
        d.set(现在 + 4 * 3600, forKey: "静默到")                 // 演过就歇 4 小时
        d.synchronize()
    }

    /// 记一笔"这一条演过了"（用来扣额度）。
    static func 记账(_ k: HintKind) {
        let d = UserDefaults.standard
        let 现在 = Date().timeIntervalSince1970
        switch k {
        case .文字:
            d.set(现在, forKey: "上次文字")
            d.set(今天(d, "文字") + 1, forKey: "文字")
            d.set(天序号(现在), forKey: "文字哪天")
            d.set(本周(d, "文字本周") + 1, forKey: "文字本周")
            d.set(周序号(现在), forKey: "文字本周_第几周")
            d.set(d.integer(forKey: "文字一生") + 1, forKey: "文字一生")
        case .动作:
            d.set(现在, forKey: "上次动作")
            d.set(今天(d, "动作") + 1, forKey: "动作")
            d.set(天序号(现在), forKey: "动作哪天")
        case .彩蛋:
            d.set(现在, forKey: "上次彩蛋")
        case .痕迹:
            break
        }
        d.synchronize()
    }

    /// 他学会了吗（学会了就什么都不用再演）。
    static func 会了吗(_ p: HintPlay) -> Bool {
        UserDefaults.standard.bool(forKey: "会了_" + p.rawValue)
    }

    // ───────────────────────────── 内部

    /// 距上一次记的时间过去了多少秒。
    private static func 距上次(_ d: UserDefaults, _ 键: String) -> TimeInterval {
        let t = d.double(forKey: 键)
        guard t > 0 else { return .greatestFiniteMagnitude }
        return Date().timeIntervalSince1970 - t
    }

    /// 今天已经演过几条（跨零点自动归零）。
    private static func 今天(_ d: UserDefaults, _ 键: String) -> Int {
        if d.integer(forKey: 键 + "哪天") != 天序号(Date().timeIntervalSince1970) { return 0 }
        return d.integer(forKey: 键)
    }

    private static func 本周(_ d: UserDefaults, _ 键: String) -> Int {
        if d.integer(forKey: 键 + "_第几周") != 周序号(Date().timeIntervalSince1970) { return 0 }
        return d.integer(forKey: 键)
    }

    /// 今天是第几天（用本地时区算，别自己加减 8 小时）。
    private static func 天序号(_ t: TimeInterval) -> Int {
        let c = Calendar.current
        let day = c.startOfDay(for: Date(timeIntervalSince1970: t))
        return Int(day.timeIntervalSince1970 / 86400)
    }

    private static func 周序号(_ t: TimeInterval) -> Int {
        let c = Calendar.current
        var comps = c.dateComponents([.yearForWeekOfYear, .weekOfYear],
                                      from: Date(timeIntervalSince1970: t))
        return (comps.yearForWeekOfYear ?? 0) * 100 + (comps.weekOfYear ?? 0)
    }
}

// MARK: - 时钟被改（回退 / 换时区）时保守处理：静默，别让线索乱冒
//
// ★ 这是专家清单里点名必补的一条：只看墙上时间的话，
//   把系统时间往前调一调，冷却期就全废了。

enum HintClockWatch {
    private static var 装了 = false

    static func 装上() {
        guard !装了 else { return }
        装了 = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.significantTimeChangeNotification,
                       object: nil, queue: .main) { _ in 静默() }
        nc.addObserver(forName: Notification.Name.NSSystemTimeZoneDidChange,
                       object: nil, queue: .main) { _ in 静默() }
        nc.addObserver(forName: Notification.Name.NSSystemClockDidChange,
                       object: nil, queue: .main) { _ in 静默() }
    }

    private static func 静默() {
        UserDefaults.standard.set(Date().timeIntervalSince1970 + 3600, forKey: "静默到")
        UserDefaults.standard.synchronize()
    }
}
