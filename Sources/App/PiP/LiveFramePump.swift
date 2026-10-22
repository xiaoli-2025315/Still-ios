import AVFoundation
import CoreVideo
import QuartzCore
import UIKit

// MARK: - 实时流：把画面「抽出来、画上字、再喂进去」
//
// ★★ 这是 v35 换的那条路，跟 v32/v33 完全不是一回事。
//
//   旧路（v32/v33，已废）：系统直接播 mp4，我们在「帧离开播放器之前」
//     用 `AVPlayerItem.videoComposition` 拦一道把字盖上。
//     ⇒ 拦的那道是合成器，它跟视频轨绑死、指令表不能空，
//       代价是碰了「App 一启动就要走」的播片流程 ⇒ 点开就闪退。
//
//   新路（这里）：播放器只负责解码。我们用 `AVPlayerItemVideoOutput`
//     把解码后的像素**一帧一帧取出来**，画上字，再当成「直播画面」
//     喂给一块 `AVSampleBufferDisplayLayer`。
//     ⇒ 字是画在帧上的，跟画面是同一个东西，**不存在合成器**，
//       也没有「指令表」那种隐形前提。
//
// ★ 为什么这条路不该再崩：
//   它不碰 `AVPlayerItem` 的任何属性（不设 videoComposition），
//   也不改播放器的队列逻辑。最坏情况是「取不到帧 ⇒ 画面不动/黑」，
//   那是看得见的毛病，不是 App 打不开。
//
// ★ 为什么不用 CADisplayLink：
//   屏幕刷新驱动在 App 进后台时会被停掉，而小窗恰恰在后台才重要。
//   这里用 `addPeriodicTimeObserver` —— 它跟着**媒体时间**走，
//   只要播放器还在播（小窗期间一直在播），回调就一直在。
//
// ★ 时间戳用自己的计数器，不用播放器的时间：
//   换段、被叫一声要 seek 回零时，播放器时间会往回跳，
//   而 display layer 拿到倒退的时间戳会乱。用递增计数器 ⇒ 永远向前。

final class LiveFramePump {

    /// 素材固定 30fps（12 段逐段解析过 mp4 的 mdhd/stts）。
    static let fps: Int32 = 30

    /// ★★★ v42：喂帧频率降到 15。
    ///
    ///   原来按素材原速 30 帧/秒往图层里塞。视觉上 30 → 15 几乎看不出差别
    ///   （猫的动作本来就慢，坐着、舔毛、睡觉），但**每秒少 15 次唤醒**。
    ///
    ///   为什么这跟「打不了字」有关：键盘弹出来不是瞬间就位的，是一段 0.25 秒的
    ///   动画，每秒要跟主线程要几十次布局和刷新。屏幕这边同时有 30 帧/秒的
    ///   画面在推，两边抢同一段时间 —— 表现就是**只画出最上面一层**（建议条），
    ///   键盘本体没渲染出来。这正是他看到的「只有一个 AutoFill」。
    ///
    ///   ⇒ 这一版先把帧率让出来，用来验证「主线程被占」是不是真凶。
    ///     如果键盘因此起来了，那就不用再往下查了。
    static let feedHz: Int32 = 15

    private let player: AVQueuePlayer
    /// 全部活儿都在这个串行队列上 —— 取帧、画字、喂帧同一条道，不用加锁。
    private let queue = DispatchQueue(label: "still.live.frame", qos: .userInitiated)

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var output: AVPlayerItemVideoOutput?
    private var bound: AVPlayerItem?
    private var timeObserver: Any?

    // MARK: - 装了别只猫的时候（自己画帧）

    /// 台子上装下来的那只猫。nil = 用 App 自带那套 mp4。
    ///
    /// ★★★ 为什么不是「把包合成成 mp4 再播」：
    ///   合成要一整套 AVAssetWriter 流程，还得为每只猫占 12 份新空间；
    ///   而这里本来就有一条「自己造一帧喂进去」的路（下面 `makeSample`）。
    ///   ⇒ 直接在每一拍现画一帧（房间底图 + 猫的透明帧），
    ///     播放器继续当**时钟**用，时间轴、画字、起停全都不用动。
    private var pack: CatPack?
    /// 小窗那间房的底图（720×720），从自带的空房片段里抽一帧。
    private var roomImage: CGImage?
    /// 现在画的是哪条动作、画到第几帧
    private var actName = ""
    private var framePos: Double = 0

    /// 播放器此刻在播哪一段（由 PiPController 接上 CatPlayer）。
    /// 装了新猫时，按它把「mp4 段名」翻成「动作名」—— 这样
    /// 「被叫一声抬头」「它走了只剩空房」这些行为原样成立。
    var clipSource: (() -> String)?

    /// mp4 段名 → 台子上的动作名。
    /// 台子那边的动作是固定那十来个（sit/walk/groom/sleep/…），
    /// 自带的 mp4 段名是当年合成时起的（sit_look/sleep_curl/…），两套名字对不齐。
    private static let clipMap: [String: String] = [
        "sit_look":   "sit",
        "groom":      "groom",
        "sleep_curl": "sleep",
        "sleep_flat": "sleep",
        "wake_up":    "wake",
        "walk":       "walk_r",   // ★ 2026-10-21：台子只剩 walk_r 一条走路（往左靠镜像）
        "hunt1":      "hunt1",
        "hunt2":      "hunt2",
        "roll":       "hunt2",
        "lifted":     "struggle",
        "lifted2":    "struggle",
    ]

    /// 画布边长 —— 跟自带的 mp4 一致（720×720），换猫前后不会跳尺寸。
    private static let canvas = 720
    /// 猫在画布里的高度占比、地面线，跟 Tools/_pip_compose.py 里那两个常数一致。
    /// ★ 改了这两个值，自带那只猫和装来的猫就会一大一小 —— 必须一起改。
    private static let catHRatio = 0.56
    private static let groundRatio = 0.80

    /// 上一帧已经画好的样本。这一拍没取到新帧就重发它 ——
    /// display layer 靠「持续有帧进来」维持播放状态，断供会被判成卡住。
    private var lastSample: CMSampleBuffer?
    private var format: CMVideoFormatDescription?
    private var pts: Int64 = 0

    /// 没跑起来的原因（真机上先看这个，比猜快）
    private(set) var lastError: String?

    init(player: AVQueuePlayer) {
        self.player = player
    }

    deinit {
        if let o = timeObserver { player.removeTimeObserver(o) }
    }

    // MARK: - 接口

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        queue.async { [weak self] in
            guard let self else { return }
            self.displayLayer = layer
            layer.videoGravity = .resizeAspect
            // 换了一条输出通道，上一帧属于旧通道，作废
            layer.flush()
            self.lastSample = nil
            self.format = nil
            self.pts = 0
            self.lastError = nil
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timeObserver == nil else { return }
            self.timeObserver = self.player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: Self.feedHz),
                queue: self.queue
            ) { [weak self] _ in
                self?.tick()
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, let o = self.timeObserver else { return }
            self.player.removeTimeObserver(o)
            self.timeObserver = nil
        }
    }

    /// 换猫（nil = 换回 App 自带那只）。
    ///
    /// ★ 换了就得把上一只留下的东西全部作废：帧缓存、帧号、格式描述。
    ///   留着会出「新猫第一帧是旧猫最后一帧」这种鬼影，
    ///   而且 display layer 拿到的格式描述如果还是旧的，画面直接不动。
    func usePack(_ p: CatPack?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pack = p
            self.actName = ""
            self.framePos = 0
            self.lastSample = nil
            self.format = nil
            self.pts = 0
            if p != nil {
                self.loadRoomBG()
            } else {
                self.roomImage = nil
            }
        }
    }

    /// 小窗那间房的底图：从自带的「空房」片段里抽一帧。
    ///
    /// ★ 为什么不另外放一张 jpg 进包：那张底图必须跟自带的 mp4 **完全同一间房**，
    ///   否则换猫前后房间会换一个样子（地板线、坐垫位置全变）。
    ///   直接从 `empty.mp4` 里抽，天然就是同一张。
    private func loadRoomBG() {
        guard roomImage == nil else { return }
        guard let url = CatPlayer.url(for: CatPlayer.emptyClip) else { return }
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        // 取第 0.1 秒 —— 第 0 帧有的编码器还没完全解出来，画面偏暗
        if let cg = try? gen.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600),
                                         actualTime: nil) {
            roomImage = cg
        }
    }

    // MARK: - 每一拍

    private func tick() {
        guard let layer = displayLayer else {
            lastError = "小窗的画面层还没接上"
            return
        }

        // display layer 自己坏了（解码器被系统抢走之类）：清干净重来，
        // 不清的话之后一直不显示，而且不报错。
        if layer.status == .failed {
            layer.flush()
            lastSample = nil
            format = nil
        }

        // ★ 装了台子上的猫：画面自己画，下面那条 mp4 取帧的路就不走了。
        //   播放器还在播（它现在是**时钟**），但它的帧我们一张都不用。
        if let pack, roomImage != nil {
            tickOwnCat(pack, on: layer)
            return
        }

        guard let item = player.currentItem else { return }
        if item !== bound { bind(to: item) }
        guard let output else { return }

        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        var fresh: CVPixelBuffer?
        if output.hasNewPixelBuffer(forItemTime: t) {
            fresh = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil)
        }

        if let pb = fresh {
            SayBubble.shared.paint(on: pb)          // 字直接画在这一帧上
            ListenMark.paint(on: pb)                // 在听的时候，右上角那个小标记
            guard let sb = makeSample(pb) else { return }
            lastSample = sb
            enqueue(sb, on: layer)
            lastError = nil
        } else if let sb = lastSample {
            enqueue(sb, on: layer)                  // 没新帧：重发上一张，维持「在播」
        }
    }

    // MARK: - 装了别只猫：每一拍现画一帧

    private func tickOwnCat(_ pack: CatPack, on layer: AVSampleBufferDisplayLayer) {
        let clip = clipSource?() ?? ""

        // 空房 = 它不在。这时只画房间、不画猫。
        // ★ 这一条不能漏：它走了以后小窗里还蹲着一只，是最露馅的那种 bug。
        let want: String? = (clip == CatPlayer.emptyClip)
            ? nil
            : (Self.clipMap[clip] ?? "sit")

        if (want ?? "") != actName {
            actName = want ?? ""
            framePos = 0
        }

        guard let pb = compose(pack, actKey: want) else { return }
        SayBubble.shared.paint(on: pb)
        ListenMark.paint(on: pb)
        guard let sb = makeSample(pb) else { return }
        lastSample = sb
        enqueue(sb, on: layer)
        lastError = nil
    }

    /// 房间底图 + 当前这一帧的猫 → 一张 720×720 的像素缓冲。
    private func compose(_ pack: CatPack, actKey: String?) -> CVPixelBuffer? {
        guard let room = roomImage else { return nil }
        let S = Self.canvas

        var pbOut: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, S, S,
                                  kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pbOut) == kCVReturnSuccess,
              let pb = pbOut else {
            lastError = "这一帧的像素缓冲建不出来"
            return nil
        }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb),
              let ctx = CGContext(data: base,
                                  width: S, height: S,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue) else {
            lastError = "这一帧的绘图上下文建不出来"
            return nil
        }

        // ★ 位图上下文原点在左下，而视频帧的第一行是**画面顶部**。
        //   不翻这一下，房间和猫都会上下颠倒（而且看起来像是素材的问题，很难往这儿想）。
        ctx.translateBy(x: 0, y: CGFloat(S))
        ctx.scaleBy(x: 1, y: -1)

        let full = CGRect(x: 0, y: 0, width: CGFloat(S), height: CGFloat(S))
        drawUpright(room, in: full, ctx)

        // 猫不在：画完房间就收工
        if let name = actKey, let act = pack.fallback(for: name) {
            let h = Double(S) * Self.catHRatio
            let fs = pack.frameSize
            let scale = fs.height > 0 ? h / Double(fs.height) : 1
            let w = Double(fs.width) * scale

            let idx = Int(framePos)
            if let img = pack.image(act: act, index: idx)?.cgImage {
                // 脚底对齐地面线：`foot` 是原始帧里的脚底 y（从帧顶算）
                let foot = act.foot > 0 ? act.foot : Double(fs.height)
                let footScaled = foot * scale
                let ground = Double(S) * Self.groundRatio
                let top = ground - footScaled
                let x = (Double(S) - w) / 2
                drawUpright(img, in: CGRect(x: x, y: top, width: w, height: h), ctx)
            }

            // 推进帧号（动作自己的 fps，跟喂帧频率不是一回事）
            let rate = act.fps > 0 ? act.fps : 15
            framePos += rate / Double(Self.feedHz)
            if Double(act.frames) > 0, framePos >= Double(act.frames) {
                framePos = framePos.truncatingRemainder(dividingBy: Double(act.frames))
            }
        }
        return pb
    }

    /// 把一张图贴进合成上下文（这个上下文已经被翻成 y 朝下）。
    ///
    /// ★★★ 2026-10-21 v52：**这里必须翻这一下，方向是确定的，但不许再有开关、按钮、UserDefaults。**
    ///
    /// 硬证据（`Tools/flipcheck/main.swift`，CI 每次编译前都会跑）：
    ///   ①「上下文翻一次 + ctx.draw 直接贴」→ 画面顶部读到的是**蓝**（蓝本该在底部）⇒ 倒的。
    ///   ②「上下文翻一次 + 这里再局部翻一次」→ 顶部是红 ⇒ 正的。所以只能走 ②。
    ///
    /// 走过的弯路（别再重复）：
    ///   · v47 我在真机上判断「点一下按钮就好了」，据此加了个开关，默认还是不翻那条。
    ///     其实按钮只是把这个错误分支切走了一次，方向根本没有"因机而异"这回事。
    ///   · v51 我把默认值改成「不翻」，可机器上那个键已经有值了，默认值根本不生效。
    ///   · v52 第一版我直接把这段翻删了（以为不翻才正），被自检当场拦下 —— 幸好拦住了。
    ///
    /// 教训：这里的方向别再用眼睛判，改了就跑一次自检。它会告诉你顶上是红还是蓝。
    private func drawUpright(_ img: CGImage, in r: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        // 把这一段局部翻回 y 朝上：y' = (minY + maxY) - y，区间还是它自己，位置不动。
        ctx.translateBy(x: 0, y: r.minY + r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    /// 给一条片段挂上「取帧口」。
    private func bind(to item: AVPlayerItem) {
        if let old = bound, let o = output { old.remove(o) }

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            // 让系统用 IOSurface 承载，喂给图层时才是零拷贝的那条路
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        let o = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        item.add(o)

        output = o
        bound = item
        // 换段了：格式描述要重建，上一段的帧不能当这一段的底。
        format = nil
        lastSample = nil
    }

    // MARK: - 包成「直播样本」

    private func makeSample(_ pb: CVPixelBuffer) -> CMSampleBuffer? {
        if format == nil {
            var f: CMVideoFormatDescription?
            let st = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pb,
                formatDescriptionOut: &f)
            guard st == noErr, let f else {
                lastError = "这一帧的格式描述建不出来（\(st)）"
                return nil
            }
            format = f
        }
        guard let fmt = format else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Self.feedHz),
            presentationTimeStamp: CMTime(value: pts, timescale: Self.feedHz),
            decodeTimeStamp: .invalid)
        pts += 1

        var sb: CMSampleBuffer?
        let st = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            formatDescription: fmt,
            sampleTiming: &timing,
            sampleBufferOut: &sb)
        guard st == noErr, let sb else {
            lastError = "样本包不出来（\(st)）"
            return nil
        }

        // ★ 必须标「立即显示」：不标的话系统会按时间戳排队，
        //   在「直播」这种无限时间轴里会攒着不放，画面就僵住。
        Self.markImmediate(sb)
        return sb
    }

    private func enqueue(_ sb: CMSampleBuffer, on layer: AVSampleBufferDisplayLayer) {
        // 刚 flush 过要重新来一次，否则第一帧进不去
        if layer.status == .failed { layer.flush() }
        guard layer.isReadyForMoreMediaData else { return }
        layer.enqueue(sb)
    }

    private static func markImmediate(_ sb: CMSampleBuffer) {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
              CFArrayGetCount(arr) > 0 else { return }
        let d = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            d,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
}
