import SwiftUI
import WebKit

// MARK: - 它页 · 形象选择卡（网页版宿主）
//
// 卡片环本体是两端共用的一份网页 Resources/cardring.html —— 就是设计稿那份，
// 透视环 / 下拉拔出 / 上滑插回 / 三档虚实 / 捏捏乐 全部原样装进来，一个参数没改。
// 这里只做三件事：
// ① 加载前注入 window.INIT 真角色（有形象=真 sit.gif 带分享码，无形象=空卡）；
// ② 网页五个按钮通过 StillBridge → messageHandler 回调真机功能；
// ③ 断网 / 老台子没数据就是全空卡，绝不编角色。
// ★ 老 HerStagePane 原样留着，MainHomeView 一换就能退回。

struct CardRingHost: View {
    let onMakeImage: (String, String) -> Void   // 建动态形象：角色 id、名字
    let onCreate: () -> Void                    // 新建角色

    private let box = CardRingBox()

    var body: some View {
        CardRingWebView(box: box)
            .ignoresSafeArea()
            .background(Color.white)
            .task { box.reload() }
            .onReceive(NotificationCenter.default.publisher(for: .cardRingRefresh)) { _ in
                box.reload()
            }
    }
}

extension Notification.Name {
    static let cardRingRefresh = Notification.Name("StillCardRingRefresh")
}

/// 持有 web 引用；刷新＝重新构造带真 INIT 的整页加载（和安卓一致，避免空 INIT 覆盖真数据）。
final class CardRingBox {
    weak var web: WKWebView?
    var pendingInit: String? = nil

    func reload() {
        Task {
            let payload = await CardRingBuild.initPayload()
            let initScript = "window.INIT=\(payload);"
            let work = {
                guard let w = self.web else { self.pendingInit = initScript; return }
                guard let html = CardRingHTML.build(initScript: initScript) else { return }
                w.loadHTMLString(html, baseURL: Bundle.main.bundleURL)
            }
            if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
        }
    }
}

/// 拼 shim（五个按钮）+ 真 INIT 到模板第一个 <script> 前，和安卓 loadWith 同一套。
enum CardRingHTML {
    static func build(initScript: String) -> String? {
        guard let url = Bundle.main.url(forResource: "cardring", withExtension: "html"),
              var html = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let shim = """
        <script>
        function __sb(m,a){try{webkit.messageHandlers.StillBridge.postMessage({m:m,a:a})}catch(e){}}
        window.StillBridge={
          make:function(a,b,c){__sb('make',[a,b,c])},
          floatPet:function(a,b){__sb('floatPet',[a,b])},
          floatName:function(a){__sb('floatName',[a])},
          create:function(a,b){__sb('create',[a,b])},
          ready:function(){__sb('ready',[])}
        };
        </script>
        <script>\(initScript)</script>
        """
        if let at = html.range(of: "<script>") {
            html.insert(contentsOf: shim, at: at.lowerBound)
        }
        return html
    }
}

struct CardRingWebView: UIViewRepresentable {
    let box: CardRingBox
    func makeCoordinator() -> CardRingCoord { CardRingCoord(box: box) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "StillBridge")
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.isOpaque = false
        w.backgroundColor = .white
        w.scrollView.isScrollEnabled = false
        w.scrollView.bounces = false
        box.web = w
        // 先渲染全空卡壳，真数据由 box.reload() 注入
        if let html = CardRingHTML.build(initScript: "window.INIT={roles:[],noav:[]};") {
            w.loadHTMLString(html, baseURL: Bundle.main.bundleURL)
        }
        return w
    }

    func updateUIView(_ w: WKWebView, context: Context) { }
}

/// 网页五个按钮回调。
final class CardRingCoord: NSObject, WKScriptMessageHandler {
    let box: CardRingBox
    init(box: CardRingBox) { self.box = box }

    func userContentController(_ c: WKUserContentController, didReceive msg: WKScriptMessage) {
        guard msg.name == "StillBridge",
              let d = msg.body as? [String: Any],
              let m = d["m"] as? String,
              let a = d["a"] as? [Any] else { return }
        let s = { (i: Int) -> String in (i < a.count ? a[i] as? String : nil) ?? "" }
        switch m {
        case "make":
            let cid = s(0), desc = s(1), way = s(2)
            guard !cid.isEmpty, !desc.isEmpty else { return }
            Task { await 下单(charId: cid, desc: desc, way: way) }
        case "floatPet":
            let name = s(0), on = (a.count > 1 ? (a[1] as? NSNumber)?.intValue ?? 0 : 0)
            Task {
                await 设当前(name)
                await MainActor.run {
                    if let pip = PiPController.shared {
                        if on == 1 { pip.start() } else { pip.stop() }
                    }
                }
            }
        case "floatName":
            let name = s(0)
            Task { await 设当前(name) }
        case "create":
            let kind = s(0), name = s(1)
            if kind == "noav" {
                NotificationCenter.default.post(name: .cardRingMakeImage,
                    object: ["id": name, "name": name])
            } else {
                NotificationCenter.default.post(name: .cardRingCreate, object: nil)
            }
        case "ready":
            break
        default:
            break
        }
    }

    /// 网页传来的是角色名（桌宠名单用的是名字），异步查回真 id 设为当前。
    private func 设当前(_ name: String) async {
        guard !name.isEmpty else { return }
        let cs = (try? await ActLab.chars()) ?? []
        if let c = cs.first(where: { $0.title == name || $0.id == name }) {
            await MainActor.run { CatBrain.currentCharId = c.id }
        }
    }

    /// 制作动作：和老 HerStagePane 同一条 draft 链。
    private func 下单(charId: String, desc: String, way: String) async {
        do {
            let d1 = try await ActLab.rawPost("/api/act/draft",
                body: ["char": charId, "描述": desc])
            let obj1 = (try? JSONSerialization.jsonObject(with: d1)) as? [String: Any] ?? [:]
            guard obj1["ok"] as? Bool == true else { return }
            let job = obj1["单号"] as? String ?? ""
            let path = way == "wan" ? "/api/act/draft/wan" : "/api/act/draft/start"
            _ = try await ActLab.rawPost(path, body: ["单号": job])
        } catch { }
    }
}

extension Notification.Name {
    static let cardRingMakeImage = Notification.Name("StillCardRingMakeImage")
    static let cardRingCreate = Notification.Name("StillCardRingCreate")
}

/// 构造 window.INIT：真角色按有无形象分组；img 用带分享码的 sit.gif。
enum CardRingBuild {
    static func initPayload() async -> String {
        var roles: [[String: Any]] = []
        var noav: [[String: Any]] = []
        let cs = (try? await ActLab.chars()) ?? []
        for c in cs {
            let row: [String: Any] = ["id": c.id, "name": c.title, "done": c.doneCount]
            if OrbPet.hasFrame(c.id) {
                var r = row
                let assetId = (c.id == "builtin" || c.id == "__builtin") ? "maozhan" : c.id
                var comp = URLComponents(string: ActLab.base + "/assets/acts/"
                    + (assetId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? assetId)
                    + "/sit.gif")
                comp?.queryItems = [URLQueryItem(name: "v", value: "8"),
                                    URLQueryItem(name: "sharecode", value: StillShare.code)]
                if let u = comp?.string { r["img"] = u }
                roles.append(r)
            } else {
                noav.append(row)
            }
        }
        let payload: [String: Any] = ["roles": roles, "noav": noav]
        guard let d = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let str = String(data: d, encoding: .utf8) else { return "{}" }
        return str
    }
}
