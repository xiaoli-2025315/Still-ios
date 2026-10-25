import SwiftUI
import WebKit

// MARK: - 认一认（把识别那一步搬到苹果端）
//
// ★★★ v95（功能匹配）：**台子上有「认一认」，苹果手机上一直没有**。
//
//   上传动作视频时是不起名字的（2026-10-07 他拍的板：「不应该按照上传入口命名，
//   应该识别完了命名」）—— 抠完由「认一认」看画面定它进哪一格，服务器再改名归位。
//   安卓 v2.26 就自动跑了；苹果端一直没接 ⇒ 在苹果上传的视频永远停在 `x_临时名`，
//   进不了格子，等于白传。
//
// ★ 为什么必须跑在网页里：平台规矩 —— 模型通道只能「网页端当场调」，
//   服务器不许在背后代理调。所以这块就是那只「眼睛」：把 recog.html 装进一个
//   看不见的小网页，它自己认完自己回填。
//
// ★ 完成信号＝网页把标题改成「认完了」（recog.html 里的 markDone）。
//   跟安卓 ActWallActivity.recogTick 同一个暗号。

struct RecogRunner: UIViewRepresentable {

    let url: URL
    /// 认完了（服务器那边已经改名归位）
    var onDone: () -> Void = {}
    /// 超时 / 页面起不来 —— 下次进页面还会再来，不打扰他
    var onGiveUp: () -> Void = {}

    func makeCoordinator() -> Coord { Coord() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        // 云服务 SDK 要用本地存储
        cfg.websiteDataStore = .default()
        let w = WKWebView(frame: CGRect(x: -200, y: -200, width: 1, height: 1),
                          configuration: cfg)
        w.alpha = 0.01
        // ★ 不许 hidden —— 隐藏的 WKWebView 会被系统挂起，JS 根本不跑。
        //   挪到屏幕外 + 透明就够了（安卓那边也是这么做的）。
        w.isHidden = false
        w.navigationDelegate = context.coordinator
        context.coordinator.web = w
        w.load(URLRequest(url: url))
        context.coordinator.start(onDone: onDone, onGiveUp: onGiveUp)
        return w
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coord) {
        coordinator.stop()
        uiView.stopLoading()
    }

    final class Coord: NSObject, WKNavigationDelegate {
        weak var web: WKWebView?
        private var timer: Timer?
        private var began = Date()
        private var done: (() -> Void)?
        private var giveUp: (() -> Void)?
        /// 最长盯 3 分钟 —— 认完的下一步是下载，别把它卡在这儿
        private let limit: TimeInterval = 180

        func start(onDone: @escaping () -> Void, onGiveUp: @escaping () -> Void) {
            self.done = onDone
            self.giveUp = onGiveUp
            began = Date()
            stop()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.tick()
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        private func tick() {
            guard let w = web else { finish(gave: true); return }
            if Date().timeIntervalSince(began) > limit { finish(gave: true); return }
            // ★ 直接问页面要 document.title —— 被改成「认完了」就是这趟跑完了。
            w.evaluateJavaScript("document.title") { [weak self] v, _ in
                guard let self else { return }
                if let s = v as? String, s.contains("认完了") { self.finish(gave: false) }
            }
        }

        private func finish(gave: Bool) {
            guard timer != nil || gave else { return }   // 只收一次
            stop()
            web?.stopLoading()
            let cb = gave ? giveUp : done
            giveUp = nil
            done = nil
            DispatchQueue.main.async { cb?() }
        }
    }
}
