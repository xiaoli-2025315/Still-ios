import SwiftUI
import UIKit

// MARK: - 预览图落盘（照安卓 MovieView：下过一次就存进手机）
//
// ★★ 2026-11-07（他报的「角色页面每次点进来，预览图全都要重新加载出来」）：
//   台子对图片一律回 `Cache-Control: no-store`（server.py 统一回话函数），
//   系统的 AsyncImage / URLSession 就不会存 ⇒ 每次进页面重下、先闪一下占位。
//   安卓 10-29 就按他同一句话修过：下过一次存进手机，先读本地再联网。
//
//   ★ 但台子静态图**没有 ETag / Last-Modified**，光认地址存会出另一个坑：
//     素材重做后地址不变，手机上就永远是旧图。所以这里多一道后台校验 ——
//     每 10 分钟（或 App 重启后第一次）后台再问一次，数据变了才替换。
//     **画面永远先用本地那份**，不等网、不闪。
enum StillImgCache {
    private static let lock = NSLock()
    private static var 校验过: [String: Date] = [:]
    private static let 间隔: TimeInterval = 600

    private static var 目录: URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let d = base.appendingPathComponent("StillImg", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }

    /// 地址摘要（FNV-1a 64 位）—— 不引 CryptoKit，文件名短且不会撞。
    private static func 摘要(_ s: String) -> String {
        var h: UInt64 = 14695981039346656037
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 1099511628211
        }
        let x = String(h, radix: 16)
        return String(repeating: "0", count: max(0, 16 - x.count)) + x
    }

    static func 路径(_ url: URL) -> URL? {
        目录?.appendingPathComponent(摘要(url.absoluteString) + ".img")
    }

    static func 读(_ url: URL) -> Data? {
        guard let f = 路径(url), let d = try? Data(contentsOf: f), !d.isEmpty else { return nil }
        return d
    }

    /// 先写 .part 再改名 —— 写到一半被杀，也不会留下一个「看起来是好的」坏文件。
    static func 存(_ url: URL, _ d: Data) {
        guard let f = 路径(url), !d.isEmpty else { return }
        let part = f.appendingPathExtension("part")
        do {
            try d.write(to: part, options: .atomic)
            let fm = FileManager.default
            if fm.fileExists(atPath: f.path) { try? fm.removeItem(at: f) }
            try? fm.moveItem(at: part, to: f)
        } catch {
            try? FileManager.default.removeItem(at: part)
        }
    }

    static func 删(_ url: URL) {
        guard let f = 路径(url) else { return }
        try? FileManager.default.removeItem(at: f)
    }

    /// 反复进出页面别反复联网。这张表只在内存里 ⇒ App 一关就空，下次启动会校验一次。
    static func 该校验(_ url: URL) -> Bool {
        let k = url.absoluteString
        lock.lock(); defer { lock.unlock() }
        if let t = 校验过[k], Date().timeIntervalSince(t) < 间隔 { return false }
        return true
    }

    static func 记校验(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        校验过[url.absoluteString] = Date()
    }

    /// 没下回来就别记，否则这一格会空等十分钟。
    static func 忘校验(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        校验过.removeValue(forKey: url.absoluteString)
    }

    static func 后台取(_ url: URL, 完成: @escaping (Data?) -> Void) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        URLSession.shared.dataTask(with: req) { d, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            完成(code == 200 ? d : nil)
        }.resume()
    }
}

/// 角色列表的头像：原来用系统 AsyncImage，台子说 no-store 就每次重下。
/// 换成和动图同一套「先读本地、后台校验」。
struct StillCachedImage: View {
    let url: URL
    @State private var ui: UIImage?

    var body: some View {
        Group {
            if let ui {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                Image(systemName: "cat.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Tw.gray400)
            }
        }
        .onAppear { 载入() }
        .onChange(of: url) { _, _ in 载入() }
    }

    private func 载入() {
        let 本地 = StillImgCache.读(url)
        if let d = 本地 { ui = UIImage(data: d) }
        guard 本地 == nil || StillImgCache.该校验(url) else { return }
        StillImgCache.记校验(url)
        StillImgCache.后台取(url) { d in
            guard let d, !d.isEmpty else {
                StillImgCache.忘校验(url)
                return
            }
            if let old = 本地, old == d { return }
            StillImgCache.存(url, d)
            guard let img = UIImage(data: d) else { return }
            Task { @MainActor in ui = img }
        }
    }
}

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

        // ★★ 2026-11-07：先读手机上存的那一份，立刻就能播 —— 不等网、不闪占位。
        let 本地 = StillImgCache.读(url)
        if let d = 本地 {
            装上(d, for: url)
        } else {
            frames = []
            img = nil
        }

        // 台子静态图没有 ETag，光认地址存会永远读到旧素材 ⇒ 后台再校验一次。
        // 本地没图时不节流（否则这一格会空等十分钟）。
        guard 本地 == nil || StillImgCache.该校验(url) else { return }
        StillImgCache.记校验(url)
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        task = URLSession.shared.dataTask(with: req) { [weak self] d, _, _ in
            guard let d, !d.isEmpty else {
                StillImgCache.忘校验(url)
                if 本地 == nil {
                    Task { await ActLab.diagSay("GifView 下载失败 url=\(key)") }
                }
                return
            }
            if let old = 本地, old == d { return }       // 没变，别折腾
            StillImgCache.存(url, d)
            DispatchQueue.main.async {
                guard let self, self.now == key else { return }
                self.装上(d, for: url)
            }
        }
        task?.resume()
    }

    /// 把一份动图拆成帧并开播。**只在主线程调**（要动 @Published 的 img 和 Timer）。
    private func 装上(_ d: Data, for url: URL) {
        let key = url.absoluteString
        guard let src = CGImageSourceCreateWithData(d as CFData, nil) else {
            StillImgCache.删(url)                  // 存坏了 ⇒ 删掉重新下
            Task { await ActLab.diagSay("GifView 解不出帧（数据不是动图）url=\(key) 字节=\(d.count)") }
            return
        }
        var out: [UIImage] = []
        let n = min(CGImageSourceGetCount(src), cap)
        for i in 0..<n {
            if let cg = CGImageSourceCreateImageAtIndex(src, i, nil) {
                out.append(UIImage(cgImage: cg))
            }
        }
        guard !out.isEmpty else {
            StillImgCache.删(url)
            Task { await ActLab.diagSay("GifView 解出来是空的 url=\(key)") }
            return
        }
        frames = out
        idx = 0
        img = out[0]
        play()
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

/// ★★★ 2026-11-10（他报的「动作库里制作过程中那些进度都没显示了」）：
///   把圆环补回来。**只有台子真给了百分比才画**（抠像那一段按帧数算出来的真数），
///   生成中绝不画圈、绝不给数字 —— 那段机器没报过进度，写了就是编的。
struct RingProgress: View {
    let pct: Int
    var word: String = ""
    private var v: Int { max(0, min(100, pct)) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Tw.gray200, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: CGFloat(v) / 100)
                    .stroke(Tw.gray900, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(v)%")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tw.gray900)
            }
            .frame(width: 64, height: 64)
            if !word.isEmpty {
                Text(word)
                    .font(.system(size: 11))
                    .foregroundStyle(Tw.gray500)
            }
        }
    }
}
