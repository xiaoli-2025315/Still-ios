import SwiftUI

// MARK: - 「它」页全屏动态背景（2026-11-24，对齐安卓 HerBg）
//
// 淡雅四色渐变铺满整屏 + 四团光缓慢飘。玻璃卡是半透明的，底下要有柔光才看得见质感。
// 同时承担「切到它页也渐变过渡」——外层用 withAnimation 改 opacity，切走渐隐、切回渐显。
// ★ 性能：低频（0.1s 一帧）、只画渐变圆，不解码不建对象；opacity=0 时不驱动定时器。
struct HerStageBg: View {
    @State private var t: Double = 0
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                LinearGradient(
                    colors: [Color(hex: 0xCFDFE8), Color(hex: 0xE3DBE6),
                             Color(hex: 0xEFDFD9), Color(hex: 0xDFEAE0)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                blob(Color(hex: 0xA9CBE2), w: w, h: h, fx: -0.10, fy: -0.06, r: 0.78, ph: 0)
                blob(Color(hex: 0xDCB6CC), w: w, h: h, fx: 1.08, fy: 0.26, r: 0.82, ph: 1.7)
                blob(Color(hex: 0xBCD9C2), w: w, h: h, fx: 0.27, fy: 1.06, r: 0.70, ph: 3.1)
                blob(Color(hex: 0xF0D9A8), w: w, h: h, fx: 0.88, fy: 0.80, r: 0.52, ph: 4.6)
            }
            .clipped()
        }
        .onReceive(timer) { _ in t += 0.1 }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func blob(_ color: Color, w: CGFloat, h: CGFloat,
                      fx: CGFloat, fy: CGFloat, r: CGFloat, ph: Double) -> some View {
        let a = t * 0.31 + ph
        let dx = CGFloat(sin(a)) * 34
        let dy = CGFloat(cos(a * 0.8)) * 34
        let sc = 1 + 0.12 * CGFloat(sin(a))
        Circle()
            .fill(RadialGradient(
                gradient: Gradient(colors: [color.opacity(0.55), color.opacity(0)]),
                center: .center, startRadius: 2, endRadius: max(w, h) * r / 2
            ))
            .frame(width: max(w, h) * r, height: max(w, h) * r)
            .scaleEffect(sc)
            .offset(x: w * fx + dx - w / 2, y: h * fy + dy - h / 2)
    }
}
