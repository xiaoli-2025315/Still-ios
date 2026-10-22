import SwiftUI
import WidgetKit
import AppIntents   // ShortcutsLink（系统自带的「在 Siri 里用它」入口）

// MARK: - 状态面板
//
// 这一块是「给你看的」。上面画布里发生的事是它自己的，
// 这里负责把「概率在时间里」翻译成人能读的数字。

struct StatusPanelView: View {

    @ObservedObject var engine: PetEngine
    @State private var toast: String? = nil
    @State private var catName: String = ""
    /// ★ 2026-10-21：改完名字给一句回执。他要的是「取完名字立刻反馈到 Siri」，
    ///   那就得让他**看得见**它反馈了，不然改完心里没底。
    @State private var note: String = ""
    @State private var widgetCount: Int? = nil
    /// 声音开关（存在手机里，跟着 SoundKit 走）
    @State private var soundOn: Bool = SoundKit.shared.on

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

    /// 改名。
    ///
    /// ★ 2026-10-21：改完必须让 Siri 重新拼一遍短语。
    ///   短语「跟 \(\.$pet) 说句话」里的名字，是系统从 `PetBook.all()` 拿的；
    ///   不重拼，你改了名、界面和通知都叫新名字，只有 Siri 还在喊旧的那个。
    private func rename() {
        engine.setName(catName)
        // 空名会被回退成「还在」，输入框得跟着走 —— 否则框里空着、Siri 却叫「还在」。
        catName = engine.catName
        // ★ 通知系统重拼短语。这一步是"立刻"的那一半：名字表当场就换了。
        //   另一半（Siri 真的听懂新名字）由系统重建词表，几秒到几十秒，苹果不给更快的口子。
        StillShortcuts.updateAppShortcutParameters()
        note = "Siri 也改叫「\(engine.catName)」了 · 几秒后生效"
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if note.hasSuffix("几秒后生效") { note = "" }
        }
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
            //
            // ★ 2026-10-21：这行字以前是**假的** —— 短语里用的是 App 显示名，
            //   不是这里的名字。现在把「它」做成了 AppEntity，这句才真的成立。
            //   改完名字要立刻让 Siri 重新拼一遍短语，否则它还认旧名字。
            HStack(spacing: 6) {
                Text("叫它").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("还在", text: $catName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 92)
                    .onSubmit { rename() }
                Button("改") { rename() }
                    .buttonStyle(ChipButton())
            }

            // 改完的回执。改一个名字要等到下次做梦才能验证，那就等于没改。
            if !note.isEmpty {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            // ★★★ 2026-10-21 真机踩坑后加的：**把 Siri 现在认的那句话摆出来**。
            //
            //   他从截图里反馈「喊了它说找不到奶娃 / 说不支持」——
            //   而他根本无从知道到底该怎么说、现在索引的是哪一句。
            //   这行就是给他看的答案，照着念就一定对得上。别再让他猜。
            //
            // ★★★ 2026-10-22（v60）：**这行字以前是错的，会把他带沟里。**
            //   原来写的是「用还在跟\(engine.catName)说句话」—— 猫名会被念进那句里。
            //   但苹果规定：短语里被念到的那个空位，必须是系统提前知道答案的东西
            //   （固定选项列表）。"猫叫什么"是他随手起的，系统没有这张表 ⇒ 填不上
            //   ⇒ **整句话作废** ⇒ Siri 只回「不支持」。查了五版才查到，见
            //   `TalkToCatIntent.swift` 里 `StillShortcuts` 那段。
            //   所以现在照实写：念的那句里只有 App 名，猫名不进去。
            //   ★ 再往下一层（2026-10-22）：那句里的「还在」是 App 显示名，他嫌别扭，
            //     一度把猫名焊进短语（`用还在跟奶娃说句话`）。但他明确说**名字以后会改**，
            //     焊死等于改一次名就失效、还得重发版 ⇒ 撤回，回到只念 App 名。
            //     App 显示名本身改不了（`CFBundleDisplayName` 装完定死，无运行时改名的接口）。
            HStack(spacing: 5) {
                Image(systemName: "waveform")
                    .font(.system(size: 10))
                    .foregroundStyle(Cfg.Palette.faint)
                Text("对 Siri 说「跟还在说句话」· 它会问你要说什么")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            // ★★★ 系统自带的「快捷指令」入口（v59 加的，v60 更正了说法）。
            //
            //   v59 我以为「Siri 说『不支持』」是因为快捷指令里那个开关没拨开，
            //   所以放了这颗按钮。**那个判断是错的** —— 真凶是短语里那个
            //   「猫叫什么名字」的空位（系统没法预填，整句作废），
            //   已经在 `TalkToCatIntent.swift` 里修掉了。
            //
            //   ★ 按钮留着，是因为它确实有用：点开这一页就能**亲眼看到**
            //     系统到底收下了哪几句话 —— v59 之前那一页是空的，
            //     正因为短语没被收下；v60 之后应该能看到「跟它说句话」。
            //     这比任何说明文字都直观，也省得他再问我「到底该说什么」。
            ShortcutsLink()
                .shortcutsLinkStyle(.automaticOutline)

            // 装完必须打开一次 App，系统才会把这几句登记进去 ——
            // 没打开过就是「这个 App 不支持用 Siri 做这件事」。
            // 这句只在他还没成功用过时才有价值，所以直接写死一行小字，不做判断。
            // ★ v66：小窗上那个键现在跑的是「问它」，而「问它」要在快捷指令里存在一次。
            //   这一步是他自己点的（苹果没给第三方 App 写快捷指令库的接口），
            //   但**只点一次**，之后就一直是「按小窗键 → 弹框 → 画中画不动」。
            Text("点上面那颗 → 找到「问它」→ 点「添加」，做一次就行 · 之后按小窗上那个键就是它")
                .font(.system(size: 10))
                .foregroundStyle(Cfg.Palette.faint)
                .fixedSize(horizontal: false, vertical: true)
                .font(.system(size: 10))
                .foregroundStyle(Cfg.Palette.faint)
                .fixedSize(horizontal: false, vertical: true)

            // 它的声音（v48）：关了它照样跑跳，只是不出声 —— 跟安卓那个开关是同一条。
            HStack(spacing: 6) {
                Image(systemName: soundOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(soundOn ? .green : .secondary)
                Text("它的声音")
                    .font(.system(size: 11))
                Toggle("", isOn: $soundOn)
                    .labelsHidden()
                    .scaleEffect(0.75)
                    .frame(width: 44)
                Spacer()
                Button("喵一声") { SoundKit.shared.meow() }
                    .buttonStyle(ChipButton())
            }
            .onChange(of: soundOn) { _, v in SoundKit.shared.on = v }

            // 小窗气泡开关。
            // ★ 这一行是排障的眼睛：字进小窗连着两版闪退（v32/v33），
            //   先关掉保「App 能开」。装上新版先看这行写的是「开」还是「关」，
            //   别靠猜 —— 之前版本号停在 v30 三个版本，就是没人看得见装的是什么。
            HStack(spacing: 6) {
                Image(systemName: Cfg.liveFramePiP ? "dot.radiowaves.left.and.right" : "bubble.right")
                    .font(.system(size: 11))
                    .foregroundStyle(Cfg.liveFramePiP ? .green : .orange)
                Text(Cfg.bubbleStatusText)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text(AppVersion.tag)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Cfg.Palette.faint)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(Capsule().fill(Cfg.Palette.accent.opacity(0.08)))

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
