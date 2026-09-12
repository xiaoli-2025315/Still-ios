import Foundation
// 向系统问「桌面上摆了哪几张卡」只有 App 做。扩展里不做这次跨进程询问。
#if !WIDGET_EXT
import WidgetKit
#endif

// MARK: - 房间范围：它只在你真正摆出来的那几个组件之间跑
//
// 用户的话：「装了几个组件＝几个房间，猫只在这些房间跑，后加的扩大范围；
//            它起码得在我放置的一个房间里，或者是灵动岛。」
//           「如果这个猫他不在画中画中，他肯定就在某个小组件中呀」。
//
// 难点：WidgetKit 不告诉小组件「你是第几个」，也不告诉它「用户一共摆了几个」。
//
// ★★ 后来找到了正门（这是这个文件存在的理由）：
//    WWDC20《Meet WidgetKit》原话 ——
//      "You can use the WidgetCenter APIs from within your app process or
//       extension to reload your timeline ... and you can retrieve the list
//       of **current configurations**."
//    → `WidgetCenter.currentConfigurations()` 拿到的是「桌面上真的摆着的那几张卡」
//      及其 AppIntent 配置（房间里选的是哪间）。
//    → **不需要 App Group，不需要任何 entitlement。**
//
//    ⚠️ 但它在**扩展进程**里要 **iOS 18.0** 起（编译期实测的硬限制，见
//       refreshFromSystem 的注释）。17.x 的机器拿不到，只能退回下面的自报。
//
//    这条是唯一性的救命绳：所有组件在同一时刻问系统，拿到的是**同一份配置**，
//    于是各自算出的 place(T) 也必然是同一个 → 桌面上永远只有一只猫，
//    而且**用户摆出来的那几间里必定有一间有猫**（他不会再看到「全都是空房间」）。
//
// 自报（下面那段）保留着：App Group 若能通，它比系统配置更"新鲜"（24 小时过期）。
// 但它是次要的 —— 自签下常常读不到，不能当主路。

enum RoomScope {

    /// 一个「已摆房间」都问不到时的默认范围。
    /// 就是小组件库里预置的那五张卡 —— 纯兜底，正常情况下走不到这里。
    static let fallback: [String] = ["still", "clock", "weather", "photo", "notes"]

    /// 报告多久算过期：24 小时。≈ 组件被删掉之后一天，范围自动收缩回去。
    static let validHours: Double = 24

    private static let reportKey = "still.scope.report.v1"
    private static let renderKey = "still.widget.renders.v1"
    private static let probeKey = "still.probe.v1"

    // MARK: - ★ 正门：问系统

    /// 从系统问出来的「你桌面上摆了哪几间」。
    ///
    /// 进程内缓存：一次 timeline 生成里 `active()` 会被调很多次，只需问一次系统。
    /// 它对**所有组件实例**是同一份（都来自系统配置），所以不影响唯一性。
    private static var systemScope: [String] = []

    /// 我们自己的组件 kind。
    ///
    /// ★ 只有 `StillWidget` —— 它才是「一个房间」。
    ///   探针（StillProbeWidget）不算：它是 StaticConfiguration，没有房间可报，
    ///   也不会出现在这里的匹配结果里（它的 configuration 不是 SelectRoomIntent）。
    private static let ourKinds: Set<String> = ["StillWidget"]

    /// 在生成 timeline 之前调一次。失败就保持原样，绝不把已有的范围弄丢。
    ///
    /// ★★ 只在 **iOS 18.0+** 的扩展里可用 —— 这是编译期实测出来的：
    ///     `'currentConfigurations()' is only available in application extensions
    ///      for iOS 18.0 or newer`
    ///     （主 App 里更早就有，但**扩展进程**里要 18.0 起。工程 target 是 17.0，
    ///      所以必须显式加 `#available`，否则直接编译不过。）
    ///   17.x 的机器拿不到这份名单 → 保持原样，退回「组件自报 / 默认五间」，
    ///   不会更糟。
    ///
    /// 为什么把 scope / 房间有效性都校验一遍：桌面上的组件可能是旧版本留下的、
    /// 或者房间列表改过名 —— 落进 `Rooms.byId` 里查不到的 id 会让猫无处可去。
    static func refreshFromSystem() async {
#if !WIDGET_EXT
        guard #available(iOS 18.0, *) else { return }

        // ★ 一个进程里只问一次。
        //   这是一次跨进程调用，而且是在**系统正等着我们出结果**的时候发的
        //   （生成 timeline 的那一下）。问第二遍没有任何新信息 ——
        //   同一个进程的生命周期里，桌面上摆着哪几张卡不会变。
        //   少问一次，就少一次「扩展卡住 → 被系统杀掉」的机会。
        guard systemScope.isEmpty else { return }

        guard let infos = try? await WidgetCenter.shared.currentConfigurations() else { return }

        var ids: [String] = []
        for info in infos where ourKinds.contains(info.kind) {
            guard let intent = info.configuration as? SelectRoomIntent else { continue }
            let id = intent.room.roomId
            if Rooms.byId[id] != nil { ids.append(id) }
        }

        let uniq = Array(Set(ids)).sorted()
        if !uniq.isEmpty { systemScope = uniq }
#endif
    }

    /// 面板显示用：这一版范围是从哪儿来的。
    static var scopeSource: String {
        if !systemScope.isEmpty { return "系统配置" }
        if isLive() { return "组件自报" }
        return "默认五间"
    }

    // MARK: - 自报（App Group 通的时候才有）

    /// 小组件自报。写不进去（App Group 不通）也没关系 —— 见 active 的兜底。
    static func report(roomId: String) {
        guard let d = UserDefaults(suiteName: Cfg.appGroup) else { return }
        var m = (d.dictionary(forKey: reportKey) as? [String: Double]) ?? [:]
        // 用相对小时存没意义 —— 一律存绝对小时，跨进程、跨时区都一致
        m[roomId] = Date().timeIntervalSince1970 / 3600.0
        d.set(m, forKey: reportKey)

        // 顺手记一次「我渲染过」—— 这是判断小组件到底跑没跑的唯一证据。
        // App 面板里显示这个数：0 = 扩展压根没被系统加载；>0 = 代码跑了，问题在别处。
        d.set(d.integer(forKey: renderKey) + 1, forKey: renderKey)
    }

    /// 小组件被系统渲染过多少次。
    static func renderCount() -> Int {
        UserDefaults(suiteName: Cfg.appGroup)?.integer(forKey: renderKey) ?? 0
    }

    /// App Group 自己能不能写进去再读出来。
    /// 只能证明这个容器可用，**不能**证明和另一个进程共享 —— 那要看 renderCount。
    static func probe() -> Bool {
        guard let d = UserDefaults(suiteName: Cfg.appGroup) else { return false }
        d.set("ok", forKey: probeKey)
        return d.string(forKey: probeKey) == "ok"
    }

    // MARK: - 生效范围

    /// 某一时刻生效的房间集合。**任何进程在同一小时问，答案必须逐字相同。**
    ///
    /// 三级：系统配置 → 组件自报 → 默认五间。
    /// 三条路拿到的都是「所有进程一致」的东西 —— 这是唯一性的前提。
    static func active(atHour h: Double) -> [String] {
        // ① 正门：桌面上真的摆着的那几间
        if !systemScope.isEmpty { return systemScope }

        // ② App Group 里的自报（自签下大概率读不到）
        if let d = UserDefaults(suiteName: Cfg.appGroup),
           let m = d.dictionary(forKey: reportKey) as? [String: Double] {
            let H = floor(h)
            let live = m.filter { $0.value <= H && $0.value > H - validHours }
                        .keys
                        .filter { Rooms.byId[$0] != nil }
                        .sorted()
            if !live.isEmpty { return live }
        }

        // ③ 兜底
        return fallback
    }

    /// 给面板显示用：让用户一眼看出「抽屉通不通」。
    static func isLive() -> Bool {
        guard let d = UserDefaults(suiteName: Cfg.appGroup),
              let m = d.dictionary(forKey: reportKey) as? [String: Double]
        else { return false }
        let H = floor(Date().timeIntervalSince1970 / 3600.0)
        return m.contains { $0.value <= H && $0.value > H - validHours }
    }
}
