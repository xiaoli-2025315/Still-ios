import SwiftUI

// MARK: - 聊天页里浮着的那一只
//
// ★★★★ 2026-11-09（他定）：**只在「还在」App 的聊天页里**，形式跟安卓那只浮窗一样 ——
//   盖在气泡上面、能拖、按住会挣扎、松手回坐立、拖到哪儿松手就待在哪儿。
//   不跨 App、不要系统权限、不用画中画：出了这一页它就不在了。
//
// ★ 跟谁聊就显示谁：`CatPackStore.current` 是 @Published，聊天页左边「换一只」
//   切过去，这里自动跟着换画面，不用另外接线。群聊跟着当前那一只。
//
// ★ 画面读的是包里现成的帧（跟主页框同一个 PackCatView），**不碰帧泵** ——
//   画中画那条实时帧层一路只供一个地方，抢它会把小窗弄黑。
//   所以这里另起一条 Timer 自己播，两条各走各的，互不干扰。
//
// ★ 上一轮主页展示框刚改成「只负责展示、不许碰」，那只保持不许碰；
//   **只有聊天页这一只能碰**。两处是各自独立的开关，别互相带坏。

// ★ @MainActor 必须标在 View 上：属性默认值里读了 `CatPackStore.shared`，
//   而它是主线程隔离的单例；不标，CI 就报「在非隔离的同步上下文里调用了主线程隔离的初始化器」
//   —— 项目里 ActLibPage / DispatchPage / KeyboardProbe 都栽过，这是同一条。
@MainActor
struct TalkFloatPet: View {

    @ObservedObject private var store = CatPackStore.shared

    /// 落点按屏幕比例存，退出再进还在那儿；换机型 / 横竖屏也不会跑出屏。
    @AppStorage("talk_float_pet_x") private var px: Double = 0.80
    @AppStorage("talk_float_pet_y") private var py: Double = 0.18

    /// 拖动中只改内存里的临时位置，松手才落盘 —— 手指每动一下就写一次
    /// UserDefaults 会把整页重算拖卡。
    @State private var liveX: Double?
    @State private var liveY: Double?
    @State private var dragFrom: CGPoint?
    @State private var holding = false

    private let side: CGFloat = 104

    private var curX: Double { liveX ?? px }
    private var curY: Double { liveY ?? py }

    var body: some View {
        GeometryReader { geo in
            // 没装过任何一只时退回自带那只，别让这一页空着一块。
            if let pack = store.current ?? store.builtin {
                let w = max(1.0, geo.size.width)
                let h = max(1.0, geo.size.height)
                let x = CGFloat(min(max(curX, 0.12), 0.88)) * w
                let y = CGFloat(min(max(curY, 0.10), 0.72)) * h

                // 按住那一下直接演挣扎，跟安卓浮窗一个手感；松手回坐立。
                PackCatView(pack: pack, width: side,
                            actName: holding ? "struggle" : "sit")
                    .frame(width: side, height: side)
                    .contentShape(Rectangle())
                    .position(x: x, y: y)
                    // ★ minimumDistance: 0 ⇒ 手指一落下就进 onChanged，
                    //   光点一下也会演一下挣扎；拖动则同一条手势一起管。
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { v in
                                // 用局部变量记起点，不依赖 @State 写入后立刻回读。
                                // 起点是「按下那一刻的绝对位置」，之后一律按位移算，
                                // 不会因为页面重算而越拖越偏。
                                let s = dragFrom ?? CGPoint(x: x, y: y)
                                dragFrom = s
                                holding = true
                                liveX = min(max(Double((s.x + v.translation.width) / w), 0.12), 0.88)
                                liveY = min(max(Double((s.y + v.translation.height) / h), 0.10), 0.72)
                            }
                            .onEnded { _ in
                                // 松手这一刻才把落点记下来，下次进聊天页还在那儿。
                                px = liveX ?? px
                                py = liveY ?? py
                                liveX = nil
                                liveY = nil
                                dragFrom = nil
                                holding = false
                            }
                    )
                    .animation(.interactiveSpring, value: holding)
            }
        }
        // 只让宠物那一块收手指：底下的气泡照样能滚、输入条照样能点。
        // 这一层没有铺底色，透明处不会拦触摸。
    }
}
