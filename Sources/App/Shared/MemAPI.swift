import Foundation

// MARK: - 记忆柜（2026-11-22）
//
// 台子把记忆整理成柜子里一份份文件，球只是看它们的窗口。
// 这里只做「列 / 读 / 写 / 改 / 删 / 撤销」，全部走 /api/mem/*，带票（stillStamp）。
// 台子没这几条接口 / 断网 → 全部安全失败，界面显示空，绝不崩、绝不编数据。

enum MemAPI {

    struct File: Identifiable, Codable {
        var id: String { 名 }
        var 名: String
        var 摘要: String
        var 说明: String = ""
        var 重要: String
        var 时间: String
        var 字节: Int
    }

    struct Detail: Codable {
        var 元信息: [String: String]
        var 正文: String
    }

    struct Role: Identifiable {
        var id: String { 标识 }
        var 标识: String
        var 名字: String
        var n: Int
    }

    static let 类别 = ["它记住的", "设定", "它会的动作", "聊天流水"]

    /// 当前用户能看的猫（内置猫排第一）。失败回空。
    static func 角色列表() async -> [Role] {
        guard let u = URL(string: ActLab.base + "/api/mem/chars") else { return [] }
        var req = URLRequest(url: u); req.stillStamp(); req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              o["ok"] as? Bool == true,
              let arr = o["chars"] as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let id = d["id"] as? String else { return nil }
            return Role(标识: id, 名字: d["name"] as? String ?? id,
                        n: (d["n"] as? NSNumber)?.intValue ?? 0)
        }
    }

    /// 列一类（或传 nil 列全部，返回 {类别:[文件]}）。
    static func 列(_ char: String, _ cat: String?) async -> [String: [File]] {
        var comp = URLComponents(string: ActLab.base + "/api/mem/list")!
        var items = [URLQueryItem(name: "char", value: char)]
        if let cat { items.append(URLQueryItem(name: "类别", value: cat)) }
        comp.queryItems = items
        guard let u = comp.url else { return [:] }
        var req = URLRequest(url: u); req.stillStamp(); req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              o["ok"] as? Bool == true else { return [:] }
        /// ★★ 2026-11-23 真根因：带了「类别」时台子回的「柜子」直接是数组，
        ///   只有不带类别时才是 {类别: [...]}。以前一律当字典 ⇒ 每只猫都「还没有记忆」。
        func 解析(_ arr: [[String: Any]]) -> [File] {
            arr.compactMap { d in
                guard let 名 = d["名"] as? String else { return nil }
                return File(名: 名, 摘要: d["摘要"] as? String ?? "",
                            说明: d["说明"] as? String ?? "",
                            重要: d["重要"] as? String ?? "",
                            时间: d["时间"] as? String ?? "",
                            字节: (d["字节"] as? NSNumber)?.intValue ?? 0)
            }
        }
        if let flat = o["柜子"] as? [[String: Any]] {
            return [cat ?? "": 解析(flat)]
        }
        guard let box = o["柜子"] as? [String: Any] else { return [:] }
        var out: [String: [File]] = [:]
        for (k, v) in box {
            guard let arr = v as? [[String: Any]] else { continue }
            out[k] = arr.compactMap { d in
                guard let 名 = d["名"] as? String else { return nil }
                return File(名: 名, 摘要: d["摘要"] as? String ?? "",
                            说明: d["说明"] as? String ?? "",
                            重要: d["重要"] as? String ?? "",
                            时间: d["时间"] as? String ?? "",
                            字节: (d["字节"] as? NSNumber)?.intValue ?? 0)
            }
        }
        return out
    }

    /// 读一份。
    static func 读(_ char: String, _ cat: String, _ name: String) async -> Detail? {
        var comp = URLComponents(string: ActLab.base + "/api/mem/read")!
        comp.queryItems = [URLQueryItem(name: "char", value: char),
                           URLQueryItem(name: "类别", value: cat),
                           URLQueryItem(name: "名", value: name)]
        guard let u = comp.url else { return nil }
        var req = URLRequest(url: u); req.stillStamp(); req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              o["ok"] as? Bool == true,
              let f = o["文件"] as? [String: Any],
              let meta = f["元信息"] as? [String: String],
              let body = f["正文"] as? String else { return nil }
        return Detail(元信息: meta, 正文: body)
    }

    /// 写 / 改 / 删 / 撤销，统一 POST。
    @discardableResult
    static func 动(_ path: String, _ char: String, _ body: [String: Any]) async -> Bool {
        guard let u = URL(string: ActLab.base + path) else { return false }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.stillStamp(); req.timeoutInterval = 20
        var all = body; all["char"] = char
        req.httpBody = try? JSONSerialization.data(withJSONObject: all)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return o["ok"] as? Bool == true
    }
}
