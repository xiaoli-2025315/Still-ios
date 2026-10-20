import Foundation

// MARK: - 台子上的「动作库」
//
// 这是安卓 `Act.java` 的 iOS 版。整条链一共这几条：
//   GET  /api/act/chars                     角色表：每只 + 它这套动作好了几条
//   GET  /api/act/manifest?char=<角色id>     这只的动作清单（一行一条，竖线分隔）
//   GET  /api/act/jobs                       抠像队列：谁在抠、抠到几成
//   POST /api/act/char?name=&channel=&ext=   登记新角色（body 直接就是那张照片）
//   POST /api/act?loop=&fps=&w=&char=        传一条动作视频（body 直接就是那段 mp4）
//   GET  /api/act/charpack?char=             取整套动作（zip，见 CatPack）
//
// 生成（付费通道）那条走生成服务，台子只是转发：
//   POST /api/gen        {"char":"<角色id>"}  一次把词库里的动作各做一条
//   GET  /api/gen?job=                         这趟做到哪了（阶段、进度、逐条）
//
// ★ 上传是**裸 body**，不是 multipart —— 安卓那边 `postFile` 就是直接写字节。
//   所以这里用 `upload(for:from:)`，别包成表单，台子不认。
//
// ★ 「通道」两个值跟安卓一样：free（自己传动作视频，台子免费抠像）
//   / paid（台子按照片生成整套动作）。

enum ActLab {

    static let base = "https://still-ui-design.app.workbuddy.host"

    /// 台子原来就有的 12 条。跟安卓 `Act.OFFICIAL` 同一批、同一顺序 ——
    /// 两边对不上，用户看到的「好了 7 条」就不是同一件事。
    static let official: [(key: String, label: String)] = [
        ("sit", "坐着张望"), ("walk", "走路"), ("groom", "舔毛"), ("sleep", "睡着了"),
        ("liedown", "趴下"), ("wake", "起身"), ("walk_r", "行走·往右"),
        ("hunt1", "扑猎 1"), ("hunt2", "扑猎 2"), ("struggle", "挣扎"),
        ("inhale", "吸气"), ("exhale", "呼气"),
    ]

    // MARK: - 模型

    struct Char: Decodable, Identifiable, Equatable {
        let id: String
        let name: String
        let channel: String?
        let img: String?
        let done: Int?

        var title: String { name.isEmpty ? id : name }
        var doneCount: Int { done ?? 0 }
        var isPaid: Bool { (channel ?? "free") == "paid" }
        var imgURL: URL? {
            guard let img, !img.isEmpty else { return nil }
            if img.hasPrefix("http") { return URL(string: img) }
            return URL(string: base + "/" + img.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }
    }

    /// 某只的动作清单。只关心「有哪些名字」——够了，格子亮不亮就看这个。
    struct Manifest {
        var stamp: Int64 = 0
        /// 已经抠好、能下的动作名
        var names: Set<String> = []
        /// 还在队列里、没认领的（服务器起的 x_ 临时名）
        var pending: Int = 0
    }

    // MARK: - 响应壳

    private struct CharsResp: Decodable { let chars: [Char]? }

    /// 抠像队列里的一条。字段全是「有就填」——台子不同版本给的键不完全一样，
    /// 用可选包着，缺哪个都不会解不出来。
    struct Job: Decodable, Identifiable, Equatable {
        let id: String
        let name: String?
        let display: String?
        let stage: String?
        let pct: Int?
        let char: String?
        let err: String?
        let ok: Bool?

        var isDone: Bool { (stage ?? "") == "好了" }
        var isBad: Bool {
            let s = stage ?? ""
            return s.contains("失败") || s.contains("错")
        }
        /// 一句话进度。给小窗那条横条用的。
        var line: String {
            if isDone { return "抠好了" }
            if isBad { return (err?.isEmpty == false ? err! : (stage ?? "出错了")) }
            return "\(stage ?? "排队中") \(pct ?? 0)%"
        }
    }

    private struct JobsResp: Decodable { let jobs: [Job]? }

    private struct SubmitResp: Decodable {
        let ok: Bool?
        let job: Job?
        let dup: Bool?
        let why: String?
        enum CodingKeys: String, CodingKey {
            case ok, job, dup
            case why = "错误"
        }
    }

    // MARK: - 生成（付费通道）一趟的进度

    struct GenJob: Decodable {
        let job: String?
        /// 机器内部的阶段码（准备形象图 / 生成中 / 送进台子 / 抠像中…）
        let stage: String?
        /// 给人看的那句（「豆包正在画（已发 3/12 条）」这种）
        let phase: String?
        let msg: String?
        let progress: Int?
        let allDone: Bool?
        let failed: Bool?
        let acts: [String]?
        let each: [GenSeg]?

        struct GenSeg: Decodable, Identifiable {
            let act: String?
            let stage: String?
            var id: String { act ?? UUID().uuidString }
        }

        enum CodingKeys: String, CodingKey {
            case job, stage, msg, acts, failed
            case phase    = "阶段"
            case progress = "进度"
            case allDone  = "全完成"
            case each     = "每条"
        }

        var isDone: Bool { allDone == true }
        var isBad: Bool { failed == true }
        var line: String {
            if isDone { return "整套做完了，动作已经可以用了" }
            if isBad { return "没成 —— " + (phase ?? msg ?? stage ?? "看台子上的日志") }
            // ★ 用「阶段」那句人话，别把内部阶段码（生成中/送进台子）直接甩给用户看
            let st = (phase?.isEmpty == false ? phase! : (msg?.isEmpty == false ? msg! : stage ?? "排队中"))
            if let p = progress, p > 0, p < 100 { return "\(st) · \(p)%" }
            return st
        }
    }

    private struct GenStartResp: Decodable {
        let ok: Bool?
        let job: String?
        let acts: [String]?
        let why: String?
        enum CodingKeys: String, CodingKey {
            case ok, job, acts
            case why = "错误"
        }
    }

    private struct ManifestResp: Decodable {
        let stamp: Int64?
        let list: [String]?
        enum CodingKeys: String, CodingKey {
            case stamp
            case list = "清单"
        }
    }

    private struct NewResp: Decodable {
        let ok: Bool?
        let char: Char?
        let why: String?
        enum CodingKeys: String, CodingKey {
            case ok, char
            case why = "错误"
        }
    }

    // MARK: - 读

    static func chars() async throws -> [Char] {
        let r: CharsResp = try await get("/api/act/chars")
        return r.chars ?? []
    }

    static func manifest(charId: String) async throws -> Manifest {
        var comp = URLComponents(string: base + "/api/act/manifest")!
        comp.queryItems = [URLQueryItem(name: "char", value: charId)]
        let r: ManifestResp = try await get(absURL: comp.url!)

        var m = Manifest()
        m.stamp = r.stamp ?? 0
        for line in r.list ?? [] {
            // 一行长这样：name|显示名|帧数|…|fps
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard let head = parts.first else { continue }
            let nm = String(head)
            if nm.hasPrefix("x_") { m.pending += 1 } else if !nm.isEmpty { m.names.insert(nm) }
        }
        return m
    }

    /// 抠像队列（台子只留最近 40 条）。按角色筛。
    static func jobs(charId: String) async throws -> [Job] {
        let r: JobsResp = try await get("/api/act/jobs")
        let all = r.jobs ?? []
        guard !charId.isEmpty else { return all }
        return all.filter { ($0.char ?? "") == charId }
    }

    // MARK: - 写：传一条动作视频（免费通道）

    /// 把一段视频交给台子，让它抽帧抠像。
    ///
    /// ★ 不带名字：台子会给它一个 `x_` 临时名，抠完由「认一认」看画面定它进哪一格。
    ///   这是 2026-10-07 他自己拍的板（「不应该按照上传入口命名」），安卓也是这么传的，
    ///   两边必须一致，不然同一条动作会两边各算一版。
    /// - Parameter video: 已经落到本地的 mp4 文件（相册给的是临时文件）
    static func submitVideo(charId: String, video: URL) async throws -> Job {
        var comp = URLComponents(string: base + "/api/act")!
        comp.queryItems = [
            URLQueryItem(name: "loop", value: "1"),
            URLQueryItem(name: "fps", value: "50"),
            URLQueryItem(name: "w", value: "384"),
            URLQueryItem(name: "char", value: charId),
        ]
        var req = URLRequest(url: comp.url!)
        req.httpMethod = "POST"
        // 视频比图片大得多；30MB 的手机网要传几分钟，别让它中途超时
        req.timeoutInterval = 600
        req.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.upload(for: req, fromFile: video)
        guard let http = resp as? HTTPURLResponse else { throw LabError("没接到台子的回话") }
        guard (200..<300).contains(http.statusCode) else {
            throw LabError("台子说 HTTP \(http.statusCode)：\(snip(data))")
        }
        let r = try? JSONDecoder().decode(SubmitResp.self, from: data)
        // ★ 传过同一段视频时台子回 ok=false + dup=true。这不是故障，是它省了一次重复抠像。
        if let r, r.dup == true {
            throw LabError(r.why?.isEmpty == false ? r.why! : "这段视频传过了，没有重复处理。")
        }
        if let r, r.ok == false {
            throw LabError(r.why?.isEmpty == false ? r.why! : "台子没收这段视频")
        }
        guard let j = r?.job else {
            throw LabError("台子没给任务号（回的是：\(snip(data))）")
        }
        return j
    }

    // MARK: - 写：让台子把整套动作生成出来（付费通道）

    /// 下一次单，台子按词库把动作**各做一条**（已经在做 / 已经做好的会自己跳过）。
    /// ★ 这会消耗豆包额度 —— 调用方必须先让用户确认。
    static func genStart(charId: String, replace: Bool = false) async throws -> (job: String, acts: [String]) {
        var req = URLRequest(url: URL(string: base + "/api/gen")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        var body: [String: Any] = ["char": charId]
        if replace { body["replace"] = true }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LabError("生成服务说 HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)：\(snip(data))")
        }
        let r = try? JSONDecoder().decode(GenStartResp.self, from: data)
        if let r, r.ok == false {
            throw LabError(r.why?.isEmpty == false ? r.why! : "生成服务拒了这一单")
        }
        guard let jid = r?.job, !jid.isEmpty else {
            throw LabError("没拿到生成任务号（回的是：\(snip(data))）")
        }
        return (jid, r?.acts ?? [])
    }

    /// 这一趟生成做到哪了。
    static func genState(job: String) async throws -> GenJob {
        var comp = URLComponents(string: base + "/api/gen")!
        comp.queryItems = [URLQueryItem(name: "job", value: job)]
        var req = URLRequest(url: comp.url!)
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LabError("查进度失败（HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)）")
        }
        return try JSONDecoder().decode(GenJob.self, from: data)
    }

    // MARK: - 写：登记一个新角色

    /// - Parameters:
    ///   - photo: 已经转成 JPEG 的字节（相册里可能是 HEIC，台子不一定认）
    static func create(name: String, channel: String, photo: Data) async throws -> Char {
        var comp = URLComponents(string: base + "/api/act/char")!
        comp.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "channel", value: channel),
            URLQueryItem(name: "ext", value: "jpg"),
        ]
        var req = URLRequest(url: comp.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.upload(for: req, from: photo)
        guard let http = resp as? HTTPURLResponse else { throw LabError("没接到台子的回话") }
        guard (200..<300).contains(http.statusCode) else {
            throw LabError("台子说 HTTP \(http.statusCode)：\(snip(data))")
        }
        let r = try? JSONDecoder().decode(NewResp.self, from: data)
        if let r, r.ok == false {
            throw LabError(r.why?.isEmpty == false ? r.why! : "登记失败")
        }
        if let c = r?.char { return c }
        // 台子回了 ok 但没给 char：拿名字现拼一只，界面至少能显示出来
        return Char(id: "", name: name, channel: channel, img: nil, done: 0)
    }

    // MARK: - 底层

    struct LabError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    private static func get<T: Decodable>(_ path: String) async throws -> T {
        try await get(absURL: URL(string: base + path)!)
    }

    private static func get<T: Decodable>(absURL: URL) async throws -> T {
        var req = URLRequest(url: absURL)
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw LabError("没接到台子的回话") }
        guard (200..<300).contains(http.statusCode) else {
            throw LabError("台子说 HTTP \(http.statusCode)：\(snip(data))")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func snip(_ d: Data) -> String {
        let s = String(data: d.prefix(160), encoding: .utf8) ?? ""
        return s.isEmpty ? "（没有正文）" : s
    }
}
