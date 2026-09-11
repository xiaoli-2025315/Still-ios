import Foundation
import SwiftUI

// MARK: - 还在 Still · iOS 全局常量
//
// 这里的数值不是随便定的，是从 Android v1.23 的 PetEngine 逐条搬过来的。
// 两个平台必须共用同一套语义，否则它们就是两个不同的产品。

enum Cfg {

    // App Group：主 App 和小组件之间唯一的通道。
    // ⚠️ 上 Xcode 后必须把这个前缀换成你自己的 Team ID，
    //    并在 Signing & Capabilities 里给 App 和 Widget 两个 target 都加上 App Groups。
    static let appGroup = "group.com.still.app"

    /// ★ 版本号只在这一处定义。
    ///   App 的状态栏和小组件里的排障文字都读它 —— 装完一眼就能确认是哪个包。
    ///   此前两边各写各的（App 写 v9、组件里躺着一个写死的 v6），
    ///   光看版本号根本分不清扩展是不是新的。
    ///   这个文件同时编进主 App 和 Widget Extension（见 project.yml），所以两边都读得到。
    static let version = "v15"

    // MARK: 纵深（v1.23：z 是引擎的第三坐标，不是渲染层的滤镜）
    static let zNear: Float = 0.04     // 它自己能走到最近的地方
    static let zFar: Float  = 0.60     // 它自己最远只退到这儿（再远就快看不见了）
    static let zDefault: Float = 0.12
    static let depthK: Float = 2.2     // scale = 1 / (1 + 2.2z)
    static let depthAlpha: Float = 0.26 // alpha = 1 - 0.26z

    // MARK: 召回
    static let recallRate = 0.68       // 喊它，68% 概率它会来。不是 bug，是设计。

    // MARK: 时间
    static let tickHz: Double = 30.0   // 引擎主循环 30fps（Android 是 80ms/12.5fps，iOS 上可以更细）
    static let stayHoursMin: Double = 1.0   // 在一个组件里待 1.0 ~ 3.4 小时
    static let stayHoursMax: Double = 3.4
    static let samePageRate = 0.78     // 不出页的时候，78% 在本页里换组件 —— 这才叫穿梭，不是翻页

    /// 跨页时有多大概率优先挑「最久没去过的那几个」。
    ///
    /// 为什么需要它：纯随机游走在「7 天 81 次访问 / 16 个房间」下**必然**漏掉一两个，
    /// 这是统计规律，调 homePull 调不好。漏掉的那个组件就永远显示「它还没来过」——
    /// 一块死组件，留痕也无从谈起。加了它以后 7 天覆盖率才稳在 16/16。
    static let freshBias = 0.50
    static let freshPool = 4           // 从最久没去过的 4 个里挑一个

    // MARK: 灵动岛
    // 岛是「第 17 个房间」，和组件同级：在岛里的时候，任何组件都不画猫。
    static let islandRate = 0.14       // 14% 的停留会先去岛上待一会儿
    static let islandHoursMin: Double = 0.15   // 9 分钟
    static let islandHoursMax: Double = 0.60   // 36 分钟（别太长：岛独占它，组件就空了）

    // MARK: 小组件
    /// 一次 reload 往后排多少小时。
    /// 这是唯一性 vs 可见性的调节旋钮（数据见 Tools/_uniqueness.js）：
    ///   覆盖 24h → 看不见它 0.1%
    ///   覆盖  6h → 看不见它 0.5%（刷新少时 1.6%）
    /// 无论取哪个，「两个组件同时有猫」都是 0.0000%。
    /// 取 8 是因为它远大于最坏刷新间隔（预算最紧时约 4 小时一次），
    /// 又不至于让「行程表被改写」的风险窗口太长 —— 虽然行程表本来就不可改写。
    static let widgetCoverHours: Double = 8

    /// 它在别的页逛久了会回第 0 页。
    /// 没有这一条的话，随机游走会把它困在某页好几天不回家 ——
    /// 而第 0 页正是你打开 App 看到的那一屏。它会「不在家」，这不对。
    ///
    /// ⚠️ 下面这三个数是跑参数扫描扫出来的（Still-iOS/Tools/_tune.js），别凭感觉改。
    ///   ⚠️⚠️ 凡是改动 build() 里 rnd() 的调用**次数**，整条随机序列就会错开，
    ///   之前扫出来的数全部作废，必须重跑 _tune.js。
    ///   2026-09-03 已经因为这个翻过一次车：岛从「整段」改成「段开头一小段」之后
    ///   多消耗了一次 rnd()，跨页率从 22.7% 悄悄涨到 30.9%，7 天开始漏组件。
    ///
    /// 当前这组（0.06 / 0.78 / freshBias 0.50）：
    ///   跨页 19.3%   7 天漏组件 0.0 个   第 0 页占时 38.2%
    /// 对照（同一次扫描里的失败组合）：
    ///   0.10 / 0.70 → 跨页 30.2%，变成看翻页动画
    ///   0.24 / 0.85 → 第 0 页占时 69.5%，基本不出门了
    static let homePull = 0.06

    // MARK: 走路
    static let walkSecPerUnit: Double = 9.0  // Android: animDur = dist * 9000ms
    static let walkSecMin: Double = 0.6
    static let walkSecMax: Double = 6.0
    static let depthCost: Float = 0.55       // 纵深走得慢，时长只按 0.55 折算

    // MARK: 动作时长（秒）—— 和走路一样，不跟着时间倍速压缩
    static let actSec: [Act: ClosedRange<Double>] = [
        .sleep:   9.0...16.0,
        .groom:   4.2...7.2,
        .stretch: 2.1...2.8,
        .hunt:    2.5...3.1,
        .sit:     4.0...8.0,
        .look:    2.5...4.1
    ]

    // MARK: 配色（沿用设计系统）
    enum Palette {
        static let bg       = Color(hex: 0xFAF6F0)
        static let accent   = Color(hex: 0xC97B4E)  // 赤陶
        static let honey    = Color(hex: 0xE0A458)
        static let sage     = Color(hex: 0x8FA38A)
        static let twilight = Color(hex: 0x2F4060)
        static let ink      = Color(hex: 0x6B5D50)
        static let faint    = Color(hex: 0xA08878)

        // 毛毡猫
        static let fur      = Color(hex: 0xE3D3C3)
        static let furDeep  = Color(hex: 0xC9B7A4)
        static let inner    = Color(hex: 0xE8B4A0)
        static let line     = Color(hex: 0x6B5D50)
    }
}

// MARK: - 动作

enum Act: String, CaseIterable, Codable {
    case sleep, groom, stretch, hunt, sit, look

    var label: String {
        switch self {
        case .sleep:   return "睡觉"
        case .groom:   return "舔毛"
        case .stretch: return "伸懒腰"
        case .hunt:    return "扑着玩"
        case .sit:     return "坐着发呆"
        case .look:    return "抬头张望"
        }
    }

    var pose: CatPose {
        switch self {
        case .sleep:   return .sleep
        case .groom:   return .groom
        case .stretch: return .stretch
        case .hunt:    return .crouch
        case .sit:     return .sit
        case .look:    return .look
        }
    }
}

// MARK: - 引擎状态（对齐 Android 的 state 字符串）

enum PetState: String, Codable {
    case idle, sleep, walk
    var label: String {
        switch self {
        case .sleep: return "睡着了"
        case .walk:  return "溜达中"
        case .idle:  return "趴着"
        }
    }
}

// MARK: - 小组件类型（房间）

enum RoomKind: String, Codable {
    case still, clock, weather, photo, notes, music, podcast,
         cal, remind, health, maps, album, battery, short, world, timer
}

struct Room: Identifiable, Codable, Hashable {
    let id: String          // "clock" 等，同时是持久化 key
    let name: String
    let kind: RoomKind
    var page: Int
    var col: Int            // 1...4
    var row: Int            // 1...6
    var w: Int              // 占几列
    var h: Int              // 占几行
    var tintHex: Int

    // 组件内部：猫可以站的位置（相对组件的归一化坐标）
    // 由 id 确定性推导，保证每次打开位置一致 —— 这是"它住在这儿"的一部分
    var spot: CGPoint {
        var r = SeededRandom(seed: FNV.hash(id))
        return CGPoint(x: 0.26 + 0.48 * CGFloat(r.next()),
                       y: 0.52 + 0.26 * CGFloat(r.next()))
    }
}

// MARK: - 16 个组件（从 still-ios-widgets.html 原样搬过来）

enum Rooms {
    static let all: [Room] = [
        Room(id: "still",   name: "还在",     kind: .still,   page: 0, col: 1, row: 1, w: 4, h: 2, tintHex: 0xC97B4E),
        Room(id: "clock",   name: "时钟",     kind: .clock,   page: 0, col: 1, row: 3, w: 2, h: 2, tintHex: 0x9A7482),
        Room(id: "weather", name: "天气",     kind: .weather, page: 0, col: 3, row: 3, w: 2, h: 2, tintHex: 0x6E8CA3),
        Room(id: "photo",   name: "照片",     kind: .photo,   page: 0, col: 1, row: 5, w: 2, h: 2, tintHex: 0xB08A5E),
        Room(id: "notes",   name: "备忘录",   kind: .notes,   page: 0, col: 3, row: 5, w: 2, h: 2, tintHex: 0xA6975F),

        Room(id: "music",   name: "音乐",     kind: .music,   page: 1, col: 1, row: 1, w: 2, h: 2, tintHex: 0x7E7396),
        Room(id: "podcast", name: "播客",     kind: .podcast, page: 1, col: 3, row: 1, w: 2, h: 2, tintHex: 0x8A6E63),
        Room(id: "cal",     name: "日历",     kind: .cal,     page: 1, col: 1, row: 3, w: 2, h: 2, tintHex: 0xB26B5E),
        Room(id: "remind",  name: "提醒",     kind: .remind,  page: 1, col: 3, row: 3, w: 2, h: 2, tintHex: 0x7E9070),
        Room(id: "health",  name: "健康",     kind: .health,  page: 1, col: 1, row: 5, w: 2, h: 2, tintHex: 0xC08A72),
        Room(id: "maps",    name: "地图",     kind: .maps,    page: 1, col: 3, row: 5, w: 2, h: 2, tintHex: 0x6E9078),

        Room(id: "album",   name: "相册",     kind: .album,   page: 2, col: 1, row: 1, w: 4, h: 2, tintHex: 0xA9865F),
        Room(id: "battery", name: "电池",     kind: .battery, page: 2, col: 1, row: 3, w: 2, h: 2, tintHex: 0x7E9070),
        Room(id: "short",   name: "快捷指令", kind: .short,   page: 2, col: 3, row: 3, w: 2, h: 2, tintHex: 0x6E8CA3),
        Room(id: "world",   name: "世界时钟", kind: .world,   page: 2, col: 1, row: 5, w: 2, h: 2, tintHex: 0x8A7E96),
        Room(id: "timer",   name: "计时器",   kind: .timer,   page: 2, col: 3, row: 5, w: 2, h: 2, tintHex: 0xB0895E)
    ]

    static let byId: [String: Room] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    static let home = byId["still"]!      // 「还在」组件 = 它名义上的家

    static func rooms(onPage p: Int) -> [Room] { all.filter { $0.page == p } }
    static let pageCount = 3
}

// MARK: - 确定性随机
// 猫的行为必须可复现：同一个时刻打开，它在同一个地方做同一件事。
// 这是「概率在时间里，不在 App 手里」的实现前提。

struct SeededRandom {
    private var state: UInt64

    init(seed: UInt32) { state = UInt64(seed) }

    /// splitmix64。`&+` / `&*` 是 Swift 的 wrapping 运算符，溢出不会 trap。
    mutating func next() -> Double {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        return Double(z >> 11) / Double(1 << 53)
    }

    mutating func int(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() * Double(n)) % n }
    mutating func range(_ r: ClosedRange<Double>) -> Double {
        r.lowerBound + next() * (r.upperBound - r.lowerBound)
    }
    mutating func bool(_ p: Double) -> Bool { next() < p }
}

// FNV-1a：把 "clock" 这样的字符串变成种子
enum FNV {
    static func hash(_ s: String) -> UInt32 {
        var h: UInt32 = 2166136261
        for b in s.utf8 { h ^= UInt32(b); h = h &* 16777619 }
        return h
    }
}

// MARK: - 工具

extension Color {
    init(hex: Int, alpha: Double = 1.0) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8)  & 0xFF) / 255.0,
                  blue:  Double( hex        & 0xFF) / 255.0,
                  opacity: alpha)
    }
}

extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { Swift.min(Swift.max(self, lo), hi) }
}
extension Float {
    func clamped(_ lo: Float, _ hi: Float) -> Float { Swift.min(Swift.max(self, lo), hi) }
}
extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}
extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(self, lo), hi) }
}
