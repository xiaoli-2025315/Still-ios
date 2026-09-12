import WidgetKit
import SwiftUI
import AppIntents

// MARK: - 小组件
//
// v24 现状（用户拍板）：
//   · 组件 = 一整张大猫图，**永远显示，不判断它在不在**。
//     「同一时刻只在一处」对画面的约束撤掉 —— 每个组件都直接是猫。
//   · 猫图走内嵌 base64（CatImageData.swift），不依赖任何资源查找：
//     v21~v23 里 Image("cat_sit") 在组件进程里从来没显示出来过（文字能变、
//     包里也有图），资源查找这条路不可信。数据编进二进制就没有丢失的可能。

enum WidgetState {
    /// 它现在就在这个房间里
    case here(pose: CatPose, since: Date)
    /// 它不在这儿。lastVisit 是它上一次来是什么时候（留痕）
    case away(lastVisit: Date?)
    /// 用户还没打开过 App，行程表还没生成
    case noHome
}

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

struct StillWidgetProvider: AppIntentTimelineProvider {

    typealias Entry = StillWidgetEntry
    typealias Intent = SelectRoomIntent

    func placeholder(in context: Context) -> StillWidgetEntry {
        Self.alwaysCatEntry(roomId: "clock", date: Date())
    }

    func snapshot(for configuration: SelectRoomIntent, in context: Context) async -> StillWidgetEntry {
        RoomScope.report(roomId: configuration.room.roomId)
        return Self.alwaysCatEntry(roomId: configuration.room.roomId, date: Date())
    }

    func timeline(for configuration: SelectRoomIntent, in context: Context) async -> Timeline<StillWidgetEntry> {
        // 自报家门：告诉别的进程「这个房间有组件在桌面上」（App 侧要用）。
        RoomScope.report(roomId: configuration.room.roomId)

        // 画面不依赖行程表：一条 entry，policy .never —— 内容不变就不用刷新，
        // 也不占用一天 72 次的刷新预算。
        return Timeline(entries: [Self.alwaysCatEntry(roomId: configuration.room.roomId, date: Date())],
                        policy: .never)
    }

    /// 每个组件、任何时刻：同一个「它在这儿」的大猫图。
    private static func alwaysCatEntry(roomId: String, date: Date) -> StillWidgetEntry {
        StillWidgetEntry(date: date,
                         state: .here(pose: .sit, since: date),
                         roomName: Rooms.byId[roomId]?.name ?? "")
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
}

// MARK: - 小组件本体

struct StillWidget: Widget {
    let kind = "StillWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind,
                               intent: SelectRoomIntent.self,
                               provider: StillWidgetProvider()) { entry in
            StillWidgetView(entry: entry, textOnly: false)
                // 暖米底，猫图铺满 —— 组件本身一张图，不装卡片
                .containerBackground(Color(red: 0.98, green: 0.96, blue: 0.93), for: .widget)
        }
        .configurationDisplayName("还在 v24 · 猫")
        .description("它的一个房间，带猫。多摆几个，每个组件上都是它。")
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
        .configurationDisplayName("还在 v24 · 字")
        .description("排障用：同一个房间，但只写字不画猫。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct StillWidgetBundle: WidgetBundle {
    var body: some Widget {
        StillWidget()          // 小组件：一张大猫图，永远显示
        StillTextWidget()      // 排障用：只画字（定位完可删）
        StillLiveActivity()    // 灵动岛 + 锁屏横幅
    }
}

// MARK: - 视图

struct StillWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: StillWidgetEntry
    /// true = 只写字、不画猫（排障用，见 StillTextWidget）
    var textOnly: Bool = false

    var body: some View {
        if textOnly {
            switch entry.state {
            case .here:
                plainHere()
            case .away:
                plainAway()
            case .noHome:
                plainNoHome()
            }
        } else {
            // 组件 = 一整张大猫图。没有文字、没有卡片版式。
            // 状态（在/不在）不参与画面 —— 任何状态都是这只猫。
            catFull()
        }
    }

    // MARK: 大猫图铺满组件

    private func catFull() -> some View {
        link {
            if let ui = Self.catUIImage() {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 三条加载路全失败才会走到这儿 —— 至少让屏幕上有个东西，
                //看到它就说明「图加载失败、绘制本身是好的」。
                Text("🐱").font(.system(size: 48))
            }
        }
    }

    /// 加载猫图的三条路，按可靠程度排序：
    /// ① 内嵌 base64（数据在二进制里，没有查找、没有丢包可能）
    /// ② 包内文件路径（cat_sit.png 就躺在扩展包根目录）
    /// ③ 资源名查找（v21~v23走的这条路，实测不可靠）
    static func catUIImage() -> UIImage? {
        if let d = Data(base64Encoded: CatImageBytes.base64),
           let ui = UIImage(data: d) { return ui }
        if let p = Bundle.main.path(forResource: "cat_sit", ofType: "png"),
           let ui = UIImage(contentsOfFile: p) { return ui }
        return UIImage(named: "cat_sit")
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
            Text("v6")
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
            Text("v6")
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

    private func link<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().widgetURL(URL(string: "still://open"))
    }
}

#Preview(as: .systemSmall) {
    StillWidget()
} timeline: {
    StillWidgetEntry(date: Date(), state: .here(pose: .sit, since: Date()), roomName: "时钟")
}
