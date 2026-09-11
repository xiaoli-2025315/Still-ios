import WidgetKit
import SwiftUI
import AppIntents

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
    /// 这一条要不要画**会动的**猫（帧字体 + 每秒翻页）。
    ///
    /// ★ 组件库里那张预览卡是系统单独调一次 `snapshot` 画的，那一条路必须走最朴素的画法：
    ///   不加载自定义字体、不问系统配置。理由见 `snapshot(for:in:)` 的注释 ——
    ///   那一条路上出任何岔子，系统会把整个 App 从组件库里摘掉，用户看到的就是「加不了」。
    var animated: Bool = true
}

// MARK: - Provider

struct StillWidgetProvider: AppIntentTimelineProvider {

    typealias Entry = StillWidgetEntry
    typealias Intent = SelectRoomIntent

    func placeholder(in context: Context) -> StillWidgetEntry {
        StillWidgetEntry(date: Date(), state: .away(lastVisit: nil), roomName: "时钟")
    }

    func snapshot(for configuration: SelectRoomIntent, in context: Context) async -> StillWidgetEntry {
        // ★★ 这一条路要**无趣**，这是「App 能出现在组件库里」的前提。
        //
        //   组件库里那张预览卡，是系统单独调一次 `snapshot` 画的 —— 和桌面上那几张
        //   互不相干。这条路上我们做过两件别人没做过的事：
        //     ① 问系统要「桌面上摆着哪几间」（`WidgetCenter.currentConfigurations()`，
        //        一次跨进程调用，而且是**在系统正等着我们出结果的时候**发的）
        //     ② 加载一份自定义的彩色位图字体（sbix）—— 那是唯一的动画手段，见文件末尾
        //   任何一件让扩展卡住或者被杀，系统的处理不是「预览空白」，
        //   而是**把这个 App 整个从组件库里摘掉** —— 用户看到的就是「组件加不了」。
        //
        //   所以这里一律走最朴素的一条：不算范围、不问系统、不碰字体、不画会动的猫。
        //   桌面上那张卡照样是活的 —— 走的是 timeline，不是这里。
        var e = entry(for: configuration.room.roomId, at: Date())
        e.animated = false
        return e
    }

    func timeline(for configuration: SelectRoomIntent, in context: Context) async -> Timeline<StillWidgetEntry> {
        let roomId = configuration.room.roomId
        let now = Date()

        // ★★ 第一步，必须在这一步之前问系统：**桌面上到底摆着哪几间**。
        //
        //   这是「它肯定在某个小组件里」唯一靠得住的来源。
        //   以前只靠 RoomScope.report 自报，而自报要 App Group —— 自签下读不到，
        //   于是所有组件都退回默认五间；用户摆的房间若不在那五间里，
        //   桌面上就是**一片空房间，一只猫都看不见**（实测就是这个现象）。
        //
        //   WidgetCenter.currentConfigurations() 在扩展里也能调（WWDC20 明说），
        //   而且所有组件拿到的是同一份 → 各自算出的 place(T) 依然唯一。
        await RoomScope.refreshFromSystem()

        // 自报家门：告诉别的进程「这个房间有组件在桌面上」。
        // App Group 通的时候它比系统配置更新鲜（24 小时过期），是第二优先。
        RoomScope.report(roomId: roomId)

        // ★ 不再依赖 App Group：行程表是确定性算出来的，
        //   小组件自己和 App 算出来的必然是同一份（见 Schedule.resolve 的注释）。
        //   以前「读不到就显示『还没接它回家』」那一支删了 ——
        //   自签名下 App Group 常常不通，那一支会让用户在桌面永远看不见它。
        let segs = Schedule.resolve()

        // 只排「有变化」的时刻。末尾那个 false 是兜底。
        let moments = Schedule.moments(forRoom: roomId, segs: segs, from: now)
        let entries = moments.map { m -> StillWidgetEntry in
            let h = m.date.timeIntervalSince1970 / 3600.0
            let wn = whereNow(segs: segs, atHour: h)
            if m.here {
                let seg = Schedule.segment(segs, atHour: h)
                let since = seg.map { Date(timeIntervalSince1970: $0.t0 * 3600.0) } ?? m.date
                return StillWidgetEntry(date: m.date,
                                        state: .here(pose: Self.pose(roomId: roomId, at: m.date),
                                                     since: since),
                                        roomName: Rooms.byId[roomId]?.name ?? "",
                                        whereNow: wn)
            } else {
                return StillWidgetEntry(date: m.date,
                                        state: .away(lastVisit: Schedule.lastVisit(segs, roomId: roomId, before: h)),
                                        roomName: Rooms.byId[roomId]?.name ?? "",
                                        whereNow: wn)
            }
        }

        // .atEnd：走完最后一条就再要一条新的。
        // 预算用尽时它会停在最后那条（兜底的「不在这儿」）—— 这是安全的失败方向。
        return Timeline(entries: entries, policy: .atEnd)
    }

    /// 小组件库里的预置：直接给你几个现成的，不用添加完再长按编辑。
    /// 描述写死字面量，不用插值 —— 少一个编译期可能出问题的地方。
    func recommendations() -> [AppIntentRecommendation<SelectRoomIntent>] {
        let picks: [(RoomOption, String)] = [
            (.still,   "它的家"),
            (.clock,   "时钟房"),
            (.weather, "天气房"),
            (.photo,   "照片房"),
            (.notes,   "备忘录房")
        ]
        return picks.map { AppIntentRecommendation(intent: SelectRoomIntent(room: $0.0),
                                                   description: $0.1) }
    }

    private func entry(for roomId: String, at date: Date) -> StillWidgetEntry {
        let segs = Schedule.resolve()
        let h = date.timeIntervalSince1970 / 3600.0
        let here = Schedule.place(segs, atHour: h) == .room(roomId)
        let name = Rooms.byId[roomId]?.name ?? ""
        let wn = whereNow(segs: segs, atHour: h)
        if here, let seg = Schedule.segment(segs, atHour: h) {
            return StillWidgetEntry(date: date,
                                    state: .here(pose: Self.pose(roomId: roomId, at: date),
                                                 since: Date(timeIntervalSince1970: seg.t0 * 3600.0)),
                                    roomName: name,
                                    whereNow: wn)
        }
        return StillWidgetEntry(date: date,
                                state: .away(lastVisit: Schedule.lastVisit(segs, roomId: roomId, before: h)),
                                roomName: name,
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
    private static func pose(roomId: String, at date: Date) -> CatPose {
        let quarter = Int(date.timeIntervalSince1970 / 900)
        var r = SeededRandom(seed: FNV.hash(roomId) ^ UInt32(truncatingIfNeeded: quarter))
        return [CatPose.sleep, .sit, .groom, .look][r.int(4)]
    }
}

// MARK: - 小组件本体

struct StillWidget: Widget {
    let kind = "StillWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind,
                               intent: SelectRoomIntent.self,
                               provider: StillWidgetProvider()) { entry in
            StillWidgetView(entry: entry, textOnly: false)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("还在 \(Cfg.version) · 猫")
        .description("它的一个房间，带猫。多摆几个，它就会在它们之间穿梭。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// 同一个房间、同一份数据，**只画字、不画猫**。
///
/// 存在的唯一目的：把「小组件扩展整体没渲染」和「画猫的那段代码崩了」一分为二。
///   · 它也是空白  → 扩展层面就没画出来，跟画猫无关
///   · 它有字、带猫的那个空白 → 画猫那段代码在小组件进程里崩了，修它就行
/// 定位完可以删掉这个组件。
struct StillTextWidget: Widget {
    let kind = "StillTextWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind,
                               intent: SelectRoomIntent.self,
                               provider: StillWidgetProvider()) { entry in
            StillWidgetView(entry: entry, textOnly: true)
                // 用写死的颜色，不用语义色 —— 排除「背景渲染不出来看着像空白」
                .containerBackground(Color(red: 0.98, green: 0.96, blue: 0.93), for: .widget)
        }
        .configurationDisplayName("还在 \(Cfg.version) · 字")
        .description("排障用：同一个房间，但只写字不画猫。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct StillWidgetBundle: WidgetBundle {
    var body: some Widget {
        StillWidget()          // 小组件：按行程表预排，同一时刻只有一个有猫
        StillTextWidget()      // 排障用：同上，但只画字（定位完可删）
        StillLiveActivity()    // 灵动岛 + 锁屏横幅
    }
}

// MARK: - 会动的猫
//
// 组件里**不能播视频、不能播动图**，timeline 换图最快也只有约 5 秒/张 ——
// 5 秒一换看着是幻灯片，不是动画。
//
// 唯一能让组件「自己连续动」的公开手段是 `Text(timerInterval:)`：
// 它由**系统每秒自更新**，不重跑组件代码、不吃刷新额度、App 被杀也照走。
//
// 所以做法是：把猫的 10 帧画成字体里 '0'..'9' 十个字形
// （生成脚本 Tools/_cat_font.py，sbix 彩色位图字体），
// 再让计时器去驱动它 —— 秒的个位每秒 +1，于是每秒翻一帧，10 帧循环。
//
// ★ 裁切：文本长成 "0:02:03" 这样，只用 frame 留下最右边一个字符。
//   左边溢出的部分被 clipped 掉，看不见。
//
// ★ 字号必须**正好落在字体的 strike 档位上**（STRIKES = 40/48/56/64/72/88/112/160/224）。
//   实测：字号不在档位上时，有的实现会去缩放位图（糊），
//   有的干脆判定「这个字号没有可用字形」直接不画。

private let CAT_PT_SMALL: CGFloat = 56
private let CAT_PT_MEDIUM: CGFloat = 72

/// 猫的位图比例：256 × 224
private let CAT_ASPECT: CGFloat = 224.0 / 256.0

struct CatFrames: View {
    /// ★ 必须是字体 strike 列表里的值，别随手写。
    let pt: CGFloat
    /// 计时器起点。用 entry 自己的时刻 —— 每条 entry 一个起点，彼此独立。
    let start: Date

    private var h: CGFloat { pt * CAT_ASPECT }

    var body: some View {
        // 起点往前挪 2 分钟：这样显示的时长永远 > 1 分钟，
        // 不会掉进「最后 60 秒显示小数」的格式里（那种格式最后一位会变得很快）。
        Text(timerInterval: start.addingTimeInterval(-120)
                          ... start.addingTimeInterval(60 * 60 * 24 * 7),
             countsDown: false)
            .font(.custom("StillFrames", size: pt))
            .lineLimit(1)
            // 先让文本按完整宽度排版，再用小框裁 —— 顺序反了就变成省略号
            .fixedSize()
            .frame(width: pt, height: h + 4,
                   alignment: Alignment(horizontal: .trailing, vertical: .center))
            .clipped()
    }
}

// MARK: - 视图

struct StillWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: StillWidgetEntry
    /// true = 只写字，不碰 CatView / PawMark（排障用，见 StillTextWidget）
    var textOnly: Bool = false

    var body: some View {
        switch entry.state {
        case .here(let pose, let since):
            textOnly ? AnyView(plainHere()) : AnyView(here(pose: pose, since: since))
        case .away(let last):
            textOnly ? AnyView(plainAway()) : AnyView(away(lastVisit: last))
        case .noHome:
            textOnly ? AnyView(plainNoHome()) : AnyView(noHome)
        }
    }

    // MARK: 纯文字版（不画猫、不画爪印，最大限度排除绘制层）

    private func plainHere() -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("它在这儿")
                .font(.system(size: 10))
                .foregroundStyle(Color(red: 0.55, green: 0.35, blue: 0.25))
            Text(entry.roomName.isEmpty ? "（未选房间）" : entry.roomName)
                .font(.system(size: family == .systemMedium ? 22 : 17, weight: .medium, design: .serif))
                .foregroundStyle(.black)
                .lineLimit(1)
            Text(Cfg.version)
                .font(.system(size: 9))
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(13)
    }

    private func plainAway() -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.roomName.isEmpty ? "（未选房间）" : entry.roomName)
                .font(.system(size: 13, weight: .medium, design: .serif))
                .foregroundStyle(.gray)
                .lineLimit(1)
            if let w = entry.whereNow {
                Text("它现在在 " + w.label)
                    .font(.system(size: 12))
                    .foregroundStyle(.black)
                    .lineLimit(1)
            } else {
                Text("它还没来过")
                    .font(.system(size: 11))
                    .foregroundStyle(.gray)
            }
            Text(Cfg.version)
                .font(.system(size: 9))
                .foregroundStyle(Color(red: 0.7, green: 0.7, blue: 0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(13)
    }

    private func plainNoHome() -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("还没接它回家")
                .font(.system(size: 12, weight: .medium, design: .serif))
                .foregroundStyle(.black)
            Text("打开「还在」再回来")
                .font(.system(size: 9))
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(13)
    }

    // MARK: 它在这儿

    /// 组件上那只猫。**两种画法，尺寸完全一样**（宽 : 高 都是 1 : 0.875）。
    ///
    /// · `animated` —— 走帧字体，每秒翻一页，这是桌面上那只「活猫」
    /// · 否则      —— 走矢量 CatView，静态、零依赖，只用在组件库预览那一条路
    ///
    /// 之所以要留静态这一档，是因为预览那一条路不能有任何新鲜东西（见 snapshot 的注释）。
    /// 两者的外框一样大，所以切来切去布局不会跳。
    @ViewBuilder
    private func cat(pose: CatPose) -> some View {
        let pt = family == .systemMedium ? CAT_PT_MEDIUM : CAT_PT_SMALL
        if entry.animated {
            // ★ 这只猫是**活的**：由系统每秒翻一帧，10 帧循环甩尾。
            //   姿势暂时固定成「坐着甩尾」—— 字体现在只有这一套动画帧，
            //   要加别的动作（睡觉 / 舔毛 / 走动）就在 Tools/_cat_font.py 里多画几套，
            //   每一套占一组字符即可。
            CatFrames(pt: pt, start: entry.date)
        } else {
            CatView(pose: pose, width: pt)
                .frame(width: pt, height: pt * CAT_ASPECT, alignment: .center)
        }
    }

    private func here(pose: CatPose, since: Date) -> some View {
        link {
            HStack(spacing: 10) {
                cat(pose: pose)
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
    StillWidget()
} timeline: {
    StillWidgetEntry(date: Date(), state: .here(pose: .sleep, since: Date().addingTimeInterval(-5400)),
                     roomName: "时钟")
    StillWidgetEntry(date: Date().addingTimeInterval(3600), state: .away(lastVisit: Date().addingTimeInterval(-7200)),
                     roomName: "时钟")
}
