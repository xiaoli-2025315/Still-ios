import SwiftUI

/// ★ 2026-11-03（他定的）：生成阶段没有真百分比 → 用一条"来回流动的光带"，
///   不假装进度，但让人看得出它在动。抠像那段仍用真百分比。
struct LightBandView: View {

    var height: CGFloat = 6
    var corner: CGFloat = 3

    @State private var phase: CGFloat = -0.35

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let bandW = max(60, w * 0.32)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Tw.gray200)
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Tw.gray200.opacity(0.2), Tw.gray700, Tw.gray200.opacity(0.2)],
                            startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: bandW)
                    .offset(x: (w + bandW) * phase - bandW)
            }
            .clipped()
        }
        .frame(height: height)
        .onAppear {
            phase = -0.35
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                phase = 1.0
            }
        }
    }
}
