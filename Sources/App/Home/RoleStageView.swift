import SwiftUI
import UIKit
import QuartzCore

// MARK: - 「它」页角色舞台（2026-11-23，对齐安卓 RoleStageActivity）
//
// 首页「角色」卡点进来。一条链：
//   ① 横滑选角色（真角色表 ActLab.chars + sit 预览图）
//   ② 三圆钮：悬浮 / 捏捏 / 制作动作，互斥
//   ③ 悬浮 → 系统画中画 PiPController.shared.toggle()
//   ④ 制作动作 → 输入框(wan/豆包号/5s) → 确认 → /api/act/draft 真下单 → 聊天进度卡 → 完成提示
//   ⑤ 捏捏乐 → 笔/橡皮涂选区 → 确认后逐格变形(弹簧回弹)，动作照常但锁住 → 清除解锁
// ★ 不碰首页原来的房间/按钮；不想要了把 MainHomeView 里那一行入口换回去即可。

struct RoleStageView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var roles: [ActLab.Char] = []
    @State private var pos: Double = 0          // 连续位置
    @State private var focus: Int = 0
    @State private var dragStart: Double = 0
    @State private var panel = ""               // "" / "float" / "pinch" / "make" / "chat"
    @State private var locked = false
    @State private var hint = "拖别的角色切过来"

    // 制作动作
    @State private var prompt = ""
    @State private var model = "wan"
    @State private var doubaoBound = false
    @State private var boundSlot = ""
    @State private var confirmShow = false
    @State private var chatLines: [ChatLine] = []
    @State private var makeDone = false

    // 捏捏乐
    @State private var sqState = 0              // 0 browse 1 paint 2 squish
    @State private var tool = 0                 // 0 brush 1 eraser
    @State private var squishKey = 0            // 触发画布重置

    struct ChatLine: Identifiable { let id = UUID(); let text: String; let mine: Bool }

    private let gap: CGFloat = 104

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .top) {
                stageBackground

                // 顶栏
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left").font(.title2).foregroundStyle(.white)
                    }
                    Spacer()
                    Text("它 · 选一个").font(.system(size: 17, weight: .bold)).foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Text("　").foregroundStyle(.white)
                }
                .padding(.horizontal, 18).padding(.top, 16)
                .zIndex(5)

                Text("拖别的角色切过来")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
                    .padding(.top, 56).zIndex(5)

                // 角色轨道（横向手势）
                VStack(spacing: 0) {
                    ZStack {
                        ForEach(roles.indices, id: \.self) { i in
                            roleCard(i)
                        }
                    }
                    .frame(height: 252)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { v in
                                if locked { return }
                                pos = clamp(dragStart - Double(v.translation.width / gap), -0.4, Double(roles.count) - 1 + 0.4)
                            }
                            .onEnded { v in
                                if locked { return }
                                withAnimation(.easeOut(duration: 0.34)) {
                                    focus = max(0, min(roles.count - 1, Int(pos.rounded())))
                                    pos = Double(focus)
                                }
                            }
                    )
                    .onAppear { dragStart = pos }
                    .padding(.top, 84)

                    // 捏捏画布盖在中间卡上
                    if sqState != 0 {
                        SquishUIView(state: $sqState, tool: $tool, key: squishKey)
                            .frame(width: 150, height: 252)
                            .offset(y: -168)
                            .zIndex(6)
                    }

                    Spacer(minLength: 12)

                    // 三圆钮
                    HStack(spacing: 22) {
                        roundBtn("▢", "悬浮模式", panel == "float") { floatTap() }
                        roundBtn("✋", "捏捏它", panel == "pinch" || sqState != 0) { pinchTap() }
                        roundBtn("✦", "制作动作", panel == "make") { makeTap() }
                    }
                    .padding(.bottom, 4)

                    Text(hint)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(sqState == 2 ? Color(red: 1, green: 0.88, blue: 0.54) : .white)
                        .frame(height: 20)

                    // 面板区（互斥）
                    ZStack {
                        if panel == "pinch" { pinchPanel }
                        if panel == "make" { makePanel }
                        if panel == "chat" { chatPanel }
                    }
                    .frame(height: 176)
                }
                .zIndex(4)
            }
            .ignoresSafeArea(edges: .bottom)
            .alert("确认开始生成？", isPresented: $confirmShow) {
                Button("取消", role: .cancel) {}
                Button("确认生成") { submitJob() }
            } message: {
                Text("角色：\(currentRole?.title ?? "它")\n模型：\(model == "wan" ? "wan" : "豆包号")\n时长：5s\n\n\(prompt)")
            }
            .task { await load() }
        }
    }

    // ---------- 舞台背景 ----------
    private var stageBackground: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [
                Color(hex: 0x241542), Color(hex: 0x4A2263), Color(hex: 0x8E3B8F),
                Color(hex: 0xD966A0), Color(hex: 0xF6A9C0)
            ], startPoint: .top, endPoint: .bottom)
            // 地面透视线
            VStack {
                Spacer().frame(height: g80)
                GeometryReader { gg in
                    Path { p in
                        let w = gg.size.width, h = gg.size.height
                        for i in -3...3 {
                            p.move(to: CGPoint(x: w/2, y: 0))
                            p.addLine(to: CGPoint(x: w/2 + CGFloat(i)*w/3, y: h))
                        }
                        for k in 1...4 {
                            let yy = h * CGFloat(k) * CGFloat(k) / 16
                            p.move(to: CGPoint(x: 0, y: yy)); p.addLine(to: CGPoint(x: w, y: yy))
                        }
                    }
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
                }
            }
        }
        .ignoresSafeArea()
    }
    private var g80: CGFloat { 380 }

    // ---------- 角色卡 ----------
    private func roleCard(_ i: Int) -> some View {
        let d = Double(i) - pos
        let ad = abs(d)
        let sc = max(0.55, 1 - ad * 0.17)
        let op = max(0.42, 1 - ad * 0.27)
        let br = max(0.52, 1 - ad * 0.18)
        let isFocus = i == focus && sqState == 0
        return Group {
            if i < roles.count {
                VStack(spacing: 4) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.white.opacity(0.10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(Color.white.opacity(isFocus ? 0.95 : 0.5), lineWidth: isFocus ? 3 : 1.2)
                            )
                        if let u = previewURL(roles[i]) {
                            StillCachedImage(url: u)
                                .scaledToFit().padding(16)
                        } else {
                            Image(systemName: "cat.fill").font(.system(size: 60)).foregroundStyle(.white.opacity(0.6))
                        }
                        Text(roles[i].title).font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white).shadow(radius: 3).padding(.bottom, 8)
                    }
                }
                .frame(width: 150, height: 252)
                .scaleEffect(CGFloat(sc))
                .opacity(op)
                .brightness(CGFloat(br - 1))
                .offset(x: CGFloat(d) * gap)
                .animation(.easeOut(duration: 0.05), value: pos)
            }
        }
    }

    private func previewURL(_ c: ActLab.Char) -> URL? {
        URL(string: ActLab.base + "/assets/acts/" + c.id + "/sit.gif?v=8")
    }
    private func clamp(_ v: Double, _ a: Double, _ b: Double) -> Double { max(a, min(b, v)) }

    private var currentRole: ActLab.Char? {
        roles.indices.contains(focus) ? roles[focus] : nil
    }
    private var promptReady: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // ---------- 圆钮 ----------
    private func roundBtn(_ icon: String, _ label: String, _ on: Bool, _ tap: @escaping () -> Void) -> some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().fill(on ? Color(hex: 0x111111) : .white)
                    .frame(width: 50, height: 50)
                    .shadow(radius: 6, y: 4)
                Text(icon).font(.system(size: 20))
                    .foregroundStyle(on ? .white : Color(hex: 0x111111))
            }
            .onTapGesture(perform: tap)
            Text(label).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white)
        }
    }

    private func floatTap() {
        panel = (panel == "float") ? "" : "float"
        if panel == "float" {
            PiPController.shared?.toggle()
            hint = "它浮在屏幕上了，切到别处还在"
        } else { hint = "拖别的角色切过来" }
    }

    private func pinchTap() {
        if sqState != 0 { exitPinch(); return }
        panel = "pinch"; locked = true
        sqState = 1; tool = 0; squishKey += 1
        hint = "选笔或橡皮在它身上涂，涂完点确认"
    }

    private func confirmPinch() {
        sqState = 2; locked = true
        hint = "🔒 捏着呢：清除了才能切角色"
    }

    private func exitPinch() {
        sqState = 0; squishKey += 1; locked = false
        panel = ""; hint = "拖别的角色切过来"
    }

    private func makeTap() {
        panel = (panel == "make") ? "" : "make"
        locked = (panel == "make")
    }

    // ---------- 捏捏面板 ----------
    private var pinchPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 28) {
                toolButton("✏ 笔", 0)
                toolButton("▧ 橡皮", 1)
            }
            HStack(spacing: 14) {
                miniButton("取消", Color(hex: 0xF7F7F5), Color(hex: 0x6E6E68)) { exitPinch() }
                miniButton("确认", Color(hex: 0xDC2626), .white) { confirmPinch() }
                if sqState == 2 {
                    miniButton("清除", Color(hex: 0xDC2626), .white) { exitPinch() }
                }
            }
        }
    }
    private func toolButton(_ label: String, _ which: Int) -> some View {
        Text(label).font(.system(size: 13, weight: .bold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(tool == which ? .white : .white.opacity(0.2)))
            .foregroundStyle(tool == which ? Color(hex: 0x111111) : .white)
            .onTapGesture { tool = which }
    }
    private func miniButton(_ label: String, _ bg: Color, _ fg: Color, _ tap: @escaping () -> Void) -> some View {
        Text(label).font(.system(size: 12, weight: .bold))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(bg)).foregroundStyle(fg)
            .onTapGesture(perform: tap)
    }

    // ---------- 制作面板 ----------
    private var makePanel: some View {
        VStack(spacing: 8) {
            Text("你好，想制作什么动作").font(.system(size: 18, weight: .heavy)).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $prompt)
                    .frame(height: 54).font(.system(size: 12))
                    .foregroundStyle(.white).scrollContentBackground(.hidden)
                    .overlay(
                        Group {
                            if prompt.isEmpty {
                                Text("描述它要做什么动作，比如：它伸个懒腰，然后回头看看你。")
                                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.48))
                                    .padding(.horizontal, 4).padding(.top, 2)
                            }
                        }, alignment: .topLeading)
                HStack {
                    Button { chooseModel() } label: {
                        Text(model == "wan" ? "◈ wan ⌄" : "◈ 豆包号 ⌄")
                            .font(.system(size: 11)).foregroundStyle(Color(red: 0.56, green: 0.76, blue: 1))
                    }
                    Text("◷ 5s").font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    ZStack {
                        Circle().fill(promptReady ? Color(hex: 0x111111) : Color.white.opacity(0.16)).frame(width: 30, height: 30)
                        Image(systemName: "arrow.up").font(.system(size: 14)).foregroundStyle(promptReady ? .white : .white.opacity(0.4))
                    }
                    .onTapGesture { if promptReady { confirmShow = true } }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color(hex: 0x1A0E22).opacity(0.74)))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.18), lineWidth: 1))
        }
        .padding(.horizontal, 16)
    }

    private func chooseModel() {
        if !doubaoBound {
            // 去豆包登录页绑一个（现成）
            NotificationCenter.default.post(name: Notification.Name("StillOpenDoubaoLogin"), object: nil)
            hint = "先去绑一个豆包号，一人只能绑一个"
        } else {
            model = (model == "wan") ? "doubao" : "wan"
        }
    }

    // ---------- 聊天面板 ----------
    private var chatPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollViewReader { sv in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(chatLines) { line in
                            HStack {
                                if line.mine { Spacer() }
                                Text(line.text).font(.system(size: 12))
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(RoundedRectangle(cornerRadius: 14).fill(line.mine ? Color(hex: 0x111111) : Color(hex: 0xF3EEFB)))
                                    .foregroundStyle(line.mine ? .white : Color(hex: 0x6D28D9))
                                if !line.mine { Spacer() }
                            }
                            .id(line.id)
                        }
                    }
                }
                .onChange(of: chatLines.count) { _, n in
                    if let last = chatLines.last { sv.scrollTo(last.id) }
                }
            }
        }
        .padding(10).background(.white)
    }
    private func addLine(_ text: String, _ mine: Bool) {
        chatLines.append(ChatLine(text: text, mine: mine))
    }

    // ---------- 真下单 ----------
    private func load() async {
        do {
            let cs = try await ActLab.chars()
            await MainActor.run { roles = cs; focus = 0; pos = 0 }
        } catch { /* 没连上台子就留空，界面会显示没找到 */ }
        do {
            let st = try await ActLab.loginState()
            if st.loggedIn {
                await MainActor.run { doubaoBound = true; boundSlot = st.name }
            }
        } catch { }
    }

    private func submitJob() {
        panel = "chat"; locked = true
        addLine("正在把动作交给它做…", true)
        guard let char = currentRole else {
            addLine("还没选到角色，先拖一只到中间", true)
            return
        }
        let charId = char.id
        let desc = prompt
        let useModel = model
        let slot = boundSlot
        Task.detached {
            do {
                let body: [String: Any] = ["char": charId, "描述": desc]
                let d1 = try await ActLab.rawPost("/api/act/draft", body: body)
                let j1 = try JSONSerialization.jsonObject(with: d1) as? [String: Any] ?? [:]
                guard j1["ok"] as? Bool == true else {
                    throw NSError(domain: "still", code: 1, userInfo: [NSLocalizedDescriptionKey: (j1["错误"] as? String) ?? "没接上"])
                }
                let job = (j1["单号"] as? String) ?? ""
                await MainActor.run { addLine("回执 \(job)，开工中…", true) }
                var startBody: [String: Any] = ["单号": job]
                if useModel == "doubao" && !slot.isEmpty { startBody["账号"] = slot }
                let path = useModel == "wan" ? "/api/act/draft/wan" : "/api/act/draft/start"
                let d2 = try await ActLab.rawPost(path, body: startBody)
                let j2 = try JSONSerialization.jsonObject(with: d2) as? [String: Any] ?? [:]
                let msg = (j2["ok"] as? Bool == true) ? "它开始做了，做好了会告诉你"
                                                      : ((j2["错误"] as? String) ?? "开工没成")
                await MainActor.run { addLine(msg, false) }
                await poll(job: job)
            } catch {
                await MainActor.run { addLine("没接上台子：\(error.localizedDescription)", false) }
            }
        }
    }

    private func poll(job: String) async {
        for _ in 0..<120 {
            do {
                let d = try await ActLab.rawPost("/api/act/draft/state", body: ["单号": job])
                let j = try JSONSerialization.jsonObject(with: d) as? [String: Any] ?? [:]
                let st = (j["状态"] as? String) ?? ""
                if st == "装好了" || st == "已完成" || st == "做好了" {
                    await MainActor.run {
                        addLine("✓ 做完了，动作已存进它的记忆", false)
                        hint = "给它做的动作好了"
                    }
                    return
                }
            } catch { }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }
}

// MARK: - 捏捏乐网格变形画布（UIKit 自绘，跟安卓 SquishCanvas 同构）
struct SquishUIView: UIViewRepresentable {
    @Binding var state: Int
    @Binding var tool: Int
    let key: Int

    func makeUIView(context: Context) -> SquishView {
        let v = SquishView()
        v.onMaskEmpty = { /* 由外层确认时判断 */ }
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

final class SquishView: UIView {
    private static let W = 22, H = 22
    private var ox = [CGFloat](repeating: 0, count: W*H)
    private var oy = [CGFloat](repeating: 0, count: W*H)
    private var vx = [CGFloat](repeating: 0, count: W*H)
    private var vy = [CGFloat](repeating: 0, count: W*H)
    // ★ 不能叫 mask：UIView 自带 mask:UIView?，同名会被当覆盖而编译失败
    private var paintMask = [Bool](repeating: false, count: W*H)
    private var mode = 0, currentTool = 0
    private var down = false, last = CGPoint.zero
    private var link: CADisplayLink?
    var lastKey = -1
    var onMaskEmpty: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        link = CADisplayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    func applyState(_ s: Int, tool t: Int) {
        mode = s; currentTool = t
        isUserInteractionEnabled = (s != 0)
        alpha = (s == 0) ? 0 : 1
        if s == 1 { clearAll() }
    }
    func clearAll() {
        for i in 0..<(Self.W*Self.H) { ox[i]=0; oy[i]=0; vx[i]=0; vy[i]=0; paintMask[i]=false }
    }
    func hasMask() -> Bool { paintMask.contains(true) }

    @objc private func tick() {
        guard mode != 0 else { return }
        for i in 0..<(Self.W*Self.H) {
            vx[i] += -0.11 * ox[i]; vy[i] += -0.11 * oy[i]
            vx[i] *= 0.80; vy[i] *= 0.80
            ox[i] += vx[i]; oy[i] += vy[i]
        }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard mode != 0, rect.width > 0 else { return }
        // 涂过的地方画青色高亮格；真正形变用位移画一组点阵提示（真图由底层卡显示）
        let cw = rect.width / CGFloat(Self.W), ch = rect.height / CGFloat(Self.H)
        if mode == 1 {
            UIColor(red: 0.37, green: 0.78, blue: 0.94, alpha: 0.30).setFill()
            for gy in 0..<Self.H {
                for gx in 0..<Self.W {
                    if paintMask[gy*Self.W+gx] {
                        UIRectFill(CGRect(x: CGFloat(gx)*cw, y: CGFloat(gy)*ch, width: cw+0.6, height: ch+0.6))
                    }
                }
            }
        }
        // 捏的位移：把每个涂过的格点按位移画一个小圆，直观反馈「这里被捏动了」
        UIColor.white.withAlphaComponent(0.5).setFill()
        for gy in 0..<Self.H {
            for gx in 0..<Self.W {
                let i = gy*Self.W+gx
                if !paintMask[i] { continue }
                let px = CGFloat(gx+0.5)*cw + ox[i], py = CGFloat(gy+0.5)*ch + oy[i]
                UIBezierPath(arcCenter: CGPoint(x: px, y: py), radius: 1.4, startAngle: 0, endAngle: .pi*2, clockwise: true).fill()
            }
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard mode != 0, let t = touches.first else { return }
        let p = t.location(in: self)
        down = true; last = p
        if mode == 1 { paintAt(p) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard down, let t = touches.first else { return }
        let p = t.location(in: self)
        if mode == 1 { paintAt(p) }
        else if mode == 2 { pushAt(p, dx: p.x-last.x, dy: p.y-last.y) }
        last = p
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { down = false }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { down = false }

    private func paintAt(_ p: CGPoint) {
        let cw = bounds.width/CGFloat(Self.W), ch = bounds.height/CGFloat(Self.H)
        let r: CGFloat = 32
        for gy in 0..<Self.H {
            for gx in 0..<Self.W {
                let px = (CGFloat(gx)+0.5)*cw, py = (CGFloat(gy)+0.5)*ch
                let dx = px-p.x, dy = py-p.y
                if dx*dx+dy*dy < r*r { paintMask[gy*Self.W+gx] = (currentTool == 0) }
            }
        }
    }
    private func pushAt(_ p: CGPoint, dx: CGFloat, dy: CGFloat) {
        let cw = bounds.width/CGFloat(Self.W), ch = bounds.height/CGFloat(Self.H)
        for gy in 0..<Self.H {
            for gx in 0..<Self.W {
                let i = gy*Self.W+gx
                guard paintMask[i] else { continue }
                let px = (CGFloat(gx)+0.5)*cw, py = (CGFloat(gy)+0.5)*ch
                let d2 = (px-p.x)*(px-p.x)+(py-p.y)*(py-p.y)
                if d2 > 88*88 { continue }
                let w = CGFloat(exp(-Double(d2)/(2*30*30)))
                ox[i] += dx*w; oy[i] += dy*w
                let m = sqrt(ox[i]*ox[i]+oy[i]*oy[i])
                if m > 76 { ox[i] *= 76/m; oy[i] *= 76/m }
            }
        }
    }
}
