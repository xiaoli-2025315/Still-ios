import WidgetKit
import SwiftUI

// MARK: - 真的小组件
//
// ★ 这个文件解决的是整个 iOS 版最难的一条要求：
//   **同一时刻，桌面上有且只有一个组件里有猫。**
//
// 难点：小组件是系统渲染的静态快照，各实例刷新时刻由系统决定（一天 72 次预算），
//       它们之间没法互相商量。
//
// 破法：不让它们商量，让它们各自算同一个答案。
//
//   · 行程表是确定性算出来的：App 和小组件各自调 Schedule.resolve()，
//     得到逐字节相同的同一份 —— 不再依赖 App Group（自签名下它常常不通）
//   · 每个组件按行程表预排一条 timeline，entry 精确落在「猫进出我这个房间」的时刻
//     （一天挪窝约 11 次，所以 8 小时的 timeline 里通常只有 2~4 个 entry）
//   · 于是任意时刻 T，所有组件的答案都来自同一个 place(T)，只有一个回答 true
//
// 关键取舍：timeline 末尾一律放一个「不画猫」的兜底 entry。
//   → 失败方向必须是「看不见它」，绝不能是「两个地方都有它」。
//
// 实测（Tools/_uniqueness.js，16 组件 × 7 天 × 3 种子 × 1 分钟采样）：
//   两个组件同时有猫   0.0000%      （旧做法：2%~16%）
//   它暂时看不见       0.1% ~ 1.6%  （覆盖越短、刷新越少，越多）

// MARK: - Entry

enum WidgetState {
    /// 它现在就在这个房间里
    case here(pose: CatPose, since: Date)
    /// 它不在这儿。lastVisit 是它上一次来是什么时候（留痕）
    case away(lastVisit: Date?)
    /// 用户还没打开过 App，行程表还没生成
    case noHome
}

/// 它这会儿在哪儿。
/// ★ 不管猫在不在「我」这一间，用户都有权知道 —— 「可寻址」是七条原理之一。
///   以前只有打开 App 才说，现在每个组件上都写，扫一眼桌面就知道去哪儿找它。
struct WhereNow {
    let label: String      // "日历" / "灵动岛"
    let isIsland: Bool
}

struct StillWidgetEntry: TimelineEntry {
    let date: Date
    let state: WidgetState
    let roomName: String
    /// 它现在在哪儿。给默认值，旧调用点不用跟着改。
    var whereNow: WhereNow? = nil
}

// MARK: - Provider
//
// ★ 用的是最老、最稳的 TimelineProvider（iOS 14 就有），**不是** AppIntent 那一套。
//   原因：AppIntentConfiguration 依赖 AppIntentsMetadata，重签时一旦元数据没被正确保留，
//   整个扩展渲染不出来 —— 实测就是「组件库里的预览图也是一片空白」。
//   房间不再让用户长按编辑去选：**一个组件天生就是一间房**（见下方 RoomWidget）。

struct RoomTimelineProvider: TimelineProvider {

    let roomId: String

    private var roomName: String { Rooms.byId[roomId]?.name ?? "" }

    func placeholder(in context: Context) -> StillWidgetEntry {
        StillWidgetEntry(date: Date(), state: .away(lastVisit: nil), roomName: roomName)
    }

    func getSnapshot(in context: Context, completion: @escaping (StillWidgetEntry) -> Void) {
        RoomScope.report(roomId: roomId)
        completion(entry(at: Date()))
    }

    func getTimeline(in context: Context,
                     completion: @escaping (Timeline<StillWidgetEntry>) -> Void) {
        let now = Date()
        // 自报家门：告诉别的进程「这个房间有组件在桌面上」。
        // 它只在你摆出来的房间之间跑，靠的就是每个组件各自报这一笔（见 RoomScope）。
        RoomScope.report(roomId: roomId)

        let segs = Schedule.resolve()
        let moments = Schedule.moments(forRoom: roomId, segs: segs, from: now)

        let entries = moments.map { m -> StillWidgetEntry in
            let h = m.date.timeIntervalSince1970 / 3600.0
            let wn = whereNow(segs: segs, atHour: h)
            if m.here {
                let seg = Schedule.segment(segs, atHour: h)
                let since = seg.map { Date(timeIntervalSince1970: $0.t0 * 3600.0) } ?? m.date
                return StillWidgetEntry(date: m.date,
                                        state: .here(pose: pose(at: m.date), since: since),
                                        roomName: roomName,
                                        whereNow: wn)
            }
            return StillWidgetEntry(date: m.date,
                                    state: .away(lastVisit: Schedule.lastVisit(segs, roomId: roomId, before: h)),
                                    roomName: roomName,
                                    whereNow: wn)
        }

        // .atEnd：走完最后一条就再要一条新的。
        // 预算用尽时它会停在最后那条（兜底的「不在这儿」）—— 这是安全的失败方向。
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func entry(at date: Date) -> StillWidgetEntry {
        let segs = Schedule.resolve()
        let h = date.timeIntervalSince1970 / 3600.0
        let here = Schedule.place(segs, atHour: h) == .room(roomId)
        let wn = whereNow(segs: segs, atHour: h)
        if here, let seg = Schedule.segment(segs, atHour: h) {
            return StillWidgetEntry(date: date,
                                    state: .here(pose: pose(at: date),
                                                 since: Date(timeIntervalSince1970: seg.t0 * 3600.0)),
                                    roomName: roomName,
                                    whereNow: wn)
        }
        return StillWidgetEntry(date: date,
                                state: .away(lastVisit: Schedule.lastVisit(segs, roomId: roomId, before: h)),
                                roomName: roomName,
                                whereNow: wn)
    }

    /// 它这会儿在哪个房间 —— 在灵动岛里也算一间（第 17 间）。
    private func whereNow(segs: [Segment], atHour h: Double) -> WhereNow {
        switch Schedule.place(segs, atHour: h) {
        case .island:
            return WhereNow(label: "灵动岛", isIsland: true)
        case .room(let id):
            return WhereNow(label: Rooms.byId[id]?.name ?? "—", isIsland: false)
        }
    }

    /// 姿势确定性决定：同一个房间的同一个时刻，看几次都是同一个姿势。
    /// 不用随机数 —— 否则每次重绘都在抖。
    private func pose(at date: Date) -> CatPose {
        let quarter = Int(date.timeIntervalSince1970 / 900)
        var r = SeededRandom(seed: FNV.hash(roomId) ^ UInt32(truncatingIfNeeded: quarter))
        return [CatPose.sleep, .sit, .groom, .look][r.int(4)]
    }
}

// MARK: - 小组件本体
//
// 一个组件 = 一间房，天生就是，不需要用户长按编辑去选房间名。
// 摆几个，它的活动范围就是几间（见 RoomScope）。

struct RoomWidget: Widget {
    var roomId: String

    // ★ Widget 协议强制要求一个无参 init（报错 "protocol requires initializer 'init()'"），
    //   所以带参数的组件必须**显式**把它写出来，光靠成员逐一初始化是不够的。
    init() { self.roomId = Rooms.home.id }
    init(roomId: String) { self.roomId = roomId }

    private var name: String { Rooms.byId[roomId]?.name ?? "还在" }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StillRoom-\(roomId)",
                            provider: RoomTimelineProvider(roomId: roomId)) { entry in
            StillWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("还在 · \(name)")
        .description("它的一个房间。多摆几个，它就会在它们之间穿梭。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - 探针组件（排障专用）
//
// 这一片里**只有一行字**，不读行程表、不画猫、不碰 App Group。
// 如果连它都是空白 → 小组件扩展整体没被加载（重签时插件没签上），
// 跟我们的代码无关，只能重装 / 换签名工具；
// 如果它能显示字，而房间组件空白 → 问题在我们这边，继续查。
//
// 定位清楚了就可以删掉这整个 struct。

struct ProbeEntry: TimelineEntry {
    let date: Date
}

struct ProbeProvider: TimelineProvider {
    func placeholder(in context: Context) -> ProbeEntry { ProbeEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (ProbeEntry) -> Void) {
        completion(ProbeEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ProbeEntry>) -> Void) {
        completion(Timeline(entries: [ProbeEntry(date: Date())],
                            policy: .after(Date().addingTimeInterval(1800))))
    }
}

struct StillProbeWidget: Widget {
    let kind = "StillProbe"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ProbeProvider()) { entry in
            VStack(alignment: .leading, spacing: 3) {
                Text("还在")
                    .font(.system(size: 13, weight: .medium, design: .serif))
                Text("探针正常")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(12)
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("还在 · 探针")
        .description("只有一行字。它也是空白＝小组件扩展没被加载，重装 App 即可。")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct StillWidgetBundle: WidgetBundle {
    var body: some Widget {
        RoomWidget(roomId: "still")      // 它的家
        RoomWidget(roomId: "clock")      // 时钟
        RoomWidget(roomId: "weather")    // 天气
        RoomWidget(roomId: "photo")      // 照片
        RoomWidget(roomId: "notes")      // 备忘录
        StillProbeWidget()               // 排障用，定位完可删
        StillLiveActivity()              // 灵动岛 + 锁屏横幅
    }
}

// MARK: - 视图

struct StillWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: StillWidgetEntry

    var body: some View {
        switch entry.state {
        case .here(let pose, let since): here(pose: pose, since: since)
        case .away(let last):            away(lastVisit: last)
        case .noHome:                    noHome
        }
    }

    // MARK: 它在这儿

    private func here(pose: CatPose, since: Date) -> some View {
        link {
            HStack(spacing: 10) {
                CatView(pose: pose, width: family == .systemMedium ? 66 : 50)
                VStack(alignment: .leading, spacing: 2) {
                    Text("在").font(.system(size: 9)).foregroundStyle(.secondary)
                    Text(entry.roomName)
                        .font(.system(size: family == .systemMedium ? 19 : 15,
                                      weight: .medium, design: .serif))
                        .lineLimit(1)
                    Text("待了 \(since, format: .relative(presentation: .numeric))")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(family == .systemMedium ? 15 : 13)
        }
    }

    // MARK: 它不在这儿
    //
    // 留痕照留，但**要说清楚它现在在哪儿**。
    // 以前是「找不到它是正常的，自己翻别的组件去」—— 结果用户摆的房间里
    // 一只也看不见，等于它消失了。现在每个组件上都写「它现在在 ××」，
    // 扫一眼桌面就知道去哪儿找（可寻址）。

    private func away(lastVisit: Date?) -> some View {
        link {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    PawMark(color: Cfg.Palette.accent)
                        .frame(width: 11, height: 11)
                        .opacity(0.45)
                    Text(entry.roomName)
                        .font(.system(size: 13, weight: .medium, design: .serif))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let w = entry.whereNow {
                    Text("它现在在")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(w.label)
                        .font(.system(size: 12, weight: .medium, design: .serif))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                } else if let last = lastVisit {
                    Text("上次来")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(last, format: .relative(presentation: .named))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("它还没来过")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 还没接它回家

    private var noHome: some View {
        link {
            VStack(alignment: .leading, spacing: 5) {
                Text("还没接它回家")
                    .font(.system(size: 12, weight: .medium, design: .serif))
                Text("打开「还在」，再回来添加组件")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func link<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().widgetURL(URL(string: "still://open"))
    }
}

#Preview(as: .systemSmall) {
    RoomWidget(roomId: "clock")
} timeline: {
    StillWidgetEntry(date: Date(), state: .here(pose: .sleep, since: Date().addingTimeInterval(-5400)),
                     roomName: "时钟")
    StillWidgetEntry(date: Date().addingTimeInterval(3600), state: .away(lastVisit: Date().addingTimeInterval(-7200)),
                     roomName: "时钟")
}
