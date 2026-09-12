import Foundation
import AppIntents

// MARK: - 行程表：唯一真相
//
// 这个文件是整个 iOS 版的核心，比猫画得好不好看重要得多。
//
// 它要解决的问题只有一句话：
//   **同一时刻，桌面上有且只有一个组件里有猫。**
//
// 难在哪：小组件是系统渲染的静态快照，各实例刷新时刻由系统决定（一天 72 次预算），
// 它们之间没法约好「你先空着，我再亮」。
//
// 破法：不要让它们互相商量，让它们各自算同一个答案。
//   · 行程表是确定性的、持久化的 —— App 和小组件读到的是同一份数据
//   · 每个组件按行程表预排一条 timeline，entry 落在「猫进出我这个房间」的切换点上
//   · 于是任意时刻 T，所有组件的答案都来自同一个 place(T)，只有一个回答 true
//
// 关键取舍：timeline 末尾一律放一个「不画猫」的兜底 entry。
//   → 失败方向必须是「看不见它」，绝不能是「两个地方都有它」。
//
// ⚠️ 行程表一旦生成就**绝不中途改写**（重置除外）。
//   改写会让已经下发到各组件的 timeline 与新表矛盾，那才会真的出现两个猫。

// MARK: - 它在哪儿

enum Place: Equatable {
    case room(String)
    case island

    var isIsland: Bool { if case .island = self { return true }; return false }
    var roomId: String? { if case .room(let id) = self { return id }; return nil }
}

// MARK: - 行程表的一段

struct Segment: Codable {
    let t0: Double              // 起始时刻。**绝对小时**（Unix epoch / 3600），不是相对量
    let t1: Double
    let roomId: String          // 这一段时间它待在哪个组件
    let nextRoomId: String      // 下一段去哪
    /// 这一段开头它在灵动岛里待多久（小时）。0 = 不进岛。
    /// 岛是「第 17 个房间」，和组件同级 —— 在岛里的时候，任何组件都不画猫。
    let islandHours: Double

    var islandUntil: Double { t0 + islandHours }
    var contains: ClosedRange<Double> { t0...t1 }
}

// MARK: - 行程表

enum Schedule {

    static let seedString = "still-ios-widgets"
    static let backHours: Double = 26      // 往前多算一点，时光机能往回看
    static let spanHours: Double = 600     // 往后算 25 天
    static let extendWhenLeft: Double = 96 // 剩余不足 4 天就往后续
    /// 行程表周期。= spanHours：相邻周期首尾相接、不重叠。
    /// 有它，「任何进程自己算同一份表」才不会在边界处给出两个答案。
    static let cycleHours: Double = spanHours

    /// 绝对小时。所有时间计算都用这个单位，别再混用相对小时。
    static var hourEpoch: Double { Date().timeIntervalSince1970 / 3600.0 }

    // MARK: 读 —— 唯一入口

    /// ★ App / 小组件 / 灵动岛只认这一个函数。
    ///
    /// 以前是「App 算好存进 App Group，小组件去读」。一旦 App Group 不通
    /// （自签名下高概率），小组件读到 nil 就整片空白 ——
    /// 用户除了打开 App 本体，哪儿都看不见它，违反「它一定在被看见的某处」。
    ///
    /// 改成谁都能算、且算出来必然是同一份：
    /// build() 是确定性的（同 seed + 同起点 + 同样一串时长 = 逐字节相同），
    /// 只要把起点也钉死在 cycleHours 网格上，任何进程在任意时刻算，
    /// 只要落在同一周期，得到的就是同一份表。
    static func resolve() -> [Segment] {
        deterministic(atHour: hourEpoch, seed: SharedStore.loadSeed())
    }

    /// 周期 N 的表覆盖 [N*cycleHours, (N+1)*cycleHours)：首尾相接、不重叠。
    static func deterministic(atHour h: Double, seed: UInt32?) -> [Segment] {
        let n = floor(h / cycleHours)
        let t0 = n * cycleHours
        return build(from: t0, to: t0 + cycleHours,
                     startRoom: "weather",
                     seed: seed ?? FNV.hash(seedString))
    }

    /// 兼容旧调用点：语义等价于 resolve()（不再依赖共享存储）。
    @discardableResult
    static func ensure() -> [Segment] { resolve() }

    /// 往后续。**只追加，绝不重写已有的段** ——
    /// 重写已下发的段会让旧 timeline 与新表矛盾，那才会出现两个猫。
    @discardableResult
    static func extendIfNeeded(_ segs: inout [Segment]) -> Bool {
        let h = hourEpoch
        guard let last = segs.last, last.t1 - h < extendWhenLeft else { return false }
        let more = build(from: last.t1,
                         to: last.t1 + spanHours,
                         startRoom: last.nextRoomId,
                         seed: FNV.hash(last.nextRoomId + "@\(Int(last.t1))"))
        segs.append(contentsOf: more)
        SharedStore.saveSchedule(segs)
        return true
    }

    /// 重置 = 换一个 seed。
    /// ★ 关键：「读不到就用默认 seed」这条规则对 App 和小组件是对称的 ——
    ///   存进去了（App Group 通）两边都读到新 seed；没存进去（不通）两边都用默认。
    ///   所以无论哪种情况，所有进程算出的都是同一份表，唯一性不崩。
    @discardableResult
    static func reset() -> [Segment] {
        SharedStore.saveSeed(UInt32.random(in: 1...UInt32.max))
        return resolve()
    }

    private static func covers(_ s: [Segment], _ h: Double) -> Bool {
        guard let f = s.first, let l = s.last else { return false }
        return f.t0 <= h && l.t1 > h + 2
    }

    // MARK: 生成（确定性）

    static func build(from t0Hour: Double, to tEndHour: Double,
                      startRoom: String,
                      seed: UInt32 = FNV.hash(Schedule.seedString)) -> [Segment] {
        var r = SeededRandom(seed: seed)
        var list: [Segment] = []
        var t = t0Hour
        var cur = startRoom
        var lastSeen: [String: Double] = [:]     // 每个房间它最后一次离开的时刻

        while t < tEndHour {
            let dur = r.range(Cfg.stayHoursMin...Cfg.stayHoursMax)
            let curPage = Rooms.byId[cur]?.page ?? 0

            // 在别的页逛久了会回第 0 页（见 Cfg.homePull 的注释）。
            // 判的是「不在第 0 页」，不是「不在 still 组件」——
            // 否则它在自己那一页里也会被反复拽回 still，另外 4 个组件就没人去了。
            let target: String
            if curPage != Rooms.home.page && r.bool(Cfg.homePull) {
                target = Rooms.home.id
            } else {
                let samePage = Rooms.all.filter { $0.page == curPage && $0.id != cur }
                let anyOther = Rooms.all.filter { $0.id != cur }

                let pool: [Room]
                if r.bool(Cfg.samePageRate) && !samePage.isEmpty {
                    pool = samePage
                } else if r.bool(Cfg.freshBias) {
                    // 优先去最久没去过的那几个 —— 保证没有组件永远空着（见 Cfg.freshBias）
                    pool = Array(anyOther
                        .sorted { (lastSeen[$0.id] ?? -1e9) < (lastSeen[$1.id] ?? -1e9) }
                        .prefix(Cfg.freshPool))
                } else {
                    pool = anyOther
                }
                target = pool.isEmpty ? Rooms.home.id : pool[r.int(pool.count)].id
            }

            let islandHours = r.bool(Cfg.islandRate)
                ? r.range(Cfg.islandHoursMin...Cfg.islandHoursMax)
                : 0

            // 末段截断到 tEndHour：相邻周期才能首尾相接、不重叠。
            // 否则同一时刻会同时落进两份表的重叠区，唯一性就崩了。
            list.append(Segment(t0: t, t1: min(t + dur, tEndHour), roomId: cur,
                                nextRoomId: target, islandHours: islandHours))
            lastSeen[cur] = t
            t += dur
            cur = target
        }
        return list
    }

    // MARK: 查询 —— App / 小组件 / 灵动岛只认这一个答案

    static func segment(_ segs: [Segment], atHour h: Double) -> Segment? {
        for s in segs where h >= s.t0 && h < s.t1 { return s }
        return nil
    }

    static func place(_ segs: [Segment], atHour h: Double) -> Place {
        guard let s = segment(segs, atHour: h) else { return .room(Rooms.home.id) }
        if s.islandHours > 0 && h < s.islandUntil { return .island }
        return .room(remap(s.roomId, atHour: h, segT0: s.t0))
    }

    // MARK: 房间范围映射
    //
    // 段里写的房间，可能是你根本没摆的那个组件 —— 直接照着显示的话，
    // 你扫一遍桌面一个猫都看不见，等于它消失了（用户原话）。
    // 所以这里把它挪到「你已经摆出来的某一间」里去。
    //
    // ★ 为什么不在 build() 里就只生成范围内的房间：
    //   build() 里 rnd() 的调用次数一变，整条随机序列就错位，
    //   之前跑参数扫描扫出来的那组数（homePull / samePageRate / freshBias）全部作废。
    //   而映射是确定性函数：给定「段 + 小时」，无论谁算、算几次，结果都一样。
    //
    // ★ 唯一性不受影响：place(T) 仍然只有一个返回值，所有进程算的是同一个。

    static func remap(_ roomId: String, atHour h: Double, segT0: Double) -> String {
        let scope = RoomScope.active(atHour: h)
        if scope.isEmpty || scope.contains(roomId) { return roomId }
        let idx = Int(FNV.hash(roomId + "@\(Int(segT0))") % UInt32(scope.count))
        return scope[idx]
    }

    static func placeNow(_ segs: [Segment], offsetHours: Double = 0) -> Place {
        place(segs, atHour: hourEpoch + offsetHours)
    }

    // MARK: 给小组件的 timeline

    /// 这个房间里「猫在 / 不在」发生变化的所有时刻
    static func boundaries(_ segs: [Segment], in range: ClosedRange<Double>) -> [Double] {
        var out: [Double] = []
        for s in segs {
            if s.t0 > range.lowerBound && s.t0 < range.upperBound { out.append(s.t0) }
            if s.islandHours > 0 {
                let ix = s.islandUntil
                if ix > range.lowerBound && ix < range.upperBound { out.append(ix) }
            }
        }
        return out.sorted()
    }

    /// 排一条 timeline：只放入「有变化」的 entry，末尾放兜底。
    ///
    /// 一天挪窝约 11 次，所以单个组件 8 小时的 timeline 里通常只有 2~4 个 entry。
    /// 极轻量 —— Apple DTS 原话：预算限制的是 reload 次数（72/天），entry 数量不限。
    static func moments(forRoom roomId: String,
                        segs: [Segment],
                        from now: Date = Date(),
                        coverHours: Double = Cfg.widgetCoverHours) -> [RoomMoment] {
        let h0 = now.timeIntervalSince1970 / 3600.0
        // ★ 绝不跨周期边界：跨了的话，这条 timeline 里「未来」的 entry 用的是旧周期的表，
        //   到点后别的组件已经换到新周期的表 —— 那才会真的出现两只猫。
        //   截断到边界，走完让系统按 .atEnd 再要一条（那时算的是新周期）。
        let cycleEnd = (floor(h0 / cycleHours) + 1) * cycleHours
        let hEnd = min(h0 + coverHours, cycleEnd)

        var out: [RoomMoment] = [
            RoomMoment(date: now, here: place(segs, atHour: h0) == .room(roomId))
        ]
        for b in boundaries(segs, in: h0...hEnd) {
            let here = place(segs, atHour: b + 1e-6) == .room(roomId)
            if Optional(here) != out.last?.here {
                out.append(RoomMoment(date: Date(timeIntervalSince1970: b * 3600.0), here: here))
            }
        }
        // 兜底：timeline 走完后一律不画猫。
        out.append(RoomMoment(date: Date(timeIntervalSince1970: hEnd * 3600.0), here: false))
        return out
    }

    /// 它上一次来这个房间是什么时候（留痕用）
    static func lastVisit(_ segs: [Segment], roomId: String, before h: Double) -> Date? {
        let scope = RoomScope.active(atHour: h)
        var best = -1.0
        for s in segs where s.t1 <= h {
            // 留痕也要跟着映射走，否则「上次来」指的是一个你从不看的房间
            let r = remap(s.roomId, atHour: h, segT0: s.t0)
            if r == roomId { best = max(best, s.t1) }
        }
        return best > 0 ? Date(timeIntervalSince1970: best * 3600.0) : nil
    }
}

/// timeline 上的一个时刻：那一刻猫在不在我这个房间里
struct RoomMoment {
    let date: Date
    let here: Bool
}

// MARK: - 组件配置：用户长按编辑时选「这个组件是哪个房间」
//
// WidgetKit 不告诉组件自己是第几个 —— Apple 文档原话：
// "users can add multiple instances... your provider needs a way to differentiate which instance"
// 唯一办法就是让用户选。这一步没法自动化，是 iOS 的硬交互。

enum RoomOption: String, AppEnum, CaseIterable {
    case still, clock, weather, photo, notes, music, podcast,
         cal, remind, health, maps, album, battery, short, world, timer

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "房间" }

    static var caseDisplayRepresentations: [RoomOption: DisplayRepresentation] {
        [
            .still:   DisplayRepresentation(title: "还在"),
            .clock:   DisplayRepresentation(title: "时钟"),
            .weather: DisplayRepresentation(title: "天气"),
            .photo:   DisplayRepresentation(title: "照片"),
            .notes:   DisplayRepresentation(title: "备忘录"),
            .music:   DisplayRepresentation(title: "音乐"),
            .podcast: DisplayRepresentation(title: "播客"),
            .cal:     DisplayRepresentation(title: "日历"),
            .remind:  DisplayRepresentation(title: "提醒"),
            .health:  DisplayRepresentation(title: "健康"),
            .maps:    DisplayRepresentation(title: "地图"),
            .album:   DisplayRepresentation(title: "相册"),
            .battery: DisplayRepresentation(title: "电池"),
            .short:   DisplayRepresentation(title: "捷径"),
            .world:   DisplayRepresentation(title: "世界时钟"),
            .timer:   DisplayRepresentation(title: "计时器"),
        ]
    }

    var roomId: String { rawValue }
}

struct SelectRoomIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "它是哪个房间"
    static var description = IntentDescription("决定这个组件代表它的哪一个房间")

    @Parameter(title: "房间", default: .clock)
    var room: RoomOption

    // 显式写两个 init：一个是 Swift 的默认成员构造，
    // 一个是 WidgetKit 在组件库里创建预置时要用的无参构造。
    init() { self.room = .clock }
    init(room: RoomOption) { self.room = room }

    static var parameterSummary: some ParameterSummary {
        Summary("这个组件是 \(\.$room)")
    }
}
