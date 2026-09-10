import Foundation

// MARK: - 房间范围：它只在你真正摆出来的那几个组件之间跑
//
// 用户的话：「装了几个组件＝几个房间，猫只在这些房间跑，后加的扩大范围；
//            它起码得在我放置的一个房间里，或者是灵动岛。」
//
// 难点：WidgetKit 不告诉小组件「你是第几个」，也不告诉它「用户一共摆了几个」。
//       所以不能靠谁去统计，只能让每个组件**自报**：我在桌面上，我是房间 X。
//
// 破法：自报 + 整点生效。
//   · 每个组件每次排 timeline 时顺手写一笔「我是 X，我还在」（best-effort）
//   · 24 小时没再报的房间（组件被删了）自动出局
//
// ★★ 为什么必须「整点生效」—— 这是唯一性的命门。
//    App 和小组件是两个进程，各自算 place(T)。只要它们在同一时刻问「它现在在哪」
//    得到的集合不同，就会算出两个答案 → 屏幕上出现两只猫。
//    所以集合不是「读到什么用什么」，而是「**这个小时**生效的那一版」：
//    报告写进去之后，要到下一个整点才对所有进程可见。
//    一旦进入某小时，这一版集合就不再变化 —— 于是谁算都一样。
//
// ★ 兜底是安全的：App Group 不通时，两边都读不到任何报告 → 都用 fallback
//   → 算出来的必然是同一份（和 Schedule.resolve 里 seed 的对称规则是同一招）。

enum RoomScope {

    /// 一个报告都没收到时的默认范围。
    /// 就是小组件库里预置的那五张卡 —— 你摆的几乎一定是这五个里的。
    static let fallback: [String] = ["still", "clock", "weather", "photo", "notes"]

    /// 报告多久算过期：24 小时。≈ 组件被删掉之后一天，范围自动收缩回去。
    static let validHours: Double = 24

    private static let reportKey = "still.scope.report.v1"

    /// 小组件自报。写不进去（App Group 不通）也没关系 —— 见 active 的兜底。
    static func report(roomId: String) {
        guard let d = UserDefaults(suiteName: Cfg.appGroup) else { return }
        var m = (d.dictionary(forKey: reportKey) as? [String: Double]) ?? [:]
        // 用相对小时存没意义 —— 一律存绝对小时，跨进程、跨时区都一致
        m[roomId] = Date().timeIntervalSince1970 / 3600.0
        d.set(m, forKey: reportKey)
    }

    /// 某一时刻生效的房间集合。**任何进程在同一小时问，答案必须逐字相同。**
    static func active(atHour h: Double) -> [String] {
        guard let d = UserDefaults(suiteName: Cfg.appGroup),
              let m = d.dictionary(forKey: reportKey) as? [String: Double]
        else { return fallback }

        let H = floor(h)
        let live = m.filter { $0.value <= H && $0.value > H - validHours }
                    .keys
                    .filter { Rooms.byId[$0] != nil }
                    .sorted()
        return live.isEmpty ? fallback : live
    }

    /// 给面板显示用：让用户一眼看出「抽屉通不通」。
    /// 通 = 显示你摆出来的房间；不通 = 显示默认五个。
    static func isLive() -> Bool {
        guard let d = UserDefaults(suiteName: Cfg.appGroup),
              let m = d.dictionary(forKey: reportKey) as? [String: Double]
        else { return false }
        let H = floor(Date().timeIntervalSince1970 / 3600.0)
        return m.contains { $0.value <= H && $0.value > H - validHours }
    }
}
