import SwiftUI
import UIKit

// MARK: - 原生记忆球（对齐安卓 MemPlanetView）
//
// 2026-11-23：记忆页不再嵌网页。这颗球用系统画布自己算透视画出来：
// 球面散点（多色过渡）+ 细线网 + 记忆节点（极点/核心/呼吸柔光/名字）。
// 拖动转球、一松手就接着转；点中一颗 → 原地放大 + 拉线出卡片（不转球）；整球缓缓呼吸。
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
    var desc: String              // 记的原物
    var 说明: String = ""          // 为什么记它 / 注解
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
    /// ★ 2026-11-23 晚：镜头朝这颗点整屏推近；放大期间停自转，呼吸/微动继续。
    func focusOn(_ node: MemNode) {
        guard 点号[node.id] != nil else { return }
        focusId = node.id
        auto = false
        goalOn = false
        lastAct = CACurrentMediaTime()
        setNeedsDisplay()
    }
    func setNodes(_ ns: [MemNode]) {
        nodes = ns
        focusId = nil
        goalOn = false
        展开点()
        重建节点坐标()
        setNeedsDisplay()
    }
    /// 聚焦那颗现在画在哪（给外面拉线用）
    func focusPoint() -> CGPoint? {
        guard let id = focusId, let i = 点号[id], i < 512 else { return nil }
        return CGPoint(x: CGFloat(nsx[i]), y: CGFloat(nsy[i]))
    }

    // ---- 参数（照安卓/网页）----
    private static let PN = 2000
    private static let SN = 900
    private static let COLOR_N = 16
    private static let DEPTH_N = 3

    private static let ANCH: [(Float, Float, Float, Float, Float, Float)] = [
        (0, 1, 0, 1, 0.80, 0.32),
        (0.9, 0.25, 0.3, 1, 0.45, 0.28),
        (0.25, 0.3, 0.9, 0.94, 0.42, 0.80),
        (-0.85, 0.2, 0.35, 0.36, 0.62, 1),
        (-0.2, -0.4, -0.9, 0.28, 0.88, 0.84),
        (0.7, -0.6, -0.3, 0.60, 0.92, 0.52),
        (-0.6, -0.7, 0.4, 1, 0.96, 0.86),
    ]

    private var px = [Float](), py = [Float](), pz = [Float](), pPh = [Float]()
    private var pcol = [Int]()                    // 颜色桶
    private var segA = [Int](), segB = [Int]()

    // 球上真正画出来的每一颗：四类各一颗，类里每一份记忆也各一颗
    private var 点: [MemNode] = []
    private var 点号: [Int: Int] = [:]
    private var 母点 = [Int](repeating: -1, count: 512)
    private var 点径 = [Float](repeating: 1, count: 512)

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
    private var downX0: CGFloat = 0, downY0: CGFloat = 0
    private var moved: CGFloat = 0

    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var glowImg: UIImage?
    /// 球半径：画图和手势都要用，提成属性，别在 draw 里藏成局部变量
    private var 球半径: CGFloat { min(bounds.width * 0.31, 112) }

    // ★★ 2026-11-23：姿态改成 3×3 旋转矩阵。
    //   以前 ry/rx 两个欧拉角：上下拖会被 clamp 住、斜着划也只能"先竖后横"，
    //   跟手指划的那条线对不上。现在拖动 = 绕**垂直于划线**的轴转（那条线的横截面方向）。
    private var M: [CGFloat] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
    private var 姿态初 = false
    // 聚焦那块区域整体放大（不是只把一颗珠子画大）
    /// ★ 镜头＝整屏靠近那颗点；轴x/轴y 是那颗点钉住不动的屏幕位置
    private var 镜头: CGFloat = 1
    private var 轴x: CGFloat = 0, 轴y: CGFloat = 0
    /// ★ 2026-11-23：双指缩放。下限 1.0＝原始大小（不缩得更小），上限 2.8。
    ///  放大时次级记忆点名称渐显；跟聚焦镜头叠加（两级缩放）。
    private var 捏放: CGFloat = 1
    private let 捏放上限: CGFloat = 2.8
    private var 捏合中 = false
    private var 本趟捏过 = false
    private var 捏起距: CGFloat = 0, 捏起放: CGFloat = 1

    private func 左乘Y(_ th: CGFloat) {
        let c = cos(th), s = sin(th)
        左乘([c, 0, s, 0, 1, 0, -s, 0, c])
    }

    private func 左乘轴角(_ ux: CGFloat, _ uy: CGFloat, _ uz: CGFloat, _ th: CGFloat) {
        let len = (ux * ux + uy * uy + uz * uz).squareRoot()
        if len < 0.000001 || abs(th) < 0.0000001 { return }
        let x = ux / len, y = uy / len, z = uz / len
        let c = cos(th), s = sin(th), t = 1 - c
        左乘([t * x * x + c, t * x * y - s * z, t * x * z + s * y,
             t * x * y + s * z, t * y * y + c, t * y * z - s * x,
             t * x * z - s * y, t * y * z + s * x, t * z * z + c])
    }

    private func 左乘(_ r: [CGFloat]) {
        let m00 = M[0], m01 = M[1], m02 = M[2]
        let m10 = M[3], m11 = M[4], m12 = M[5]
        let m20 = M[6], m21 = M[7], m22 = M[8]
        M[0] = r[0] * m00 + r[1] * m10 + r[2] * m20
        M[1] = r[0] * m01 + r[1] * m11 + r[2] * m21
        M[2] = r[0] * m02 + r[1] * m12 + r[2] * m22
        M[3] = r[3] * m00 + r[4] * m10 + r[5] * m20
        M[4] = r[3] * m01 + r[4] * m11 + r[5] * m21
        M[5] = r[3] * m02 + r[4] * m12 + r[5] * m22
        M[6] = r[6] * m00 + r[7] * m10 + r[8] * m20
        M[7] = r[6] * m01 + r[7] * m11 + r[8] * m21
        M[8] = r[6] * m02 + r[7] * m12 + r[8] * m22
    }

    private func 建姿态() {
        M = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        左乘Y(CGFloat(ry))
        左乘轴角(1, 0, 0, CGFloat(rx))
        左乘轴角(0, 0, 1, 0.28)
        姿态初 = true
    }

    /// 信息条：先长线，线到位后浮窗才长出来。线画在球这一层，终点给卡片顶部那一行。
    var 线进度: CGFloat = 0
    var 线终点Y: CGFloat = 0

    /// 两级缩放：先按聚焦镜头绕焦点推近，再按双指捏放绕屏幕中心放大。
    private func 过镜头(_ X: CGFloat, _ Y: CGFloat) -> CGPoint {
        var x = X, y = Y
        if 镜头 != 1 {
            x = 轴x + (x - 轴x) * 镜头
            y = 轴y + (y - 轴y) * 镜头
        }
        if 捏放 != 1 {
            let 中x = bounds.width / 2
            let 中y = bounds.height / 2 - 6
            x = 中x + (x - 中x) * 捏放
            y = 中y + (y - 中y) * 捏放
        }
        return CGPoint(x: x, y: y)
    }

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
            pPh.append(Float(px.count) * 0.6180339)
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

    /// 把树摊平：四类各占一颗，类里每一份记忆也各占一颗
    private func 展开点() {
        点.removeAll(); 点号.removeAll()
        for top in nodes {
            if 点.count >= 512 { break }
            let ti = 点.count
            点号[top.id] = ti
            点.append(top)
            母点[ti] = -1
            点径[ti] = 1.45
            for kd in (top.kids ?? []) {
                if 点.count >= 512 { break }
                if 点号[kd.id] != nil { continue }
                let ki = 点.count
                点号[kd.id] = ki
                点.append(kd)
                母点[ki] = ti
                点径[ki] = 0.80 + 0.45 * Float(ki % 5) / 4
            }
        }
    }

    /// 布点：四类各占球面一个方向，类里每一份围绕它散成一簇（记忆越多簇越大）
    private func 重建节点坐标() {
        let topN = min(nodes.count, 32)
        guard topN > 0 else { return }
        let gold = Float.pi * (3 - sqrt(5))
        // 四类时用正四面体四个方向（两两约 109 度），怎么转都不会挤在一起
        let 四面: [(Float, Float, Float)] = [(0, 1, 0), (0.9428, -0.3333, 0),
                                          (-0.4714, -0.3333, 0.8165), (-0.4714, -0.3333, -0.8165)]
        for i in 0..<topN {
            let ax: Float, ay: Float, az: Float
            if topN <= 4 {
                let d = 四面[i]
                ax = d.0; ay = d.1; az = d.2
            } else {
                let p = Float(acos(1 - 2 * (Float(i) + 0.5) / Float(topN)))
                let t = gold * Float(i)
                ax = sin(p) * cos(t)
                ay = cos(p)
                az = sin(p) * sin(t)
            }
            guard let ci = 点号[nodes[i].id] else { continue }
            nx[ci] = ax; ny[ci] = ay; nz[ci] = az

            let kids = nodes[i].kids ?? []
            let k = kids.count
            if k == 0 { continue }

            var ux: Float = 0, uy: Float = 1, uz: Float = 0
            if abs(ay) > 0.92 { ux = 1; uy = 0; uz = 0 }
            var e1x = uy * az - uz * ay, e1y = uz * ax - ux * az, e1z = ux * ay - uy * ax
            var l1 = sqrt(e1x * e1x + e1y * e1y + e1z * e1z)
            if l1 < 1e-4 { e1x = 1; e1y = 0; e1z = 0; l1 = 1 }
            e1x /= l1; e1y /= l1; e1z /= l1
            let e2x = ay * e1z - az * e1y, e2y = az * e1x - ax * e1z, e2z = ax * e1y - ay * e1x

            let cap = min(0.50, 0.16 + 0.040 * sqrt(Float(k)))
            for j in 0..<k {
                guard let ki = 点号[kids[j].id] else { continue }
                let tt = (Float(j) + 0.5) / Float(k)
                let rr = cap * (0.42 + 0.58 * sqrt(tt)) * (0.88 + 0.24 * Float((j * 37) % 11) / 10)
                let ph = gold * Float(j)
                let cs = cos(rr), sn = sin(rr)
                let qx = ax * cs + (e1x * cos(ph) + e2x * sin(ph)) * sn
                let qy = ay * cs + (e1y * cos(ph) + e2y * sin(ph)) * sn
                let qz = az * cs + (e1z * cos(ph) + e2z * sin(ph)) * sn
                let ql = sqrt(qx * qx + qy * qy + qz * qz)
                if ql < 1e-4 { continue }
                nx[ki] = qx / ql; ny[ki] = qy / ql; nz[ki] = qz / ql
            }
        }
    }

    // MARK: 每帧

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(0.05, Float(now - lastFrame))
        lastFrame = now

        if !姿态初 { 建姿态() }
        if goalOn {
            let k = 1 - pow(1 - 0.11, dt * 60)
            ry += (goalRy - ry) * k
            rx += (goalRx - rx) * k
            if abs(goalRy - ry) < 0.003 && abs(goalRx - rx) < 0.003 {
                ry = goalRy; rx = goalRx; goalOn = false
            }
        } else if !dragging && auto && focusId == nil && now - lastAct > 0.26 {
            // 聚焦期间**停自转**（他这轮明确要求）；呼吸和散点微动在 draw 里照旧
            左乘Y(CGFloat(0.096 * Double(dt)))
        }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let W = bounds.width, H = bounds.height
        if W <= 0 || H <= 0 { return }
        let cx = W / 2
        let cy = H / 2 - 6
        let R = 球半径

        if !姿态初 { 建姿态() }
        let m00 = M[0], m01 = M[1], m02 = M[2]
        let m10 = M[3], m11 = M[4], m12 = M[5]
        let m20 = M[6], m21 = M[7], m22 = M[8]
        let now = CACurrentMediaTime()
        // 整球缓缓胀缩：6 秒一次、幅度 3%（"它在喘气"，不是缩放动画）
        let 呼吸 = 1 + 0.030 * CGFloat(sin(now * 0.00052))

        // ---- 镜头轴心：拿聚焦那颗**没过镜头**的位置，缩放时它钉在原处 ----
        let n = min(点.count, 512)
        var 焦点号: Int? = nil
        if let fid = focusId, let boxed = 点号[fid], boxed >= 0, boxed < n { 焦点号 = boxed }
        if let j = 焦点号 {
            let x = CGFloat(nx[j]), y = CGFloat(ny[j]), z = CGFloat(nz[j])
            let x1 = m00 * x + m01 * y + m02 * z
            let y1 = m10 * x + m11 * y + m12 * z
            let z2 = m20 * x + m21 * y + m22 * z
            let f = 1 / (1 - z2 * 0.30)
            let nw = 呼吸 * (1 + 0.012 * CGFloat(sin(now * 0.00080 + Double(j) * 0.9)))
            let out: CGFloat = 母点[j] < 0 ? 1.055 : 1.040
            轴x = cx + x1 * R * out * nw * f
            轴y = cy - y1 * R * out * nw * f
        } else {
            轴x = cx; 轴y = cy
        }
        let 镜头目标: CGFloat = 焦点号 != nil ? 1.65 : 1
        镜头 += (镜头目标 - 镜头) * 0.13
        if abs(镜头 - 镜头目标) < 0.002 { 镜头 = 镜头目标 }

        // ---- 记忆点投影（呼吸 + 镜头，整屏一起靠近）----
        for i in 0..<n {
            let x = CGFloat(nx[i]), y = CGFloat(ny[i]), z = CGFloat(nz[i])
            let x1 = m00 * x + m01 * y + m02 * z
            let y1 = m10 * x + m11 * y + m12 * z
            let z2 = m20 * x + m21 * y + m22 * z
            let f = 1 / (1 - z2 * 0.30)
            let nw = 呼吸 * (1 + 0.012 * CGFloat(sin(now * 0.00080 + Double(i) * 0.9)))
            let out: CGFloat = 母点[i] < 0 ? 1.055 : 1.040
            let p = 过镜头(cx + x1 * R * out * nw * f, cy - y1 * R * out * nw * f)
            nsx[i] = Float(p.x); nsy[i] = Float(p.y)
            nsf[i] = Float(z2)
        }

        // ---- 散点分桶 ----
        let bucketN = Self.COLOR_N * Self.DEPTH_N
        for i in 0..<bucketN { bufPaths[i] = nil }
        var counts = [Int](repeating: 0, count: bucketN)

        for i in 0..<px.count {
            let x = CGFloat(px[i]), y = CGFloat(py[i]), z = CGFloat(pz[i])
            let x1 = m00 * x + m01 * y + m02 * z
            let y1 = m10 * x + m11 * y + m12 * z
            let z2 = m20 * x + m21 * y + m22 * z
            let f = 1 / (1 - z2 * 0.30)
            let wob = 1 + 0.015 * CGFloat(sin(now * 0.00090 + Double(pPh[i])))
            let p = 过镜头(cx + x1 * R * 呼吸 * wob * f, cy - y1 * R * 呼吸 * wob * f)
            let X = p.x, Y = p.y
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
                let ax1 = CGFloat(px[a]) * m00 + CGFloat(py[a]) * m01 + CGFloat(pz[a]) * m02
                let ay1 = CGFloat(px[a]) * m10 + CGFloat(py[a]) * m11 + CGFloat(pz[a]) * m12
                let az2 = CGFloat(px[a]) * m20 + CGFloat(py[a]) * m21 + CGFloat(pz[a]) * m22
                let af = 1 / (1 - az2 * 0.30)

                let bx1 = CGFloat(px[b]) * m00 + CGFloat(py[b]) * m01 + CGFloat(pz[b]) * m02
                let by1 = CGFloat(px[b]) * m10 + CGFloat(py[b]) * m11 + CGFloat(pz[b]) * m12
                let bz2 = CGFloat(px[b]) * m20 + CGFloat(py[b]) * m21 + CGFloat(pz[b]) * m22
                let bf = 1 / (1 - bz2 * 0.30)

                let aw = 呼吸 * (1 + 0.015 * CGFloat(sin(now * 0.00090 + Double(pPh[a]))))
                let bw = 呼吸 * (1 + 0.015 * CGFloat(sin(now * 0.00090 + Double(pPh[b]))))
                let pa = 过镜头(cx + ax1 * R * aw * af, cy - ay1 * R * aw * af)
                let pb = 过镜头(cx + bx1 * R * bw * bf, cy - by1 * R * bw * bf)
                linePath.move(to: pa)
                linePath.addLine(to: pb)
            }
            ctx.addPath(linePath)
            ctx.setStrokeColor(UIColor(red: 111/255, green: 168/255, blue: 184/255, alpha: 0.13).cgColor)
            ctx.setLineWidth(0.9)
            ctx.strokePath()
        }

        // ---- 信息条：从聚焦那颗点往卡片长一条线（按进度一段段画出来）----
        if 线进度 > 0.001, let i = focusId.flatMap({ 点号[$0] }), i < 512 {
            let sx = CGFloat(nsx[i]), sy = CGFloat(nsy[i])
            let tx = W / 2, ty = 线终点Y
            if ty > sy {
                let mx = (sx + tx) / 2, my = sy + (ty - sy) * 0.3
                let line = CGMutablePath()
                line.move(to: CGPoint(x: sx, y: sy))
                let steps = 24
                for k in 1...steps {
                    let t = 线进度 * CGFloat(k) / CGFloat(steps)
                    let u = 1 - t
                    let qx = u*u*sx + 2*u*t*mx + t*t*tx
                    let qy = u*u*sy + 2*u*t*my + t*t*ty
                    line.addLine(to: CGPoint(x: qx, y: qy))
                }
                ctx.addPath(line)
                ctx.setStrokeColor(UIColor(red: 143/255, green: 216/255, blue: 210/255, alpha: 1).cgColor)
                ctx.setLineWidth(2)
                ctx.strokePath()
                ctx.setFillColor(UIColor.white.cgColor)
                ctx.fillEllipse(in: CGRect(x: sx - 5, y: sy - 5, width: 10, height: 10))
                if 线进度 >= 0.995 {
                    ctx.fillEllipse(in: CGRect(x: tx - 2.5, y: ty - 2.5, width: 5, height: 5))
                }
            }
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

        // ---- 记忆点：四类各一簇，每一份记忆都是一颗（投影已在上面算好）----

        // 类别到它自己每一份之间的细线：一眼看得出"这些记忆属于这一类"
        let 簇色 = UIColor(red: 111/255, green: 168/255, blue: 184/255, alpha: 1)
        ctx.setLineWidth(0.7)
        for i in 0..<n {
            let m = 母点[i]
            if m < 0 || m >= n { continue }
            if nsf[i] < -0.30 { continue }
            let dep = CGFloat((nsf[i] + 1) * 0.5)
            ctx.setStrokeColor(簇色.withAlphaComponent(0.06 + 0.20 * dep).cgColor)
            ctx.move(to: CGPoint(x: CGFloat(nsx[m]), y: CGFloat(nsy[m])))
            ctx.addLine(to: CGPoint(x: CGFloat(nsx[i]), y: CGFloat(nsy[i])))
            ctx.strokePath()
        }

        var order = Array(0..<n)
        order.sort { nsf[$0] < nsf[$1] }

        for i in order {
            let nd = 点[i]
            let sel = (focusId == nd.id)
            let 类 = 母点[i] < 0
            let 径 = CGFloat(点径[i])
            let scale: CGFloat = sel ? 2.4 : 1
            let depth = CGFloat(max(0, min(1, (nsf[i] + 1) / 2)))
            let alpha = (类 ? 0.30 : 0.18) + (类 ? 0.70 : 0.82) * depth
            let col = 类别色(nd.cat)
            let X = CGFloat(nsx[i]), Y = CGFloat(nsy[i])

            // 柔光
            let gs = (类 ? 30.0 : 17.0) * 径 * scale
                * (1 + 0.10 * CGFloat(sin(now * 3 + Double(i) * 0.9)))
            if let g = 光晕图()?.cgImage {
                ctx.saveGState()
                ctx.setAlpha(alpha * (sel ? 0.58 : (类 ? 0.44 : 0.30)))
                ctx.setBlendMode(.plusLighter)
                ctx.draw(g, in: CGRect(x: X - gs / 2, y: Y - gs / 2, width: gs, height: gs))
                ctx.restoreGState()
            }
            // 类别点外面那圈淡环（一颗"珠子"，跟装饰散点分开）
            if 类 {
                ctx.setStrokeColor(col.withAlphaComponent(alpha * (sel ? 0.75 : 0.45)).cgColor)
                ctx.setLineWidth(1.1)
                let rr = 9 * scale
                ctx.strokeEllipse(in: CGRect(x: X - rr, y: Y - rr, width: rr * 2, height: rr * 2))
            }
            // 极点
            ctx.setFillColor(UIColor.white.withAlphaComponent(min(1, alpha + 0.10)).cgColor)
            let r1 = (类 ? 6.0 : 3.2) * scale
            ctx.fillEllipse(in: CGRect(x: X - r1, y: Y - r1, width: r1 * 2, height: r1 * 2))
            // 核心
            ctx.setFillColor(col.withAlphaComponent(min(1, alpha + 0.20)).cgColor)
            let r2 = (类 ? 3.0 : 1.6) * scale
            ctx.fillEllipse(in: CGRect(x: X - r2, y: Y - r2, width: r2 * 2, height: r2 * 2))

            // 名字：类别一直显示（带份数）；单份记忆只在点中时显示，免得糊成一片
            if 类 {
                let kn = (nd.kids ?? []).count
                let la = sel ? 1.0 : 0.10 + 0.90 * pow(depth, 1.5)
                let font = UIFont.systemFont(ofSize: sel ? 12.5 : 10.5, weight: .light)
                let sh = NSShadow()
                sh.shadowColor = UIColor.black.withAlphaComponent(0.70)
                sh.shadowBlurRadius = 3
                sh.shadowOffset = CGSize(width: 0, height: 1)
                let str = NSAttributedString(string: "\(缩短(nd.label)) · \(kn)", attributes: [
                    .font: font,
                    .foregroundColor: UIColor(red: 236/255, green: 244/255, blue: 252/255, alpha: la),
                    .shadow: sh,
                ])
                let sz = str.size()
                var ly = Y - (sel ? 30 : 17) - sz.height
                if ly < 6 { ly = Y + (sel ? 20 : 14) }   // 贴到顶就画到下面
                str.draw(at: CGPoint(x: X - sz.width / 2, y: ly))
            } else {
                // ★ 双指放大时次级记忆点名称随放大程度慢慢显现；缩回原始就隐去
                let 显现 = max(0, min(1, (捏放 - 1.35) / 0.85))
                let la: CGFloat = sel ? 1.0 : 显现 * (0.35 + 0.65 * depth)
                if la > 0.02 {
                    let font = UIFont.systemFont(ofSize: sel ? 12 : 10.5, weight: sel ? .medium : .light)
                    let sh = NSShadow()
                    sh.shadowColor = UIColor.black.withAlphaComponent(0.75)
                    sh.shadowBlurRadius = 3
                    sh.shadowOffset = CGSize(width: 0, height: 1)
                    let str = NSAttributedString(string: 缩短(nd.label), attributes: [
                        .font: font,
                        .foregroundColor: UIColor(red: 236/255, green: 244/255, blue: 252/255, alpha: la),
                        .shadow: sh,
                    ])
                    let sz = str.size()
                    var ly = Y - (sel ? 26 : 17) - sz.height
                    if ly < 6 { ly = Y + (sel ? 16 : 12) }
                    str.draw(at: CGPoint(x: X - sz.width / 2, y: ly))
                }
            }
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

    /// 当前屏上（含本事件）前两指间距；不够两指返回 0
    private func 两指距(_ event: UIEvent?) -> CGFloat {
        guard let all = event?.allTouches, all.count >= 2 else { return 0 }
        let a = all.array[0].location(in: self), b = all.array[1].location(in: self)
        return hypot(a.x - b.x, a.y - b.y)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        dragging = true
        moved = 0
        本趟捏过 = false
        捏合中 = false
        lastX = t.location(in: self).x
        lastY = t.location(in: self).y
        downX0 = lastX; downY0 = lastY
        auto = false
        goalOn = false
        lastAct = CACurrentMediaTime()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        // 两指捏合：只缩放、不转球；下限 1.0（不缩得比原始更小），上限 2.8
        if 捏合中 {
            let d = 两指距(event)
            if 捏起距 > 1, d > 0 {
                捏放 = max(1, min(捏放上限, 捏起放 * d / 捏起距))
            }
            lastAct = CACurrentMediaTime()
            setNeedsDisplay()
            return
        }
        // 第二指刚落下（还没进 MOVE 的捏合分支）：识别并记起点
        if let all = event?.allTouches, all.count >= 2 {
            捏合中 = true
            本趟捏过 = true
            捏起距 = 两指距(event)
            捏起放 = 捏放
            dragging = false
            lastAct = CACurrentMediaTime()
            return
        }
        guard dragging, let t = touches.first else { return }
        let p = t.location(in: self)
        let dx = p.x - lastX, dy = p.y - lastY
        moved += abs(dx) + abs(dy)
        // ★ 球面沿手指那条线滚：转轴 = 垂直于划线（ω = r × v），转角 = 弧长 / 半径
        let 弧 = (dx * dx + dy * dy).squareRoot()
        if 弧 > 0.01 && 球半径 > 1 { 左乘轴角(dy, dx, 0, 弧 * 1.6 / 球半径) }
        lastX = p.x; lastY = p.y
        lastAct = CACurrentMediaTime()
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let 捏过 = 本趟捏过
        if 捏合中 {
            // 还有手指在屏上：本次捏合结束，剩一指接管拖动，别跳
            捏合中 = false
            本趟捏过 = true
            if let all = event?.allTouches, all.count >= 1 {
                let p = all.array[0].location(in: self)
                lastX = p.x; lastY = p.y; downX0 = p.x; downY0 = p.y
                dragging = !touches.isEmpty
            }
            lastAct = CACurrentMediaTime()
            return
        }
        guard dragging, let t = touches.first else { return }
        dragging = false
        lastAct = CACurrentMediaTime()
        let p = t.location(in: self)
        // ★ 判"点一下"用起止距离；捏合那一趟绝不当点击
        let 位移 = hypot(p.x - downX0, p.y - downY0)
        if !捏过 && 位移 < 8 * 捏放 {
            let hit = 命中(p)
            if let h = hit {
                focusOn(h)
                onTap?(h)
            } else {
                clearFocus()
                onTap?(nil)
            }
        }
        // 点空白（清了聚焦）才恢复自转；点中某颗是主动聚焦，镜头停着不动
        auto = (focusId == nil)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        dragging = false
        捏合中 = false
        auto = (focusId == nil)
        lastAct = CACurrentMediaTime()
    }

    private func 命中(_ p: CGPoint) -> MemNode? {
        let n = min(点.count, 512)
        var best = -1
        var bd = CGFloat.greatestFiniteMagnitude
        for i in 0..<n {
            if nsf[i] < 0.02 { continue }
            let d = hypot(p.x - CGFloat(nsx[i]), p.y - CGFloat(nsy[i]))
            let lim: CGFloat = (母点[i] < 0 ? 26 : 15) * 镜头 * 捏放
            if d > lim { continue }
            if d < bd { bd = d; best = i }
        }
        return best >= 0 ? 点[best] : nil
    }
}

/// SwiftUI 壳子：把原生球塞进来。
struct MemPlanet: UIViewRepresentable {
    let nodes: [MemNode]
    var onTap: (MemNode?) -> Void
    /// 信息条：线长到哪、线头落在哪、关卡片要清焦点
    var 线进度: CGFloat = 0
    var 线终点Y: CGFloat = 0
    var 清焦点号: Int = 0

    final class Coord {
        var 签名: Int? = nil
        var 清焦点号: Int = 0
    }

    func makeCoordinator() -> Coord { Coord() }

    func makeUIView(context: Context) -> MemPlanetUIView {
        let v = MemPlanetUIView()
        v.onTap = onTap
        v.线进度 = 线进度
        v.线终点Y = 线终点Y
        v.setNodes(nodes)
        context.coordinator.签名 = 算签名(nodes)
        context.coordinator.清焦点号 = 清焦点号
        return v
    }

    func updateUIView(_ v: MemPlanetUIView, context: Context) {
        v.onTap = onTap
        v.线进度 = 线进度
        v.线终点Y = 线终点Y
        if context.coordinator.清焦点号 != 清焦点号 {
            context.coordinator.清焦点号 = 清焦点号
            v.clearFocus()
        }
        let s = 算签名(nodes)
        if context.coordinator.签名 != s {
            context.coordinator.签名 = s
            v.setNodes(nodes)
        }
    }

    private func 算签名(_ ns: [MemNode]) -> Int {
        var h = 17
        for n in ns {
            h = h &* 31 &+ n.id &+ n.label.count
            for k in (n.kids ?? []) { h = h &* 31 &+ k.id &+ k.label.count }   // ★ 加了/删了一份也要重画
        }
        return h
    }
}
