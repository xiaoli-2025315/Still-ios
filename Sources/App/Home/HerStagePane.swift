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
    /// ★ 2026-11-24：制作动作面板输入框被键盘盖住 —— 按真实键盘高度把面板抬上去
    @ObservedObject private var kb = KeyboardHeight.shared
    var onHit: () -> Void = {}
    /// 点「创作动态形象」：回到角色页登记/做第一套动作（老流程一行没删）
    var onCreateImage: () -> Void = {}
    /// ★ 11-24：由 MainHomeView 在切到聊天/记忆浮层时 +1，触发「清除并退出捏捏」。
    ///   这两个页是 fullScreenCover，不会让本视图 onDisappear，得靠这个信号兜住。
    var pinchReset: Int = 0

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
    /// ★ 纠偏4：是否点过笔/橡皮。刚进捏捏=false（「取消」不出现），点工具后=true。
    @State private var toolChosen = false
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
    @State private var showWaySheet = false
    @State private var pendingDesc = ""   // 发送后到聊天里问方式期间，暂存用户写的动作原句
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

    // ★ 2026-11-26：3D 透视环。8 个槽位绕 Y 轴匀速转；选中卡拔出正对、身后卡合拢。
    private let stepDeg: Double = 45
    @State private var slotA: [Double] = Array(0..<8).map { Double($0) * 45 }
    /// 每张卡类型：0=有形象 1=有聊天端没形象 2=完全空卡。与 slotRoles 下标一一对应。
    @State private var cardKind: [Int] = Array(repeating: 2, count: 8)
    /// 环上 8 张卡对应的角色（nil=完全空卡）。
    @State private var slotRoles: [ActLab.Char?] = Array(repeating: nil, count: 8)
    @State private var selIdx: Int = -1
    @State private var selW: Double = 0
    @State private var selS: Double = 0
    @State private var pullIdx: Int = -1
    @State private var pullDy: CGFloat = 0
    @State private var dragDY: CGFloat = 0
    @State private var petOn = false
    private let ringTimer = Timer.publish(every: 0.033, on: .main, in: .common).autoconnect()
    private let gap: CGFloat = 150

    // MARK: 当前角色

    private var currentRole: ActLab.Char? {
        guard slotRoles.indices.contains(focus) else { return nil }
        return slotRoles[focus]
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
            ForEach(slotRoles.indices, id: \.self) { i in
                ringCard(i)
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
                            let dx = v.translation.width, dy = v.translation.height
                            if selIdx < 0 {
                                // 纵向拉超过阈值 → 抓正面那张开始拔出；否则横滑转环。
                                if pullIdx < 0 && abs(dy) > 14 && abs(dy) > abs(dx) * 1.1 {
                                    pullIdx = frontIndex()
                                }
                                if pullIdx >= 0 { pullDy = max(-70, min(90, dy)) }
                                else { pos = dragStart - Double(dx / gap) }
                            } else if pullIdx == selIdx || abs(dx) < abs(dy) {
                                pullIdx = selIdx
                                pullDy = max(-90, min(70, dy))
                            }
                        }
                        .onEnded { _ in
                            if pullIdx >= 0 && pullDy < -46 && selIdx < 0 {
                                let i = pullIdx; pullIdx = -1; pullDy = 0; flyTo(i); return
                            }
                            if pullIdx == selIdx && pullDy < -46 {
                                pullIdx = -1; pullDy = 0; startInsert(); return
                            }
                            pullIdx = -1; pullDy = 0
                            if selIdx < 0 {
                                let n = max(1, slotA.count)
                                let target = ((Int(pos.rounded()) % n) + n) % n
                                var m = pos.truncatingRemainder(dividingBy: Double(n))
                                if m < 0 { m += Double(n) }
                                var delta = Double(target) - m
                                if delta > Double(n) / 2 { delta -= Double(n) }
                                if delta < -Double(n) / 2 { delta += Double(n) }
                                withAnimation(.easeOut(duration: 0.26)) {
                                    pos += delta
                                    dragStart = pos
                                }
                            }
                            onHit()
                        }
                )
                .onReceive(ringTimer) { _ in
                    if !stageLocked && selIdx < 0 && spread > 0.05 && slotA.count > 1 {
                        pos += 0.006
                    }
                }
        }
    }

    private func frontIndex() -> Int {
        let pd = pos * stepDeg
        var best = 0, bd = 1e9
        for i in slotA.indices {
            let w = normDeg(slotA[i] - pd)
            if abs(w) < bd { bd = abs(w); best = i }
        }
        return best
    }

    var body: some View {
        // ★ 11-24 夜：整页铺满、不再上下滑；「它在这儿」小标题按他要求删掉。
        GeometryReader { _ in
            VStack(alignment: .leading, spacing: 0) {
                // ★ 2026-11-26：桌宠模式条（左上角，名字下拉 + 开关点）。
                HStack(spacing: 10) {
                    Text("桌宠模式").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Tw.gray500)
                    Menu {
                        ForEach(slotRoles.indices, id: \.self) { i in
                            if let c = slotRoles[i] {
                                Button(c.title) { pickPet(c) }
                            }
                        }
                    } label: {
                        Text((currentRole?.title ?? "选一只") + " ▾")
                            .font(.system(size: 11)).foregroundStyle(Tw.gray900)
                    }
                    Button { togglePet() } label: {
                        Text(petOn ? "●" : "○").font(.system(size: 20))
                            .foregroundStyle(petOn ? Tw.red600 : Tw.gray400)
                    }
                    Spacer()
                }
                .padding(.horizontal, 4).padding(.bottom, 2)

                stageView

                // ★ 名字只在卡面上显示：按钮上方这行整个删掉，不再单独显示角色名。
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
                // ★ 2026-11-24：面板打开时，键盘弹起就往上抬 kb.高，输入框不被盖住；
                //   面板没开照旧藏到屏幕下方 240。
                .offset(y: panel.isEmpty ? 240 : -kb.高)
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
        // ★ 11-24：切页 / 视图移除时＝清除涂抹＋退出玩耍＋解锁，不等残留。
        .onDisappear {
            退出并清除捏捏()
        }
        // ★ 11-24：聊天/记忆浮层按钮不会让本视图消失，靠这个计数变化兜住同等清理。
        .onChange(of: pinchReset) { _ in
            退出并清除捏捏()
        }
        .alert("确认开始生成？", isPresented: $confirmShow) {
            Button("取消", role: .cancel) {}
            Button("确认生成") {
                Task { await submitJob() }
            }
        } message: {
            Text("角色：\(currentRole?.title ?? "它")\n用哪个来做：\(model == "wan" ? "wan" : "豆包号")\n时长：5s\n\n\(prompt)")
        }
        // ★ 2026-11-26：发送后在聊天里多问一步「用哪个来做」。
        .confirmationDialog("用哪个来做？", isPresented: $showWaySheet, titleVisibility: .visible) {
            Button("wan") { model = "wan"; Task { await submitJob() } }
            if boundSlot.isEmpty {
                Button("绑定豆包账号") { openDoubaoLogin() }
            } else {
                Button("豆包号（\(boundSlot)）") { model = "doubao"; Task { await submitJob() } }
            }
            Button("取消", role: .cancel) {}
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

    /// ★ 2026-11-24 纠偏2：卡片回到单层半透明白底圆角。
    ///   不再叠侧壁 / 高光 Path，也去掉斜向内高光；玻璃感靠透出 HerStageBg 动态背景。
    private func glassCard(on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(Color.white.opacity(on ? 0.32 : 0.22))
    }

    /// 3D 环一张卡的几何（普通函数，避开 @ViewBuilder 里不能写赋值语句的限制）。
    private struct RingGeom {
        var w: Double = 0
        var ringR: CGFloat = 0
        var ty: CGFloat = 0
        var sc: CGFloat = 1
        var op: Double = 1
        var picked: Bool = false
        var depth: Double = 1
        var x: CGFloat = 0
    }

    private func ringGeom(_ i: Int) -> RingGeom {
        let n = slotA.count
        let pd = pos * stepDeg
        var g = RingGeom()
        g.ringR = cardW * 1.66
        var w = normDeg(slotA[i] - pd)

        // ① 完全拔出选中：正对、前推、下移、稍大、实体。
        if i == selIdx && selS > 0.99 {
            w = normDeg(selW)
            g.ty = 44; g.sc = 1.12; g.op = 1; g.picked = true
        }
        // ② 跟手：被抓的卡随手指上下；已选中的卡只在拔出位微微跟。
        else if i == pullIdx && abs(pullDy) > 0.01 {
            g.ty = (i == selIdx ? 44 : 0) + pullDy * 0.85
            g.sc = i == selIdx ? 1.12 : 1 + max(0, pullDy) * 0.0009
            g.op = 0.88
        }
        // ③ 环上的卡：身后合拢（角度就近挪向缺口 + 半径收进），三档虚实。
        else {
            let tgt = closedAngle(i, n: n)
            let angle = selIdx >= 0 && selS > 0
                ? slotA[i] + selS * normDeg(tgt - slotA[i]) : slotA[i]
            if selIdx >= 0 && selS > 0 {
                g.ringR = g.ringR * CGFloat(1 - selS)
                    + (cardW * 1.66 * CGFloat(n - 1) / CGFloat(n)) * CGFloat(selS)
            }
            w = normDeg(angle - pd)
            let dim = min(1, max(0, (abs(w) - 30) / 150))
            g.op = (1 - dim * 0.5) * (selIdx >= 0 ? (1 - 0.22 * (1 - abs(w) / 180)) : 1)
        }
        g.depth = cos(w * .pi / 180)
        let perspectiveScale: CGFloat = 0.72 + 0.28 * CGFloat(max(0, g.depth))
        g.sc = g.sc * perspectiveScale
        g.x = CGFloat(sin(w * .pi / 180)) * g.ringR
        g.w = w
        return g
    }

    // ★ 2026-11-26：3D 透视环上的一张卡（原生 rotation3DEffect，不是网页）。
    @ViewBuilder
    private func ringCard(_ i: Int) -> some View {
        let g = ringGeom(i)
        let w = g.w
        let kind = i < cardKind.count ? cardKind[i] : 2

        ZStack(alignment: .bottom) {
            if kind == 0, let c = slotRoles[i] {
                glassCard(on: g.picked)
                if OrbPet.hasFrame(c.id) {
                    OrbPet(charId: c.id, actName: "sit", width: cardW * 0.92,
                           playBridge: (i == focus && !g.picked) ? playBridge : nil,
                           playEnabled: i == focus && sqState == 2)
                        .frame(width: cardW * 0.92, height: cardH * 0.84)
                }
                ZStack(alignment: .bottom) {
                    LinearGradient(colors: [Color.clear, Color(hex: 0x1A1A1E).opacity(0.8)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: cardH * 0.4)
                    Text(c.title).font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.white.opacity(g.picked ? 1 : 0.82))
                        .lineLimit(1).padding(.bottom, 8)
                }
                .frame(maxWidth: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
                if i == focus && OrbPet.hasFrame(c.id) {
                    CardPinchPaintView(active: panel == "pinch" && (sqState == 1 || sqState == 2),
                                       playMode: sqState == 2, tool: sqTool, key: sqKey,
                                       bridge: playBridge,
                                       onSoftChanged: { hasSoftPaint = $0 },
                                       onReady: { paintRef = $0 })
                        .frame(width: cardW * 0.92, height: cardH * 0.84)
                }
            } else {
                VStack(spacing: 8) {
                    Text("＋").font(.system(size: 42, weight: .light))
                        .foregroundStyle(Tw.gray400)
                    Text(kind == 2 ? "创建角色" : "创作动态形象")
                        .font(.system(size: 11)).foregroundStyle(Tw.gray500)
                }
                .frame(width: cardW, height: cardH)
                .background(glassCard(on: g.picked))
            }
        }
        .frame(width: cardW, height: cardH)
        .scaleEffect(g.sc)
        .rotation3DEffect(.degrees(w), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
        .offset(x: g.x, y: g.ty + CGFloat(abs(w)) * 0.08)
        .opacity(g.op)
        .zIndex(g.depth + (g.picked ? 100 : 0))
        .animation(.easeOut(duration: 0.28), value: selIdx)
        .onTapGesture { ringTap(i, kind: kind) }
    }

    private func ringTap(_ i: Int, kind: Int) {
        if stageLocked { return }
        if selIdx >= 0 { return }               // 选中期间锁：先上滑插回
        if kind == 1 || kind == 2 {
            // 建动态形象 / 建角色都进角色页那条真实入口（做形象、登记都在那）。
            onCreateImage()
            return
        }
        flyTo(i)
    }

    private func normDeg(_ a: Double) -> Double {
        var x = a.truncatingRemainder(dividingBy: 360)
        if x >= 180 { x -= 360 }
        if x < -180 { x += 360 }
        return x
    }

    private func closedAngle(_ i: Int, n: Int) -> Double {
        guard selIdx >= 0, n > 1 else { return slotA[i] }
        let rest = slotA.indices.filter { $0 != selIdx }.sorted { normDeg(slotA[$0]) < normDeg(slotA[$1]) }
        let k = rest.firstIndex(of: i) ?? 0
        let start = normDeg(selW + 180 / Double(n - 1))
        return start + Double(k) * (360 / Double(n - 1))
    }

    private func flyTo(_ i: Int) {
        guard slotA.indices.contains(i) else { return }
        let w0 = normDeg(slotA[i] - pos * stepDeg)
        selIdx = i
        pullIdx = -1; pullDy = 0
        focus = i
        withAnimation(.easeOut(duration: 0.56)) {
            selW = w0 * 0.001
            selS = 1
        }
        onHit()
    }

    private func startInsert() {
        guard selIdx >= 0 else { return }
        let idx = selIdx
        var nearest = slotA[idx], bd = 1e9
        for j in slotA.indices where j != idx {
            let d = abs(normDeg(slotA[j] - pos * stepDeg - selW))
            if d < bd { bd = d; nearest = slotA[j] }
        }
        let targetW = normDeg(nearest - pos * stepDeg)
        withAnimation(.easeOut(duration: 0.56)) {
            selS = 0
            selW = targetW
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.58) {
            slotA[idx] = normDeg(selW + pos * stepDeg)
            let order = slotA.indices.sorted { normDeg(slotA[$0] - pos * stepDeg) < normDeg(slotA[$1] - pos * stepDeg) }
            let start = slotA[idx]
            for (k, oi) in order.enumerated() { slotA[oi] = normDeg(start + Double(k) * stepDeg) }
            selIdx = -1; selW = 0; selS = 0; pullIdx = -1; pullDy = 0
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

                // ★ 纠偏5：名字区改成卡片下部自下而上由深到透明的渐变蒙层，
                //   上面只放一个白色名字。Z 序在 OrbPet 之后、CardPinchPaint 之前；
                //   allowsHitTesting(false) 保证不拦截涂抹/玩耍的触摸。
                ZStack(alignment: .bottom) {
                    LinearGradient(colors: [Color.clear, Color(hex: 0x1A1A1E).opacity(0.8)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: cardH * 0.4)
                    Text(c.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.white.opacity(on ? 1 : 0.82))
                        .lineLimit(1)
                        .padding(.bottom, 8)
                }
                .frame(maxWidth: .infinity, alignment: .bottom)
                .allowsHitTesting(false)

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

    /// 点卡选中：就近选中，锁住时（涂抹/玩耍）不换人。
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
                // ★ 单层半透明白底，跟其他组件同层，不浮起来。
                .flatGlass(corner: 18, opacity: enabled ? 0.46 : 0.22)
        }
        .buttonStyle(PressStyle(scale: 0.97))
        .disabled(!enabled)
    }

    private func showPanel(_ which: String) {
        if panel == "pinch" {
            // ★ 11-24：从捏捏切到别的模式 → 清除涂抹＋退出玩耍＋解锁，等同「清除并退出捏捏」。
            退出并清除捏捏()
        }
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
            // ★ 纠偏4：玩耍态再点「捏捏它」＝退出玩耍回「刚进捏捏」态，
            //   软区保留（不调 clearPinch、不清软区），工具条回到笔/橡皮/确认。
            playBridge.setPlaying(false)
            playBridge.playEnabled = false
            paintRef?.setMarksVisible(true, animated: true)
            sqState = 1
            sqTool = 0
            toolChosen = false
            hint = "用笔在它身上涂一块软的，涂完点确认"
            return
        }
        if sqState == 1 {
            exitPinch()
            return
        }
        panel = "pinch"
        sqState = 1
        sqTool = 0
        toolChosen = false
        // 只有真正开始新的一次才清软区（key 变化会让涂抹层回调一次空 mask）。
        sqKey += 1
        playBridge.playEnabled = false
        playBridge.setPlaying(false)
        paintRef?.clearSoft()
        paintRef?.setMarksVisible(true, animated: false)
        hasSoftPaint = false
        hint = "用笔在它身上涂一块软的，涂完点确认"
    }

    /// ★ 纠偏4：点铅笔 / 橡皮。玩耍态先退出玩耍（软区保留），再进涂抹/选取态；
    ///   点过工具后 toolChosen=true，「取消」这时才出现。
    private func pickTool(_ tool: Int) {
        if sqState == 2 {
            playBridge.setPlaying(false)
            playBridge.playEnabled = false
            paintRef?.setMarksVisible(true, animated: true)
            sqState = 1
        }
        sqTool = tool
        toolChosen = true
    }

    private func confirmPinch() {
        guard paintRef?.hasSoft() == true else {
            hint = "先用笔在它身上涂一块，再点确认"
            return
        }
        // ★ 确认 → 玩耍态：桥接软区采样，形变 view 进玩耍；按钮「确认」原地变「清除」，
        //   笔/橡皮保留、取消隐藏（pinchPanel 按 sqState 分支）。
        playBridge.paintView = paintRef
        playBridge.playEnabled = true
        playBridge.setPlaying(true)
        paintRef?.setMarksVisible(false, animated: true)
        sqState = 2
        hint = "摸摸它软的地方，按住拽拽看"
    }

    /// ★ 纠偏4：「清除」新语义——清软区 / 标记、退出玩耍，但**留在捏捏界面**，
    ///   回到「刚进捏捏」态（笔/橡皮/确认，取消不出现）。不调 exitPinch、不清 panel。
    private func clearPinch() {
        playBridge.setPlaying(false)
        playBridge.playEnabled = false
        paintRef?.clearSoft()
        paintRef?.setMarksVisible(true, animated: true)
        hasSoftPaint = false
        sqState = 1
        sqTool = 0
        toolChosen = false
        // key 变化兜底：即便 paintRef 此刻为 nil，下次 updateUIView 也会再清一次软区。
        sqKey += 1
        hint = "已清除，可以重新涂软的地方"
    }

    private func exitPinch() {
        playBridge.setPlaying(false)
        playBridge.playEnabled = false
        sqState = 0
        sqTool = 0
        toolChosen = false
        sqKey += 1
        panel = ""
        hint = ""
    }

    /// ★ 11-24：离开捏捏＝清除本次涂抹＋退出玩耍＋解锁角色卡横轨。
    /// 切页、点悬浮模式/制作动作/聊天都会走这里，回来不会残留「清除」态、也不会锁住竖选。
    private func 退出并清除捏捏() {
        playBridge.setPlaying(false)
        playBridge.playEnabled = false
        paintRef?.clearSoft()
        paintRef?.setMarksVisible(true, animated: false)
        hasSoftPaint = false
        sqState = 0
        sqTool = 0
        toolChosen = false
        sqKey += 1                       // 兜底：paintRef 为 nil 时下次 updateUIView 也清一次
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
                    .flatGlass(corner: 22, opacity: 0.52)
            }
            .buttonStyle(PressStyle(scale: 0.97))
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var pinchPanel: some View {
        // ★ 纠偏4：笔 / 橡皮常驻；「确认 / 清除」同一位置换文字和回调；
        //   「取消」只在 toolChosen && sqState==1（涂抹/选取态）出现。
        //   内层 if 交给 HStack 的 ViewBuilder 消化，整体仍是单一 some View。
        HStack(spacing: 12) {
            toolGlyph(asset: "tool_pencil", selected: sqTool == 0, wide: false) { pickTool(0) }
            toolGlyph(asset: "tool_eraser", selected: sqTool == 1, wide: true) { pickTool(1) }
            Spacer(minLength: 0)
            // ★ 取消 = 一键清除：清掉刚涂的软区、留在捏捏面板，不再退出。
            if toolChosen && sqState == 1 {
                smallButton("取消", primary: false) { clearPinch() }
            }
            if sqState == 2 {
                smallButton("清除", primary: true) { clearPinch() }
            } else {
                // ★ 确认键不再灰化：没涂时点它会提示，但仍一眼看得清。
                smallButton("确认", primary: true) { confirmPinch() }
            }
        }
        .frame(height: 62)
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
            .flatGlass(corner: 31, opacity: selected ? 0.52 : 0.30)
        }
        .opacity(selected ? 1 : 0.72)
        .buttonStyle(PressStyle(scale: 0.94))
    }

    private func smallButton(_ label: String, primary: Bool,
                             _ tap: @escaping () -> Void) -> some View {
        Button {
            onHit()
            tap()
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                // ★ 确认/清除 = 实心深底白字，一眼看得清；取消 = 浅底深字。
                .foregroundStyle(primary ? Tw.white : Tw.gray900)
                .frame(width: 62, height: 34)
                .background(
                    Capsule().fill(primary ? Tw.gray900 : Color.white.opacity(0.72))
                )
        }
        .buttonStyle(PressStyle(scale: 0.94))
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
                // ★ 2026-11-26：秒数、制作方式都撤掉；发送后在聊天里多问一步方式。
                Spacer(minLength: 0)
                Button {
                    onHit()
                    if promptReady { confirmMake() }
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
        // ★ 不再给整块面板垫一层透明底：输入区各组件自带底，别多垫一层。
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
        // ★ 单层半透明面板，无阴影无描边。
        .flatGlass(corner: 18, opacity: 0.52)
    }

    // MARK: - 数据 / 下单

    private func load() async {
        do {
            let cs = try await ActLab.chars()
            await MainActor.run {
                roles = cs
                // ★ 2026-11-26：一环 8 张；有形象优先全摆上（与创建先后无关），
                //   不足依次补「有聊天端没形象」「完全空卡」。@MainActor 下同步取 hasFrame。
                var filled: [ActLab.Char?] = Array(repeating: nil, count: 8)
                var kinds: [Int] = Array(repeating: 2, count: 8)
                var k = 0
                for c in cs where OrbPet.hasFrame(c.id) {
                    if k >= 8 { break }
                    filled[k] = c; kinds[k] = 0; k += 1
                }
                for c in cs where !OrbPet.hasFrame(c.id) {
                    if k >= 8 { break }
                    filled[k] = c; kinds[k] = 1; k += 1
                }
                slotRoles = filled
                cardKind = kinds
                slotA = Array(0..<8).map { Double($0) * 45 }
                selIdx = -1; selW = 0; selS = 0; pullIdx = -1; pullDy = 0
                if focus >= 8 { focus = 0 }
                pos = 0
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

    private func pickPet(_ c: ActLab.Char) {
        CatBrain.currentCharId = c.id
        onHit()
    }

    private func togglePet() {
        if petOn { pip.stop(); petOn = false }
        else {
            pip.start()
            petOn = true
        }
    }

    private func openDoubaoLogin() {
        NotificationCenter.default.post(name: Notification.Name("StillOpenDoubaoLogin"), object: nil)
        hint = "先去绑一个豆包号，一人只绑一个"
    }

    private func addLine(_ text: String, _ mine: Bool) {
        chatLines.append(ChatLine(text: text, mine: mine))
    }

    /// ★ 2026-11-26：点发送 → 用户原句进聊天 → 再问制作方式。
    private func confirmMake() {
        let desc = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !desc.isEmpty else { return }
        pendingDesc = desc
        panel = "chat"
        chatLines.removeAll()
        addLine(desc, true)            // 用户写的动作原句，一字不动
        prompt = ""
        showWaySheet = true
    }

    private func submitJob() async {
        guard let c = currentRole else { return }
        let charId = c.id
        let roleName = c.title
        let desc = pendingDesc.isEmpty
            ? prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            : pendingDesc
        let useModel = model
        let slot = boundSlot
        guard !desc.isEmpty else { return }

        panel = "chat"
        banner = ""
        if chatLines.isEmpty { addLine("正在把动作交给它做…", true) }
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

// MARK: - 扁平玻璃（2026-11-24 纠偏2）
//
// ★ 组件全部待在同一层：只有一层半透明白底圆角。
//   没有侧壁、没有描边、没有高光 Path、没有 shadow；玻璃感靠透出 HerStageBg。

private struct FlatGlass: ViewModifier {
    let corner: CGFloat
    let opacity: CGFloat
    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.white.opacity(opacity))
        )
    }
}

private extension View {
    func flatGlass(corner: CGFloat = 18, opacity: CGFloat = 0.32) -> some View {
        modifier(FlatGlass(corner: corner, opacity: opacity))
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
