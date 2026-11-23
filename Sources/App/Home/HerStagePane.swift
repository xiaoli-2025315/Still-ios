import SwiftUI
import UIKit

// MARK: - 「它」页首页本体（2026-11-23 方向纠偏后）
//
// ★ 不是从「角色」按钮另开一页：这一块直接占住首页的「它」这一格，
//   跟聊天、记忆用同一条底栏、同一套浅色组件。
// ★ 卡里播的是 OrbPet / CatPack 那套透明动态帧包，不是 sit.gif 白底静图。
// ★ 没形象：加号 +「创作动态形象」；三颗功能键全灰 +「请先创建形象」。
//   老 HerPane 一行没删，要退回把 MainHomeView 里 case 0 换回去即可。

@MainActor
struct HerStagePane: View {
    @ObservedObject var pip: PiPController
    @ObservedObject private var packs = CatPackStore.shared
    var onHit: () -> Void = {}
    /// 点「创作动态形象」：回到角色页登记/做第一套动作（老流程一行没删）
    var onCreateImage: () -> Void = {}

    @State private var roles: [ActLab.Char] = []
    @State private var pos: Double = 0
    @State private var dragStart: Double = 0
    @State private var focus = 0
    /// 0 = 三张合在一起像一叠牌；1 = 摊开成扇形。切到它页时播放展开。
    @State private var spread: CGFloat = 0
    @State private var panel = ""          // "" / "float" / "pinch" / "make" / "chat"
    @State private var hint = ""
    @State private var sqState = 0         // 0 browse / 1 paint / 2 play
    @State private var sqTool = 0
    @State private var sqKey = 0
    /// 焦点卡上那层涂抹层（只记软区 mask，不触发形变）。
    @State private var paintRef: CardPinchPaint? = nil
    /// ★ 形变桥：涂抹层和形变 view 通过它传软区采样 + 触摸事件。
    ///   @State 持引用类型，SwiftUI 重建不会换实例。
    @State private var playBridge = SquishPlayBridge()
    /// 软区有无（驱动「确认」按钮 enabled，避免回调里读 @State 快照滞后）
    @State private var hasSoftPaint = false

    @State private var prompt = ""
    @State private var model = "wan"
    @State private var boundSlot = ""
    @State private var confirmShow = false
    @State private var chatLines: [ChatLine] = []
    @State private var banner = ""

    private struct ChatLine: Identifiable {
        let id = UUID()
        let text: String
        let mine: Bool
    }

    // ★ 2026-11-24：卡面加大（对齐预览），角色缩小留白；扇形展牌靠 rotationEffect。
    private let cardW: CGFloat = 182
    private let cardH: CGFloat = 258
    private let gap: CGFloat = 150

    // MARK: 当前角色

    private var currentRole: ActLab.Char? {
        roles.indices.contains(focus) ? roles[focus] : nil
    }

    private var currentHasFrame: Bool {
        guard let c = currentRole else { return false }
        return OrbPet.hasFrame(c.id)
    }

    private var stageLocked: Bool {
        !panel.isEmpty && panel != "float"
    }

    private var promptReady: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 舞台卡片本身。抽出来是为了按 sqState 决定要不要挂高优先级拖拽。
    @ViewBuilder
    private var stageContent: some View {
        ZStack {
            if roles.isEmpty {
                addCard
            } else {
                ForEach(roles.indices, id: \.self) { i in
                    roleCard(i)
                }
            }
        }
        // 舞台固定高度（跟安卓 330dp 一致），下方交给 Spacer 把面板压到底栏上方。
        .frame(height: 330)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    /// ★ 拖动改成 highPriorityGesture（对齐 MainHomeView 老 HerPane）：按在卡上也能拨。
    ///   涂抹时（stageLocked）整段手势不挂 —— 高优先级拖拽会抢走笔迹的触摸；
    ///   这样既保留「stageLocked 吞拖动」，笔也涂得动。
    @ViewBuilder
    private var stageView: some View {
        if stageLocked {
            stageContent
        } else {
            stageContent
                .highPriorityGesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { v in
                            // 循环：往一个方向一直滑就一直换，不再卡在两端。
                            pos = dragStart - Double(v.translation.width / gap)
                        }
                        .onEnded { _ in
                            guard !roles.isEmpty else { return }
                            let n = roles.count
                            let target = ((Int(pos.rounded()) % n) + n) % n
                            // 走最短一圈回到选中位置，避免多滑了后跳一大段。
                            var m = pos.truncatingRemainder(dividingBy: Double(n))
                            if m < 0 { m += Double(n) }
                            var delta = Double(target) - m
                            if delta > Double(n) / 2 { delta -= Double(n) }
                            if delta < -Double(n) / 2 { delta += Double(n) }
                            withAnimation(.easeOut(duration: 0.26)) {
                                focus = target
                                pos += delta
                                dragStart = pos
                            }
                            onHit()
                        }
                )
        }
    }

    var body: some View {
        // ★ 11-24 夜：整页铺满、不再上下滑；「它在这儿」小标题按他要求删掉。
        GeometryReader { _ in
            VStack(alignment: .leading, spacing: 0) {
                stageView

                Text(currentRole?.title ?? "还没有形象")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Tw.gray900)
                    .frame(maxWidth: .infinity)
                // 「左右拖动换一只」按他要求删掉。
                if currentRole == nil {
                    Text("先做一只，它就有地方住了")
                        .font(.system(size: 11))
                        .foregroundStyle(Tw.gray400)
                        .frame(maxWidth: .infinity)
                }
                HStack(spacing: 8) {
                    actionButton("悬浮模式", enabled: currentHasFrame && sqState != 2) { showPanel("float") }
                    actionButton("捏捏它", enabled: currentHasFrame) { pinchTap() }
                    actionButton("制作动作", enabled: currentHasFrame && sqState != 2) { showPanel("make") }
                }

                if !currentHasFrame {
                    Text("请先创建形象")
                        .font(.system(size: 13))
                        .foregroundStyle(Tw.gray400)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10)
                }

                if !hint.isEmpty {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(Tw.gray500)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }

                // 这段空白把面板压到底栏上方，工具条贴着底栏从下方推出。
                Spacer(minLength: 8)

                // ★ 11-24 夜：面板从屏幕下方推出、切走收回（跟安卓同一手感）。
                ZStack {
                    if panel == "float" { floatPanel }
                    if panel == "pinch" { pinchPanel }
                    if panel == "make" { makePanel }
                    if panel == "chat" { chatPanel }
                }
                .frame(height: 214)
                .padding(.top, 4)
                .offset(y: panel.isEmpty ? 240 : 0)
                .opacity(panel.isEmpty ? 0 : 1)
                .animation(.easeOut(duration: 0.26), value: panel)

                if !banner.isEmpty {
                    Text(banner)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tw.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Tw.gray900))
                        .padding(.top, 8)
                }
            }
            // ★ 展开动画挂在外层稳定 VStack 上：开合捏捏面板不会重播摊牌。
            .onAppear {
                spread = 0
                withAnimation(.easeInOut(duration: 0.42)) { spread = 1 }
            }
            // ★ 整页铺满：左右不留白，两侧卡延伸到屏幕边缘（gap 仍按安卓约定 150）。
            .padding(.horizontal, 0)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .background(Color.clear)   // ★ 透出底下 MainHomeView 的全屏动态柔光
        .task { await load() }
        .alert("确认开始生成？", isPresented: $confirmShow) {
            Button("取消", role: .cancel) {}
            Button("确认生成") {
                Task { await submitJob() }
            }
        } message: {
            Text("角色：\(currentRole?.title ?? "它")\n用哪个来做：\(model == "wan" ? "wan" : "豆包号")\n时长：5s\n\n\(prompt)")
        }
    }

    // MARK: - 角色卡

    private var addCard: some View {
        VStack(spacing: 8) {
            Text("＋")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Tw.gray400)
            Text("创作动态形象")
                .font(.system(size: 13))
                .foregroundStyle(Tw.gray500)
        }
        .frame(width: cardW, height: cardH)
        .background(glassCard(on: false))
        // ★ 加号卡不再进动作库：点到只给个提示，什么都不打开。
        .onTapGesture { hint = "加号卡只占位，这里不进动作库" }
        .frame(maxWidth: .infinity)
    }

    /// ★ 玻璃卡：厚度感由 GlassPlate 分层画出，无阴影、无均匀白描边。
    private func glassCard(on: Bool) -> some View {
        ZStack {
            GlassPlate(corner: 26, opacity: on ? 0.32 : 0.22)
            // 斜向内高光保留
            LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.03), Color.clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }

    @ViewBuilder
    private func roleCard(_ i: Int) -> some View {
        if i < roles.count {
            let c = roles[i]
            let n = roles.count
            // 循环最短偏移：选中的那张永远在正中，左右从队尾/队首接上。
            // ★ 赋值必须放进闭包里算：@ViewBuilder 里直接写 var += 会被当成 View 表达式而报错。
            let d: Double = {
                var m = pos.truncatingRemainder(dividingBy: Double(n))
                if m < 0 { m += Double(n) }
                var v = Double(i) - m
                if v > Double(n) / 2 { v -= Double(n) }
                if v < -Double(n) / 2 { v += Double(n) }
                return v
            }()
            let ad = abs(d)
            // ★ 扇形展牌：旋转锚点挪到卡下方（y=1.68），越靠边转得越多 → 底部收拢顶部散开。
            //   spread=0 时合成一叠（微微错开）；切到它页 0→1 摊开。
            let fold: CGFloat = 1 - spread
            let sc0 = max(0.90, 1 - ad * 0.05)
            let sc = sc0 * spread + 0.86 * fold
            let op = ad > 2.01 ? 0 : max(0.5, 1 - ad * 0.22)
            let on = (i == focus)
            let stackRot = CGFloat(i - (n - 1) / 2) * 1.6
            let rot = CGFloat(d) * 11 * spread + stackRot * fold
            // ★ 帧是 384×216 宽幅，在卡里 scaledToFit 后只占中间一条。
            //   涂抹层按这个实际显示矩形摆，软区采样 (u,v) 才跟播放帧逐格对齐。
            let frameBox = CGSize(width: cardW * 0.92, height: cardH * 0.84)
            let frameRect = OrbPet.frameRect(in: frameBox, charId: c.id)

            ZStack(alignment: .bottom) {
                glassCard(on: on)

                if OrbPet.hasFrame(c.id) {
                    // ★ 玩耍态形变只给焦点卡；确认后桥接软区采样，涂抹期照旧走 Image 分支。
                    OrbPet(charId: c.id, actName: "sit", width: cardW * 0.92,
                           playBridge: on ? playBridge : nil,
                           playEnabled: on && sqState == 2)
                        .frame(width: cardW * 0.92, height: cardH * 0.84)
                } else {
                    VStack(spacing: 8) {
                        Text("＋")
                            .font(.system(size: 42, weight: .light))
                            .foregroundStyle(Tw.gray400)
                        Text("创作动态形象")
                            .font(.system(size: 11))
                            .foregroundStyle(Tw.gray500)
                    }
                }

                // ★ 名字区：一整块深灰半透明托槽，从角色图下沿铺到卡底。
                //   Z 序在 OrbPet 之后、CardPinchPaint 之前；半透明能透出一点猫。
                nameTray(i, c)

                // ★ 涂抹层严格盖在帧图的实际显示矩形上（居中），软区采样 (u,v)
                //   才跟形变格心逐格对上。只焦点卡常驻：涂抹/玩耍期收触摸，平时不收。
                if on && OrbPet.hasFrame(c.id) {
                    CardPinchPaintView(active: panel == "pinch" && (sqState == 1 || sqState == 2),
                                       playMode: sqState == 2,
                                       tool: sqTool, key: sqKey,
                                       bridge: playBridge,
                                       onSoftChanged: { hasSoftPaint = $0 },
                                       onReady: { paintRef = $0 })
                        .frame(width: frameRect.width, height: frameRect.height)
                        .frame(width: frameBox.width, height: frameBox.height, alignment: .center)
                }
            }
            .frame(width: cardW, height: cardH)
            .rotationEffect(.degrees(rot), anchor: UnitPoint(x: 0.5, y: 1.68))
            .scaleEffect(CGFloat(sc))
            .opacity(op)
            .offset(x: CGFloat(d) * gap * spread,
                    y: ad * 14 * spread + CGFloat(i) * 2 * fold)
            .onTapGesture {
                // ★ 点卡只做选中，绝不进动作库（有没有形象都一样）。
                selectRole(i)
            }
        }
    }

    /// 点卡 / 托槽「看看它」共用：就近选中，锁住时（涂抹/玩耍）不换人。
    private func selectRole(_ i: Int) {
        guard !stageLocked, roles.indices.contains(i), i != focus else { return }
        let n = roles.count
        var mm = pos.truncatingRemainder(dividingBy: Double(n))
        if mm < 0 { mm += Double(n) }
        var delta = Double(i) - mm
        if delta > Double(n) / 2 { delta -= Double(n) }
        if delta < -Double(n) / 2 { delta += Double(n) }
        withAnimation(.easeOut(duration: 0.26)) {
            focus = i
            pos += delta
            dragStart = pos
        }
        onHit()
    }

    /// ★ 名字区大灰托槽：名字 + 认证勾 / 灰色简介 / 底部数据 + 中性小按钮。
    @ViewBuilder
    private func nameTray(_ i: Int, _ c: ActLab.Char) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(c.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Tw.white)
                    .lineLimit(1)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.85))
            }
            Text(c.channel.map { $0.isEmpty ? "一只住在这里的小家伙" : $0 }
                 ?? "一只住在这里的小家伙")
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.55))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text("已完成 \(c.done ?? 0) 段动作")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    onHit()
                    selectRole(i)
                } label: {
                    Text("看看它")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.16)))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 9)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(hex: 0x1E1E22).opacity(0.86))
                // 顶边一道细高光，两端渐隐，呼应玻璃厚度语言
                GeometryReader { g in
                    Path { p in
                        p.move(to: CGPoint(x: 16, y: 0.6))
                        p.addLine(to: CGPoint(x: g.size.width - 16, y: 0.6))
                    }
                    .stroke(
                        LinearGradient(colors: [Color.white.opacity(0),
                                                Color.white.opacity(0.22),
                                                Color.white.opacity(0)],
                                       startPoint: .leading, endPoint: .trailing),
                        lineWidth: 0.9
                    )
                }
            }
        )
        .padding(.horizontal, 5)
        .padding(.bottom, 4)
    }

    // MARK: - 三颗功能键

    private func actionButton(_ label: String, enabled: Bool,
                              _ tap: @escaping () -> Void) -> some View {
        Button {
            onHit()
            tap()
        } label: {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(enabled ? Tw.gray900 : Tw.gray400)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                // ★ 玻璃厚度：分层侧壁 + 高光断点，无阴影无白框。
                .glassThickness(corner: 18, opacity: enabled ? 0.46 : 0.22)
        }
        .buttonStyle(PressStyle(scale: 0.97))
        .disabled(!enabled)
    }

    private func showPanel(_ which: String) {
        panel = (panel == which) ? "" : which
        hint = ""
        if panel == "float" {
            if pip.active {
                pip.toggle()
                hint = "它先回去了。想它就再让它出来。"
            } else {
                pip.toggle()
                hint = "它出来了，浮在屏幕上"
            }
        }
    }

    private func pinchTap() {
        if sqState == 2 {
            // 玩耍态再点「捏捏它」＝还原退出
            clearPinch()
            return
        }
        if sqState == 1 {
            exitPinch()
            return
        }
        panel = "pinch"
        sqState = 1
        sqTool = 0
        // 只有真正开始新的一次才清软区（key 变化会让涂抹层回调一次空 mask）。
        sqKey += 1
        playBridge.playEnabled = false
        playBridge.setPlaying(false)
        paintRef?.clearSoft()
        paintRef?.setMarksVisible(true, animated: false)
        hasSoftPaint = false
        hint = "用笔在它身上涂一块软的，涂完点确认"
    }

    private func confirmPinch() {
        guard paintRef?.hasSoft() == true else {
            hint = "先用笔在它身上涂一块，再点确认"
            return
        }
        // ★ 确认 → 玩耍态：桥接软区采样，形变 view 进玩耍，工具条只留「还原」。
        //   stageLocked 由 panel == "pinch" 派生，卡片拖动手势自动不挂。
        playBridge.paintView = paintRef
        playBridge.playEnabled = true
        playBridge.setPlaying(true)
        paintRef?.setMarksVisible(false, animated: true)
        sqState = 2
        hint = "摸摸它软的地方，按住拽拽看"
    }

    private func clearPinch() {
        // 先收形变，再清软区 / 标记，最后解锁恢复工具条。
        playBridge.setPlaying(false)
        playBridge.playEnabled = false
        paintRef?.clearSoft()
        paintRef?.setMarksVisible(true, animated: true)
        hasSoftPaint = false
        exitPinch()
        hint = "已还原，可以换动作了"
    }

    private func exitPinch() {
        sqState = 0
        sqKey += 1
        panel = ""
        hint = ""
    }

    // MARK: - 三块面板

    private var floatPanel: some View {
        VStack(spacing: 10) {
            Button {
                onHit()
                if !pip.active { pip.toggle() }
                hint = "它出来了，浮在屏幕上"
            } label: {
                Text("让它出现在屏幕上")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tw.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Tw.gray900))
            }
            .buttonStyle(PressStyle(scale: 0.97))

            Button {
                onHit()
                pip.stop()
                hint = "它先回去了。想它就再让它出来。"
            } label: {
                Text("让它先回去")
                    .font(.system(size: 13))
                    .foregroundStyle(Tw.gray900)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .glassThickness(corner: 22, opacity: 0.52)
            }
            .buttonStyle(PressStyle(scale: 0.97))
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var pinchPanel: some View {
        if sqState == 2 {
            // ★ 确认后工具条收起：只留一个居中的「还原」，别的全不显示。
            HStack {
                Spacer(minLength: 0)
                smallButton("还原", primary: true) { clearPinch() }
                Spacer(minLength: 0)
            }
            .frame(height: 62)
        } else {
            // ★ 涂抹中：笔 / 橡皮 / 取消 / 确认，白底阴影无白边。
            HStack(spacing: 12) {
                toolGlyph(asset: "tool_pencil", selected: sqTool == 0, wide: false) { sqTool = 0 }
                toolGlyph(asset: "tool_eraser", selected: sqTool == 1, wide: true) { sqTool = 1 }
                Spacer(minLength: 0)
                smallButton("取消", primary: false) { exitPinch() }
                smallButton("确认", primary: true, enabled: hasSoftPaint) { confirmPinch() }
            }
            .frame(height: 62)
        }
    }

    /// ★ 11-24 夜：换成他给的真素材（黄木铅笔 / 奶油小狗 4B 橡皮），系统图标那版留着可回退。
    private func toolGlyph(asset: String, selected: Bool, wide: Bool,
                           _ tap: @escaping () -> Void) -> some View {
        Button {
            onHit()
            tap()
        }         label: {
            ZStack {
                if let img = UIImage(named: asset) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: wide ? 68 : 52, height: 52)
                }
            }
            .frame(width: wide ? 76 : 62, height: 62)
            .glassThickness(corner: 31, opacity: selected ? 0.52 : 0.30)
        }
        .opacity(selected ? 1 : 0.72)
        .buttonStyle(PressStyle(scale: 0.94))
    }

    private func smallButton(_ label: String, primary: Bool, enabled: Bool = true,
                             _ tap: @escaping () -> Void) -> some View {
        Button {
            onHit()
            tap()
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? Tw.gray900 : Tw.gray400)
                .frame(width: 62, height: 34)
                // ★ 统一玻璃厚度，无阴影无描边。
                .glassThickness(corner: 12,
                                opacity: enabled ? (primary ? 0.55 : 0.34) : 0.18)
        }
        .buttonStyle(PressStyle(scale: 0.94))
        .disabled(!enabled)
    }

    private var makePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $prompt)
                .font(.system(size: 13))
                .foregroundStyle(Tw.gray900)
                .scrollContentBackground(.hidden)
                .frame(height: 56)
                .overlay(
                    Group {
                        if prompt.isEmpty {
                            Text("描述它要做什么动作，比如：它伸个懒腰，然后回头看看你。")
                                .font(.system(size: 13))
                                .foregroundStyle(Tw.gray400)
                                .padding(.horizontal, 4)
                                .padding(.top, 2)
                        }
                    }, alignment: .topLeading
                )

            HStack(spacing: 8) {
                Menu {
                    Button { model = "wan" } label: { Text("wan") }
                    if boundSlot.isEmpty {
                        Button { openDoubaoLogin() } label: { Text("绑定豆包账号") }
                    } else {
                        Button { model = "doubao" } label: { Text("豆包号（\(boundSlot)）") }
                    }
                } label: {
                    Text("用哪个来做：\(model == "wan" ? "wan" : "豆包号") ▾")
                        .font(.system(size: 11))
                        .foregroundStyle(Tw.gray500)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glassThickness(corner: 13, opacity: 0.44)
                }
                Text("5 秒")
                    .font(.system(size: 11))
                    .foregroundStyle(Tw.gray500)
                Spacer(minLength: 0)
                Button {
                    onHit()
                    if promptReady { confirmShow = true }
                } label: {
                    ZStack {
                        Circle()
                            .fill(promptReady ? Tw.gray900 : Tw.gray200)
                            .frame(width: 30, height: 30)
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(promptReady ? Tw.white : Tw.gray100)
                    }
                }
                .buttonStyle(PressStyle(scale: 0.94))
                .disabled(!promptReady)
            }
        }
        .padding(14)
        // ★ 玻璃厚度面板；TextEditor 文字仍是深色，看得清。
        .glassThickness(corner: 18, opacity: 0.50)
    }

    private var chatPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("和它的聊天")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Tw.gray900)
                .frame(maxWidth: .infinity)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(chatLines) { line in
                        HStack {
                            if line.mine { Spacer(minLength: 0) }
                            Text(line.text)
                                .font(.system(size: 12))
                                .foregroundStyle(line.mine ? Tw.white : Tw.gray900)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(line.mine ? Tw.gray900 : Color.white.opacity(0.72))
                                )
                            if !line.mine { Spacer(minLength: 0) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .padding(12)
        // ★ 玻璃厚度面板，无阴影无描边。
        .glassThickness(corner: 18, opacity: 0.52)
    }

    // MARK: - 数据 / 下单

    private func load() async {
        do {
            let cs = try await ActLab.chars()
            await MainActor.run {
                roles = cs
                if focus >= cs.count { focus = 0 }
                pos = Double(focus)
                dragStart = pos
            }
        } catch {
            // 没连上台子就留空，卡上照实显示加号，不编假角色。
        }
        do {
            let st = try await ActLab.loginState()
            if st.loggedIn {
                await MainActor.run { boundSlot = st.name; model = "doubao" }
            }
        } catch { }
    }

    private func openDoubaoLogin() {
        NotificationCenter.default.post(name: Notification.Name("StillOpenDoubaoLogin"), object: nil)
        hint = "先去绑一个豆包号，一人只绑一个"
    }

    private func addLine(_ text: String, _ mine: Bool) {
        chatLines.append(ChatLine(text: text, mine: mine))
    }

    private func submitJob() async {
        guard let c = currentRole else { return }
        let charId = c.id
        let roleName = c.title
        let desc = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let useModel = model
        let slot = boundSlot
        guard !desc.isEmpty else { return }

        panel = "chat"
        banner = ""
        chatLines.removeAll()
        addLine("正在把动作交给它做…", true)
        do {
            let d1 = try await ActLab.rawPost("/api/act/draft", body: ["char": charId, "描述": desc])
            let j1 = (try? JSONSerialization.jsonObject(with: d1) as? [String: Any]) ?? [:]
            guard j1["ok"] as? Bool == true else {
                let why = (j1["错误"] as? String) ?? "没接上台子"
                addLine(why, false)
                return
            }
            let job = (j1["单号"] as? String) ?? ""
            addLine("回执 \(job)，开工中…", true)
            var startBody: [String: Any] = ["单号": job]
            if useModel == "doubao" && !slot.isEmpty { startBody["账号"] = slot }
            let path = useModel == "wan" ? "/api/act/draft/wan" : "/api/act/draft/start"
            let d2 = try await ActLab.rawPost(path, body: startBody)
            let j2 = (try? JSONSerialization.jsonObject(with: d2) as? [String: Any]) ?? [:]
            addLine((j2["ok"] as? Bool == true) ? "它开始做了，做好了会告诉你"
                                                : ((j2["错误"] as? String) ?? "开工没成"), false)
            await poll(job: job, charId: charId)
        } catch {
            addLine("没接上台子：\(error.localizedDescription)", false)
        }
        _ = roleName
    }

    private func poll(job: String, charId: String) async {
        for _ in 0..<120 {
            do {
                let d = try await ActLab.rawPost("/api/act/draft/state", body: ["单号": job])
                let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
                let st = (j["状态"] as? String) ?? ""
                if st == "装好了" || st == "已完成" || st == "做好了" {
                    addLine("✓ 做完了，动作已存进它的记忆", false)
                    banner = "给它做的动作好了"
                    // 把新包装进手机，卡片立刻从加号变成透明动态帧。
                    _ = try? await CatPackStore.shared.install(charId: charId, force: true)
                    roles = (try? await ActLab.chars()) ?? roles
                    return
                }
            } catch {
                // 查不到状态不等于失败，继续等，不诱导重复下单。
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }
}

// MARK: - 玻璃厚度（替代阴影 + 均匀白描边）
//
// ★ 一块有厚度的透明玻璃：底层比面层略大、下/右缘更深（侧壁），
//   上层半透明白（玻璃面），再叠顶/左高光（两端 alpha 渐隐成高光断点）、
//   底边细折射线、上/左转角更亮的高光。

private struct GlassPlate: View {
    let corner: CGFloat
    let opacity: CGFloat

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let h = g.size.height
            ZStack {
                // 玻璃侧壁：略大一点、往右下错开，下/右缘渐深
                RoundedRectangle(cornerRadius: corner + 1.5, style: .continuous)
                    .fill(
                        LinearGradient(colors: [
                            Color.white.opacity(0.06),
                            Color.white.opacity(0.14),
                            Color.black.opacity(0.20)
                        ], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .offset(x: 1.4, y: 2.6)

                // 玻璃面
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color.white.opacity(opacity))

                // 顶边 + 左边一道亮线，LinearGradient 两端渐隐 → 高光不是一整圈
                Path { p in
                    p.move(to: CGPoint(x: corner * 0.9, y: 0.7))
                    p.addLine(to: CGPoint(x: w - corner * 0.6, y: 0.7))
                    p.move(to: CGPoint(x: 0.7, y: corner * 0.9))
                    p.addLine(to: CGPoint(x: 0.7, y: h - corner * 0.6))
                }
                .stroke(
                    LinearGradient(colors: [
                        Color.white.opacity(0),
                        Color.white.opacity(0.72),
                        Color.white.opacity(0.16),
                        Color.white.opacity(0)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1.1
                )

                // 底边细亮折射线
                Path { p in
                    p.move(to: CGPoint(x: corner, y: h - 0.8))
                    p.addLine(to: CGPoint(x: w - corner, y: h - 0.8))
                }
                .stroke(Color.white.opacity(0.26), lineWidth: 0.9)

                // 上/左转角高光更亮
                Path { p in
                    p.move(to: CGPoint(x: 0.9, y: corner))
                    p.addQuadCurve(to: CGPoint(x: corner, y: 0.9),
                                   control: CGPoint(x: 0.9, y: 0.9))
                }
                .stroke(Color.white.opacity(0.92), lineWidth: 1.5)
            }
        }
    }
}

private struct GlassThickness: ViewModifier {
    let corner: CGFloat
    let opacity: CGFloat
    func body(content: Content) -> some View {
        content.background(GlassPlate(corner: corner, opacity: opacity))
    }
}

private extension View {
    func glassThickness(corner: CGFloat = 18, opacity: CGFloat = 0.32) -> some View {
        modifier(GlassThickness(corner: corner, opacity: opacity))
    }
}

// MARK: - 捏捏画布接线（复用老 SquishView，只把「涂没涂」送到按钮）
struct StageSquish: UIViewRepresentable {
    @Binding var state: Int
    @Binding var tool: Int
    @Binding var key: Int
    @Binding var hasPaint: Bool

    func makeUIView(context: Context) -> SquishView {
        let v = SquishView()
        let flag = $hasPaint
        v.onMaskChanged = { flag.wrappedValue = $0 }
        return v
    }

    func updateUIView(_ v: SquishView, context: Context) {
        if v.lastKey != key {
            v.lastKey = key
            v.clearAll()
        }
        v.applyState(state, tool: tool)
    }
}
