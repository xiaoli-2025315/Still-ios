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
    @State private var sqState = 0         // 0 browse / 1 paint / 2 squish
    @State private var sqTool = 0
    @State private var sqKey = 0
    @State private var hasPaint = false
    /// 焦点卡上那层涂抹层（笔迹直接画在卡里这只身上）。
    @State private var paintRef: CardPinchPaint? = nil
    @State private var springAmt: CGFloat = 1

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

    var body: some View {
        // ★ 11-24 夜：整页铺满、不再上下滑；「它在这儿」小标题按他要求删掉。
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
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
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { v in
                            if stageLocked { return }
                            // 循环：往一个方向一直滑就一直换，不再卡在两端。
                            pos = dragStart - Double(v.translation.width / gap)
                        }
                        .onEnded { v in
                            if stageLocked { return }
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
                .onAppear {
                    // 每次切到它页，三张卡从一叠摊开（这个页面每次 tab 切换都会重建）。
                    spread = 0
                    withAnimation(.easeInOut(duration: 0.42)) { spread = 1 }
                }

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
            .padding(.horizontal, 20)
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
        .onTapGesture { onCreateImage() }
        .frame(maxWidth: .infinity)
    }

    /// 玻璃卡面：半透明白 + 白描边 + 斜向那道高光。中间那张更透亮、描边更实。
    private func glassCard(on: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.white.opacity(on ? 0.30 : 0.18))
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(on ? 0.90 : 0.60), lineWidth: on ? 2.5 : 1)
            // 斜向高光
            LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.08), Color.clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .shadow(color: Color.black.opacity(0.16), radius: on ? 22 : 16, y: 10)
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

            ZStack(alignment: .bottom) {
                glassCard(on: on)

                if OrbPet.hasFrame(c.id) {
                    // ★ 11-24 夜：按他要求放大、在卡里真正居中（原来太小）。
                    OrbPet(charId: c.id, actName: "sit", width: cardW * 0.92)
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

                Text(c.title)
                    .font(.system(size: 13, weight: on ? .bold : .regular))
                    .foregroundStyle(on ? Tw.gray900 : Tw.gray500)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.72))

                // ★ 捏捏直接涂在卡里这只身上：只叠在焦点卡、只捏的时候能吃触摸。
                if on && panel == "pinch" {
                    CardPinchPaintView(active: true, tool: sqTool, key: sqKey,
                                       onPaint: { springOnce() },
                                       onReady: { paintRef = $0 })
                        .frame(width: cardW, height: cardH)
                }
            }
            .frame(width: cardW, height: cardH)
            .rotationEffect(.degrees(rot), anchor: UnitPoint(x: 0.5, y: 1.68))
            .scaleEffect(CGFloat(sc) * springAmt)
            .opacity(op)
            .offset(x: CGFloat(d) * gap * spread,
                    y: ad * 14 * spread + CGFloat(i) * 2 * fold)
            .onTapGesture {
                if !OrbPet.hasFrame(c.id) {
                    onCreateImage()
                } else if i != focus {
                    // 点到哪张就近转成哪张（循环），不硬跳整条队列。
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
            }
        }
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
                // ★ 11-24 夜：悬浮玻璃底，浮在动态柔光上。
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(enabled ? Color.white.opacity(0.62) : Color.white.opacity(0.28))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.white.opacity(enabled ? 0.9 : 0.4), lineWidth: enabled ? 1.5 : 1)
                        )
                )
                .shadow(color: Color.black.opacity(0.10), radius: 10, y: 5)
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

    /// 涂一下：卡里那只软一下、松手弹回（弹簧手感）。
    private func springOnce() {
        springAmt = 0.94
        withAnimation(.spring(response: 0.22, dampingFraction: 0.45)) { springAmt = 1 }
        hasPaint = true
    }

    private func pinchTap() {
        if sqState != 0 {
            exitPinch()
            return
        }
        panel = "pinch"
        sqState = 1
        sqTool = 0
        sqKey += 1
        hasPaint = false
        paintRef?.clearMarks()
        hint = "用笔在卡里这只身上涂，涂到就软，涂完点确认"
    }

    private func confirmPinch() {
        guard paintRef?.hasMarks == true else {
            hint = "先用笔在它身上涂一块，再点确认"
            return
        }
        springOnce()
        sqState = 2
        hint = "捏着呢：清除了才能换"
    }

    private func clearPinch() {
        paintRef?.clearMarks()
        exitPinch()
        hint = "已还原，可以换动作了"
    }

    private func exitPinch() {
        sqState = 0
        sqKey += 1
        hasPaint = false
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
                    .background(
                        Capsule().fill(Tw.white)
                            .overlay(Capsule().stroke(Tw.gray200, lineWidth: 1))
                    )
            }
            .buttonStyle(PressStyle(scale: 0.97))
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var pinchPanel: some View {
        // ★ 2026-11-24：不再另起画布复制一只来捏 —— 笔/橡皮直接涂在卡里那只身上，
        //   这里只剩工具条（两个大图形 + 取消/确认/清除）。
        HStack(spacing: 12) {
            toolGlyph(asset: "tool_pencil", selected: sqTool == 0, wide: false) { sqTool = 0 }
            toolGlyph(asset: "tool_eraser", selected: sqTool == 1, wide: true) { sqTool = 1 }
            Spacer(minLength: 0)
            smallButton("取消", primary: false) { exitPinch() }
            smallButton("确认", primary: true, enabled: paintRef?.hasMarks == true) { confirmPinch() }
            if sqState == 2 {
                smallButton("清除", primary: true) { clearPinch() }
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
        } label: {
            ZStack {
                Circle()
                    .fill(selected ? Color.white.opacity(0.92) : Color.white.opacity(0.5))
                    .overlay(Circle().stroke(Color.white.opacity(selected ? 0.9 : 0.55),
                                             lineWidth: selected ? 2 : 1))
                    .frame(width: wide ? 76 : 62, height: 62)
                    .shadow(color: Color.black.opacity(0.12), radius: selected ? 10 : 5, y: 4)
                if let img = UIImage(named: asset) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: wide ? 68 : 52, height: 52)
                }
            }
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
                .foregroundStyle(enabled ? (primary ? Tw.white : Tw.gray500) : Tw.gray400)
                .frame(width: 62, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(enabled ? (primary ? Tw.gray900 : Tw.white) : Tw.gray100)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(primary ? Color.clear : Tw.gray200, lineWidth: 1)
                        )
                )
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
                        .background(Capsule().fill(Tw.white).overlay(Capsule().stroke(Tw.gray200, lineWidth: 1)))
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
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Tw.gray100)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Tw.gray200, lineWidth: 1)
                )
        )
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
                                        .fill(line.mine ? Tw.gray900 : Tw.white)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .stroke(line.mine ? Color.clear : Tw.gray200, lineWidth: 1)
                                        )
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
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Tw.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Tw.gray200, lineWidth: 1)
                )
        )
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
