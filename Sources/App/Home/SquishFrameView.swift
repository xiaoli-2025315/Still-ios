import SwiftUI
import UIKit
import QuartzCore

// MARK: - 「它」页捏捏：玩耍态的逐顶点弹簧形变（2026-11-24 方向级重做）
//
// ★ 涂抹阶段不走这里（走 Image(uiImage:)）。点确认后才创建本 view：
//   软区 mask 由 CardPinchPaint 提供，17×17 顶点覆盖帧的 scaledToFit 显示矩形；
//   抓住软区跟手拽，松手 K=0.22 / C=0.12 阻尼弹簧回弹，甩着松手带 FLING_K 初速。
// ★ 形变状态全在 UIView 子类里（@State 会被 SwiftUI 重建冲掉），定时器只在主线程驱动。

private let squishMesh = 16                 // 16×16 小格 → 17×17 顶点
private let squishSigma: CGFloat = 0.18     // 抓点高斯影响半径（归一化）
private let squishK: CGFloat = 0.22         // 弹簧刚度
private let squishC: CGFloat = 0.12         // 阻尼（欠阻尼，多次回弹）
private let squishFling: CGFloat = 0.45     // 甩手速度注入系数
private let squishEps: CGFloat = 0.3        // 全停阈值（px）

// MARK: - 形变桥：涂抹层和形变 view 通过它见面

final class SquishPlayBridge {
    weak var squishView: SquishFrameView? {
        didSet {
            // view 可能比 confirmPinch 晚一帧才创建：把「要玩耍」的意图记下来，
            // 等 view 到位再补一次 beginPlay / endPlay。
            if wantPlaying { squishView?.beginPlay() } else { squishView?.endPlay() }
        }
    }
    weak var paintView: CardPinchPaint?
    var playEnabled = false

    private var wantPlaying = false

    /// 软区采样：未进玩耍态一律 0，形变 view 拿到的 mask 全空就不会动。
    func softness(_ u: CGFloat, _ v: CGFloat) -> CGFloat {
        guard playEnabled else { return 0 }
        return paintView?.softAt(u, v) ?? 0
    }

    /// 涂抹层把触摸转成 (0 down / 1 move / 2 up)，这里换算坐标再转给形变 view。
    func playTouch(_ type: Int, _ p: CGPoint) {
        guard playEnabled, let s = squishView, let paint = paintView else { return }
        let sx = paint.bounds.width > 0 ? s.bounds.width / paint.bounds.width : 1
        let sy = paint.bounds.height > 0 ? s.bounds.height / paint.bounds.height : 1
        s.playTouch(type, CGPoint(x: p.x * sx, y: p.y * sy))
    }

    func setPlaying(_ on: Bool) {
        wantPlaying = on
        if on { squishView?.beginPlay() } else { squishView?.endPlay() }
    }
}

// MARK: - 形变层本体

final class SquishFrameView: UIView {

    private struct Vertex {
        var nu: CGFloat = 0     // 顶点在帧矩形里的归一化坐标
        var nv: CGFloat = 0
        var ox: CGFloat = 0     // 原始像素坐标（view 坐标）
        var oy: CGFloat = 0
        var dx: CGFloat = 0     // 位移
        var dy: CGFloat = 0
        var vx: CGFloat = 0     // 速度（px / 帧）
        var vy: CGFloat = 0
    }

    var img: UIImage? { didSet { setNeedsDisplay() } }

    /// 软区采样闭包（u,v 归一化 0..1 → 软度 0..1），由 configure 注入
    private var maskProvider: ((CGFloat, CGFloat) -> CGFloat)?
    /// 外部可覆盖帧矩形；.zero = 按 bounds 自动算 scaledToFit
    private var frameRectOverride: CGRect = .zero

    private var verts: [Vertex] = []
    private var playing = false
    private var grabbing = false
    private var grabStart: CGPoint = .zero
    private var grabU: CGFloat = 0
    private var grabV: CGFloat = 0
    private var fvx: CGFloat = 0
    private var fvy: CGFloat = 0
    private var lastMovePoint: CGPoint = .zero
    private var lastMoveT: TimeInterval = 0
    private var displayLink: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { displayLink?.invalidate() }

    override func layoutSubviews() {
        super.layoutSubviews()
        if playing { rebuildGeometry() }
    }

    /// 离开窗口（切页 / 视图被拆）时停表，别让链路空转或吊住 self。
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            stopLoop()
            grabbing = false
        }
    }

    // MARK: 对外

    /// 注入软区采样闭包；frameRect 传 .zero 表示按当前 bounds 自动算。
    func configure(maskProvider: @escaping (CGFloat, CGFloat) -> CGFloat,
                   frameRect: CGRect = .zero) {
        self.maskProvider = maskProvider
        self.frameRectOverride = frameRect
        rebuildGeometry()
    }

    func beginPlay() {
        playing = true
        grabbing = false
        stopLoop()
        resetMotion()
        rebuildGeometry()
        setNeedsDisplay()
    }

    func endPlay() {
        playing = false
        grabbing = false
        stopLoop()
        resetMotion()
        setNeedsDisplay()
    }

    /// type: 0 down / 1 move / 2 up；p 是 view 坐标
    func playTouch(_ type: Int, _ p: CGPoint) {
        guard playing else { return }
        if type == 0 {
            let fr = frameRect
            guard fr.width > 0, fr.height > 0, let m = maskProvider else { return }
            let gu = (p.x - fr.minX) / fr.width
            let gv = (p.y - fr.minY) / fr.height
            // 只有按在软区上才抓得住
            guard m(gu, gv) > 0.2 else { return }
            stopLoop()
            grabbing = true
            grabStart = p
            grabU = gu
            grabV = gv
            fvx = 0; fvy = 0
            lastMovePoint = p
            lastMoveT = Date().timeIntervalSince1970
            for i in verts.indices { verts[i].vx = 0; verts[i].vy = 0 }
            return
        }
        if type == 1 {
            guard grabbing, let m = maskProvider else { return }
            let dx = p.x - grabStart.x
            let dy = p.y - grabStart.y

            // 平滑记录手指速度（px / 帧）：先算 px/秒再按 60fps 归一。
            let now = Date().timeIntervalSince1970
            let dt = max(0.008, now - lastMoveT)
            let ix = (p.x - lastMovePoint.x) / CGFloat(dt) / 60.0
            let iy = (p.y - lastMovePoint.y) / CGFloat(dt) / 60.0
            fvx = fvx * 0.7 + ix * 0.3
            fvy = fvy * 0.7 + iy * 0.3
            let vmag = CGFloat(hypot(Double(fvx), Double(fvy)))
            if vmag > 14 {
                let k: CGFloat = 14 / vmag
                fvx *= k; fvy *= k
            }
            lastMovePoint = p
            lastMoveT = now

            // 顶点位移直接 = 手指位移 × (软度 × 高斯)，跟手。
            let twoSigma2 = 2 * squishSigma * squishSigma
            for i in verts.indices {
                let vv = verts[i]
                let du = vv.nu - grabU
                let dv = vv.nv - grabV
                let d2 = du * du + dv * dv
                let g = CGFloat(exp(-Double(d2) / Double(twoSigma2)))
                let w = m(vv.nu, vv.nv) * g
                verts[i].dx = dx * w
                verts[i].dy = dy * w
            }
            setNeedsDisplay()
            return
        }
        if type == 2 {
            guard grabbing else { return }
            grabbing = false
            // 静止握了一会再松手：速度按停驻时间衰减，不该甩出去。
            let quiet = max(0, Date().timeIntervalSince1970 - lastMoveT)
            let decay = CGFloat(max(0, 1 - quiet * 6))
            let fx = fvx * decay * squishFling
            let fy = fvy * decay * squishFling
            for i in verts.indices {
                verts[i].vx += fx
                verts[i].vy += fy
            }
            startLoop()
        }
    }

    // MARK: 帧矩形 / 顶点几何

    private var frameRect: CGRect {
        if frameRectOverride != .zero { return frameRectOverride }
        guard let img = img, img.size.width > 0, img.size.height > 0 else { return bounds }
        let s = min(bounds.width / img.size.width, bounds.height / img.size.height)
        let w = img.size.width * s
        let h = img.size.height * s
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2,
                      width: w, height: h)
    }

    private func rebuildGeometry() {
        let n = squishMesh
        let fr = frameRect
        guard fr.width > 0, fr.height > 0 else { return }
        let cw = fr.width / CGFloat(n)
        let ch = fr.height / CGFloat(n)
        let count = (n + 1) * (n + 1)
        if verts.count != count { verts = Array(repeating: Vertex(), count: count) }
        for r in 0...n {
            for c in 0...n {
                let i = r * (n + 1) + c
                verts[i].nu = CGFloat(c) / CGFloat(n)
                verts[i].nv = CGFloat(r) / CGFloat(n)
                verts[i].ox = fr.minX + CGFloat(c) * cw
                verts[i].oy = fr.minY + CGFloat(r) * ch
            }
        }
    }

    private func resetMotion() {
        for i in verts.indices {
            verts[i].dx = 0; verts[i].dy = 0
            verts[i].vx = 0; verts[i].vy = 0
        }
        fvx = 0; fvy = 0
        lastMovePoint = .zero
        lastMoveT = 0
    }

    // MARK: 逐帧驱动

    private func startLoop() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tickLink))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopLoop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tickLink() {
        step()
    }

    private func step() {
        guard !grabbing else { return }
        var moving = false
        for i in verts.indices {
            var v = verts[i]
            if abs(v.dx) > squishEps || abs(v.dy) > squishEps ||
               abs(v.vx) > squishEps || abs(v.vy) > squishEps {
                // 半隐式欧拉：v += (-K*d - C*v); d += v
                v.vx = v.vx + (-squishK * v.dx - squishC * v.vx)
                v.vy = v.vy + (-squishK * v.dy - squishC * v.vy)
                v.dx = v.dx + v.vx
                v.dy = v.dy + v.vy
                verts[i] = v
                if abs(v.dx) > squishEps || abs(v.dy) > squishEps ||
                   abs(v.vx) > squishEps || abs(v.vy) > squishEps {
                    moving = true
                }
            } else {
                v.dx = 0; v.dy = 0; v.vx = 0; v.vy = 0
                verts[i] = v
            }
        }
        setNeedsDisplay()
        if !moving { stopLoop() }     // 全停就收工，不空转
    }

    // MARK: 绘制：把每格四角的位移烘进目标矩形，逐格画当前帧

    override func draw(_ rect: CGRect) {
        guard let img = img, let cg = img.cgImage else { return }
        let fr = frameRect
        guard fr.width > 0, fr.height > 0, cg.width > 0, cg.height > 0 else { return }
        let n = squishMesh
        let count = (n + 1) * (n + 1)
        if verts.count != count { rebuildGeometry() }
        guard verts.count == count else { return }

        let pxW = CGFloat(cg.width)
        let pxH = CGFloat(cg.height)
        let cw = fr.width / CGFloat(n)
        let ch = fr.height / CGFloat(n)
        let fn = CGFloat(n)

        for row in 0..<n {
            for col in 0..<n {
                let i00 = row * (n + 1) + col
                let i10 = i00 + 1
                let i01 = i00 + (n + 1)
                let i11 = i01 + 1
                // 格心位移 = 四角平均
                let ax = (verts[i00].dx + verts[i10].dx + verts[i01].dx + verts[i11].dx) / 4
                let ay = (verts[i00].dy + verts[i10].dy + verts[i01].dy + verts[i11].dy) / 4

                let tileRect = CGRect(x: pxW * CGFloat(col) / fn,
                                      y: pxH * CGFloat(row) / fn,
                                      width: pxW / fn,
                                      height: pxH / fn)
                guard let tile = cg.cropping(to: tileRect) else { continue }
                // 格间重叠 0.5pt 防缝
                let dest = CGRect(x: fr.minX + CGFloat(col) * cw + ax - 0.25,
                                  y: fr.minY + CGFloat(row) * ch + ay - 0.25,
                                  width: cw + 0.5,
                                  height: ch + 0.5)
                UIImage(cgImage: tile).draw(in: dest)
            }
        }
    }
}

// MARK: - SwiftUI 桥

struct SquishFrameHost: UIViewRepresentable {
    let img: UIImage
    let bridge: SquishPlayBridge?
    let width: CGFloat

    func makeUIView(context: Context) -> SquishFrameView {
        let v = SquishFrameView()
        v.configure(maskProvider: { [weak bridge] u, vv in
            bridge?.softness(u, vv) ?? 0
        })
        bridge?.squishView = v     // didSet 会补一次 beginPlay / endPlay
        return v
    }

    func updateUIView(_ v: SquishFrameView, context: Context) {
        v.img = img
        if bridge?.squishView !== Optional(v) { bridge?.squishView = v }
    }

    /// 跟原 `Image(uiImage:).resizable().scaledToFit()` 一样：宽度定死、高度按图比例。
    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: SquishFrameView,
                      context: Context) -> CGSize? {
        let w = proposal.width ?? width
        guard img.size.width > 0 else { return CGSize(width: w, height: w) }
        return CGSize(width: w, height: w * img.size.height / img.size.width)
    }
}
