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
                .fill(.black.opacity(0.16 * (1 - engine.z * 0.72)))
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
