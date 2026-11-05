import SwiftUI

// MARK: - 猫这一层
//
// 它不在任何组件里，它浮在整张桌面上。
// 纵深 z 是引擎给的，这里只负责把它翻译成「看起来多远」：
//   缩放 1/(1+2.2z)、空气透视、影子随距离变淡 —— 和 Android v1.23 同一套公式。

struct CatLayerView: View {

    @ObservedObject var engine: PetEngine
    let size: CGSize

    private let baseWidth: CGFloat = 88

    // 微动画开关
    @State private var breathe = false
    @State private var bob = false
    @State private var groomNod = false
    @State private var lookSweep = false
    @State private var crouchTremble = false

    private var depthScale: CGFloat { 1.0 / (1.0 + CGFloat(Cfg.depthK) * engine.z) }
    private var w: CGFloat { baseWidth * depthScale }

    var body: some View {
        let x = engine.pos.x * size.width
        let y = engine.pos.y * size.height

        ZStack(alignment: .bottom) {
            // 影子：越远越淡越小
            Ellipse()
                .fill(.black.opacity(0.16 * (1.0 - Double(engine.z) * 0.72)))
                .frame(width: w * 0.52, height: w * 0.13)
                .blur(radius: 2 + engine.z * 4)

            catBody
        }
        // pos 是脚底中心
        .position(x: x, y: y)
        .animation(.linear(duration: 1.0 / Cfg.tickHz), value: engine.pos)
        .onAppear(perform: startMotions)
        .onChange(of: engine.act) { startMotions() }
    }

    /// 走路的颠簸 和 待着的微动 是两回事，不能叠在一起
    @ViewBuilder
    private var catBody: some View {
        // ★★ 2026-11-05（他定的）：主页框显示**选中的那只**。
        //   画中画用的是包里的帧，跟这只矢量猫无关（查过：CatView 只被主页框和灵动岛用到），
        //   所以这里换成"包里那只"不影响小窗。
        if let pk = CatPackStore.shared.current {
            PackCatView(pack: pk, width: w)
        } else {
            vectorCat
        }
    }

    /// 原来那只（App 自带、程序画的）—— 没选任何猫时用它兜底
    private var vectorCat: some View {
        let cat = CatView(pose: pose, width: w)
            .scaleEffect(x: engine.facing >= 0 ? 1 : -1, y: 1, anchor: .center)

        if engine.isWalking {
            cat.modifier(WalkBob(on: engine.isWalking))
        } else {
            cat.modifier(ActMotion(act: engine.act,
                                   breathe: breathe, bob: bob,
                                   groomNod: groomNod, lookSweep: lookSweep,
                                   crouchTremble: crouchTremble))
        }
    }

    private var pose: CatPose {
        if engine.isWalking { return .walk }
        return engine.act.pose
    }

    private func startMotions() {
        breathe = false; bob = false; groomNod = false; lookSweep = false; crouchTremble = false
        withAnimation { breathe = true; bob = true; groomNod = true; lookSweep = true; crouchTremble = true }
    }
}

// MARK: - 每个动作的微动

struct ActMotion: ViewModifier {
    let act: Act
    let breathe: Bool
    let bob: Bool
    let groomNod: Bool
    let lookSweep: Bool
    let crouchTremble: Bool

    func body(content: Content) -> some View {
        switch act {
        case .sleep:
            content
                .scaleEffect(x: 1.0, y: breathe ? 1.022 : 1.0, anchor: .bottom)
                .animation(.easeInOut(duration: 2.9).repeatForever(autoreverses: true), value: breathe)

        case .groom:
            content
                .offset(y: groomNod ? 1.2 : -0.6)
                .rotationEffect(.degrees(groomNod ? 2.2 : -0.8))
                .animation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true), value: groomNod)

        case .stretch:
            content
                .scaleEffect(x: groomNod ? 1.035 : 1.0, y: groomNod ? 0.975 : 1.0, anchor: .bottom)
                .animation(.easeOut(duration: 1.4), value: groomNod)

        case .hunt:
            content
                .scaleEffect(x: crouchTremble ? 1.014 : 1.0, y: crouchTremble ? 0.988 : 1.0, anchor: .bottom)
                .animation(.easeInOut(duration: 0.13).repeatForever(autoreverses: true), value: crouchTremble)

        case .look:
            content
                .rotationEffect(.degrees(lookSweep ? 2.6 : -2.6))
                .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: lookSweep)

        case .sit:
            content
                .scaleEffect(x: 1.0, y: breathe ? 1.008 : 1.0, anchor: .bottom)
                .animation(.easeInOut(duration: 3.6).repeatForever(autoreverses: true), value: breathe)
        }
    }
}

// MARK: - 走路时的颠簸（walk 姿势专用，由 isWalking 驱动）

struct WalkBob: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        content
            .offset(y: on ? -2.4 : 0)
            .rotationEffect(.degrees(on ? 1.2 : -1.2))
            .animation(on
                       ? .easeInOut(duration: 0.34).repeatForever(autoreverses: true)
                       : .default, value: on)
    }
}


// MARK: - 用"包里的帧"在主页框里播（选中的那只）
//
// ★ 2026-11-05：主页框以前只画程序画的那只；现在优先画选中的那只的真实帧。
//   每格 20 次/秒，跟动作库里的预览同速，省内存（只缓存最近若干张）。

struct PackCatView: View {

    let pack: CatPack
    let width: CGFloat

    @State private var img: UIImage?
    @State private var idx = 0
    @State private var timer: Timer?

    private var act: CatPack.Act? {
        pack.acts.first(where: { $0.name == "sit" }) ?? pack.acts.first
    }

    var body: some View {
        Group {
            if let i = img {
                Image(uiImage: i)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(width: width)
        .onAppear { start() }
        .onDisappear { stop() }
    }

    private func start() {
        guard let a = act, a.frames > 0 else { return }
        img = pack.image(act: a, index: 0)
        stop()
        let t = Timer(timeInterval: 1.0 / 20.0, repeats: true) { _ in
            Task { @MainActor in
                guard let a2 = act, a2.frames > 0 else { return }
                idx = (idx + 1) % a2.frames
                if let f = pack.image(act: a2, index: idx) { img = f }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}
