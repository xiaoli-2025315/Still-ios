import WidgetKit
import SwiftUI
import AppIntents
import CoreText

// MARK: - 小组件
//
// v26 现状（豆包方案 1，用户拍板）：
//   · 组件 = 暖米底上一只**纯代码画的矢量猫**。不用任何图片文件——
//     v21~v23 资源名查找不显示、v24~v25 内嵌位图解码出来是黑/灰块，
//     而文字、爪印这类代码直画的矢量从 v20 起每一次都显示成功。
//     → 猫改走与爪印同一层的绘制方式（SwiftUI Canvas 矢量）。
//   · 「同一时刻只在一处」的画面约束已撤（v24 起）：每个组件都是这只猫。

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
    /// true = 帧动画（每秒翻页）。组件库的预览卡（placeholder/snapshot）保持 false：
    /// 预览那条路只走静态矢量猫，不碰字体（v16 立的规矩：预览路径上不放会失败的东西）。
    var animated: Bool = false
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
        // 也不占用一天 72 次的刷新预算。动画靠 Text(timerInterval:) 系统每秒自翻页。
        return Timeline(entries: [Self.alwaysCatEntry(roomId: configuration.room.roomId,
                                                      date: Date(), animated: true)],
                        policy: .never)
    }

    /// 每个组件、任何时刻：同一个「它在这儿」的猫。
    private static func alwaysCatEntry(roomId: String, date: Date, animated: Bool = false) -> StillWidgetEntry {
        StillWidgetEntry(date: date,
                         state: .here(pose: .sit, since: date),
                         roomName: Rooms.byId[roomId]?.name ?? "",
                         animated: animated)
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
                .containerBackground(Color(red: 0.98, green: 0.96, blue: 0.93), for: .widget)
        }
        .configurationDisplayName("还在 v27 · 猫")
        .description("它的一个房间，带猫。多摆几个，每个组件上都是它。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// 同一个房间、同一份数据，**只画字、不画猫**（排障用，定位完可删）。
struct StillTextWidget: Widget {
    let kind = "StillTextWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind,
                               intent: SelectRoomIntent.self,
                               provider: StillWidgetProvider()) { entry in
            StillWidgetView(entry: entry, textOnly: true)
                .containerBackground(Color(red: 0.98, green: 0.96, blue: 0.93), for: .widget)
        }
        .configurationDisplayName("还在 v27 · 字")
        .description("排障用：同一个房间，但只写字不画猫。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct StillWidgetBundle: WidgetBundle {
    var body: some Widget {
        StillWidget()          // 小组件：一只矢量猫
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
            catFull()
        }
    }

    // MARK: 猫铺满组件

    private func catFull() -> some View {
        link {
            Group {
                // 桌面上的卡走帧动画；字体没注册上就退回静态矢量猫 —— 组件照样在。
                if entry.animated, CatFontReg.ok() {
                    CatFrames(pt: family == .systemMedium ? 112 : 96, start: entry.date)
                } else {
                    VectorCat()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(family == .systemMedium ? 10 : 4)
        }
    }

    // MARK: 纯文字版（不画猫，最大限度排除绘制层）

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

// MARK: - 矢量猫
//
// 设计坐标系 172×230（跟原来那张猫图同比例），Canvas 里按组件实际尺寸缩放。
// 全部是 Path / 椭圆 / 直线 —— 和 v20~v22 一直能显示的爪印同一层绘制。

struct VectorCat: View {
    // 配色跟随项目色板：赤陶主色 + 深一档花纹 + 深棕五官 + 奶色胸脯
    private let fur  = Color(red: 0.79, green: 0.48, blue: 0.31)  // #C97B4E 赤陶
    private let dark = Color(red: 0.60, green: 0.35, blue: 0.21)  // 花纹深档
    private let ink  = Color(red: 0.24, green: 0.17, blue: 0.12)  // 五官
    private let cream = Color(red: 0.95, green: 0.87, blue: 0.76) // 胸脯

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width / 172, size.height / 230)
            var c = ctx
            c.translateBy(x: (size.width - 172 * s) / 2,
                          y: (size.height - 230 * s) / 2)
            c.scaleBy(x: s, y: s)

            // —— 尾巴（先画，根部被身体压住）：从右下绕上来一记弯钩
            var tail = Path()
            tail.move(to: CGPoint(x: 126, y: 212))
            tail.addQuadCurve(to: CGPoint(x: 156, y: 146),
                              control: CGPoint(x: 174, y: 198))
            c.stroke(tail, with: .color(fur),
                     style: StrokeStyle(lineWidth: 15, lineCap: .round))
            var tailTip = Path()
            tailTip.move(to: CGPoint(x: 156, y: 162))
            tailTip.addLine(to: CGPoint(x: 156, y: 146))
            c.stroke(tailTip, with: .color(dark),
                     style: StrokeStyle(lineWidth: 15, lineCap: .round))

            // —— 身体（坐姿钟形）
            c.fill(Path(ellipseIn: CGRect(x: 38, y: 106, width: 96, height: 118)),
                   with: .color(fur))
            // 胸脯
            c.fill(Path(ellipseIn: CGRect(x: 64, y: 128, width: 44, height: 66)),
                   with: .color(cream))

            // —— 耳朵（外层毛色 + 内层深色）
            c.fill(ear(left: true), with: .color(fur))
            c.fill(ear(left: false), with: .color(fur))
            c.fill(earInner(left: true), with: .color(dark))
            c.fill(earInner(left: false), with: .color(dark))

            // —— 头
            c.fill(Path(ellipseIn: CGRect(x: 42, y: 26, width: 88, height: 86)),
                   with: .color(fur))

            // —— 头顶花纹（三道短竖纹）
            for dx in [-15.0, 0.0, 15.0] {
                var st = Path()
                st.move(to: CGPoint(x: 86 + dx, y: 32))
                st.addQuadCurve(to: CGPoint(x: 86 + dx * 1.5, y: 48),
                                control: CGPoint(x: 86 + dx, y: 42))
                c.stroke(st, with: .color(dark),
                         style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }

            // —— 身体两侧纹（左右各两道短弧）
            for sx in [0.0, 1.0] {
                let x0 = sx == 0 ? 40.0 : 132.0
                let dir: Double = sx == 0 ? 1 : -1
                for i in 0..<2 {
                    var st = Path()
                    let y = 148.0 + Double(i) * 22
                    st.move(to: CGPoint(x: x0, y: y))
                    st.addQuadCurve(to: CGPoint(x: x0 + 14 * dir, y: y + 8),
                                    control: CGPoint(x: x0 + 2 * dir, y: y + 8))
                    c.stroke(st, with: .color(dark),
                             style: StrokeStyle(lineWidth: 5, lineCap: .round))
                }
            }

            // —— 眼睛
            c.fill(Path(ellipseIn: CGRect(x: 61, y: 60, width: 11, height: 11)),
                   with: .color(ink))
            c.fill(Path(ellipseIn: CGRect(x: 100, y: 60, width: 11, height: 11)),
                   with: .color(ink))

            // —— 鼻子 + 嘴
            var nose = Path()
            nose.move(to: CGPoint(x: 80, y: 79))
            nose.addLine(to: CGPoint(x: 92, y: 79))
            nose.addLine(to: CGPoint(x: 86, y: 86))
            nose.closeSubpath()
            c.fill(nose, with: .color(dark))
            var mouth = Path()
            mouth.move(to: CGPoint(x: 86, y: 86))
            mouth.addQuadCurve(to: CGPoint(x: 78, y: 92), control: CGPoint(x: 81, y: 91))
            mouth.move(to: CGPoint(x: 86, y: 86))
            mouth.addQuadCurve(to: CGPoint(x: 94, y: 92), control: CGPoint(x: 91, y: 91))
            c.stroke(mouth, with: .color(ink),
                     style: StrokeStyle(lineWidth: 2, lineCap: .round))

            // —— 胡须（左右各两根，淡）
            let whiskerColor = Color(ink.opacity(0.35))
            for (x0, y0, x1, y1) in [(58.0, 82.0, 30.0, 78.0),
                                     (58.0, 89.0, 32.0, 96.0),
                                     (114.0, 82.0, 142.0, 78.0),
                                     (114.0, 89.0, 140.0, 96.0)] {
                var w = Path()
                w.move(to: CGPoint(x: x0, y: y0))
                w.addLine(to: CGPoint(x: x1, y: y1))
                c.stroke(w, with: .color(whiskerColor),
                         style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }

            // —— 前爪（两只 + 脚趾缝）
            c.fill(Path(ellipseIn: CGRect(x: 54, y: 206, width: 30, height: 19)),
                   with: .color(fur))
            c.fill(Path(ellipseIn: CGRect(x: 88, y: 206, width: 30, height: 19)),
                   with: .color(fur))
            for px in [62.0, 70.0, 96.0, 104.0] {
                var t = Path()
                t.move(to: CGPoint(x: px, y: 212))
                t.addLine(to: CGPoint(x: px, y: 222))
                c.stroke(t, with: .color(dark.opacity(0.45)),
                         style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
        }
        .aspectRatio(172.0 / 230.0, contentMode: .fit)
    }

    private func ear(left: Bool) -> Path {
        Path { p in
            if left {
                p.move(to: CGPoint(x: 50, y: 50))
                p.addLine(to: CGPoint(x: 59, y: 6))
                p.addLine(to: CGPoint(x: 84, y: 32))
            } else {
                p.move(to: CGPoint(x: 122, y: 50))
                p.addLine(to: CGPoint(x: 113, y: 6))
                p.addLine(to: CGPoint(x: 88, y: 32))
            }
            p.closeSubpath()
        }
    }

    private func earInner(left: Bool) -> Path {
        Path { p in
            if left {
                p.move(to: CGPoint(x: 58, y: 42))
                p.addLine(to: CGPoint(x: 63, y: 17))
                p.addLine(to: CGPoint(x: 77, y: 31))
            } else {
                p.move(to: CGPoint(x: 114, y: 42))
                p.addLine(to: CGPoint(x: 109, y: 17))
                p.addLine(to: CGPoint(x: 95, y: 31))
            }
            p.closeSubpath()
        }
    }
}

// MARK: - 帧字体注册（v27）
//
// 字体数据在 CatFrameFonts.swift 里（base64 直接编进二进制）。
// 运行时按需注册，任何一步失败都只是「猫不动」，静态矢量猫照常显示 ——
// 绝不连坐组件本体。也绝不用 UIAppFonts（启动即加载，失败 = 整个扩展失败）。

enum CatFontReg {
    private static var checked = false
    private static var usable = false

    static func ok() -> Bool {
        if checked { return usable }
        checked = true
        for f in CatFrameFonts.all {
            guard let data = Data(base64Encoded: f.b64) else { return false }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(f.name + ".ttf")
            do { try data.write(to: url) } catch { return false }
            // ① 先让 CoreText 验一遍 —— 它说不行就拉倒
            guard let ds = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
                    as? [CTFontDescriptor], !ds.isEmpty else { return false }
            // ② 进程内注册（scope = .process，不需要任何权限）
            var err: Unmanaged<CFError>?
            guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err) else {
                return false
            }
        }
        usable = true
        return true
    }
}

// MARK: - 逐帧翻页的猫（v27）
//
// 5 层各一套字体（同色层一个字形一种颜色），同一个计时器 → 每层同步翻页。
// 只显示计时器文本的最后一个字符（'0'..'9' = 10 帧，每秒一帧，10 秒一循环）：
// 先 .fixedSize() 按完整宽度排版，再 .frame(width: 1em) + .clipped() 裁到最右一位。

struct CatFrames: View {
    let pt: CGFloat
    let start: Date
    /// 字形高 1150 / 字宽 1000（画布 200x230，见 Tools/_cat_font_vector.py）
    private var h: CGFloat { pt * 1.15 }

    var body: some View {
        ZStack {
            layer("StillCatFur",   Color(red: 0.79,  green: 0.48,  blue: 0.31))
            layer("StillCatCream", Color(red: 0.95,  green: 0.87,  blue: 0.76))
            layer("StillCatDark",  Color(red: 0.60,  green: 0.35,  blue: 0.21))
            layer("StillCatInk",   Color(red: 0.24,  green: 0.17,  blue: 0.12))
            layer("StillCatSoft",  Color(red: 0.596, green: 0.373, blue: 0.243))
        }
    }

    private func layer(_ name: String, _ color: Color) -> some View {
        Text(timerInterval: start.addingTimeInterval(-120)
                              ... start.addingTimeInterval(60 * 60 * 24 * 365),
             countsDown: false)
            .font(.custom(name, size: pt))
            .foregroundColor(color)
            .lineLimit(1)
            .fixedSize()
            .frame(width: pt, height: h,
                   alignment: Alignment(horizontal: .trailing, vertical: .center))
            .clipped()
    }
}

#Preview(as: .systemSmall) {
    StillWidget()
} timeline: {
    StillWidgetEntry(date: Date(), state: .here(pose: .sit, since: Date()), roomName: "时钟")
}
