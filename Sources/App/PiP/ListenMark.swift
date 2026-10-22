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
        // CGContext 原点在左下、y 向上 ⇒ 「右上角」就是 x 大、y 大。
        let cx = CGFloat(w) - 92 * k
        let cy = CGFloat(h) - 92 * k

        // 深色圆底：亮背景（白墙、雪地）上没有它，红点会糊掉
        ctx.setFillColor(UIColor(white: 0, alpha: 0.34).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - 56 * k, y: cy - 56 * k,
                                   width: 112 * k, height: 112 * k))

        // 红点
        ctx.setFillColor(UIColor(red: 0.86, green: 0.16, blue: 0.16, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - 22 * k, y: cy - 22 * k,
                                   width: 44 * k, height: 44 * k))

        // 朝右的两道声波弧
        ctx.setStrokeColor(UIColor(white: 1, alpha: 0.92).cgColor)
        ctx.setLineWidth(7 * k)
        ctx.setLineCap(.round)
        for r in [CGFloat(36), CGFloat(52)] {
            let p = CGMutablePath()
            p.addArc(center: CGPoint(x: cx, y: cy),
                     radius: r * k,
                     startAngle: -0.78, endAngle: 0.78,
                     clockwise: false)
            ctx.addPath(p)
        }
        ctx.strokePath()
    }
}
