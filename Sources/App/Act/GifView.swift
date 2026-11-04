import SwiftUI
import UIKit

// ★ 2026-11-03：只把 GifView / GifBox 从删掉的旧生产页里留下 ——
//   制作中页「做好了」那一屏要播动作预览，其余（RingProgress/DotsLabel/GenGlow/
//   StudioModel/RoleStudioView）全部随旧流程一起删掉了。

final class GifBox: ObservableObject {

    @Published var img: UIImage?

    private var frames: [UIImage] = []
    private var idx = 0
    private var timer: Timer?
    // ★ 观测用（不改行为）：最后换帧时间 + 是否已经报过"卡住"
    private var lastFrameAt = Date()
    private var reportedStuck = false
    private var watch: Timer?
    private var task: URLSessionDataTask?
    private var now: String = ""

    /// 台子上那几张预览图是抽过帧的，不会太大；这里再兜一道，别让一张图把内存吃了。
    private let cap = 90

    func load(_ url: URL) {
        let key = url.absoluteString
        if key == now, !frames.isEmpty { return }   // 同一张在播，别重下
        now = key
        stop()
        task?.cancel()
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        task = URLSession.shared.dataTask(with: req) { [weak self] d, _, _ in
            guard let d else {
                Task { await ActLab.diagSay("GifView 下载失败 url=\(key)") }
                return
            }
            guard let src = CGImageSourceCreateWithData(d as CFData, nil) else {
                Task { await ActLab.diagSay("GifView 解不出帧（数据不是动图）url=\(key) 字节=\(d.count)") }
                return
            }
            var out: [UIImage] = []
            let n = min(CGImageSourceGetCount(src), self?.cap ?? 90)
            for i in 0..<n {
                if let cg = CGImageSourceCreateImageAtIndex(src, i, nil) {
                    out.append(UIImage(cgImage: cg))
                }
            }
            guard !out.isEmpty else {
                Task { await ActLab.diagSay("GifView 解出来是空的 url=\(key)") }
                return
            }
            DispatchQueue.main.async {
                guard let self, self.now == key else { return }
                self.frames = out
                self.idx = 0
                self.img = out[0]
                self.play()
            }
        }
        task?.resume()
    }

    private func play() {
        stop()
        guard frames.count > 1 else { return }
        // 台子的预览图是 20 格/秒抽的，这里就按 20 放 —— 跟手机上看它是一样的速度。
        let t = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.frames.isEmpty else { return }
                self.idx = (self.idx + 1) % self.frames.count
                self.img = self.frames[self.idx]
                self.lastFrameAt = Date()
                self.reportedStuck = false
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        lastFrameAt = Date()
        reportedStuck = false
        // ★ 只观测：每 2 秒看一眼有没有换帧；没换就报一条（不改任何行为）
        watch?.invalidate()
        let w = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if Date().timeIntervalSince(self.lastFrameAt) > 2.0, !self.reportedStuck {
                    self.reportedStuck = true
                    await ActLab.diagSay("GifView 2 秒没换帧 url=\(self.now) 帧数=\(self.frames.count)")
                }
            }
        }
        RunLoop.main.add(w, forMode: .common)
        watch = w
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        watch?.invalidate()
        watch = nil
    }
}

struct GifView: View {

    let url: URL?

    @StateObject private var box = GifBox()

    var body: some View {
        Group {
            if let i = box.img {
                Image(uiImage: i)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .onAppear {
            if let url { box.load(url) }
        }
        .onChange(of: url) { _, u in
            if let u { box.load(u) }
        }
        .onDisappear { box.stop() }
    }

    /// 台子上那一段的地址（按宽度分档，格子和中间那个大框不是一档）。
    static func makeURL(_ charId: String, _ act: String, width: Int) -> URL? {
        let w = max(120, min(width, 900))
        var s = ActLab.base + "/assets/acts/"
        s += charId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? charId
        s += "/"
        s += act.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? act
        s += ".gif?v=\(w)"
        return URL(string: s)
    }
}

// MARK: - 圆环进度

