import UIKit

// MARK: - 原生记忆球（对齐安卓 MemPlanetView）
//
// 2026-11-23：记忆页不再嵌网页。这颗球用系统画布自己算透视画出来：
// 球面散点（多色过渡）+ 细线网 + 记忆节点（极点/核心/呼吸柔光/名字）。
// 拖动转球、松手继续转、静止两秒自转；点中一颗 → 转到正面 + 放大 + 回调出卡片。
//
// ★ 一个点都不编：节点只从 setNodes() 进来，几份画几颗；空就画"这只还没有记忆"。
// ★ 不用 WebGL / Metal，纯 CoreGraphics —— 老机器也跑得动。

/// 球上的一颗记忆（跟柜子里一份文件一一对应）。
struct MemNode: Identifiable, Equatable {
    let id: Int
    var label: String
    var type: String          // folder / text / act
    var cat: String
    var catName: String
    var desc: String
    var kids: [MemNode]?

    static func == (a: MemNode, b: MemNode) -> Bool { a.id == b.id }
}

final class MemPlanetUIView: UIView {

    // ---- 外面塞进来的 ----
    var onTap: ((MemNode?) -> Void)?

    private(set) var nodes: [MemNode] = []
    private var focusId: Int?
    /// 外面（信息卡关掉）清聚焦
    func clearFocus() {
        guard focusId != nil else { return }
        focusId = nil
        goalOn = false
        auto = true
        setNeedsDisplay()
    }
    /// 外面（搜索/列表）直接聚焦某一颗
    func focusOn(_ node: MemNode) {
        guard let i = nodes.firstIndex(where: { $0.id == node.id }) else { return }
        focusId = node.id
        auto = false
        lastAct = CACurrentMediaTime()
        let x = nx[i], y = ny[i], z = nz[i]
        let cs = cos(-0.28), sn = sin(-0.28)
        let qx = x * cs - y * sn, qy = x * sn + y * cs, qz = z
        var tRy = atan2(-qx, qz)
        var tRx = atan2(qy, sqrt(qx * qx + qz * qz)) - 0.34
        tRx = max(-1.1, min(1.1, tRx))
        var d = tRy - ry
        while d > .pi { d -= .pi * 2 }
        while d < -.pi { d += .pi * 2 }
        tRy = ry + d
        goalRy = tRy; goalRx = tRx; goalOn = true
        setNeedsDisplay()
    }
    func setNodes(_ ns: [MemNode]) {
        nodes = ns
        focusId = nil
        goalOn = false
        重建节点坐标()
        setNeedsDisplay()
    }
    /// 聚焦那颗现在画在哪（给外面拉线用）
    func focusPoint() -> CGPoint? {
        guard let id = focusId, let i = nodes.firstIndex(where: { $0.id == id }), i < 512 else { return nil }
        return CGPoint(x: nsx[i], y: nsy[i])
    }

    // ---- 参数（照安卓/网页）----
    private static let PN = 2000
    private static let SN = 900
    private static let COLOR_N = 16
    private static let DEPTH_N = 3

    private static let ANCH: [(Float, Float, Float, Float, Float, Float)] = [
        (0, 1, 0, 1, .80, .32),
        (.9, .25, .3, 1, .45, .28),
        (.25, .3, .9, .94, .42, .80),
        (-.85, .2, .35, .36, .62, 1),
        (-.2, -.4, -.9, .28, .88, .84),
        (.7, -.6, -.3, .60, .92, .52),
        (-.6, -.7, .4, 1, .96, .86),
    ]

    private var px = [Float](), py = [Float](), pz = [Float]()
    private var pcol = [Int]()                    // 颜色桶
    private var segA = [Int](), segB = [Int]()

    private var nx = [Float](repeating: 0, count: 512)
    private var ny = [Float](repeating: 0, count: 512)
    private var nz = [Float](repeating: 0, count: 512)
    private var nsx = [Float](repeating: 0, count: 512)
    private var nsy = [Float](repeating: 0, count: 512)
    private var nsf = [Float](repeating: 0, count: 512)

    // ---- 视角 ----
    private var ry: Float = -0.35
    private var rx: Float = -0.18
    private var goalRy: Float = 0
    private var goalRx: Float = 0
    private var goalOn = false
    private var auto = true
    private var lastAct: CFTimeInterval = 0

    private var dragging = false
    private var lastX: CGFloat = 0, lastY: CGFloat = 0
    private var moved: CGFloat = 0

    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var glowImg: UIImage?

    // 分桶缓冲
    private var bufPaths = [CGMutablePath?](repeating: nil, count: MemPlanetUIView.COLOR_N * MemPlanetUIView.DEPTH_N)
    private let layerAlpha: [CGFloat] = [0.26, 0.55, 1.0]
    private let layerWidth: [CGFloat] = [0.85, 1.15, 1.5]
    private var 桶色RGB: [(CGFloat, CGFloat, CGFloat)] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = false
        造点()
        造色板()
        lastAct = CACurrentMediaTime()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { link?.invalidate() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { 起() } else { 停() }
    }
    private func 起() {
        guard link == nil else { return }
        lastFrame = CACurrentMediaTime()
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }
    private func 停() {
        link?.invalidate()
        link = nil
    }

    // MARK: 造点

    private func 造点() {
        var rng = SystemRandomNumberGenerator()
        let gold = Float.pi * (3 - sqrt(5))
        var dens: [(Float, Float, Float)] = []
        for _ in 0..<11 {
            let dy = Float.random(in: -1...1, using: &rng)
            let dr = sqrt(max(0, 1 - dy * dy))
            let dt = Float.random(in: 0...(Float.pi * 2), using: &rng)
            dens.append((cos(dt) * dr, dy, sin(dt) * dr))
        }

        let total = Self.PN * 2
        var c = 0
        while px.count < Self.PN && c < total {
            let y = 1 - (Float(c) + 0.5) / Float(total) * 2
            let rr = sqrt(max(0, 1 - y * y))
            let th = gold * Float(c)
            var ax = cos(th) * rr + (Float.random(in: 0...1, using: &rng) - 0.5) * 0.09
            var ay = y + (Float.random(in: 0...1, using: &rng) - 0.5) * 0.09
            var az = sin(th) * rr + (Float.random(in: 0...1, using: &rng) - 0.5) * 0.09
            c += 1
            let pl = sqrt(ax * ax + ay * ay + az * az)
            if pl < 0.0001 { continue }
            ax /= pl; ay /= pl; az /= pl

            var keep: Float = 0.3
            for d in dens {
                let ex = ax - d.0, ey = ay - d.1, ez = az - d.2
                let dist = sqrt(ex * ex + ey * ey + ez * ez)
                if dist < 0.5 { keep += 0.55 * (1 - dist / 0.5) }
            }
            if Float.random(in: 0...1, using: &rng) > keep { continue }

            px.append(ax); py.append(ay); pz.append(az)
            pcol.append(颜色桶(ax, ay, az))
        }

        // 网线：相邻点固定配对
        let step = max(1, px.count / 700)
        var i = 0
        while i < px.count && segA.count < Self.SN {
            var j = i + 1
            while j < min(i + 12, px.count) && segA.count < Self.SN {
                let ex = px[i] - px[j], ey = py[i] - py[j], ez = pz[i] - pz[j]
                if ex * ex + ey * ey + ez * ez < 0.040 {
                    segA.append(i); segB.append(j)
                }
                j += 1
            }
            i += step
        }
    }

    private func 混色(_ x: Float, _ y: Float, _ z: Float) -> (Float, Float, Float) {
        var r: Float = 0, g: Float = 0, b: Float = 0, tw: Float = 0
        for a in Self.ANCH {
            let d = x * a.0 + y * a.1 + z * a.2
            let w = pow((d + 1) * 0.5, 3)
            r += a.3 * w; g += a.4 * w; b += a.5 * w; tw += w
        }
        if tw > 0 { r /= tw; g /= tw; b /= tw }
        return (r, g, b)
    }

    private func 颜色桶(_ x: Float, _ y: Float, _ z: Float) -> Int {
        let c = 混色(x, y, z)
        var best = 0
        var bd = Float.greatestFiniteMagnitude
        for i in 0..<Self.COLOR_N {
            let t = Float(i) / Float(Self.COLOR_N - 1)
            let yy = 1 - 2 * t
            let rr = sqrt(max(0, 1 - yy * yy))
            let th = t * 7.7
            let p = 混色(cos(th) * rr, yy, sin(th) * rr)
            let d = (p.0 - c.0) * (p.0 - c.0) + (p.1 - c.1) * (p.1 - c.1) + (p.2 - c.2) * (p.2 - c.2)
            if d < bd { bd = d; best = i }
        }
        return best
    }

    private func 造色板() {
        桶色RGB.removeAll()
        for i in 0..<Self.COLOR_N {
            let t = Float(i) / Float(Self.COLOR_N - 1)
            let yy = 1 - 2 * t
            let rr = sqrt(max(0, 1 - yy * yy))
            let th = t * 7.7
            let c = 混色(cos(th) * rr, yy, sin(th) * rr)
            桶色RGB.append((CGFloat(min(1, c.0 * 0.88 + 0.12)),
                            CGFloat(min(1, c.1 * 0.88 + 0.12)),
                            CGFloat(min(1, c.2 * 0.88 + 0.12))))
        }
    }

    private func 重建节点坐标() {
        let n = min(nodes.count, 512)
        let gold = Float.pi * (3 - sqrt(5))
        for i in 0..<n {
            let p = Float(acos(1 - 2 * (Float(i) + 0.5) / Float(max(n, 1))))
            let t = gold * Float(i)
            nx[i] = sin(p) * cos(t)
            ny[i] = cos(p)
            nz[i] = sin(p) * sin(t)
        }
    }

    // MARK: 每帧

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(0.05, Float(now - lastFrame))
        lastFrame = now

        if goalOn {
            let k = 1 - pow(1 - 0.11, dt * 60)
            ry += (goalRy - ry) * k
            rx += (goalRx - rx) * k
            if abs(goalRy - ry) < 0.003 && abs(goalRx - rx) < 0.003 {
                ry = goalRy; rx = goalRx; goalOn = false
            }
        } else if !dragging && auto && now - lastAct > 2.2 {
            ry += 0.096 * dt
        }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let W = bounds.width, H = bounds.height
        if W <= 0 || H <= 0 { return }
        let cx = W / 2
        let cy = H / 2 - 6
        let R = min(W * 0.31, 112)

        let csY = CGFloat(cos(ry)), snY = CGFloat(sin(ry))
        let csX = CGFloat(cos(rx)), snX = CGFloat(sin(rx))
        let csZ = CGFloat(cos(0.28)), snZ = CGFloat(sin(0.28))

        // ---- 散点分桶 ----
        let bucketN = Self.COLOR_N * Self.DEPTH_N
        for i in 0..<bucketN { bufPaths[i] = nil }
        var counts = [Int](repeating: 0, count: bucketN)

        for i in 0..<px.count {
            let x = CGFloat(px[i]), y = CGFloat(py[i]), z = CGFloat(pz[i])
            let x1 = x * csY + z * snY
            let z1 = -x * snY + z * csY
            let y1 = y * csX - z1 * snX
            let z2 = y * snX + z1 * csX
            let sx = x1 * csZ - y1 * snZ
            let sy = x1 * snZ + y1 * csZ
            let f = 1 / (1 - z2 * 0.30)
            let X = cx + sx * R * f
            let Y = cy - sy * R * f
            let depth = z2 > 0.25 ? 2 : (z2 > -0.25 ? 1 : 0)
            let bi = depth * Self.COLOR_N + pcol[i]
            if bufPaths[bi] == nil { bufPaths[bi] = CGMutablePath() }
            let rad = layerWidth[depth] * 0.5 * (1 + z2 * 0.15) + 0.35
            bufPaths[bi]!.addEllipse(in: CGRect(x: X - rad, y: Y - rad, width: rad * 2, height: rad * 2))
            counts[bi] += 1
        }

        // ---- 网线 ----
        if focusId == nil && !segA.isEmpty {
            let linePath = CGMutablePath()
            for k in 0..<segA.count {
                let a = segA[k], b = segB[k]
                let ax1 = CGFloat(px[a]) * csY + CGFloat(pz[a]) * snY
                let az1 = -CGFloat(px[a]) * snY + CGFloat(pz[a]) * csY
                let ay1 = CGFloat(py[a]) * csX - az1 * snX
                let az2 = CGFloat(py[a]) * snX + az1 * csX
                let asx = ax1 * csZ - ay1 * snZ, asy = ax1 * snZ + ay1 * csZ
                let af = 1 / (1 - az2 * 0.30)

                let bx1 = CGFloat(px[b]) * csY + CGFloat(pz[b]) * snY
                let bz1 = -CGFloat(px[b]) * snY + CGFloat(pz[b]) * csY
                let by1 = CGFloat(py[b]) * csX - bz1 * snX
                let bz2 = CGFloat(py[b]) * snX + bz1 * csX
                let bsx = bx1 * csZ - by1 * snZ, bsy = bx1 * snZ + by1 * csZ
                let bf = 1 / (1 - bz2 * 0.30)

                linePath.move(to: CGPoint(x: cx + asx * R * af, y: cy - asy * R * af))
                linePath.addLine(to: CGPoint(x: cx + bsx * R * bf, y: cy - bsy * R * bf))
            }
            ctx.addPath(linePath)
            ctx.setStrokeColor(UIColor(red: 111/255, green: 168/255, blue: 184/255, alpha: 0.13).cgColor)
            ctx.setLineWidth(0.9)
            ctx.strokePath()
        }

        // ---- 画散点（每桶一次）----
        for bi in 0..<bucketN where counts[bi] > 0 {
            guard let p = bufPaths[bi] else { continue }
            let depth = bi / Self.COLOR_N
            let c = 桶色RGB[bi % Self.COLOR_N]
            ctx.addPath(p)
            ctx.setFillColor(UIColor(red: c.0, green: c.1, blue: c.2,
                                     alpha: layerAlpha[depth]).cgColor)
            ctx.fillPath()
        }

        // ---- 记忆节点 ----
        let n = min(nodes.count, 512)
        for i in 0..<n {
            let x = CGFloat(nx[i]), y = CGFloat(ny[i]), z = CGFloat(nz[i])
            let x1 = x * csY + z * snY
            let z1 = -x * snY + z * csY
            let y1 = y * csX - z1 * snX
            let z2 = y * snX + z1 * csX
            let sx = x1 * csZ - y1 * snZ
            let sy = x1 * snZ + y1 * csZ
            let f = 1 / (1 - z2 * 0.30)
            nsx[i] = Float(cx + sx * R * 1.02 * f)
            nsy[i] = Float(cy - sy * R * 1.02 * f)
            nsf[i] = Float(z2)
        }
        var order = Array(0..<n)
        order.sort { nsf[$0] < nsf[$1] }

        let now = CACurrentMediaTime()
        for i in order {
            let nd = nodes[i]
            let sel = (focusId == nd.id)
            let scale: CGFloat = sel ? 2.4 : 1
            let depth = CGFloat(max(0, min(1, (nsf[i] + 1) / 2)))
            let alpha = 0.25 + 0.75 * depth
            let col = 类别色(nd.cat)
            let X = CGFloat(nsx[i]), Y = CGFloat(nsy[i])

            // 柔光
            let gs = 38 * scale * (1 + 0.10 * CGFloat(sin(now * 3 + Double(i) * 0.9)))
            if let g = 光晕图() {
                ctx.saveGState()
                ctx.setAlpha(alpha * (sel ? 0.58 : 0.46))
                ctx.setBlendMode(.plusLighter)
                ctx.draw(g, in: CGRect(x: X - gs / 2, y: Y - gs / 2, width: gs, height: gs))
                ctx.restoreGState()
            }
            // 极点
            ctx.setFillColor(UIColor.white.withAlphaComponent(alpha).cgColor)
            ctx.fillEllipse(in: CGRect(x: X - 5.5 * scale, y: Y - 5.5 * scale,
                                       width: 11 * scale, height: 11 * scale))
            // 核心
            ctx.setFillColor(col.withAlphaComponent(min(1, alpha + 0.15)).cgColor)
            ctx.fillEllipse(in: CGRect(x: X - 2.6 * scale, y: Y - 2.6 * scale,
                                       width: 5.2 * scale, height: 5.2 * scale))

            // 名字
            let la = sel ? 1.0 : 0.08 + 0.92 * pow(depth, 1.7)
            let font = UIFont.systemFont(ofSize: sel ? 12.5 : 10.5, weight: .light)
            let str = NSAttributedString(string: 缩短(nd.label), attributes: [
                .font: font,
                .foregroundColor: UIColor(red: 236/255, green: 244/255, blue: 252/255, alpha: la),
            ])
            let sz = str.size()
            str.draw(at: CGPoint(x: X - sz.width / 2, y: Y - (sel ? 30 : 18) - sz.height))
        }

        if n == 0 {
            let str = NSAttributedString(string: "这只还没有记忆", attributes: [
                .font: UIFont.systemFont(ofSize: 11),
                .foregroundColor: UIColor(white: 0.85, alpha: 0.4),
            ])
            let sz = str.size()
            str.draw(at: CGPoint(x: cx - sz.width / 2, y: cy - sz.height / 2))
        }
    }

    private func 光晕图() -> UIImage? {
        if let g = glowImg { return g }
        let S: CGFloat = 96
        let r = UIGraphicsImageRenderer(size: CGSize(width: S, height: S))
        let img = r.image { c in
            let ctx = c.cgContext
            let colors = [UIColor.white.cgColor,
                          UIColor.white.withAlphaComponent(0.9).cgColor,
                          UIColor.white.withAlphaComponent(0.35).cgColor,
                          UIColor.white.withAlphaComponent(0.14).cgColor,
                          UIColor.white.withAlphaComponent(0).cgColor] as CFArray
            let locs: [CGFloat] = [0, 0.10, 0.28, 0.55, 1]
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors, locations: locs) {
                ctx.drawRadialGradient(grad,
                                       startCenter: CGPoint(x: S/2, y: S/2), startRadius: 0,
                                       endCenter: CGPoint(x: S/2, y: S/2), endRadius: S/2,
                                       options: [])
            }
        }
        glowImg = img
        return img
    }

    private func 类别色(_ cat: String) -> UIColor {
        switch cat {
        case "act": return UIColor(white: 0.07, alpha: 1)
        case "image", "video", "file": return UIColor(red: 91/255, green: 143/255, blue: 168/255, alpha: 1)
        default: return UIColor(red: 0.43, green: 0.43, blue: 0.41, alpha: 1)
        }
    }

    private func 缩短(_ s: String) -> String {
        s.count <= 8 ? s : String(s.prefix(8))
    }

    // MARK: 触摸

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        dragging = true
        moved = 0
        lastX = t.location(in: self).x
        lastY = t.location(in: self).y
        auto = false
        goalOn = false
        lastAct = CACurrentMediaTime()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard dragging, let t = touches.first else { return }
        let p = t.location(in: self)
        let dx = p.x - lastX, dy = p.y - lastY
        moved += abs(dx) + abs(dy)
        ry += Float(dx) * 0.012
        rx = max(-1.1, min(1.1, rx + Float(dy) * 0.009))
        lastX = p.x; lastY = p.y
        lastAct = CACurrentMediaTime()
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard dragging, let t = touches.first else { return }
        dragging = false
        lastAct = CACurrentMediaTime()
        let p = t.location(in: self)
        if moved < 7 {
            let hit = 命中(p)
            if let h = hit {
                focusOn(h)
                onTap?(h)
            } else {
                clearFocus()
                onTap?(nil)
            }
        } else {
            auto = (focusId == nil)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        dragging = false
        lastAct = CACurrentMediaTime()
    }

    private func 命中(_ p: CGPoint) -> MemNode? {
        let n = min(nodes.count, 512)
        var best = -1
        var bd: CGFloat = 30
        for i in 0..<n {
            if nsf[i] < 0.05 { continue }
            let d = hypot(p.x - CGFloat(nsx[i]), p.y - CGFloat(nsy[i]))
            if d < bd { bd = d; best = i }
        }
        return best >= 0 ? nodes[best] : nil
    }
}

/// SwiftUI 壳子：把原生球塞进来。
struct MemPlanet: UIViewRepresentable {
    let nodes: [MemNode]
    var onTap: (MemNode?) -> Void

    final class Coord {
        var 签名: Int? = nil
    }

    func makeCoordinator() -> Coord { Coord() }

    func makeUIView(context: Context) -> MemPlanetUIView {
        let v = MemPlanetUIView()
        v.onTap = onTap
        v.setNodes(nodes)
        context.coordinator.签名 = 算签名(nodes)
        return v
    }

    func updateUIView(_ v: MemPlanetUIView, context: Context) {
        v.onTap = onTap
        let s = 算签名(nodes)
        if context.coordinator.签名 != s {
            context.coordinator.签名 = s
            v.setNodes(nodes)
        }
    }

    private func 算签名(_ ns: [MemNode]) -> Int {
        var h = 17
        for n in ns { h = h &* 31 &+ n.id &+ n.label.count }
        return h
    }
}
