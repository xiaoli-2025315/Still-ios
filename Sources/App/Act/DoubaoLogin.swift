import SwiftUI
import WebKit

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
// ★ 用电脑版 UA：豆包手机版网页会一直想把你导去下载 App，登录入口也不好找。

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
            try await ActLab.loginGive(cookie: jar,
                                       ua: Self.desktopUA,
                                       name: Self.desktopUA.contains("Mac") ? "手机上登的豆包" : "")
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

    var body: some View {
        VStack(spacing: 0) {
            header
            stateCard
            DoubaoWebView()
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

struct DoubaoWebView: UIViewRepresentable {

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        // 手机版网页会一直劝你去下载 App，登录入口还被藏起来 —— 用电脑版
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true

        let v = WKWebView(frame: .zero, configuration: cfg)
        v.customUserAgent = DoubaoLoginModel.desktopUA
        v.allowsBackForwardNavigationGestures = true
        v.isInspectable = false

        if let u = URL(string: "https://www.doubao.com/chat/") {
            v.load(URLRequest(url: u))
        }
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {}
}
