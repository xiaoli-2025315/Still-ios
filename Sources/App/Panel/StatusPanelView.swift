import SwiftUI
import WidgetKit

// MARK: - 状态面板
//
// 这一块是「给你看的」。上面画布里发生的事是它自己的，
// 这里负责把「概率在时间里」翻译成人能读的数字。

struct StatusPanelView: View {

    @ObservedObject var engine: PetEngine
    @State private var toast: String? = nil
    @State private var catName: String = ""
    @State private var widgetCount: Int? = nil

    private let speeds: [(Double, String)] = [
        (1, "1×"), (60, "60×"), (300, "300×"), (600, "600×")
    ]

    // MARK: 小组件自检（把这一屏截图给我，就能定位问题）

    private var widgetCountText: String {
        guard let n = widgetCount else { return "正在查询系统登记的组件…" }
        return "系统里登记的 Still 组件：\(n) 个"
    }

    private var diagnosis: String {
        let renders = RoomScope.renderCount()
        if renders > 0 {
            return "组件跑起来了。还空白的话是渲染的事 —— 把这一屏截图给我。"
        }
        if let n = widgetCount, n > 0 {
            return "系统里有组件，但它一次都没刷新 → 扩展没被加载，多半是重签时插件没签上。"
        }
        if let n = widgetCount, n == 0 {
            return "系统里没登记到组件 → 先长按桌面把旧的删掉，重新加一个。"
        }
        return ""
    }

    private func loadWidgetCount() {
        // 用 iOS 16 就有的回调版，别用 iOS 17 的 async 版 —— 少一个可用性上的雷。
        WidgetCenter.shared.getCurrentConfigurations { result in
            let n: Int
            if case .success(let infos) = result {
                n = infos.filter { $0.kind == "StillWidget" }.count
            } else {
                n = -1
            }
            DispatchQueue.main.async { widgetCount = n }
        }
        // 打开 App 就催一次刷新：小组件的刷新时刻由系统定，不催可能几小时不动。
        WidgetCenter.shared.reloadAllTimelines()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // 它在哪、在干嘛
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Cfg.Palette.accent)
                Text(headline)
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                Text(engine.state.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // 这阵子在做什么（最近 4 个动作，倒序）
            if !engine.actLog.isEmpty {
                Text(engine.actLog.reversed().map(\.label).joined(separator: " → "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // 给它起名：Siri 唤醒词里用的就是它（「跟豆豆说…」）
            HStack(spacing: 6) {
                Text("叫它").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("还在", text: $catName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 92)
                    .onSubmit { engine.setName(catName) }
                Button("改") { engine.setName(catName) }
                    .buttonStyle(ChipButton())
            }

            Divider().opacity(0.5)

            // 撞见概率
            let c = engine.chanceSummary()
            VStack(alignment: .leading, spacing: 3) {
                Text("你平均 \(Int(c.days.rounded())) 天会撞见它一次在走")
                    .font(.system(size: 12))
                Text("它一天挪 \((24.0 / ((Cfg.stayHoursMin + Cfg.stayHoursMax) / 2)).rounded()) 次，每次走四五秒。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Divider().opacity(0.5)

            // 活动范围 + 小组件自检
            //
            // 这块是排障用的：小组件跑在另一个进程里，它到底有没有被执行，
            // 在 App 里是看不见的。所以让它每次渲染都记一笔，这里读出来。
            //   刷新 0 次      = 扩展压根没被系统加载（重签时插件没签上，最常见）
            //   系统登记 0 个  = 组件根本没加上去
            //   刷新 > 0 还空白 = 代码跑了，是渲染层的事
            let scope = RoomScope.active(atHour: Schedule.hourEpoch)
            VStack(alignment: .leading, spacing: 3) {
                Text(RoomScope.isLive() ? "它只在这几间跑" : "它先在默认的五间跑")
                    .font(.system(size: 12))
                Text(scope.compactMap { Rooms.byId[$0]?.name }.joined(separator: " · "))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)

                Divider().opacity(0.4)

                Text("App Group \(RoomScope.probe() ? "可用" : "不可用")　·　组件已刷新 \(RoomScope.renderCount()) 次")
                    .font(.system(size: 10.5))
                    .foregroundStyle(RoomScope.renderCount() > 0 ? .secondary : Cfg.Palette.accent)
                Text(widgetCountText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(widgetCount == 0 ? Cfg.Palette.accent : .secondary)
                if !diagnosis.isEmpty {
                    Text(diagnosis)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Cfg.Palette.accent)
                }
            }
            .onAppear(perform: loadWidgetCount)

            Divider().opacity(0.5)

            // 时间机器
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("时间机器").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text(offsetLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(Cfg.Palette.accent)
                }
                Slider(value: Binding(
                    get: { engine.hoursNow },
                    set: { engine.seek(hoursOffset: $0) }
                ), in: -72...0)
                .tint(Cfg.Palette.accent)
            }

            // 倍速
            HStack(spacing: 6) {
                Text("演示速度").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                ForEach(speeds, id: \.0) { v, label in
                    Button(label) { engine.speed = v }
                        .font(.system(size: 11))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(engine.speed == v ? Cfg.Palette.accent : Color.secondary.opacity(0.12))
                        .foregroundStyle(engine.speed == v ? .white : .primary)
                        .clipShape(Capsule())
                }
            }
            .buttonStyle(.plain)

            Text(speedNote)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

            // 操作
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button("跳到它下次挪窝") { engine.jumpToNextMove() }
                        .buttonStyle(PrimaryButton())
                    Button("喊它") {
                        let came = engine.call()
                        toast = came ? "它从深处走出来了" : "它没应"
                    }
                    .buttonStyle(ChipButton())
                }
                HStack(spacing: 8) {
                    // NFC 不再把它拽到另一个房间（那要改写行程表，会破坏唯一性），
                    // 只保证它一定走到你跟前。见 PetEngine.nfcRecall 的注释。
                    Button("碰 NFC 牌") { engine.nfcRecall(); toast = "它走到你跟前了" }
                        .buttonStyle(ChipButton())
                    Button("回到现在") { engine.seek(hoursOffset: 0); toast = nil }
                        .buttonStyle(ChipButton())
                    Button("重置行程") { engine.reset(); toast = "行程表已重新生成" }
                        .buttonStyle(ChipButton())
                }
            }

            if let toast {
                Text(toast)
                    .font(.system(size: 11))
                    .foregroundStyle(Cfg.Palette.accent)
                    .transition(.opacity)
            }
        }
        .padding(14)
        .onAppear { catName = engine.catName }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var headline: String {
        let room = Rooms.byId[engine.roomId]?.name ?? "—"
        if engine.isWalking { return "它正在走过去…" }
        if engine.inIsland { return "它钻进灵动岛了" }
        return "它在「\(room)」里，在\(engine.act.label)"
    }

    private var offsetLabel: String {
        let h = -engine.hoursNow
        if h < 0.08 { return "现在" }
        if h < 1 { return "\(Int(h * 60)) 分钟前" }
        if h < 24 { return String(format: "%.1f 小时前", h) }
        return String(format: "%.1f 天前", h / 24)
    }

    private var speedNote: String {
        let avg = (Cfg.stayHoursMin + Cfg.stayHoursMax) / 2.0
        if engine.speed == 1 {
            return "真实速度：它平均 \(String(format: "%.1f", avg)) 小时挪一次窝。你会等很久。"
        }
        return "现在是 \(Int(engine.speed))× 演示：\(String(format: "%.1f", avg)) 小时压成约 \(Int(avg * 3600 / engine.speed)) 秒。走路那几秒不压缩 —— 走就是走。"
    }
}

// MARK: - 按钮样式

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Cfg.Palette.accent.opacity(configuration.isPressed ? 0.75 : 1))
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }
}

struct ChipButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.secondary.opacity(configuration.isPressed ? 0.22 : 0.12))
            .clipShape(Capsule())
    }
}

#Preview {
    StatusPanelView(engine: PetEngine())
        .padding()
        .background(Cfg.Palette.bg)
}
