import Foundation

// MARK: - 台子接口（这一版新接的那些）
//
// 一条原则：**接口只加不改**。这里全是新写的，老的那些还留在 ActLab.swift 里。
//
//   登录豆包   GET  /api/login/state     现在台子认的是谁
//              POST /api/login/session   把手机里这次登录交上去（body: cookie/ua/name）
//              POST /api/login/clear     换账号（把台子记得的那份挪走）
//              POST /api/gen/probe       体检：豆包认不认这份登录态（不花额度）
//   生成进度   GET  /api/gen?job=         进度、阶段、每条各到哪了、还能重收哪几条、剩几条
//              POST /api/gen/stop        取消（还没开跑才停得下来）
//              POST /api/gen/refetch     重新收一遍（豆包画好了但没捡回来 —— 不花额度）
//   动作墙     POST /api/act/retry        一键修复：把卡住的格子拿原视频重抠（不花额度）
//              POST /api/act/rename      改格：把一格改到别的动作上
//              POST /api/act/retire      删格：退下来（文件不删，可恢复）

extension ActLab {

    // MARK: - 通用

    struct Msg: Decodable {
        let ok: Bool?
        let why: String?

        enum CodingKeys: String, CodingKey {
            case ok
            case why = "错误"
        }

        var isOK: Bool { ok != false }
        var text: String { why?.isEmpty == false ? why! : "" }
    }

    static func rawGet(_ path: String, query: [String: String] = [:], timeout: TimeInterval = 20) async throws -> Data {
        var comp = URLComponents(string: base + path)!
        if !query.isEmpty {
            comp.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: comp.url!)
        req.stillStamp()      // ★ 登录制：贴票
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw LabError("没接到服务器的回话") }
        guard (200..<300).contains(http.statusCode) else {
            throw 台子回错了(http.statusCode, data)
        }
        return data
    }

    static func rawPost(_ path: String, query: [String: String] = [:],
                        body: [String: Any]? = nil, timeout: TimeInterval = 40) async throws -> Data {
        var comp = URLComponents(string: base + path)!
        if !query.isEmpty {
            comp.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: comp.url!)
        req.stillStamp()      // ★ 登录制：贴票
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else {
            req.httpBody = Data()
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw LabError("没接到服务器的回话") }
        guard (200..<300).contains(http.statusCode) else {
            throw 台子回错了(http.statusCode, data)
        }
        return data
    }

    private static func snipText(_ d: Data) -> String {
        let s = String(data: d.prefix(160), encoding: .utf8) ?? ""
        return s.isEmpty ? "（没有正文）" : s
    }

    // MARK: - 登录豆包

    struct LoginState: Decodable, Equatable {
        var loggedIn = false
        var name = ""
        var at: Int64 = 0
        var cookies = 0

        enum CodingKeys: String, CodingKey {
            case loggedIn, name, at
            case cookies = "cookie数"
        }

        init() {}

        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            loggedIn = try c.decodeIfPresent(Bool.self, forKey: .loggedIn) ?? false
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            at = try c.decodeIfPresent(Int64.self, forKey: .at) ?? 0
            cookies = try c.decodeIfPresent(Int.self, forKey: .cookies) ?? 0
        }

        var atText: String {
            guard at > 0 else { return "" }
            let d = Date(timeIntervalSince1970: TimeInterval(at) / 1000)
            let f = DateFormatter()
            f.dateFormat = "M月d日 HH:mm"
            return f.string(from: d)
        }
    }

    static func loginState() async throws -> LoginState {
        try JSONDecoder().decode(LoginState.self, from: try await rawGet("/api/login/state"))
    }

    /// 把手机上这次登录的 cookie 交上去。台子拿它去开豆包。
    static func loginGive(cookie: String, ua: String, name: String) async throws {
        let d = try await rawPost("/api/login/session",
                                  body: ["cookie": cookie, "ua": ua, "name": name])
        let m = try? JSONDecoder().decode(Msg.self, from: d)
        if let m, !m.isOK { throw LabError(m.text.isEmpty ? "服务器没认这个登录" : m.text) }
    }

    static func loginForget() async throws {
        let d = try await rawPost("/api/login/clear")
        let m = try? JSONDecoder().decode(Msg.self, from: d)
        if let m, !m.isOK { throw LabError(m.text.isEmpty ? "服务器没换掉账号" : m.text) }
    }

    /// 体检：豆包认不认这份登录态。返回一句人话。
    static func probe() async throws -> String {
        let d = try await rawPost("/api/gen/probe", timeout: 300)
        let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        return (o?["结果"] as? String) ?? (o?["错误"] as? String) ?? "没拿到结果"
    }

    // MARK: - 生成进度

    struct GenHealth: Decodable {
        let current: Cur?
        let queue: Int?
        let version: String?

        struct Cur: Decodable {
            let action: String?
            let stage: String?
        }

        enum CodingKeys: String, CodingKey {
            case current = "当前"
            case queue = "排队"
            case version = "版本"
        }
    }

    static func genHealth() async throws -> GenHealth {
        try JSONDecoder().decode(GenHealth.self, from: try await rawGet("/api/gen/health"))
    }

    /// ★ 2026-10-23：**我这些趟现在都在哪**（不分角色）。
    ///   台子回三段：`当前`（正在跑）/ `队列`（排着）/ `最近`（跑完的）。
    ///   生产页靠它找「这只猫那一趟」：正在跑优先，其次最近一条没彻底完成的。
    struct Mine: Decodable {
        let 当前: [GenJob]?
        let 队列: [GenJob]?
        let 最近: [GenJob]?

        /// 这只猫的那一趟。★ 已经彻底完成的只当兜底 —— 有没做完的，先看没做完的。
        func of(_ charId: String) -> GenJob? {
            var fallback: GenJob?
            for list in [当前, 队列, 最近] {
                for j in list ?? [] {
                    guard j.char == charId else { continue }
                    if j.allDone == true || j.matteAllDone == true {
                        if fallback == nil { fallback = j }
                        continue
                    }
                    return j
                }
            }
            return fallback
        }
    }

    static func genMine() async throws -> Mine {
        try JSONDecoder().decode(Mine.self, from: try await rawGet("/api/gen", timeout: 25))
    }

    /// ★★★ v93（他原话：「不是只要显示就可以了呀那后续呢？」）：
    ///   **按这一只猫问，不再按某一趟单问**。
    ///   他会连点几次「接着做」⇒ 机器上同时存在好几趟单。只问一趟的话，
    ///   真正等着他拿主意的那几条挂在旧单上、永远读不到 ⇒ 界面一直写「正在做」，
    ///   既没进展也没出路。这个接口把名下所有趟合起来答（跨趟合并去重）。
    static func genChar(_ charId: String) async throws -> ActLab.GenJob {
        try JSONDecoder().decode(ActLab.GenJob.self,
            from: try await rawGet("/api/gen", query: ["char": charId], timeout: 25))
    }

    static func genStop(job: String) async throws -> String {
        let d = try await rawPost("/api/gen/stop", query: ["job": job])
        let m = try? JSONDecoder().decode(Msg.self, from: d)
        if let m, !m.isOK { throw LabError(m.text.isEmpty ? "没有停下来" : m.text) }
        return "这次先停了"
    }

    /// 重新收一遍：豆包那边画好了、只是没捡回来。不重新生成、不花额度。
    static func genRefetch(charId: String) async throws -> String {
        let d = try await rawPost("/api/gen/refetch", query: ["char": charId], timeout: 60)
        let m = try? JSONDecoder().decode(Msg.self, from: d)
        if let m, !m.isOK { throw LabError(m.text.isEmpty ? "没收到" : m.text) }
        return "回去收片了（不花额度）"
    }

    /// ★ 2026-10-23（他要的）：**做不出来的那几条，由他一句话定夺**。
    /// - `选` 只有两种：`明天自动`（额度刷新了机器自己补）/ `放弃`（这条以后不提了）
    /// - `act` 留空 = 这一趟所有悬着的条一起按这个办。
    static func genDecide(job: String, act: String = "", 选: String) async throws -> String {
        var q: [String: String] = ["job": job, "选": 选]
        if !act.isEmpty { q["act"] = act }
        let d = try await rawPost("/api/gen/decide", query: q, timeout: 60)
        let m = try? JSONDecoder().decode(Msg.self, from: d)
        if let m, !m.isOK { throw LabError(m.text.isEmpty ? "没办成" : m.text) }
        return 选 == "放弃" ? "知道了 —— 这几条以后不再提" : "约好了 —— 明天额度刷新了机器自己补上"
    }

    /// ★★★ v93：**按这只猫递，不再按某一趟单递**。
    ///   以前只带单号，而手机记的往往是最新的那一趟 ⇒ 机器回一句
    ///   「这趟没有等你定夺的条」⇒ 他点了键、什么也没发生，又被打回原地。
    ///   按猫递的话，名下所有趟里同名的条一起办掉，不会再递错门。
    static func genDecide(charId: String, act: String = "", 选: String) async throws -> String {
        var q: [String: String] = ["char": charId, "选": 选]
        if !act.isEmpty { q["act"] = act }
        let d = try await rawPost("/api/gen/decide", query: q, timeout: 60)
        let m = try? JSONDecoder().decode(Msg.self, from: d)
        if let m, !m.isOK { throw LabError(m.text.isEmpty ? "没办成" : m.text) }
        return 选 == "放弃" ? "知道了 —— 这几条以后不再提" : "约好了 —— 明天额度刷新了机器自己补上"
    }

    /// ★ v94：一批做完的「结算单」—— 我名下还没播报过的那些。
    /// 不管他在哪个页面都能问到，所以单独一个口子，不挂在某一只猫身上。
    static func genSettle() async throws -> [SettleNote] {
        let d = try await rawGet("/api/gen/settle", timeout: 25)
        let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        let arr = (o?["结算"] as? [[String: Any]]) ?? []
        return arr.compactMap { SettleNote.from($0) }
    }

    /// 弹窗已经给他看过了 ⇒ 告诉机器一声，别再弹。再来=true＝他选了「把没做成的再做一遍」。
    static func genSettleAck(char: String, 再来: Bool) async throws {
        var q = ["char": char]
        if 再来 { q["再来"] = "1" }
        _ = try await rawPost("/api/gen/settle/ack", query: q, timeout: 30)
    }

    /// 只补一条动作（省额度用）。action 为空 = 整批。
    static func genStart(charId: String, action: String = "", replace: Bool = false) async throws -> (job: String, acts: [String]) {
        var body: [String: Any] = ["char": charId]
        if !action.isEmpty { body["action"] = action }
        if replace { body["replace"] = true }
        let d = try await rawPost("/api/gen", body: body, timeout: 60)
        let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        if (o?["ok"] as? Bool) == false {
            throw LabError((o?["错误"] as? String) ?? "生成服务拒了这一单")
        }
        guard let jid = o?["job"] as? String, !jid.isEmpty else {
            throw LabError("没拿到单号（回的是：\(snipText(d))）")
        }
        return (jid, (o?["acts"] as? [String]) ?? [])
    }

    // MARK: - 动作墙上的修

    /// 一键修复：把卡住的格子拿机器上原来那段源视频重抠一遍。不重新生成、不花额度。
    static func actRepair(charId: String, force: Bool = false) async throws -> String {
        var q = ["char": charId]
        if force { q["force"] = "1" }
        let d = try await rawPost("/api/act/retry", query: q, timeout: 60)
        let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        if (o?["ok"] as? Bool) == false {
            throw LabError((o?["错误"] as? String) ?? "没修起来")
        }
        let n = (o?["重抠"] as? [Any])?.count ?? (o?["排上"] as? [Any])?.count ?? 0
        return n > 0 ? "排上了 \(n) 条，重新抠一遍（不花额度）" : "已经排上了，服务器会一条条重做"
    }

    /// 改格：把这一格改到另一个标准动作上（机器认错了、或者你自己想换）。
    static func actRename(charId: String, name: String, to: String) async throws {
        let d = try await rawPost("/api/act/rename",
                                  query: ["char": charId, "name": name, "to": to])
        let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        if (o?["ok"] as? Bool) == false {
            throw LabError((o?["错误"] as? String) ?? "改不了这一格")
        }
    }

    /// 删格：从墙上退下来（文件不删，可以恢复）。
    static func actRetire(charId: String, name: String) async throws {
        let d = try await rawPost("/api/act/retire",
                                  query: ["char": charId, "name": name])
        let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        if (o?["ok"] as? Bool) == false {
            throw LabError((o?["错误"] as? String) ?? "退不下来这一格")
        }
    }

    /// 上传一段视频给**指定的**格子（换视频）。
    /// ★ 台子收视频时不带名字（按「认一认」定格子），所以传完再调一次改名把它按到那一格上。
    static func replaceVideo(charId: String, slot: String, video: URL) async throws -> String {
        let job = try await submitVideo(charId: charId, video: video)
        try? await actRename(charId: charId, name: job.name ?? "", to: slot)
        return "传上去了，正在抠（这条要按到「\(slot)」上）"
    }
}
