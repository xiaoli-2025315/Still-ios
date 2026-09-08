import SwiftUI

// MARK: - 桌面画布
//
// 三页桌面、16 个组件。猫浮在所有组件之上，不属于任何一格。
// 「它从这个组件走到那个组件」这件事只能在这里发生 ——
// 真的小组件是系统各刷各的静态快照，约不了一场接力。

struct HomeCanvasView: View {

    @ObservedObject var engine: PetEngine

    private let pad: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {

                // 三页桌面连成一条，靠 page 横向拖动
                HStack(spacing: 0) {
                    ForEach(0..<Rooms.pageCount, id: \.self) { p in
                        pageView(page: p, size: geo.size)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
                .offset(x: -CGFloat(engine.page) * geo.size.width)
                .animation(.easeInOut(duration: 0.38), value: engine.page)

                // 猫在最上面，不跟着页面动
                CatLayerView(engine: engine, size: geo.size)
            }
        }
        .clipShape(Rectangle())
    }

    // MARK: 一页桌面

    private func pageView(page: Int, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Rooms.rooms(onPage: page)) { room in
                let f = Self.frame(of: room, in: size, pad: pad)
                WidgetCardView(
                    room: room,
                    visited: engine.visited.contains(room.id),
                    isHere: !engine.isWalking && engine.roomId == room.id,
                    shaking: engine.huntingRoomId == room.id
                ) {
                    // 点组件只是翻到那一页去看，不是命令它过来
                    // —— 那是你指挥它，不是它自己动
                    engine.showPage(room.page)
                }
                .frame(width: f.width, height: f.height)
                .position(x: f.midX, y: f.midY)
            }
        }
    }

    // MARK: 网格 → 屏幕坐标（4 列 × 6 行）

    static func frame(of room: Room, in size: CGSize, pad: CGFloat) -> CGRect {
        let cw = size.width / 4.0
        let ch = size.height / 6.0
        return CGRect(
            x: CGFloat(room.col - 1) * cw + pad,
            y: CGFloat(room.row - 1) * ch + pad,
            width: CGFloat(room.w) * cw - pad * 2,
            height: CGFloat(room.h) * ch - pad * 2
        )
    }
}

#Preview {
    HomeCanvasView(engine: PetEngine())
        .background(Cfg.Palette.bg)
}
