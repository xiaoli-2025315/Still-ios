import WidgetKit
import SwiftUI
import AppIntents
import CoreText

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
//
// ─────────────────────────────────────────────────────────────
// ★★★ v13 立下、v15 继续遵守的规矩：
//   **这个扩展里凡是「让画面动起来」的东西，都必须能容错降级。**
//
//   用户的原话：「好像每次我让你改成能动的组件就会不能添加组件」。
//
//   ⚠️ 但要老实说：这条因果**没有证据**。
//     把 v9 和 v10 两个包拆开逐字节比过 —— 12 个源码文件里 9 个逐字符相同，
//     扩展 Info.plist **逐字节相同**，两版**都没有**字体。
//     也就是说 v10 在小组件上**一行动画相关的改动都没有**，
//     而「加不了」当时就已经在抱怨了。至少在 v9/v10 这一对上，
//     「动画 → 加不了」是**不成立**的。
//     （同理，早先怪罪的「Live Activity 进了 WidgetBundle」也站不住：
//       v9 的 bundle 里也有它，而 v9 是能加的。）
//
//   所以现在是**老老实实承认：真因还不知道**。
//   但规矩本身是对的，继续守：
//     · 需要额外资源（自定义字体）的能力 → **运行时按需**获取 + **能降级**
//     · 不在 Info.plist 里预注册任何"新鲜东西"
//     · 预览路径（snapshot / placeholder）无趣到不能再无趣
//
//   ★ v15 的变化：猫**默认就是活的**，不再等用户去开一个开关。
//     降级链仍然满的：字体拿不到 → 退回矢量静态猫 → 组件照样在。
//   ★ v15 还在每张卡右下角放了一串**每秒跳动的数字**（见下面 `Ticking`）——
//     它用系统字体、不依赖那份自造字体，所以
//     「这张卡到底有没有在跑新代码」从此是肉眼一眼可辨的，不用再靠猜。

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
    /// ★★ 默认 **true** —— v15 起，桌面上那只猫**默认就是活的**，没有开关。
    ///
    ///   之前 v14 把它做成「默认关、用户自己去组件设置里开」，理由是
    ///   「Pixel Pals 也是这么做的」—— 查了它的 App Store 官方介绍，原话是
    ///   "moving pixel pals that animate directly on the Home Screen"。
    ///   **人家默认就动，没有开关。** 那个前提是错的，开关已拿掉。
    ///
    ///   唯一还显式传 false 的地方是 `snapshot` —— 组件库里那张预览卡
    ///   是系统单独调一次 snapshot 画的，那条路上不能有任何新东西。
    var animated: Bool = true
}

// MARK: - 帧字体：运行时注册，**绝不**写进 Info.plist
//
// ★★ 为什么不能在 Info.plist 里写 `UIAppFonts`：
//
//   写在 Info.plist 里 = 系统**每次启动这个扩展进程**都要去解析这份字体。
//   而这份字体是我们自己用 fontTools 造的 sbix 彩色位图字体（Apple Color Emoji 同款表，
//   生成脚本 Tools/_cat_font.py）—— 它不是系统字体厂出的东西。
//   只要有任何一处系统不接受，赔上的不是「猫画不出来」，而是**整个 App 从组件库里消失**。
//
//   实测就是这么走的：v9 没有字体 → 组件能加；v11 起有字体 + Info.plist 注册 → 加不了。
//
//   改成运行时注册，把风险关进「画猫」这一件事里：
//     · 注册不上 → 退回矢量静态猫，**组件照样在**
//     · 注册上了 → 正常每秒翻页
//
//   `CTFontManagerCreateFontDescriptorsFromURL` 那一步是关键：
//   让 CoreText 先「验」一遍这份字体，验不过就干脆不注册、不碰它。

enum CatFont {

    private static var checked = false
    private static var usable = false

    /// 这个进程里帧字体能用吗。
    /// 第一次调用会真的去验 + 注册，之后走进程内缓存 —— 不会每次渲染都重来一遍。
    static func usableFont() -> Bool {
        if checked { return usable }
        checked = true

        guard let url = Bundle.main.url(forResource: "StillFrames", withExtension: "ttf") else {
            return false
        }

        // ① 先让 CoreText 解析一遍。它说不行就拉倒 —— 绝不硬注册一个自己都不认的东西。
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
                as? [CTFontDescriptor], !descs.isEmpty else {
            return false
        }

        // ② 进程内注册（scope = .process，不需要任何权限，也不需要 App Group）。
        var err: Unmanaged<CFError>?
        usable = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err)
        return usable
    }

    /// 字体文件到底有没有打进扩展包。**只查文件，不碰 CoreText** —— 探针组件用这个，
    /// 那条路上一点风险都不能有。
    static var fileIsBundled: Bool {
        Bundle.main.url(forResource: "StillFrames", withExtension: "ttf") != nil
    }
}

// MARK: - 活性证据（v15 新加）
//
// ★★ 这一小块东西存在的唯一目的：**让用户肉眼确认「桌面上那张卡有没有在跑新代码」。**
//
//   背景 —— 用户连着好几版都在说同一句话：
//     「你改了这么多，我在组件上没看出任何变化，我觉得你压根没在改。」
//   （他的原话，不是转述：**「你能让我实际地看到，就是这个小组件真的有什么变化」**）
//
//   这个指责其实站得住。在此之前，我们拿来证明「改了」的东西**全是静止的**：
//   组件显示名、一行 8.5pt 的版本号小字、背景深浅……
//   它们本来就不该指望被人注意到 —— 拿它们当证据，等于没证据。
//
//   这串数字不一样：**它每秒跳一下。**
//     · 在跳   → 桌面上这张卡确实在跑这份新代码。扎针扎对了。
//     · 不跳   → 这张卡压根没跑新代码（问题在系统登记 / 签名那一层，
//                再去改 Swift 全是白费劲）。
//   一句话把「改没改到」和「改得对不对」切成两个互不干扰的问题。
//
//   为什么它一定画得出来：
//     · 用**系统字体**，不依赖我们那份自造的 sbix 帧字体
//     · 用系统的 `Text(timerInterval:)` —— 系统自己渲染，不重跑我们的代码、
//       不吃刷新额度（72/天）、App 被杀也照走
//   所以它不可能因为「字体没注册上」「越界」这类原因失败。

enum Ticking {

    /// 从 `start` 起、每秒自己往上走的一串时间（`0:00:12` / `1:02:03`）。
    /// 字号交给调用方设 —— 它在不同卡片上大小不一样。
    static func since(_ start: Date) -> Text {
        // 右端给一个足够远的未来（2100-01-01），让它一直往上走而不是倒数完就停。
        let far = Date(timeIntervalSince1970: 4_102_444_800)
        // 防御：起止反了会让 ClosedRange 直接崩，这里兜一下。
        let from = start < far ? start : far.addingTimeInterval(-60)
        return Text(timerInterval: from...far, countsDown: false).monospacedDigit()
    }
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
        //     ② 加载一份自定义的彩色位图字体（sbix）—— 那是唯一的动画手段
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
                                        whereNow: wn,
                                        animated: true)
            } else {
                return StillWidgetEntry(date: m.date,
                                        state: .away(lastVisit: Schedule.lastVisit(segs, roomId: roomId, before: h)),
                                        roomName: Rooms.byId[roomId]?.name ?? "",
                                        whereNow: wn,
                                        animated: true)
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
            StillWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("还在 \(Cfg.version) · 猫")
        .description("它的一个房间，带猫。多摆几个，它就会在它们之间穿梭。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - 探针（排障用，定位完可删）
//
// ★★ 这个组件的唯一职责：**把「App 层面 / 签名层面」和「代码层面」一刀切开。**
//
//   它刻意做到「什么都不做」：
//     · StaticConfiguration —— 不用 AppIntent（组件库里那一趟最省）
//     · 不画猫、不碰字体、不算行程表、不读任何共享存储
//     · 只画几行写死的字 + 版本号
//
//   于是它能告诉我们一件确切的事：
//     · 组件库里连它都搜不到 → **问题不在代码**，是 App/扩展的登记或签名，
//       再去改 Swift 就是白费劲
//     · 它搜得到、带猫的那个搜不到 → 问题在带猫那条路（AppIntent / 帧字体 / 计时器）
//
//   这一条比什么都值钱：省掉一整轮「改一版、装机、试试看」的盲猜。

struct StillProbeProvider: TimelineProvider {

    typealias Entry = StillWidgetEntry

    func placeholder(in context: Context) -> StillWidgetEntry {
        StillWidgetEntry(date: Date(), state: .away(lastVisit: nil), roomName: "", animated: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (StillWidgetEntry) -> Void) {
        completion(probeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StillWidgetEntry>) -> Void) {
        // 一个小时后再要一条。探针不需要勤刷 —— 它只是用来看扩展活没活。
        completion(Timeline(entries: [probeEntry()],
                            policy: .after(Date().addingTimeInterval(3600))))
    }

    private func probeEntry() -> StillWidgetEntry {
        StillWidgetEntry(date: Date(), state: .away(lastVisit: nil), roomName: "", animated: false)
    }
}

struct StillProbeWidget: Widget {
    let kind = "StillProbeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StillProbeProvider()) { entry in
            StillProbeView(entry: entry)
                // 写死颜色，不用语义色 —— 排除「背景没渲染出来，看着像空白」
                .containerBackground(Color(red: 0.98, green: 0.96, blue: 0.93), for: .widget)
        }
        .configurationDisplayName("还在 \(Cfg.version) · 探针")
        .description("排障用，什么都不画。它能出现在组件库里，就说明扩展本身是好的。")
        .supportedFamilies([.systemSmall])
    }
}

struct StillProbeView: View {

    let entry: StillWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("探针")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(red: 0.55, green: 0.35, blue: 0.25))
            Text(Cfg.version)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(.black)
            Text("字体文件 " + (CatFont.fileIsBundled ? "✓" : "✗"))
                .font(.system(size: 10))
                .foregroundStyle(Color(red: 0.4, green: 0.4, blue: 0.4))
            Spacer(minLength: 0)
            Text("这张能加 → 扩展是好的")
                .font(.system(size: 9))
                .foregroundStyle(Color(red: 0.6, green: 0.6, blue: 0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(13)
    }
}

// MARK: - 扩展的入口
//
// ★★★ 这里放什么、不放什么，直接决定「组件库里能不能搜到这个 App」。
//
//   已知踩过两次的坑：**`StillLiveActivity`（灵动岛）放进 WidgetBundle 之后，
//   组件库里就搜不到这个 App 了**。历史上修过一次（a06f420 把它移出去），
//   后来为了修灵动岛又加了回来 —— 而「组件加不了」也跟着回来了。
//
//   现在只放两个，都是最规矩的小组件：
//     · StillWidget       —— 正主，会动的猫
//     · StillProbeWidget  —— 探针，什么都不做
//
//   灵动岛（Live Activity）**暂时不在这里**：
//     · 四个部分里它排在第三个，本来就还没开工
//     · 加回来的时候，用一个**单独的 extension** 承载它，
//       而不是塞回这个 bundle —— 让「组件」和「灵动岛」互不牵连，
//       一个出问题不连坐另一个。这才是长久解法。

@main
struct StillWidgetBundle: WidgetBundle {
    var body: some Widget {
        StillWidget()          // 它住的那间房。会动的猫走这条路。
        StillProbeWidget()     // 排障探针：库里有它、相机里没它，就能定位问题在哪一层。
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
//
// ★★ 字体怎么进来：**运行时注册**，见上面的 `CatFont`。
//   注册不上就自动退回矢量静态猫 —— 猫不动，但组件一定还在。

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

    @ViewBuilder
    var body: some View {
        switch entry.state {
        case .here(let pose, let since):
            here(pose: pose, since: since)
        case .away(let last):
            away(lastVisit: last)
        case .noHome:
            noHome
        }
    }

    // MARK: 它在这儿

    /// 组件上那只猫。**两种画法，尺寸完全一样**（宽 : 高 都是 1 : 0.875）。
    ///
    /// · `animated` 且字体注册得上 —— 走帧字体，每秒翻一页，这是桌面上那只「活猫」
    /// · 否则 —— 走矢量 CatView，静态、零依赖
    ///
    /// 之所以要留静态这一档：任何一环没到位（预览那条路、字体注册不上）都要能体面地退回来。
    /// 两者的外框一样大，所以切来切去布局不会跳。
    @ViewBuilder
    private func cat(pose: CatPose) -> some View {
        let pt = family == .systemMedium ? CAT_PT_MEDIUM : CAT_PT_SMALL
        // ★ 逗号 = 短路与：animated 为 false 时压根不会去碰字体。
        if entry.animated, CatFont.usableFont() {
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
                    // ★★ v15：这一行**每秒自己跳一下**。
                    //   以前是一句静止的「待了 1 小时」—— 静止的东西证明不了任何事，
                    //   而用户要看的就是「它到底有没有在变」。
                    //   现在这一行同时是两件事：语义（在这间房待了多久）+ 证据（组件在跑这份代码）。
                    (Text("待了 ") + Ticking.since(since))
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
                // ★★ v15：这一行**每秒自己跳一下** —— 它离开这间房多久了。
                //   和「它在这儿」那张卡上的「待了 …」是一对：
                //   两张卡上永远都有一个在动的数字，**每张卡都能自证它是活的**。
                //   见 `Ticking`。
                (Text("离开 ") + Ticking.since(entry.date))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
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
                // 版本号交给 `link` 右下角那块统一的证据位，这里不再重复画。
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func link<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .widgetURL(URL(string: "still://open"))
            // ★★ v15：右下角这一小块是**给用户看的证据**，不是装饰。
            //    版本号 + 帧字体状态，后面跟一串**每秒跳动**的数字。
            //      · 活 = 帧字体文件打进包里了，猫能动
            //      · 静 = 字体不在，猫退回静态（组件本身一定还在）
            //    `fileIsBundled` 只查 Bundle、不碰 CoreText —— 预览那条路上零风险。
            .overlay(alignment: .bottomTrailing) {
                // v15 · 活 = 帧字体在包里，猫能动 / v15 · 静 = 字体不在，退回静态猫。
                Text("\(Cfg.version)·\(CatFont.fileIsBundled ? "活" : "静")")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 11)
                    .padding(.bottom, 8)
            }
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
