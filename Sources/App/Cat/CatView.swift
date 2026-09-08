import SwiftUI

// MARK: - 毛毡猫
//
// 几何参数逐条来自 still-ios-widgets.html 的 POSE + catSVG，
// SVG viewBox 是 200×175，这里所有坐标都在同一套逻辑坐标里，最后统一乘 k 缩放。
// 别手改这些数字 —— 它们是在原型里一格一格调出来、并排截图验过的。

// MARK: 配色

enum CatColor {
    static let body     = Color(hex: 0xE3D3C3)
    static let bodyDark = Color(hex: 0xD3BFA9)
    static let patch    = Color(hex: 0xC97B4E)
    static let ear      = Color(hex: 0xE8B4A0)
    static let line     = Color(hex: 0x6B5D50)
    static let nose     = Color(hex: 0xC97B4E)
    static let eye      = Color(hex: 0x4A3F35)
    static let tongue   = Color(hex: 0xE8A0A0)
}

// MARK: 姿势

enum CatPose: String, CaseIterable {
    case sleep, sit, groom, walk, look, crouch, pounce, stretch

    struct P {
        let ry: CGFloat
        let headCy: CGFloat
        let headR: CGFloat
        let eyes: Eyes
        let tail: Tail
        let ear: CGFloat
        let paw: CGFloat
        let legs: Bool
        let tongue: Bool
    }

    enum Eyes { case shut, open, wide }
    enum Tail { case curl, wrap, up, low, swish }

    var p: P {
        switch self {
        case .sleep:   return P(ry: 24, headCy: 76, headR: 27, eyes: .shut,  tail: .wrap,  ear:  20, paw: 132, legs: false, tongue: false)
        case .sit:     return P(ry: 34, headCy: 58, headR: 30, eyes: .open,  tail: .curl,  ear:   0, paw: 142, legs: false, tongue: false)
        case .groom:   return P(ry: 32, headCy: 74, headR: 28, eyes: .shut,  tail: .curl,  ear:   8, paw: 136, legs: false, tongue: true)
        case .walk:    return P(ry: 32, headCy: 56, headR: 29, eyes: .open,  tail: .up,    ear:  -4, paw: 144, legs: true,  tongue: false)
        case .look:    return P(ry: 35, headCy: 50, headR: 30, eyes: .wide,  tail: .curl,  ear:  -9, paw: 142, legs: false, tongue: false)
        case .crouch:  return P(ry: 24, headCy: 72, headR: 27, eyes: .wide,  tail: .low,   ear: -17, paw: 140, legs: false, tongue: false)
        case .pounce:  return P(ry: 37, headCy: 42, headR: 29, eyes: .wide,  tail: .up,    ear: -19, paw: 124, legs: true,  tongue: false)
        case .stretch: return P(ry: 25, headCy: 86, headR: 26, eyes: .shut,  tail: .swish, ear:  14, paw: 166, legs: true,  tongue: false)
        }
    }
}

// MARK: - 绘制

struct CatView: View {

    var pose: CatPose = .sit
    var width: CGFloat = 74          // 显示宽度（px）。高 = width * 175/200

    private var k: CGFloat { width / 200.0 }
    private var h: CGFloat { width * 175.0 / 200.0 }
    private var lw: CGFloat { 1.7 * k }
    private let cx: CGFloat = 100

    /// SVG 原版用的是 stroke-linejoin="round"。SwiftUI 默认是 miter，
    /// 不显式指定的话耳朵尖和尾巴拐弯会变尖，整只猫的气质就不对了。
    private var lineStyle: StrokeStyle {
        StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            tailLayer
            bodyLayer
            pawLayer
            earLayer
            headLayer
        }
        .frame(width: width, height: h)
        // 注意：这里不能用 drawingGroup()。小组件是离屏渲染的，
        // Metal 合成在 Widget Extension 里会画成空白。
    }

    // MARK: 坐标helper

    private func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
    private func r(_ v: CGFloat) -> CGFloat { v * k }

    // MARK: 尾巴

    private var tailPath: Path {
        // 每条尾巴 = 起点 + 两段三次贝塞尔，共 7 个点
        // 直接对应 SVG 的 "M p0 C p1 p2 p3 C p4 p5 p6"
        let pts: [CGPoint]
        switch pose.p.tail {
        case .curl:  pts = [pt(146,116), pt(176,110), pt(180,84),  pt(161,75),  pt(151,70),  pt(142,77),  pt(147,88)]
        case .wrap:  pts = [pt(140,124), pt(168,124), pt(176,110), pt(166,102), pt(158,96),  pt(148,102), pt(152,112)]
        case .up:    pts = [pt(148,112), pt(182,104), pt(186,70),  pt(168,58),  pt(160,52),  pt(150,60),  pt(155,71)]
        case .low:   pts = [pt(142,126), pt(172,130), pt(188,120), pt(180,111), pt(173,104), pt(160,111), pt(163,120)]
        case .swish: pts = [pt(144,118), pt(180,128), pt(191,102), pt(172,94),  pt(161,89),  pt(151,99),  pt(160,110)]
        }
        var path = Path()
        path.move(to: pts[0])
        path.addCurve(to: pts[3], control1: pts[1], control2: pts[2])
        path.addCurve(to: pts[6], control1: pts[4], control2: pts[5])
        return path
    }

    private var tailLayer: some View {
        tailPath
            .fill(CatColor.bodyDark)
            .overlay(tailPath.stroke(CatColor.line, style: lineStyle))
    }

    // MARK: 身体

    private var bodyLayer: some View {
        let p = pose.p
        let bodyEllipse = Path(ellipseIn: CGRect(x: r(cx - 50), y: r(112 - p.ry),
                                                 width: r(100), height: r(2 * p.ry)))
        // 背上那块赤陶色斑
        var patch = Path()
        patch.move(to: pt(cx - 34, 112 - p.ry * 0.42))
        patch.addQuadCurve(to: pt(cx + 34, 112 - p.ry * 0.42), control: pt(cx, 112 - p.ry * 0.42 - 13))
        patch.addQuadCurve(to: pt(cx, 112 - p.ry * 0.42 + 17), control: pt(cx + 26, 112 - p.ry * 0.42 + 17))
        patch.addQuadCurve(to: pt(cx - 34, 112 - p.ry * 0.42), control: pt(cx - 26, 112 - p.ry * 0.42 + 17))
        patch.closeSubpath()

        return ZStack {
            bodyEllipse.fill(CatColor.body)
            patch.fill(CatColor.patch).opacity(0.28)
        }
        .overlay(bodyEllipse.stroke(CatColor.line, style: lineStyle))
    }

    // MARK: 爪

    private var pawLayer: some View {
        let p = pose.p
        let (lx, rx, px, py) = p.legs
            ? (CGFloat(88), CGFloat(112), CGFloat(10), CGFloat(6.4))
            : (CGFloat(86), CGFloat(114), CGFloat(11), CGFloat(7.0))
        let back  = Path(ellipseIn: CGRect(x: r(lx - px), y: r(p.paw - py), width: r(2 * px), height: r(2 * py)))
        let front = Path(ellipseIn: CGRect(x: r(rx - px), y: r(p.paw - py), width: r(2 * px), height: r(2 * py)))
        return ZStack {
            back.fill(CatColor.bodyDark)
            front.fill(CatColor.body)
        }
        .overlay(
            ZStack {
                back.stroke(CatColor.line, style: lineStyle)
                front.stroke(CatColor.line, style: lineStyle)
            }
        )
    }

    // MARK: 耳朵（整组绕头心旋转）

    private var earLayer: some View {
        let p = pose.p
        let rad = Angle(degrees: Double(p.ear)).radians
        let t = CGAffineTransform(translationX: r(cx), y: r(p.headCy))
            .rotated(by: rad)
            .translatedBy(x: -r(cx), y: -r(p.headCy))

        func tri(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Path {
            var path = Path()
            path.move(to: a); path.addLine(to: b); path.addLine(to: c); path.closeSubpath()
            return path
        }

        let lo = tri(pt(cx - 24, p.headCy - 18), pt(cx - 30, p.headCy - 44), pt(cx - 6,  p.headCy - 28))
        let ro = tri(pt(cx + 24, p.headCy - 18), pt(cx + 30, p.headCy - 44), pt(cx + 6,  p.headCy - 28))
        let li = tri(pt(cx - 23, p.headCy - 21), pt(cx - 26, p.headCy - 37), pt(cx - 12, p.headCy - 27))
        let ri = tri(pt(cx + 23, p.headCy - 21), pt(cx + 26, p.headCy - 37), pt(cx + 12, p.headCy - 27))

        return ZStack {
            lo.applying(t).fill(CatColor.body)
            ro.applying(t).fill(CatColor.body)
            li.applying(t).fill(CatColor.ear)
            ri.applying(t).fill(CatColor.ear)
        }
        .overlay(
            ZStack {
                lo.applying(t).stroke(CatColor.line, style: lineStyle)
                ro.applying(t).stroke(CatColor.line, style: lineStyle)
            }
        )
    }

    // MARK: 头

    private var headLayer: some View {
        let p = pose.p
        let head = Path(ellipseIn: CGRect(x: r(cx - p.headR), y: r(p.headCy - p.headR),
                                          width: r(2 * p.headR), height: r(2 * p.headR)))

        // 头顶那块斑
        var patch = Path()
        patch.move(to: pt(cx - 16, p.headCy - 20))
        patch.addQuadCurve(to: pt(cx + 16, p.headCy - 20), control: pt(cx, p.headCy - 27))
        patch.addQuadCurve(to: pt(cx, p.headCy - 10), control: pt(cx + 11, p.headCy - 10))
        patch.addQuadCurve(to: pt(cx - 16, p.headCy - 20), control: pt(cx - 11, p.headCy - 10))
        patch.closeSubpath()

        // 鼻子
        var nose = Path()
        nose.move(to: pt(cx, p.headCy + 7))
        nose.addLine(to: pt(cx - 4.2, p.headCy + 3.6))
        nose.addLine(to: pt(cx + 4.2, p.headCy + 3.6))
        nose.closeSubpath()

        // 嘴
        var mouth = Path()
        mouth.move(to: pt(cx, p.headCy + 7))
        mouth.addLine(to: pt(cx, p.headCy + 10.4))
        mouth.move(to: pt(cx, p.headCy + 10.4))
        mouth.addQuadCurve(to: pt(cx - 8, p.headCy + 10.4), control: pt(cx - 4.6, p.headCy + 14))
        mouth.move(to: pt(cx, p.headCy + 10.4))
        mouth.addQuadCurve(to: pt(cx + 8, p.headCy + 10.4), control: pt(cx + 4.6, p.headCy + 14))

        // 胡须
        var whiskers = Path()
        whiskers.move(to: pt(cx - 24, p.headCy + 4)); whiskers.addLine(to: pt(cx - 39, p.headCy + 1))
        whiskers.move(to: pt(cx - 24, p.headCy + 8)); whiskers.addLine(to: pt(cx - 39, p.headCy + 10))
        whiskers.move(to: pt(cx + 24, p.headCy + 4)); whiskers.addLine(to: pt(cx + 39, p.headCy + 1))
        whiskers.move(to: pt(cx + 24, p.headCy + 8)); whiskers.addLine(to: pt(cx + 39, p.headCy + 10))

        var tongue = Path()
        if p.tongue {
            tongue.move(to: pt(cx, p.headCy + 9))
            tongue.addQuadCurve(to: pt(cx - 1, p.headCy + 19), control: pt(cx + 3, p.headCy + 16))
            tongue.addQuadCurve(to: pt(cx, p.headCy + 9), control: pt(cx - 5, p.headCy + 16))
            tongue.closeSubpath()
        }

        return ZStack {
            head.fill(CatColor.body)
            patch.fill(CatColor.patch).opacity(0.30)
            eyesView(p)
            nose.fill(CatColor.nose)
            mouth.stroke(CatColor.line, style: StrokeStyle(lineWidth: 1.5 * k, lineCap: .round))
            if p.tongue { tongue.fill(CatColor.tongue) }
            whiskers.stroke(CatColor.line, style: StrokeStyle(lineWidth: 1.2 * k, lineCap: .round))
                .opacity(0.55)
        }
        .overlay(head.stroke(CatColor.line, style: lineStyle))
    }

    @ViewBuilder
    private func eyesView(_ p: CatPose.P) -> some View {
        let cy = p.headCy - 2
        switch p.eyes {
        case .shut:
            var left = Path(); var right = Path()
            left.move(to: pt(85, cy))
            left.addQuadCurve(to: pt(95, cy), control: pt(90, cy + 5))
            right.move(to: pt(105, cy))
            right.addQuadCurve(to: pt(115, cy), control: pt(110, cy + 5))
            ZStack {
                left.stroke(CatColor.line, style: StrokeStyle(lineWidth: 2.4 * k, lineCap: .round)).opacity(0.8)
                right.stroke(CatColor.line, style: StrokeStyle(lineWidth: 2.4 * k, lineCap: .round)).opacity(0.8)
            }
        case .wide:
            ZStack {
                eyeEllipse(cx: 89,  cy: cy, rx: 4.6, ry: 5.4)
                eyeEllipse(cx: 111, cy: cy, rx: 4.6, ry: 5.4)
                Circle().fill(.white)
                    .frame(width: r(3.4), height: r(3.4))
                    .position(pt(90.6, cy - 2.2))
                Circle().fill(.white)
                    .frame(width: r(3.4), height: r(3.4))
                    .position(pt(112.6, cy - 2.2))
            }
        case .open:
            ZStack {
                eyeEllipse(cx: 89,  cy: cy, rx: 3.6, ry: 4.2)
                eyeEllipse(cx: 111, cy: cy, rx: 3.6, ry: 4.2)
                Circle().fill(.white).opacity(0.9)
                    .frame(width: r(2.4), height: r(2.4))
                    .position(pt(90.2, cy - 1.6))
            }
        }
    }

    private func eyeEllipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat) -> some View {
        Ellipse()
            .fill(CatColor.eye)
            .frame(width: r(2 * rx), height: r(2 * ry))
            .position(pt(cx, cy))
    }
}

// MARK: - 预览

#Preview("全部姿势") {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 18) {
            ForEach(CatPose.allCases, id: \.rawValue) { pose in
                VStack {
                    CatView(pose: pose, width: 74)
                    Text(pose.rawValue).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }
    .background(Cfg.Palette.bg)
}
