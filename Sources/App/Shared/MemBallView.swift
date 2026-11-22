import SwiftUI
import Foundation

// MARK: - 记忆球（2026-11-22）
//
// 球只是可视化外壳：球上每个点 = 柜子里一份真文件。
// ★ 数据从外面传进来（MemView 用柜子真数据填），这里一个字不编：
//   几份画几点，空就画一个空球 + 一句提示。点击点看原件，长按点删。
// ★ 经纬网球：外圆 + 纬线椭圆 + 经线椭圆，跟 v6 设计稿、安卓 MemBallView 同一语言。

struct MemBallView: View {
    let files: [MemAPI.File]
    let hint: String
    let onOpen: (MemAPI.File) -> Void
    let onLong: (MemAPI.File) -> Void

    @State private var pressed: Int? = nil

    private let dot: CGFloat = 22

    var body: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height)
            let r = side * 0.40
            let cx = g.size.width / 2
            let cy = g.size.height / 2
            ZStack {
                // 经纬网
                Circle()
                    .stroke(Tw.gray200, lineWidth: 1)
                    .frame(width: r * 2, height: r * 2)
                ForEach(1...3, id: \.self) { i in
                    let ry = r * CGFloat(i) / 4
                    Ellipse()
                        .stroke(Tw.gray200, lineWidth: 1)
                        .frame(width: r * 2, height: ry * 2)
                    let rx = r * CGFloat(i) / 4
                    Ellipse()
                        .stroke(Tw.gray200, lineWidth: 1)
                        .frame(width: rx * 2, height: r * 2)
                }
                // 文件节点：黄金角散布，位置只由「第几个」决定，稳定不跳
                ForEach(Array(files.enumerated()), id: \.offset) { idx, f in
                    let a = Double(idx) * 2.399963229728653
                    let rr = r * 0.82 * sqrt((Double(idx) + 0.5) / Double(max(1, files.count)))
                    let x = cx + CGFloat(rr * cos(a))
                    let y = cy + CGFloat(rr * sin(a))
                    Text(Self.short(f.名))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: dot, height: dot)
                        .background(pressed == idx ? Color(red: 192.0/255.0, green: 57.0/255.0, blue: 43.0/255.0) : Tw.gray900)
                        .clipShape(Circle())
                        .position(x: x, y: y)
                        .onTapGesture { onOpen(f) }
                        .onLongPressGesture(minimumDuration: 0.5,
                                            pressing: { p in pressed = p ? idx : nil },
                                            perform: { onLong(f) })
                }
                if files.isEmpty && !hint.isEmpty {
                    Text(hint)
                        .font(.system(size: 13))
                        .foregroundStyle(Tw.gray400)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }

    private static func short(_ s: String) -> String {
        if s.isEmpty { return "·" }
        return s.count <= 2 ? s : String(s.prefix(2))
    }
}
