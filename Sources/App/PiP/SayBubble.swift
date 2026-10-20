import AVFoundation
import QuartzCore
import UIKit

// MARK: - 小窗里那行字
//
// 它回的话，浮在它头顶。
//
// ★★ 为什么绕这么大一圈（这段值得看完，免得以后有人想「直接加个视图」）：
//    小窗里的画面是**系统在放一段 mp4**。iOS 没有任何公开口子能把一个
//    视图插进小窗里去 —— 试过的路全堵着：小窗内容源只能是 playerLayer /
//    AVPlayerViewController，往那上面 addSublayer 系统不认，盖在外面的
//    那一层根本进不了小窗的窗口。
//
//    唯一能改「送进屏幕的每一帧」的地方，是 `AVPlayerItem.videoComposition`。
//    它在帧离开播放器**之前**跑，所以叠上去的字是跟着画面一起进小窗的，
//    不是盖在窗外的另一层。这就是这里在做的事。
//
// ★ 代价：每一帧都要过一次合成器（720×720@30）。换来的是「字真的在小窗里」，
//   没有第二条路。实测这个量级可以接受；真机上要是发现掉帧/发烫，
//   第一嫌疑人就是这里，第二是 `renderSize` 被换成了不匹配的值。
//
// ★ 安全：`renderSize` 必须跟片段**完全一致**（720×720，12 段全一样，
//   逐段解析过 mp4，见 Tools/out/pip）。不一致不报错、不崩溃，
//   表现是**整片黑** —— 所以这个值要改，必须连素材一起换。
//
// ★ 为什么气泡是「画成一张图」而不是几个 CALayer 拼：
//   CATextLayer 的坐标翻转在各家系统上口径不一，拼图层迟早踩。
//   整张用 UIKit 画（左上原点，跟平时写界面一模一样），零歧义。
//   代价是每次换话重画一张 720 宽的点位图 —— 一句话画一次，无所谓。
//
// ★ 长相照网页壳那一版抄的（白底圆角 + 小尾巴 + 深字），那版他已经看过。
//   只是从 384×216 的横条搬到 720×720 的方画布上：
//   猫占正中间、头顶在 y≈173，所以气泡改蹲在**底下**，
//   猫的脸始终露着，尾巴朝上指着它。
//
// ─────────────────────────────────────────────────────────────────────────
// ★★★ v32 闪退的真凶，记在这儿别再犯（2026-10-21）：
//
//   `AVMutableVideoComposition()` 建出来时 **instructions 是空的**。
//   空的 instructions 配 animationTool，**播第一帧就抛异常**。
//   App 一启动猫就开始播，所以表现是「点开就闪退」——
//   重装、重签、换证书都好不了，一度被误判成「全能签的签名问题」。
//
//   解法：**必须补一条「原样透传」的 instruction**，把源轨和合成器连起来：
//       let ins = AVMutableVideoCompositionInstruction()
//       ins.timeRange = CMTimeRange(start: .zero, duration: .positiveInfinity)
//       ins.layerInstructions = [AVMutableVideoCompositionLayerInstruction(assetTrack: track)]
//       composition.instructions = [ins]
//
//   两个连带坑（同一条链，一起踩过）：
//    ① instruction 里的 layerInstruction 跟**具体那条视频轨**绑死，
//       所以合成器**不能共享**，必须一条片段建一个 —— 挂到别的 asset 上就崩。
//    ② 附加层（root）同理：一个 CALayer 不能同时待在两棵图层树里，
//       后挂的那棵会把它从前面那棵里摘走。
// ─────────────────────────────────────────────────────────────────────────

final class SayBubble {

    static let shared = SayBubble()

    // MARK: 跟素材绑死的两个数（改了要连片段一起换）

    /// 所有片段都是 720×720（Tools/_pip_compose.py 的 CANVAS）。
    static let render = CGSize(width: 720, height: 720)

    /// 所有片段都是 30fps（逐段解析过 mp4 的 mdhd/stts）。
    private static let fps: Int32 = 30

    // MARK: 长相（一排常量，真机上觉得小就改 font 这一个数）

    /// 字号。**按「小窗大约只有源画面 1/10 大」倒推的**：
    /// 80px 在 720 画布上占 11%，缩到小窗里约 8~16pt。
    private static let font = UIFont.systemFont(ofSize: 80, weight: .semibold)
    private static let lineH: CGFloat = 102
    private static let pad: CGFloat = 30
    /// 单行最宽。660/80 ≈ 8 个汉字。
    private static let maxW: CGFloat = 660
    private static let radius: CGFloat = 40
    private static let tailW: CGFloat = 48
    private static let tailH: CGFloat = 30
    /// 气泡底边离画面底边多远。
    private static let bottom: CGFloat = 36
    /// 最多几行。小窗里塞不下第三行，多出来的截断加「…」。
    private static let maxLines = 2

    /// 字色。跟网页壳一致（stone-900），白底上对比度足够。
    private static let ink = UIColor(red: 0x1C / 255, green: 0x19 / 255,
                                     blue: 0x17 / 255, alpha: 1)

    // MARK: 图层

    /// 所有活着的附加层：**一条片段一个**，弱引用。
    ///
    /// 为什么不是一个共享的根：合成器跟视频轨绑死（见文件头 ①），
    /// 而 AVQueuePlayer 手里同时有好几条 item（正在播的 + 预填的下一条）。
    /// 只往最后建的那条根上挂字，字会等切段才冒出来 —— 说话那一下是空的。
    /// 所以每建一条合成器就登记一个根，说话时给**每一根**都挂一张。
    ///
    /// 弱引用：片段被换掉 → item 释放 → 合成器释放 → 根自己消失，不用手动清。
    private let roots = NSHashTable<CALayer>.weakObjects()

    /// 每根上挂着的气泡。跟 `roots` 同步增删（不同根上的 layer 是不同对象，
    /// 但 contents 是同一张图，不重复解码）。
    private var bubbles: [CALayer] = []

    private var hideWork: DispatchWorkItem?
    private var showing = false

    private init() {}

    // MARK: - 合成器（每个 item 调一次）

    /// 给一条片段建它的合成器。**不能共享、不能缓存** —— 原因见文件头 ①②。
    ///
    /// 拿不到视频轨就返回 nil：调用方别挂合成器。
    /// 宁可这句话不出字，也不能让 App 打不开。
    func composition(for asset: AVAsset) -> AVMutableVideoComposition? {
        // 本地 bundle 里的文件，tracks 同步就取得到；取不到说明这段素材有问题，
        // 那种片段本来就播不出画面，不挂合成器正好。
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }

        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: Self.render)

        let c = AVMutableVideoComposition()
        c.renderSize = Self.render
        c.frameDuration = CMTime(value: 1, timescale: Self.fps)

        // ★ 这条 instruction 是保命的：空 instructions + animationTool = 播即崩。
        //   内容就是「源轨原样透传」—— 我们只往上叠层，不改画面本身。
        let ins = AVMutableVideoCompositionInstruction()
        ins.timeRange = CMTimeRange(start: .zero, duration: .positiveInfinity)
        ins.layerInstructions = [AVMutableVideoCompositionLayerInstruction(assetTrack: track)]
        c.instructions = [ins]

        // asTrackID 用**这条轨自己的号**，不写死 1 —— 写死万一哪段素材轨号变了，
        // 表现是崩，而且查不到原因。
        c.animationTool = AVVideoCompositionCoreAnimationTool(
            additionalLayer: root, asTrackID: track.trackID)

        roots.add(root)
        return c
    }

    // MARK: - 对外

    /// 让它说这句话。`seconds` 后自己淡出。
    /// 重复调用会顶掉上一句（连没播完的「它听见了…」一起换掉）。
    @discardableResult
    func say(_ text: String, seconds: Double = 9) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = Self.wrap(t)
        // 空话不占地方 —— 返回 false 让调用方知道「这句没演」
        guard !lines.isEmpty else { return false }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hideWork?.cancel()
            self.hideWork = nil
            self.show(lines)
            self.showing = true

            let w = DispatchWorkItem { [weak self] in self?.hide() }
            self.hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
        }
        return true
    }

    /// 收起来。换片段、它走了，都调一次 —— 别让一句旧话留在空房里。
    func hide() {
        guard showing else { return }
        showing = false
        hideWork?.cancel()
        hideWork = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 先把引用交出去，再淡出 —— 这期间又 say() 的话建的是新的一批，互不干扰。
            let old = self.bubbles
            self.bubbles = []
            for b in old { self.fade(b, to: 0) }
            // 淡出完了才从图层树上摘掉，不然是「瞬间消失」不是「淡出」。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                old.forEach { $0.removeFromSuperlayer() }
            }
        }
    }

    // MARK: 内部

    private func show(_ lines: [String]) {
        let textW = lines.map { Self.width(of: $0) }.max() ?? 0
        let bubbleW = min(Self.maxW, textW) + Self.pad * 2
        let bubbleH = CGFloat(lines.count) * Self.lineH + Self.pad * 2
        let totalH = bubbleH + Self.tailH          // 含朝上的小尾巴

        guard let img = Self.draw(lines: lines, w: bubbleW, h: totalH) else { return }

        // 上一批先撤掉（可能挂在已经废弃的根上，也可能根换过了）
        for b in bubbles { b.removeFromSuperlayer() }
        bubbles.removeAll()

        // 每一根都挂一张 —— 正在播的那条和下一条，说话那一下都出字。
        for case let root as CALayer in roots.allObjects {
            let l = CALayer()
            l.contentsScale = 1        // 图就是按 720 画布的点位画的，1 点 = 1 像素
            l.opacity = 0
            l.contents = img.cgImage
            // frame 用画面底部往上算（CoreAnimation 原点在左下）
            l.frame = CGRect(x: (Self.render.width - bubbleW) / 2, y: Self.bottom,
                             width: bubbleW, height: totalH)
            root.addSublayer(l)
            bubbles.append(l)
            fade(l, to: 1)
        }
    }

    /// 淡入淡出。显式动画 —— 合成器是按视频帧的时间取图层树的，
    /// 隐式动画那一套在这里不可靠。
    ///
    /// ★ `value` 是 **Float 不是 CGFloat**：`CALayer.opacity` 是老 Core Animation
    ///   的底子，用 Float。按 CGFloat 传直接编不过（v32 第一版就栽在这儿）。
    private func fade(_ layer: CALayer, to value: Float) {
        layer.removeAnimation(forKey: "fade")
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = layer.opacity          // 先 remove 再读，拿到的是当前真实值
        a.toValue = value
        a.duration = 0.22
        a.isRemovedOnCompletion = false
        a.fillMode = .forwards
        layer.add(a, forKey: "fade")
        layer.opacity = value
    }

    // MARK: - 画（UIKit 坐标系，左上原点，跟写界面一样）

    /// 画成一张 `w×h` **像素**的图（scale 写死 1：一个点换一个像素，正好对上 720 画布）。
    /// 用老接口 `UIGraphicsBeginImageContextWithOptions` 而不是 `UIGraphicsImageRenderer` ——
    /// 后者的 Format 初始化在不同 SDK 上口径不稳，没必要在这儿赌。
    private static func draw(lines: [String], w: CGFloat, h: CGFloat) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(CGSize(width: w, height: h), false, 1)
        guard let c = UIGraphicsGetCurrentContext() else {
            UIGraphicsEndImageContext()
            return nil
        }
        defer { UIGraphicsEndImageContext() }

        let bodyH = h - Self.tailH
        let body = CGRect(x: 0, y: 0, width: w, height: bodyH)

        // 圆角身子 + 朝上的小尾巴（指向猫）。同一条 path，一次填完。
        let p = UIBezierPath(roundedRect: body, cornerRadius: Self.radius)
        let cx = w / 2
        p.move(to: CGPoint(x: cx - Self.tailW / 2, y: bodyH))
        p.addLine(to: CGPoint(x: cx, y: 0))
        p.addLine(to: CGPoint(x: cx + Self.tailW / 2, y: bodyH))
        p.close()

        // 投影给白气泡勾个边。房间是极浅的暖白，没这道边气泡会「融」进墙里。
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: 2),
                    blur: 8,
                    color: UIColor.black.withAlphaComponent(0.18).cgColor)
        UIColor.white.withAlphaComponent(0.97).setFill()
        p.fill()
        c.restoreGState()

        // 字：逐行画，行内在行高里垂直居中，整行水平居中
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: ink,
            .paragraphStyle: para
        ]
        var y = Self.pad
        for line in lines {
            let size = (line as NSString).size(withAttributes: attrs)
            let ty = y + (Self.lineH - size.height) / 2
            (line as NSString).draw(in: CGRect(x: 0, y: ty, width: w, height: size.height),
                                    withAttributes: attrs)
            y += Self.lineH
        }

        return UIGraphicsGetImageFromCurrentImageContext()
    }

    // MARK: - 折行

    /// 按 maxW 折行；超了 maxLines 就截断加「…」。
    /// 小窗里塞不下长篇大论 —— 宁可少给几个字，也不要一行蚂蚁。
    static func wrap(_ text: String) -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }

        var out: [String] = []
        for para in t.split(whereSeparator: { $0.isNewline }).map(String.init) {
            var cur = ""
            for ch in para {
                if !cur.isEmpty, width(of: cur + String(ch)) > maxW {
                    out.append(cur)
                    cur = String(ch)
                } else {
                    cur.append(ch)
                }
            }
            if !cur.isEmpty { out.append(cur) }
        }

        if out.count > maxLines {
            var last = out[maxLines - 1]
            if last.count > 1 { last.removeLast() }
            last += "…"
            out = Array(out.prefix(maxLines - 1)) + [last]
        }
        return out
    }

    private static func width(of s: String) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font]).width
    }
}
