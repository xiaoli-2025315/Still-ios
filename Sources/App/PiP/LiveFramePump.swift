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
            guard let sb = makeSample(pb) else { return }
            lastSample = sb
            enqueue(sb, on: layer)
            lastError = nil
        } else if let sb = lastSample {
            enqueue(sb, on: layer)                  // 没新帧：重发上一张，维持「在播」
        }
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
