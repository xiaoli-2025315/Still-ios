import SwiftUI

// MARK: - 镂空蒙层引导
//
// 就是那种全屏压一层暗底、把要说的那个地方挖个洞亮出来的引导。
//
// ★★ 三个坑（都是别人踩过的，写在这儿免得以后改回去）：
//
//  1. **挖洞用 even-odd 填充规则**，不要用 `.blendMode(.destinationOut)` ——
//     后者必须配 `.compositingGroup()`，漏了会把**底下整个 App 的内容**一起抠掉。
//     `.mask(shape, style: FillStyle(eoFill: true))` 是 SwiftUI 里最稳的一种。
//
//  2. **坐标要交给 `Anchor<CGRect>` 去解析**，不能自己用 GeometryReader 读 frame。
//     GeometryReader 读到的是**它自己被提议的尺寸**，而且会多插一次布局，
//     读出来的值经常是错的。正确做法：目标视图 `.anchorPreference`，
//     蒙层这边 `overlayPreferenceValue` + `GeometryProxy[anchor]` 解出来。
//
//  3. **点任意处都要能关掉**。`allowsHitTesting(false)` 会把整棵子树的点击
//     一起废掉，所以不能只加在暗底上 —— 得拆成三层：
//     暗底（不许点）＋ 透明命中层（收点击）＋ 说明卡（正常点）。
//
// ★ 走一遍就再也不走（记在本地）。想重讲一遍，改 `册` 名就行。

// MARK: 锚点：给视图起个名字，蒙层才知道挖哪儿

struct CoachAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// 给这个视图起个引导用的名字。例：`.coachAnchor("房间")`
    func coachAnchor(_ name: String) -> some View {
        anchorPreference(key: CoachAnchorKey.self, value: .bounds) { [name: $0] }
    }
}

// MARK: 一步

struct CoachStep {
    let 锚: String
    let 话: String
    /// 洞的形状：true 挖成圆角矩形，false 挖成正圆（适合圆形按钮）
    let 方: Bool

    init(_ 锚: String, _ 话: String, 方: Bool = true) {
        self.锚 = 锚; self.话 = 话; self.方 = 方
    }
}

// MARK: 挖洞的形状（even-odd：整屏 + 洞 = 洞被挖空）

private struct CoachHole: Shape {
    var hole: CGRect
    var radius: CGFloat
    var circle: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        if hole.width > 0 && hole.height > 0 {
            let r = circle ? min(hole.width, hole.height) / 2 : radius
            p.addPath(Path(roundedRect: hole, cornerRadius: r, style: .continuous))
        }
        return p      // ★ 配 eoFill: true 才会把重叠处挖空
    }
}

// MARK: 蒙层本体

struct CoachOverlay: View {
    let 册: String
    let 锚: [String: Anchor<CGRect>]
    var 步骤: [CoachStep] = CoachOverlay.首页步骤

    /// ★ v95：第一回进首页要讲的这三处。文案说人话，不写开发词。
    static let 首页步骤: [CoachStep] = [
        CoachStep("房间",
                  "它就住在这个框里。\n按住它能把它拎起来，拖到哪儿松手它就待在哪儿，过一会儿自己走回中间。"),
        CoachStep("叫它来",
                  "它在别的房间（比如你切到别的 App 去了）的时候，点这个，它就跑来你现在这间。"),
        CoachStep("我",
                  "它的声音、它说话的本事，还有那份新手教程，都收在这儿。"),
    ]

    @State private var 第几 = 0
    @State private var 在演 = false
    @State private var 洞 = CGRect.zero
    @State private var 这一处方 = true
    /// 这一步刚摆出来的头 0.5 秒内，点暗处不算数（防手指还在屏幕上就把三步跳完）
    @State private var 可点 = false

    var body: some View {
        GeometryReader { g in
            if 在演 {
                ZStack(alignment: .topLeading) {
                    // ① 暗底（挖了洞的）—— 不许接收点击
                    // ★ mask 不吃 style 参数；eoFill 要写在 fill 上
                    Rectangle()
                        .fill(Color.black.opacity(0.72))
                        .mask(CoachHole(hole: 洞, radius: 14, circle: !这一处方)
                                .fill(Color.white, style: FillStyle(eoFill: true)))
                        .allowsHitTesting(false)

                    // 洞口的白边：让"说的就是这儿"一眼看出来
                    if 洞.width > 0 {
                        RoundedRectangle(cornerRadius: 这一处方 ? 14 : 洞.width / 2,
                                         style: .continuous)
                            .stroke(Color.white.opacity(0.92), lineWidth: 2)
                            .frame(width: 洞.width, height: 洞.height)
                            .offset(x: 洞.minX, y: 洞.minY)
                            .allowsHitTesting(false)
                    }

                    // ② 透明命中层：点暗处任意地方 ＝「知道了」
                    // ★ 头 0.5 秒不算数：手指还停在屏幕上时，一下能把三步全跳完
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { if 可点 { 前进() } }

                    // ③ 说明卡
                    卡片
                        .frame(width: max(0, g.size.width - 40))
                        .position(x: g.size.width / 2, y: 卡Y(屏高: g.size.height))
                }
                .animation(.easeInOut(duration: 0.22), value: 第几)
                // ★ 洞的位置只能在 GeometryReader 的闭包里解 Anchor ——
                //   拿到闭包外的 GeometryProxy 是拿不到的（它只在渲染那一刻有效）
                .onAppear { 解(g) }
                .onChange(of: 第几) { 解(g) }
            }
        }
        .onAppear(perform: 开局)
        .onReceive(NotificationCenter.default.publisher(for: .stillCoachReplay)) { _ in
            CoachDone.clear(册)
            第几 = 0
            在演 = 步骤.count > 0
        }
    }

    // MARK: 卡片

    private var 卡片: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(第几 < 步骤.count ? 步骤[第几].话 : "")
                .font(.system(size: 15))
                .foregroundStyle(Color.white)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("不看了") { 收工() }
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white.opacity(0.55))
                Button("知道了") { 前进() }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(.leading, 14)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(white: 0.17))
        )
    }

    /// 洞在上半屏 ⇒ 卡片放下边；洞在下半屏 ⇒ 卡片放上边（免得压住要说的东西）
    private func 卡Y(屏高: CGFloat) -> CGFloat {
        let 上 = 洞.midY < 屏高 / 2
        let 估高: CGFloat = 130
        return 上 ? (屏高 - 估高 / 2 - 24) : (洞.maxY + 12 + 估高 / 2)
    }

    // MARK: 走

    private func 开局() {
        guard !步骤.isEmpty else { return }
        if CoachDone.走过(册) { return }
        // 等一帧，这时候锚点的位置才算得准
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            在演 = true        // 洞由 ZStack 的 .onAppear { 解(g) } 去量
        }
    }

    /// 解出这一步要挖的洞。
    ///
    /// ★ `g[anchor]` 是 SwiftUI 唯一正确的"取另一个视图位置"的办法 ——
    ///   不要用 GeometryReader 读 frame（读到的是它自己被提议的尺寸，是错的）。
    private func 解(_ g: GeometryProxy) {
        guard 第几 < 步骤.count else { return }
        let s = 步骤[第几]
        guard let a = 锚[s.锚] else { return }        // 这个锚此刻不在 ⇒ 不挖，也不崩
        let r = g[a]
        guard r.width > 0, r.height > 0 else { return }
        洞 = r.insetBy(dx: -8, dy: -8)                // 放大一圈，别贴着边
        这一处方 = s.方
        可点 = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { 可点 = true }
    }

    private func 前进() {
        if 第几 + 1 >= 步骤.count { 收工(); return }
        第几 += 1
    }

    private func 收工() {
        在演 = false
        CoachDone.记(册)
    }
}

// MARK: 走过没有（落盘）

enum CoachDone {
    private static func 键(_ 册: String) -> String { "引导_" + 册 }

    static func 走过(_ 册: String) -> Bool {
        UserDefaults.standard.bool(forKey: 键(册))
    }

    /// ★ 用同步写：这几个字节写丢了的代价是"下次又弹一遍骚扰他"
    static func 记(_ 册: String) {
        UserDefaults.standard.set(true, forKey: 键(册))
        UserDefaults.standard.synchronize()
    }

    static func clear(_ 册: String) {
        UserDefaults.standard.set(false, forKey: 键(册))
        UserDefaults.standard.synchronize()
    }
}

extension Notification.Name {
    static let stillCoachReplay = Notification.Name("stillCoachReplay")
}
