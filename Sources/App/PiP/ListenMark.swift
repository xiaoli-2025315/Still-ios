import CoreVideo
import Foundation
import UIKit

// MARK: - 小窗角上那个「正在听」的小标记
//
// ★ 为什么画在帧上，而不是发一条通知：
//   通知会打扰他（他正在别的 App 里）；而这块画面本来就是我们自己一帧一帧喂进去的，
//   往帧上画一个点，等于**免费**得到一个「按下去生效了没有」的反馈。
//
// ★ 为什么必须有这个反馈：
//   小窗那个键按下去，除了顶上那颗系统橙点，屏幕上什么都不会变。
//   没有标记的话，他没法分辨「没听」和「听了但没听清」—— 前者是 bug，后者是环境。
//
// ★ 位置固定在右上角，避开正中间的猫和底下的气泡。

enum ListenMark {

    /// 画在 720 画布上的基准尺寸（帧宽不是 720 时按比例缩）
    private static let base: CGFloat = 720

    /// 最近 12 次的电平（画竖条用）—— 每帧 push 一个
    private static var history = [CGFloat](repeating: 0.05, count: 12)

    static func push(level: CGFloat) {
        history.removeLast()
        history.insert(min(1, max(0.05, level)), at: 0)
    }

    static func paint(on pb: CVPixelBuffer) {
        guard Listening.shared.flag.value else { return }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        guard w > 0, h > 0, let baseAddr = CVPixelBufferGetBaseAddress(pb) else { return }

        // 32BGRA：小端下就是 premultipliedFirst + byteOrder32Little（跟 SayBubble 一致）。
        // 写错不崩，表现是红蓝对调。
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue
                 | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: baseAddr, width: w, height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: info) else { return }

        let k = CGFloat(w) / base

        // ★★★ 2026-10-30：小圆点 → **12 根真音波**（跟 App 里那条同一个来源：真实 RMS）。
        //   位置放**底部**（避开正中间的猫和气泡）；小窗被捏小时系统会缩放，这里按帧宽算。
        let bars = 12
        var hist = [CGFloat](repeating: 0.05, count: bars)
        // 用最近 12 帧的电平（每帧 push 一个，等系统一帧一帧来）
        Self.push(level: CGFloat(Listening.shared.levelBox.get()))
        hist = Self.history

        let barW = CGFloat(w) * 0.016
        let gap = CGFloat(w) * 0.010
        let totalW = CGFloat(bars) * barW + CGFloat(bars - 1) * gap
        let x0 = (CGFloat(w) - totalW) / 2
        let baseY = CGFloat(h) * 0.10            // 从底部往上留 10%
        let maxH = CGFloat(h) * 0.16

        // 深色底条：亮背景上没有它会看不清
        ctx.setFillColor(UIColor(white: 0, alpha: 0.28).cgColor)
        ctx.fill(CGRect(x: x0 - gap * 2, y: baseY - gap * 2,
                        width: totalW + gap * 4, height: maxH + gap * 4))

        ctx.setFillColor(UIColor.white.withAlphaComponent(0.95).cgColor)
        for i in 0..<bars {
            let v = max(0.05, hist[i])                  // 静音留 5% 底，不然像卡住
            let bh = maxH * v
            let x = x0 + CGFloat(i) * (barW + gap)
            let r = CGRect(x: x, y: baseY, width: barW, height: bh)
            ctx.fillEllipse(in: r)                      // 圆头竖条
        }
    }
}
