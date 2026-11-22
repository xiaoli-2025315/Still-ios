import SwiftUI
import WebKit

// MARK: - 记忆页 3D 版（WKWebView 宿主）
//
// 看柜子里一份份文件：真 3D 粒子星球、点开聚焦拉线、轮盘换角色、加卡、编辑、删除。
// ★ 球只是看柜子的窗口，真身是服务端「文件化记忆柜」：显示一律从 /api/mem/* 真读，
//   新增/编辑/删除一律真写回；断网 / 老台子没接口就是空球 + 空轮盘，绝不编数据、绝不崩。
// ★ 与安卓共用同一份模板 Resources/mem3d.html；数据形状 window.INIT 两端一致。
// ★ iOS 没有 addJavascriptInterface：加载前注入一段 shim，把 window.StillBridge 的
//   六个方法转成 webkit.messageHandlers.StillBridge.postMessage，模板不必分端。

struct Mem3DView: View {
    let charId: String
    @Environment(\.dismiss) private var dismiss
    private let box = Mem3DBox()

    var body: some View {
        Mem3DWebView(box: box, onClose: { dismiss() })
            .ignoresSafeArea()
            .background(Color(hex: 0x0E1018))
            .task {
                let payload = await Mem3DBuild.initPayload(start: charId)
                box.inject(payload)
            }
    }
}

/// 持有 web 引用与待注入脚本（SwiftUI 结构体里改不了类实例，用这个盒子）。
final class Mem3DBox {
    weak var web: WKWebView?
    var pending: String? = nil

    func inject(_ payload: String) {
        let js = "window.StillReload&&window.StillReload(\(payload));"
        pending = js
        let work = {
            guard let w = self.web else { return }
            w.evaluateJavaScript(js, completionHandler: nil)
        }
        if Thread.isMainThread { work() }
        else { DispatchQueue.main.async(execute: work) }
    }
}

struct Mem3DWebView: UIViewRepresentable {
    let box: Mem3DBox
    let onClose: () -> Void

    func makeCoordinator() -> Mem3DCoord { Mem3DCoord(box: box, onClose: onClose) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "StillBridge")
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.isOpaque = false
        w.backgroundColor = UIColor(red: 0x0E/255, green: 0x10/255, blue: 0x18/255, alpha: 1)
        w.scrollView.isScrollEnabled = false
        w.scrollView.bounces = false
        box.web = w
        load(into: w)
        // 若数据比 web 先就绪，在这里补注入一次
        if let js = box.pending {
            box.pending = nil
            DispatchQueue.main.async { w.evaluateJavaScript(js, completionHandler: nil) }
        }
        return w
    }

    func updateUIView(_ w: WKWebView, context: Context) {
        if let js = box.pending {
            box.pending = nil
            w.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    /// 读模板 → 拼 INIT + 桥 shim → 加载。INIT 必须在 Three.js 之前。
    private func load(into w: WKWebView) {
        guard let url = Bundle.main.url(forResource: "mem3d", withExtension: "html"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return }
        let shim = """
        <script>
        window.StillBridge={
          write:function(a,b,c,d){try{webkit.messageHandlers.StillBridge.postMessage({m:'write',a:[a,b,c,d]})}catch(e){}},
          edit:function(a,b,c,d,e){try{webkit.messageHandlers.StillBridge.postMessage({m:'edit',a:[a,b,c,d,e]})}catch(e){}},
          remove:function(a,b,c){try{webkit.messageHandlers.StillBridge.postMessage({m:'remove',a:[a,b,c]})}catch(e){}},
          role:function(a){try{webkit.messageHandlers.StillBridge.postMessage({m:'role',a:[a]})}catch(e){}},
          tab:function(a){try{webkit.messageHandlers.StillBridge.postMessage({m:'tab',a:[a]})}catch(e){}},
          ready:function(){}
        };
        window.INIT={roles:[],data:{},charId:""};
        </script>
        """
        var html = raw
        if let at = html.range(of: "<script>") {
            html.insert(contentsOf: shim, at: at.lowerBound)
        }
        w.loadHTMLString(html, baseURL: Bundle.main.bundleURL)
    }
}

/// JS 回调：解析消息，网络动作丢后台队列，回主线程刷新。
final class Mem3DCoord: NSObject, WKScriptMessageHandler {
    let box: Mem3DBox
    let onClose: () -> Void
    init(box: Mem3DBox, onClose: @escaping () -> Void) {
        self.box = box; self.onClose = onClose
    }

    func userContentController(_ c: WKUserContentController, didReceive msg: WKScriptMessage) {
        guard msg.name == "StillBridge",
              let d = msg.body as? [String: Any],
              let m = d["m"] as? String,
              let a = d["a"] as? [Any] else { return }
        switch m {
        case "tab":
            DispatchQueue.main.async { self.onClose() }
        case "role":
            if let id = a.first as? String { CatBrain.currentCharId = id }
        case "write", "edit", "remove":
            Task {
                await self.act(m: m, a: a)
                let payload = await Mem3DBuild.initPayload(start: CatBrain.currentCharId)
                self.box.inject(payload)
            }
        default:
            break
        }
    }

    /// 真写柜子：write/edit/remove 都走 MemAPI.动（自带票）。
    private func act(m: String, a: [Any]) async {
        let s = { (i: Int) -> String in (i < a.count ? a[i] as? String : nil) ?? "" }
        let cid = s(0), cat = s(1), name = s(2)
        if m == "write" {
            _ = await MemAPI.动("/api/mem/write", cid, ["类别": cat, "名": name, "正文": s(3)])
        } else if m == "edit" {
            _ = await MemAPI.动("/api/mem/edit", cid, ["类别": cat, "名": name, "正文": s(3)])
        } else if m == "remove" {
            _ = await MemAPI.动("/api/mem/delete", cid, ["类别": cat, "名": name])
        }
    }
}

/// 构造 window.INIT 的 JSON 字符串：角色表 + 每角色四类文件树（含正文真读）。
enum Mem3DBuild {
    static func initPayload(start: String) async -> String {
        let roles = await MemAPI.角色列表()
        var data: [String: [[String: Any]]] = [:]
        for r in roles {
            data[r.标识] = await tree(r.标识)
        }
        var payload: [String: Any] = ["roles": [], "data": data, "charId": start]
        var rs: [[String: Any]] = []
        for r in roles {
            var row: [String: Any] = ["id": r.标识, "name": r.名字,
                       "ch": String(r.名字.prefix(1)), "av": "#E3F1F8"]
            // ★ 头像 = 这只角色「坐着张望」的动态形象（sit.gif），跟角色表/聊天同源。
            //   内置那只（builtin / __builtin）在素材站上叫 maozhan；直接用会 404。
            //   WebView 的 <img> 没法设请求头 ⇒ 把分享码和票挂到地址上。
            let assetId = (r.标识 == "builtin" || r.标识 == "__builtin") ? "maozhan" : r.标识
            var comp = URLComponents(string: ActLab.base + "/assets/acts/"
                + (assetId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? assetId)
                + "/sit.gif")
            comp?.queryItems = [URLQueryItem(name: "v", value: "8"),
                                URLQueryItem(name: "sharecode", value: StillShare.code)]
            if let s = comp?.string { row["img"] = s }
            rs.append(row)
        }
        payload["roles"] = rs
        guard let d = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    /// 四类做成 folder，每份文件做成可点节点（都带 catName 供回写）。
    static func tree(_ cid: String) async -> [[String: Any]] {
        let box = await MemAPI.列(cid, nil)
        var out: [[String: Any]] = []
        var uid = 1
        for cat in MemAPI.类别 {
            var kids: [[String: Any]] = []
            for f in (box[cat] ?? []) {
                let detail = await MemAPI.读(cid, cat, f.名)
                kids.append([
                    "uid": uid, "type": cat == "它会的动作" ? "act" : "text",
                    "label": f.名, "cat": cat == "它会的动作" ? "act" : "text",
                    "catName": cat, "desc": f.摘要, "w": 0.6,
                    "text": detail?.正文 ?? ""
                ])
                uid += 1
            }
            out.append([
                "uid": uid, "type": "folder", "label": cat, "cat": "folder",
                "catName": cat, "desc": "\(kids.count) 份", "kids": kids
            ])
            uid += 1
        }
        return out
    }
}
