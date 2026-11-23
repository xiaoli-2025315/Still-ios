import UIKit

// MARK: - 捏捏涂抹层（2026-11-24 方向级重做）
//
// ★ 两步玩法：涂抹阶段只标记「软区」mask（32×32 浮点 0..1），**不变形**；
//   点确认后进入玩耍态，笔迹渐隐，手指按住软区拽 → 由 SquishFrameView 做弹簧形变。
// ★ mask 存在 UIView 里（@State 会被 SwiftUI 重建冲掉），软度采样用双线性。
// ★ 青点只作涂抹期的可视标记，单独放一层，玩耍期只淡出这一层、父层照常收触摸。

final class CardPinchPaint: UIView {

    /// 软区网格边长（32×32，值 0..1）
    private static let grid = 32
    private var soft: [CGFloat] = Array(repeating: 0, count: CardPinchPaint.grid * CardPinchPaint.grid)

    var tool: Int = 0                       // 0 笔 / 1 橡皮
    /// 玩耍态：touches 不再涂 mask，转成 playTouch 事件给形变 view
    var playMode = false
    /// 形变桥（持有形变 view 的弱引用）
    var playBridge: SquishPlayBridge?

    /// 软区有无变化回调（只传 Bool，不传任何形变参数）
    var onSoftChanged: ((Bool) -> Void)?

    /// 青点标记单独一层：玩耍期淡出它，父层 alpha 始终为 1，保证还能收触摸
    private let markLayer = PaintMarkLayer()
    private var lastCb: TimeInterval = 0
    private var down = false
    private var last: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true
        markLayer.isUserInteractionEnabled = false
        addSubview(markLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        markLayer.frame = bounds
    }

    // MARK: 对外 API

    /// 双线性采样软度。u/v 是相对本层 bounds 的归一化坐标 0..1。
    func softAt(_ u: CGFloat, _ v: CGFloat) -> CGFloat {
        let g = CardPinchPaint.grid
        let x = min(max(u, 0), 1) * CGFloat(g - 1)
        let y = min(max(v, 0), 1) * CGFloat(g - 1)
        let x0 = Int(floor(x))
        let y0 = Int(floor(y))
        let x1 = min(g - 1, x0 + 1)
        let y1 = min(g - 1, y0 + 1)
        let fx = x - CGFloat(x0)
        let fy = y - CGFloat(y0)
        let a = soft[y0 * g + x0]
        let b = soft[y0 * g + x1]
        let c = soft[y1 * g + x0]
        let d = soft[y1 * g + x1]
        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    }

    func hasSoft() -> Bool { soft.contains { $0 > 0.05 } }

    func clearSoft() {
        for i in soft.indices { soft[i] = 0 }
        markLayer.clear()
        notify(force: true)
    }

    /// 涂抹期显形 / 玩耍期隐形（只淡青点层，不动父层触摸）
    func setMarksVisible(_ visible: Bool, animated: Bool) {
        let target: CGFloat = visible ? 1 : 0
        if animated {
            UIView.animate(withDuration: 0.28, delay: 0, options: [.allowUserInteraction]) {
                self.markLayer.alpha = target
            }
        } else {
            markLayer.alpha = target
        }
    }

    // MARK: 触摸

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let p = touches.first?.location(in: self) else { return }
        down = true
        last = p
        if playMode {
            playBridge?.playTouch(0, p)
        } else {
            applyBrush(p)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard down, let p = touches.first?.location(in: self) else { return }
        if playMode {
            playBridge?.playTouch(1, p)
            last = p
            return
        }
        let dist = CGFloat(hypot(Double(p.x - last.x), Double(p.y - last.y)))
        let steps = max(1, Int(dist / 8))
        for i in 1...steps {
            let f = CGFloat(i) / CGFloat(steps)
            applyBrush(CGPoint(x: last.x + (p.x - last.x) * f,
                               y: last.y + (p.y - last.y) * f))
        }
        last = p
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if playMode { playBridge?.playTouch(2, touches.first?.location(in: self) ?? last) }
        down = false
        if !playMode { notify(force: true) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if playMode { playBridge?.playTouch(2, last) }
        down = false
        if !playMode { notify(force: true) }
    }

    // MARK: 笔刷 → 只改 mask，不触发形变

    private func applyBrush(_ p: CGPoint) {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }
        let g = CardPinchPaint.grid
        let u = p.x / w
        let v = p.y / h
        let radius: CGFloat = 0.15                       // 归一化笔尖半径
        let cu = u * CGFloat(g - 1)
        let cv = v * CGFloat(g - 1)
        let radCells = radius * CGFloat(g - 1)

        for r in 0..<g {
            for c in 0..<g {
                let d = CGFloat(hypot(Double(c) - Double(cu), Double(r) - Double(cv)))
                if d > radCells { continue }
                // smoothstep 柔边：笔尖中心 1，边缘平滑到 0
                let t = min(1, (radCells - d) / (radCells * 0.45))
                let s = t * t * (3 - 2 * t)
                let idx = r * g + c
                if tool == 1 {
                    soft[idx] = min(soft[idx], 1 - s)
                } else {
                    soft[idx] = max(soft[idx], s)
                }
            }
        }

        if tool == 1 {
            markLayer.marks.removeAll {
                CGFloat(hypot(Double($0.x - p.x), Double($0.y - p.y))) < $0.r + 14
            }
        } else {
            markLayer.marks.append((x: p.x, y: p.y, r: 30))
            if markLayer.marks.count > 400 { markLayer.marks.removeFirst() }
        }
        markLayer.setNeedsDisplay()
        notify()
    }

    private func notify(force: Bool = false) {
        let now = Date().timeIntervalSince1970
        if !force && now - lastCb < 0.11 { return }
        lastCb = now
        onSoftChanged?(hasSoft())
    }
}

// MARK: - 青点标记层（每帧渐变只建一次，靠 translate 挪到各笔迹）

private final class PaintMarkLayer: UIView {
    var marks: [(x: CGFloat, y: CGFloat, r: CGFloat)] = []
    private var gradient: CGGradient?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isOpaque = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func clear() { marks.removeAll(); setNeedsDisplay() }

    override func draw(_ rect: CGRect) {
        guard let c = UIGraphicsGetCurrentContext() else { return }
        if gradient == nil {
            let cs = CGColorSpaceCreateDeviceRGB()
            let colors = [UIColor(red: 0.47, green: 0.86, blue: 0.80, alpha: 0.45).cgColor,
                          UIColor(red: 0.47, green: 0.86, blue: 0.80, alpha: 0).cgColor] as CFArray
            gradient = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])
        }
        guard let g = gradient else { return }
        for m in marks {
            c.saveGState()
            c.translateBy(x: m.x, y: m.y)
            c.drawRadialGradient(g, startCenter: .zero, startRadius: 0,
                                 endCenter: .zero, endRadius: m.r, options: [])
            c.restoreGState()
        }
    }
}

import SwiftUI

// MARK: - SwiftUI 桥

struct CardPinchPaintView: UIViewRepresentable {
    var active: Bool
    var playMode: Bool
    var tool: Int
    var key: Int
    var bridge: SquishPlayBridge?
    var onSoftChanged: ((Bool) -> Void)?
    var onReady: (CardPinchPaint) -> Void

    func makeUIView(context: Context) -> CardPinchPaint {
        let v = CardPinchPaint()
        v.playBridge = bridge
        v.onSoftChanged = onSoftChanged
        // 别让首次 updateUIView 把 key 当成「变了」而误清软区。
        context.coordinator.lastKey = key
        DispatchQueue.main.async { onReady(v) }
        return v
    }

    func updateUIView(_ v: CardPinchPaint, context: Context) {
        v.isUserInteractionEnabled = active
        v.playMode = playMode
        v.tool = tool
        v.playBridge = bridge
        // 闭包会捕获当次 render 的 @State，必须每次刷新。
        v.onSoftChanged = onSoftChanged
        if context.coordinator.lastKey != key {
            context.coordinator.lastKey = key
            v.clearSoft()
            v.setMarksVisible(true, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastKey = -1 }
}
