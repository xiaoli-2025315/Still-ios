import SwiftUI
import WebKit
import UIKit

// MARK: - 登录豆包（手机里登，登录态交给台子）
//
// ★ 为什么要这一页：
//   生成动作视频是台子上的浏览器去豆包画 —— 用的是**谁的账号**，就花谁的额度。
//   以前这一页没有，台子只能用机器上原来那份登录态（他的原话：「默认用的是我安卓那个的账号，
//   也没办法给我登录豆包账号」）。
//
// ★ 为什么在 App 里开网页登，而不是让台子给个二维码：
//   豆包登录（手机号 + 验证码 / 扫码）都在它自己的网页流程里。手机上有自己的号、自己的短信，
//   在这儿登完，把 cookie 交上去，台子那边就等于「用你的号」。安卓也是这个做法，两边一条路。
//
// ★ 为什么默认走手机版 UA（2026-10-21 改）：
//   以前写死电脑版，理由是「手机版网页一直想把你导去下载 App」。
//   但电脑版页面上**根本没有「抖音登录」**这颗按钮，只能扫码或收短信 ——
//   他的原话：「用户还得把二维码截图下来、再打开自己的抖音用相册识别法扫一扫，这很麻烦」。
//   手机版页面上才有抖音登录，点了能直接跳进手机里的抖音 App 授权，回来就是登录态。
//   电脑版留着当退路（右上角那颗胶囊可以切）。

@MainActor
final class DoubaoLoginModel: ObservableObject {

    @Published var state: ActLab.LoginState?
    @Published var err: String?
    @Published var note = ""
    @Published var busy = false
    @Published var probeText = ""

    /// 手机网页里那份 cookie 的条数（点一下才知道）
    @Published var localCount = 0

    static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"

    /// ★★ 2026-10-21（他的原话：「那个豆包只能用二维码或者手机号登录」）：
    ///   这一页原来**写死电脑版 UA**，电脑版页面上根本没有「抖音登录」那颗按钮，
    ///   所以只能扫码或者收短信 —— 不是豆包不给，是我们把自己装成了一台电脑。
    ///   现在默认走手机版 UA（页面上才有抖音登录），要退回电脑版也能切。
    static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    /// 网页用哪套身份。**登录态交给台子时，UA 必须跟网页登录时用的一致**，否则豆包会判异地。
    @Published var mobile = true

    var currentUA: String { mobile ? Self.mobileUA : Self.desktopUA }

    func refresh() async {
        do { state = try await ActLab.loginState() }
        catch { err = "问不到台子：\(error.localizedDescription)" }
    }

    /// 读完手机网页里的 cookie，交给台子。
    func give() async {
        busy = true
        err = nil
        note = "正在从网页里取登录态…"
        let cookies: [HTTPCookie] = await withCheckedContinuation { cont in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cont.resume(returning: $0) }
        }

        // 只交豆包那几家域名的 —— 别把无关网站的登录态也递出去
        let mine = cookies.filter { c in
            let d = c.domain.lowercased()
            return d.contains("doubao") || d.contains("bytedance")
                || d.contains("byteimg") || d.contains("bytescm")
                || d.contains("snssdk") || d.contains("volc")
        }
        localCount = mine.count

        guard !mine.isEmpty else {
            note = ""
            err = "网页里还没登录 —— 先在上面那个页面用手机号登进去，再点这一颗。"
            busy = false
            return
        }

        let jar = mine.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        do {
            // ★ UA 跟着网页当前那套走（手机版登的就交手机版），否则豆包会判成异地登录
            try await ActLab.loginGive(cookie: jar,
                                       ua: currentUA,
                                       name: "手机上登的豆包")
            note = "交上去了（\(mine.count) 条）· 台子现在用的是你这个号"
            await refresh()
        } catch {
            note = ""
            err = "交不上去：\(error.localizedDescription)"
        }
        busy = false
    }

    /// 换账号：把台子记得的那份挪走，再把网页里的也清干净。
    func forget() async {
        busy = true
        err = nil
        do {
            try await ActLab.loginForget()
            note = "台子已经忘掉上一个账号了 · 现在在网页里登一个新的"
            await clearWebCookies()
            await refresh()
        } catch {
            err = "换不了：\(error.localizedDescription)"
        }
        busy = false
    }

    private func clearWebCookies() async {
        // ★ 这两句别写成「completionHandler 的尾巴闭包」：
        //   iOS 15 起 WebKit 有 async 版本，同一个名字会优先选 async 那个，
        //   再挂尾巴闭包就报「extra trailing closure passed in call」（CI 上栽过一次）。
        let store = WKWebsiteDataStore.default()
        let types: Set<String> = [WKWebsiteDataTypeCookies]
        let records = await store.dataRecords(ofTypes: types)
        let hit = records.filter { r in
            let n = r.displayName.lowercased()
            return n.contains("doubao") || n.contains("bytedance")
                || n.contains("byteimg") || n.contains("bytescm") || n.contains("snssdk")
        }
        await store.removeData(ofTypes: types, for: hit)
    }

    /// 体检：豆包认不认这份登录态（不花额度）。
    func probe() async {
        busy = true
        probeText = "正在问豆包…（最多等两分钟）"
        do { probeText = try await ActLab.probe() }
        catch { probeText = "没问成：\(error.localizedDescription)" }
        busy = false
    }
}

// MARK: - 页面

@MainActor
struct DoubaoLoginPage: View {

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = DoubaoLoginModel()
    /// 给「后退 / 刷新」两颗键留一个能摸到网页的把手。
    @StateObject private var box = WebBox()

    var body: some View {
        VStack(spacing: 0) {
            header
            stateCard
            webBar
            DoubaoWebView(mobile: model.mobile, box: box) { msg in
                model.err = msg
            }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Tw.gray200, lineWidth: 1)
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            bottomBar
        }
        .background(Tw.gray50.ignoresSafeArea())
        .task { await model.refresh() }
    }

    /// ★ 2026-10-22 加的这一条：他点了「抖音登录」被带到抖音的网页登录页之后，
    ///   **卡在那儿没法退回来** —— 这一页原来只有一颗「关掉整页」。
    ///   现在给他后退和刷新。
    private var webBar: some View {
        HStack(spacing: 8) {
            Button { box.web?.goBack() } label: {
                Label("后退", systemImage: "chevron.left")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Tw.gray500)
            }
            .buttonStyle(PressStyle(scale: 0.94))

            Button { box.web?.reload() } label: {
                Label("刷新", systemImage: "arrow.clockwise")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Tw.gray500)
            }
            .buttonStyle(PressStyle(scale: 0.94))

            Spacer(minLength: 0)

            Text("也可以从屏幕左边缘往右滑")
                .font(.system(size: 10))
                .foregroundStyle(Tw.gray400)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tw.gray500)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Tw.gray100))
            }
            .buttonStyle(PressStyle(scale: 0.9))

            VStack(alignment: .leading, spacing: 1) {
                Text("登录豆包")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Tw.gray900)
                Text("用你自己的号登 · 生成动作花的是这个号的额度")
                    .font(.system(size: 11))
                    .foregroundStyle(Tw.gray400)
            }
            Spacer(minLength: 0)

            // ★ 手机版页面上才有「抖音登录」；电脑版只有扫码/短信。
            //   切了会整页重载，登录态要重新给一次。
            Button { model.mobile.toggle() } label: {
                Text(model.mobile ? "手机版" : "电脑版")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.mobile ? Tw.gray900 : Tw.gray400)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Tw.gray100))
            }
            .buttonStyle(PressStyle(scale: 0.9))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var stateCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill((model.state?.loggedIn == true) ? Tw.green500 : Tw.gray300)
                    .frame(width: 7, height: 7)
                Text((model.state?.loggedIn == true) ? "台子现在认的是：\(loginName)" : "台子现在没有登录态")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tw.gray900)
                Spacer(minLength: 0)
            }

            if let s = model.state, s.loggedIn {
                Text("\(s.cookies) 条 cookie · \(s.atText)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Tw.gray400)
            }

            if !model.note.isEmpty {
                Text(model.note)
                    .font(.system(size: 11))
                    .foregroundStyle(Tw.gray500)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let e = model.err {
                Text(e)
                    .font(.system(size: 11))
                    .foregroundStyle(Tw.red600)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.probeText.isEmpty {
                Text("体检：\(model.probeText)")
                    .font(.system(size: 11))
                    .foregroundStyle(Tw.gray500)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // ★ 常驻，不做判断（他看不见"有条件的入口"）：
            //   点「抖音登录」如果手机里没装抖音，系统唤不起来，这一下就是没反应。
            //   话先摆在这儿，省得他以为是我们坏了、然后退回截图扫码那条老路。
            Text("点了「抖音登录」没反应 ＝ 手机里没装抖音 · 那就用这一页里的「验证码登录」，短信直接发到这台手机，不用截图")
                .font(.system(size: 10))
                .foregroundStyle(Tw.gray400)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Tw.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Tw.gray200, lineWidth: 1)
                )
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var loginName: String {
        let n = model.state?.name ?? ""
        return n.isEmpty ? "（手机上登的那个号）" : n
    }

    private var bottomBar: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Button {
                    Task { await model.give() }
                } label: {
                    HStack(spacing: 7) {
                        if model.busy { ProgressView().tint(.white) }
                        Text("我登录好了 · 把它交给台子")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(Tw.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(model.busy ? Tw.red600.opacity(0.5) : Tw.red600)
                    )
                }
                .buttonStyle(PressStyle())
                .disabled(model.busy)

                Button {
                    Task { await model.forget() }
                } label: {
                    Text("换账号")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tw.gray900)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Tw.white)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Tw.gray200, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(PressStyle())
                .disabled(model.busy)
            }

            HStack(spacing: 8) {
                Button {
                    Task { await model.probe() }
                } label: {
                    Text("测一下豆包认不认（不花额度）")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tw.gray500)
                }
                .buttonStyle(PressStyle(scale: 0.96))
                Spacer(minLength: 0)
                Text("登录态只交给你自己的台子")
                    .font(.system(size: 10))
                    .foregroundStyle(Tw.gray400)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .background(Tw.white.overlay(alignment: .top) {
            Rectangle().fill(Tw.gray200).frame(height: 0.5)
        })
    }
}

// MARK: - 那个网页

/// 给页面外面那两颗「后退 / 刷新」留一个能摸到网页的把手。
@MainActor
final class WebBox: ObservableObject {
    weak var web: WKWebView?
}

struct DoubaoWebView: UIViewRepresentable {

    /// 手机版才有「抖音登录」那颗按钮；电脑版只有扫码/短信。
    let mobile: Bool
    let box: WebBox
    /// 系统唤不起对应 App（多半是没装抖音）时，回一句人话给页面显示。
    let onSchemeFail: (String) -> Void

    func makeCoordinator() -> Nav { Nav(onFail: onSchemeFail) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true

        let v = WKWebView(frame: .zero, configuration: cfg)
        v.customUserAgent = mobile ? DoubaoLoginModel.mobileUA : DoubaoLoginModel.desktopUA
        v.allowsBackForwardNavigationGestures = true
        v.isInspectable = false
        v.navigationDelegate = context.coordinator
        v.uiDelegate = context.coordinator
        box.web = v

        if let u = URL(string: "https://www.doubao.com/chat/") {
            v.load(URLRequest(url: u))
        }
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {
        context.coordinator.onFail = onSchemeFail
        let want = mobile ? DoubaoLoginModel.mobileUA : DoubaoLoginModel.desktopUA
        guard v.customUserAgent != want else { return }
        v.customUserAgent = want
        v.reload()
    }

    /// ★★★ 2026-10-21 真机补的（他的原话：「用户还得把二维码截图下来、再打开自己的抖音
    ///   用相册识别法扫一扫，这很麻烦；我用手机自带浏览器登录豆包，它就会直接跳转抖音去登录」）。
    ///
    ///   差别就在这几行：**WKWebView 默认不处理非 http(s) 的跳转。**
    ///   豆包登录页上的「抖音登录」走的是 `snssdk1128://` 这类自定义 scheme，
    ///   WebView 拿到它只会**静默丢掉** —— 看起来就是「点了没反应」。
    ///   手机自带浏览器之所以能直接拉起抖音，就是系统替它做了这一步；
    ///   嵌在 App 里的浏览器得自己把这一步写出来。
    ///
    /// ★★★ 2026-10-22 更正（他：「点抖音登录完之后，它是跳到抖音的那个官方的登录页面，
    ///   也不会拉起我这个抖音」）：v59 的判断顺序**写反了**。
    ///   当时是「先看是不是新窗口，再看 scheme」，而豆包那颗「抖音登录」很可能
    ///   是 `target=_blank` 打开的 —— 于是一个 `snssdk1128://` 被当成「新窗口链接」
    ///   塞回了 WebView，抖音根本唤不起来。
    ///   **现在顺序反过来：任何不是网页的 scheme，第一件事就交给系统。**
    ///
    ///   处理三件事（顺序不能换）：
    ///     ① 非 http(s) scheme → 交给系统去唤起对应 App（抖音 / 豆包 / 支付宝…）
    ///     ② 新窗口链接（target=_blank）→ 在当前 WebView 里打开，否则一片空白
    ///     ③ 其余 → 正常放行
    final class Nav: NSObject, WKNavigationDelegate, WKUIDelegate {

        var onFail: (String) -> Void

        init(onFail: @escaping (String) -> Void) {
            self.onFail = onFail
        }

        /// 这些是「网页自己的」，剩下的都当外部 App。
        private static let webSchemes: Set<String> = [
            "http", "https", "about", "file", "data", "blob", "javascript"
        ]

        /// 交给系统。返回 true ＝ 这条不该在 WebView 里加载。
        private func handOffIfExternal(_ url: URL) -> Bool {
            let scheme = (url.scheme ?? "").lowercased()
            guard !scheme.isEmpty, !Self.webSchemes.contains(scheme) else { return false }

            UIApplication.shared.open(url, options: [:]) { [weak self] ok in
                guard !ok else { return }
                // ★ 唤不起来**必须说出来**，否则在他看来就是「点了没反应」，
                //   然后又退回去截图扫码 —— 这是他最烦的那一段。
                DispatchQueue.main.async {
                    self?.onFail("点了没反应 ＝ 这台手机没有能接住它的 App（多半是没装抖音）。"
                                 + "往下翻，用这一页里的「验证码登录」，短信直接发到这台手机。")
                }
            }
            return true
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            // ★ 顺序：先外部 App，再新窗口。写反了抖音就唤不起来（v59 的坑）。
            if handOffIfExternal(url) {
                decisionHandler(.cancel)
                return
            }

            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        /// `window.open(...)` 走的是这条，不接的话豆包某些按钮点了没反应。
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url, handOffIfExternal(url) {
                return nil
            }
            webView.load(navigationAction.request)
            return nil
        }
    }
}
