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
            guard let d, let src = CGImageSourceCreateWithData(d as CFData, nil) else { return }
            var out: [UIImage] = []
            let n = min(CGImageSourceGetCount(src), self?.cap ?? 90)
            for i in 0..<n {
                if let cg = CGImageSourceCreateImageAtIndex(src, i, nil) {
                    out.append(UIImage(cgImage: cg))
                }
            }
            guard !out.isEmpty else { return }
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
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
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

