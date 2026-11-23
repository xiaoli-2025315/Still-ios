import UIKit

// MARK: - 捏捏涂抹层（2026-11-24，对齐安卓 PinchOverlay）
// ★ 直接贴在「它」页焦点卡上，笔/橡皮就涂在卡里这只身上，不另建形象。
// 只记笔迹（青色高光），每涂一下回调外层让那只猫软一下、松手弹回。
final class CardPinchPaint: UIView {

    struct Mark { var x: CGFloat; var y: CGFloat; var r: CGFloat = 46 }
    var marks: [Mark] = []
    var tool: Int = 0                  // 0 笔 / 1 橡皮
    var onPaint: (() -> Void)?
    // ★ 卡顿修复：渐变只建一次，靠 translate 挪到各笔迹上；回调限到约 9 次/秒。
    private var gradient: CGGradient?
    private var lastCb: TimeInterval = 0
    private static let maxMarks = 400
    private var down = false
    private var last: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func clearMarks() { marks.removeAll(); setNeedsDisplay() }
    var hasMarks: Bool { !marks.isEmpty }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard let c = UIGraphicsGetCurrentContext() else { return }
        if gradient == nil {
            let cs = CGColorSpaceCreateDeviceRGB()
            let colors = [UIColor(red: 0.47, green: 0.86, blue: 0.80, alpha: 0.55).cgColor,
                          UIColor(red: 0.47, green: 0.86, blue: 0.80, alpha: 0).cgColor] as CFArray
            gradient = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])
        }
        guard let g = gradient else { return }
        for m in marks {
            c.save()
            c.translateBy(x: m.x, y: m.y)
            c.drawRadialGradient(g, startCenter: .zero, startRadius: 0,
                                 endCenter: .zero, endRadius: m.r, options: [])
            c.restore()
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let p = touches.first?.location(in: self) else { return }
        down = true; last = p
        stroke(p)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard down, let p = touches.first?.location(in: self) else { return }
        let dist = hypot(p.x - last.x, p.y - last.y)
        let steps = max(1, Int(dist / 12))
        for i in 1...steps {
            let f = CGFloat(i) / CGFloat(steps)
            stroke(CGPoint(x: last.x + (p.x - last.x) * f, y: last.y + (p.y - last.y) * f))
        }
        last = p
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { down = false }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { down = false }

    private func stroke(_ p: CGPoint) {
        if tool == 1 {
            marks.removeAll { hypot($0.x - p.x, $0.y - p.y) < $0.r + 18 }
        } else {
            marks.append(Mark(x: p.x, y: p.y))
            if marks.count > CardPinchPaint.maxMarks { marks.removeFirst() }
        }
        setNeedsDisplay()
        notify()
    }

    private func notify() {
        let now = Date().timeIntervalSince1970
        if now - lastCb < 0.11 { return }
        lastCb = now
        onPaint?()
    }
}

import SwiftUI

struct CardPinchPaintView: UIViewRepresentable {
    var active: Bool
    var tool: Int
    var key: Int
    var onPaint: () -> Void
    var onReady: (CardPinchPaint) -> Void

    func makeUIView(context: Context) -> CardPinchPaint {
        let v = CardPinchPaint()
        v.onPaint = onPaint
        DispatchQueue.main.async { onReady(v) }
        return v
    }
    func updateUIView(_ v: CardPinchPaint, context: Context) {
        v.isUserInteractionEnabled = active
        v.alpha = active ? 1 : 0
        v.tool = tool
        if context.coordinator.lastKey != key {
            context.coordinator.lastKey = key
            v.clearMarks()
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastKey = -1 }
}
