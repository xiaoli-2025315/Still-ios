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

    /// 台子上的动作，跟安卓 `Act.OFFICIAL` 同一批、同一顺序 ——
    /// 两边对不上，用户看到的「好了 7 条」就不是同一件事。
    /// ★★★ 2026-10-21：「往左走」(walk) 整条链删掉（12 → 11）。走路只留 walk_r，
    ///   往左靠播放时镜像 —— 所以这里跟安卓一样不再有 walk 那一格。
    static let official: [(key: String, label: String)] = [
        ("sit", "坐着张望"), ("groom", "舔毛"), ("sleep", "睡着了"),
        ("liedown", "趴下"), ("wake", "起身"), ("walk_r", "行走"),
        ("hunt1", "扑猎 1"), ("hunt2", "扑猎 2"), ("struggle", "挣扎"),
        ("inhale", "吸气"), ("exhale", "呼气"),
    ]

    /// 这套动作一共几条 —— **别处不要写死数字**。12 条的时候到处写 `12`，
    /// 10-21 删掉「往左走」之后全成了错的（进度、分母、齐没齐都错）。
    static var total: Int { official.count }

    // MARK: - 模型

    struct Char: Decodable, Identifiable, Equatable {
        let id: String
        let name: String
        let channel: String?
        let img: String?
        let done: Int?
        // ★ 2026-10-21：**这里不能给默认值** `let dropped: Bool? = nil` ——
        //   那样编译器会警告「Immutable property will not be decoded」，
        //   字段永远解不进来，删除功能直接失效还不报错。所以改写调用方。
        /// ★ 2026-10-21：这个角色是不是已经被「整个删掉」了（台子只盖戳、不删文件）。
        let dropped: Bool?
        /// ★ 台子算好的「能不能删」——样板是 false。**前端别自己判**，两处判法迟早会不一样。
        let canDrop: Bool?

        var title: String { name.isEmpty ? id : name }
        var doneCount: Int { done ?? 0 }
        var isPaid: Bool { (channel ?? "free") == "paid" }
        var isDropped: Bool { dropped == true }
        /// 没给 canDrop 的老台子：非样板就算能删（样板恒排第一且 channel=official）
        var dropAllowed: Bool { canDrop ?? (channel != "official") }
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
        /// 这一趟是给哪只猫做的 —— 生产页要在「我所有的趟次」里挑出这只的那一刻
        let char: String?
        /// 机器内部的阶段码（准备形象图 / 生成中 / 送进台子 / 抠像中…）
        let stage: String?
        /// 给人看的那句（「豆包正在画（已发 3/12 条）」这种）
        let phase: String?
        let msg: String?
        let progress: Int?
        let allDone: Bool?
        /// 整套连抠像都完了 —— 跟 `allDone`（画完了）不是一回事，生产页两样都要认
        let matteAllDone: Bool?
        let failed: Bool?
        let done: Bool?
        let acts: [String]?
        let each: [GenSeg]?
        /// 这几条豆包那边画好了、还没捡回来 —— 有就亮「重新收一遍」（不花额度）
        let redo: [String]?
        /// 这一趟没做、留给下一批的 —— 按钮写成「接着做下一批（还有 N 段）」
        let leftover: [String]?

        /// ★★★ 2026-10-23（他报的）：**排队得说清楚**，不然用户以为 App 坏了。
        ///   「前面还有几个」「机器忙不忙」「电闸关没关」都从台子拿，App 只负责说人话。
        //   ★ 给默认值：这样 `GenJob.stub()` 那种手写构造不用一个个补参数
        //     （v78 第一次 CI 就是漏了这个直接编译失败）。
        let queued: Bool? = nil
        let ahead: Int? = nil
        let busy: Bool? = nil
        let gateOff: Bool? = nil
        let gateWhy: String? = nil

        /// ★★★ 2026-10-23（他要的）：**做不出来的那几条** —— 由他一句话定夺。
        ///   以前这些条（今天的免费额度用完了 / 豆包在等他点确认）只会让整趟
        ///   一直挂着"还在跑"，永远不收尾。现在单独拎出来给他两颗键。
        struct Pending: Decodable, Identifiable {
            let act: String?
            let why: String?
            /// ★ v93：这条**豆包其实已经画好了、只是没拿回来** —— 有就能给一条不花钱的路。
            ///   没有就**不许**显示那颗键（不给空承诺）。
            let fetchable: Bool?
            var id: String { act ?? UUID().uuidString }
            enum CodingKeys: String, CodingKey {
                case act; case why = "为什么"; case fetchable = "可重收"
            }
        }
        let pending: [Pending]?

        // ★ v93：★ 不新增解码字段 —— 别的接口（不带 char 的那一支）不返回它们，
        //   一加就会整包解码失败、页面直接白。这几个都从已有字段现算。

        /// 跨所有趟合并后**已经真做好了的**动作名 —— 用来告诉他「没白等」。
        var madeOk: [String] {
            (each ?? []).compactMap { s in
                (s.matteDone == true) ? s.act : nil
            }.compactMap { $0 }
        }
        /// 还差几个没做（机器按台子上真有的算出来的）。
        var restN: Int { (leftover ?? []).count }

        struct GenSeg: Decodable, Identifiable {
            let act: String?
            let stage: String?
            let pct: Int?
            let sent: Bool
            let saved: Bool
            let matteDone: Bool

            var id: String { act ?? UUID().uuidString }

            enum CodingKeys: String, CodingKey {
                case act, stage, pct, matteDone, tSent, tSaved
            }

            init(from d: Decoder) throws {
                let c = try d.container(keyedBy: CodingKeys.self)
                act = try c.decodeIfPresent(String.self, forKey: .act)
                stage = try c.decodeIfPresent(String.self, forKey: .stage)
                pct = try c.decodeIfPresent(Int.self, forKey: .pct)
                matteDone = try c.decodeIfPresent(Bool.self, forKey: .matteDone) ?? false
                sent = (try c.decodeIfPresent(Double.self, forKey: .tSent) ?? 0) > 0
                saved = (try c.decodeIfPresent(Double.self, forKey: .tSaved) ?? 0) > 0
            }

            /// 这一条走到哪了。给人看的四个台阶（跟安卓那四行一样）。
            var line: String {
                if matteDone { return "好了" }
                if let s = stage, !s.isEmpty {
                    if s.contains("卡在豆包") { return s }
                    return s
                }
                if saved { return "画好了，正送到服务器" }
                if sent { return "已发给豆包，正在画" }
                return "排着队"
            }
        }

        enum CodingKeys: String, CodingKey {
            case job, char, stage, msg, acts, failed, done
            case phase    = "阶段"
            case progress = "进度"
            case allDone  = "全完成"
            // ★★★ v92（2026-10-25）：这一条以前写的是「背景去掉了」—— 可机器那边
            //   真正写出来的字段名是 **`抠像完成`**（安卓一直按这个读的）。
            //   名字对不上 ⇒ 这个值**永远是空的**：台子明明说"背景已经去掉了"，
            //   苹果这边却认不出来（它只看 `全完成`），判定就跟安卓对不齐。
            case matteAllDone = "抠像完成"
            case each     = "每条"
            case redo     = "可重收"
            case leftover = "剩"
            case pending  = "要你定的"
            case queued   = "排队"
            case ahead    = "前面还有"
            case busy     = "机器忙着"
            case gateOff  = "闸门关着"
            case gateWhy  = "闸门原因"
        }

        /// ★★★ 这一版修的那件事：台子把「已经停了」的趟次统一钳到 1%。
        ///   所以 `进度 == 1` 时**不能**当成「刚起步」——
        ///   要看「阶段」那句人话到底在说什么（取消 / 没成 / 额度用完 / 被打断）。
        ///
        /// ★ 还有一层坑：台子给「取消」的趟次也打了 `全完成 = 1`，
        ///   直接用 `全完成` 判「做完了」，取消的那趟会显示成「整套做完了」。文字优先。
        var phaseText: String {
            if let p = phase, !p.isEmpty { return p }
            if let m = msg, !m.isEmpty { return m }
            return stage ?? ""
        }

        var isDone: Bool { phaseText.contains("全都好了") || phaseText.contains("做完了") }
        var isBad: Bool { failed == true || phaseText.contains("没成") }

        var stopped: Bool {
            if isDone || isBad { return true }
            let s = phaseText
            if s.contains("取消") || s.contains("额度") || s.contains("打断")
                || s.contains("停了") || s.contains("上一趟") { return true }
            if let p = progress, p >= 100 { return true }
            return false
        }

        var line: String {
            if isDone { return "整套做完了，动作已经可以用了" }
            if isBad { return "没成 —— " + (phaseText.isEmpty ? "看服务器上的记录" : phaseText) }
            let st = phaseText.isEmpty ? "排队中" : phaseText
            // ★ 只有「真在跑」才带百分比：停了的那趟进度是假的（1% 那个坑就在这儿）
            if stopped { return st }
            if let p = progress, p > 1, p < 100 { return "\(st) · \(p)%" }
            return st
        }

        /// 进度条该画多少。**停了的不画满** —— 画满会让人以为做完了。
        var barValue: Double {
            if isDone { return 1 }
            if stopped { return 0.02 }
            let p = Double(progress ?? 0)
            return min(0.99, max(0.02, p / 100.0))
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

    /// ★ 2026-11-01：每一格现在到哪一步（跟安卓读的同一个接口）
    struct StateResp: Decodable {
        struct Row: Decodable {
            let act: String
            let 状态: String
            let 人话: String?
        }
        let ok: Bool?
        let char: String?
        let acts: [Row]
    }

    /// 读这一只的动作状态。失败返回 nil（页面保持原样，不瞎改）。
    static func state(charId: String) async -> StateResp? {
        let enc = charId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? charId
        return try? await get("/api/act/state?char=" + enc)
    }

    static func chars() async throws -> [Char] {
        let r: CharsResp = try await get("/api/act/chars")
        return r.chars ?? []
    }

    /// ★ 2026-10-21：连「已经删掉的」一起拉（`?all=1`）。
    /// 角色页靠它下面那行「已删掉 N 个 · 放回来」——删错了自己点回去，不用来找我。
    /// ★ 参数名必须是英文 `all`：中文 key 经 HTTP 路径的编码这一层对不上，会静默取不到。
    static func chars(includingDropped: Bool) async throws -> [Char] {
        if !includingDropped { return try await chars() }
        let r: CharsResp = try await get("/api/act/chars?all=1")
        return r.chars ?? []
    }

    /// 整个删掉一个角色。台子那边只是「盖个戳」，素材文件一样不删 ⇒ 能放回来。
    /// 回一句人话（失败时就是原因）。
    @discardableResult
    static func dropChar(_ id: String) async throws -> String {
        try await postSay("/api/act/chardrop", query: [URLQueryItem(name: "char", value: id)])
    }

    /// 把删掉的角色放回来（自救口）。
    @discardableResult
    static func restoreChar(_ id: String) async throws -> String {
        try await postSay("/api/act/charrestore", query: [URLQueryItem(name: "char", value: id)])
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
            // ★★★ v92（存量）：**只有明确写着 0 帧的才不算数**。
            //   台子上有一批"说好了、其实一帧都没有"的旧动作（以前那道超时兜底把它们标成了 100%），
            //   安卓一直按"帧数 > 0"认，苹果这边以前只认名字 ⇒ 那几格在苹果上看着是做好的，
            //   点进去其实是空的。现在跟安卓同一个口径。
            //   ★ 数不出帧数（格式对不上）的**照旧算数** —— 宁可多认，也不能把做好的弄丢。
            if parts.count > 2, let f = Int(parts[2].trimmingCharacters(in: .whitespaces)), f <= 0 {
                continue
            }
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

    /// ★ v95（功能匹配）：**还有几条抠完了、名字还没定**（在等「认一认」）。
    ///   安卓 v2.26 就自动跑了；苹果以前没接 ⇒ 上传的视频永远停在 `x_临时名`。
    struct RecogResp: Decodable {
        let pending: [RecogItem]?
        enum CodingKeys: String, CodingKey { case pending }
    }

    struct RecogItem: Decodable {
        let id: String?
        let char: String?
    }

    static func pendingRecog() async throws -> Int {
        let r: RecogResp = try await get("/api/act/recog")
        return r.pending?.count ?? 0
    }

    /// 认一认那一页的地址（票挂在地址上 —— 网页里塞不进自定义头）。
    static var recogURL: URL? {
        let s = Ticket.挂票(base + "/recog.html")
        return URL(string: s)
    }

    // MARK: - 重摆 / 退回（v95 功能匹配：台子有、手机上以前没入口）

    /// 把这只猫已经做好的动作**重新摆一遍大小**。
    ///
    /// 台子上早就有这本事（按「坐立」那把尺子统一身高和脚线，不重抠、不花额度、
    /// 摆之前原包留备份），可两端手机上一颗键都没有 —— 他只能开电脑上网页按。
    /// 这正是他要修的那类「台子有、App 没有」的缺口。
    @discardableResult
    static func realign(charId: String, dry: Bool) async throws -> String {
        var q = [URLQueryItem(name: "char", value: charId)]
        if dry { q.append(URLQueryItem(name: "dry", value: "1")) }
        return try await postSay("/api/act/realign", query: q)
    }

    /// 重摆是**服务器后台跑**的 —— 这一句问「摆到哪儿了」。
    struct RealignState: Decodable {
        let running: Bool?
        let done: Bool?
        let progress: String?
        let seen: Int?
        let moved: Int?
        let errors: [String]?
        enum CodingKeys: String, CodingKey {
            case running = "跑着"
            case done = "干完了"
            case progress = "进度"
            case seen = "看过"
            case moved = "动了"
            case errors = "错"
        }
    }

    static func realignState() async throws -> RealignState {
        try await get("/api/act/realign")
    }

    /// 重摆的**退路**：把摆之前那份备份原样拷回去。
    /// 某一版摆得不如从前、或者摆坏了，随时能退。
    struct UndoResp: Decodable {
        let ok: Bool?
        let back: [String]?
        let missing: [String]?
        let why: String?
        enum CodingKeys: String, CodingKey {
            case ok
            case back = "退回的"
            case missing = "没备份可退"
            case why = "错误"
        }
    }

    static func alignUndo(charId: String) async throws -> UndoResp {
        var comp = URLComponents(string: base + "/api/act/align/undo")!
        comp.queryItems = [URLQueryItem(name: "char", value: charId)]
        var req = URLRequest(url: comp.url!)
        req.stillStamp()      // ★ 登录制：贴票
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw 台子回错了((resp as? HTTPURLResponse)?.statusCode ?? -1, data)
        }
        return (try? JSONDecoder().decode(UndoResp.self, from: data)) ?? UndoResp(ok: true, back: nil, missing: nil, why: nil)
    }

    // MARK: - 检查更新（v95 功能匹配）

    /// 服务器上最新那一版（跟安装页现取的是同一份）。
    struct Latest: Decodable {
        let ok: Bool?
        let version: String?
        let build: Int?
        let file: String?
        let title: String?
        let items: [NoteItem]?
        enum CodingKeys: String, CodingKey {
            case ok
            case version = "版本"
            case build = "号"
            case file = "文件"
            case title = "标题"
            case items = "条目"
        }
    }

    struct NoteItem: Decodable {
        let tag: String?
        let text: String?
        enum CodingKeys: String, CodingKey {
            case tag = "标签"
            case text = "内容"
        }
    }

    /// 苹果这一端有没有新版。台子上有这口子，手机上以前一颗键都没有。
    static func iosLatest() async throws -> Latest {
        try await get("/api/ios/latest")
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
        req.stillStamp()      // ★ 登录制：贴票
        req.httpMethod = "POST"
        // 视频比图片大得多；30MB 的手机网要传几分钟，别让它中途超时
        req.timeoutInterval = 600
        req.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.upload(for: req, fromFile: video)
        guard let http = resp as? HTTPURLResponse else { throw LabError("没接到服务器的回话") }
        guard (200..<300).contains(http.statusCode) else {
            throw 台子回错了(http.statusCode, data)
        }
        let r = try? JSONDecoder().decode(SubmitResp.self, from: data)
        // ★ 传过同一段视频时台子回 ok=false + dup=true。这不是故障，是它省了一次重复抠像。
        if let r, r.dup == true {
            throw LabError(r.why?.isEmpty == false ? r.why! : "这段视频传过了，没有重复处理。")
        }
        if let r, r.ok == false {
            throw LabError(r.why?.isEmpty == false ? r.why! : "服务器没收这段视频")
        }
        guard let j = r?.job else {
            throw LabError("服务器没给单号（回的是：\(snip(data))）")
        }
        return j
    }

    // MARK: - 写：让台子把整套动作生成出来（付费通道）
    //
    // ★ 下单这一个动作搬到 `ActAPI.swift` 了（那边多了「只补一条」和 replace 两个参数）。
    //   这里不要再留一份 —— 两个同名的默认参数函数会互相抢，编译直接报「歧义」。

    /// 这一趟生成做到哪了。
    static func genState(job: String) async throws -> GenJob {
        var comp = URLComponents(string: base + "/api/gen")!
        comp.queryItems = [URLQueryItem(name: "job", value: job)]
        var req = URLRequest(url: comp.url!)
        req.stillStamp()      // ★ 登录制：贴票
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
        req.stillStamp()      // ★ 登录制：贴票
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.upload(for: req, from: photo)
        guard let http = resp as? HTTPURLResponse else { throw LabError("没接到服务器的回话") }
        guard (200..<300).contains(http.statusCode) else {
            throw 台子回错了(http.statusCode, data)
        }
        let r = try? JSONDecoder().decode(NewResp.self, from: data)
        if let r, r.ok == false {
            throw LabError(r.why?.isEmpty == false ? r.why! : "登记失败")
        }
        if let c = r?.char { return c }
        // 台子回了 ok 但没给 char：拿名字现拼一只，界面至少能显示出来
        return Char(id: "", name: name, channel: channel, img: nil, done: 0,
                    dropped: nil, canDrop: nil)
    }

    // MARK: - 底层

    struct LabError: LocalizedError {
        let message: String
        /// ★ 这张票没带上 / 过期了。页面要按它给「去登录」，不能说成「没连上服务器」。
        let needLogin: Bool
        init(_ m: String, needLogin: Bool = false) {
            message = m
            self.needLogin = needLogin
        }
        var errorDescription: String? { message }
    }

    /// ★★★ 2026-10-25：401 / 403 **必须**说成「要重新登录」，不能说成「没连上服务器」。
    ///   他拿到的反馈一直是「没连上服务器」—— 可服务器好好在那儿，是**不认他这张票**。
    ///   这两件事的补救办法完全不同（一个是等，一个是去登录），说错了就把人往错路上引。
    static func 台子回错了(_ code: Int, _ data: Data) -> LabError {
        if code == 401 || code == 403 {
            return LabError("登录过期了 —— 重新登录一下就好", needLogin: true)
        }
        return LabError("服务器回的是 HTTP \(code)：\(snip(data))")
    }

    private static func get<T: Decodable>(_ path: String) async throws -> T {
        try await get(absURL: URL(string: base + path)!)
    }

    /// 台子那些「做完一件事、回一句话」的接口（删角色 / 放回来）共用的回包。
    /// ★ 键是中文的：`说` = 成功那句，`错误` = 失败那句。
    private struct SayResp: Decodable {
        let ok: Bool?
        let say: String?
        let why: String?
        enum CodingKeys: String, CodingKey {
            case ok
            case say = "说"
            case why = "错误"
        }
    }

    /// POST 一个「只回一句话」的动作。
    /// ★ 台子拒绝时回的是 **409 + 中文原因**（比如「还有 2 条在做」）。
    ///   这里要把它原样当人话抛出去 —— 不然用户只看到一串 JSON。
    private static func postSay(_ path: String, query: [URLQueryItem]) async throws -> String {
        var comp = URLComponents(string: base + path)!
        comp.queryItems = query
        var req = URLRequest(url: comp.url!)
        req.stillStamp()      // ★ 登录制：贴票
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let r = try? JSONDecoder().decode(SayResp.self, from: data)
        if let r, r.ok == true { return r.say ?? "" }
        if let w = r?.why, !w.isEmpty { throw LabError(w) }
        guard let http = resp as? HTTPURLResponse else { throw LabError("没接到服务器的回话") }
        throw 台子回错了(http.statusCode, data)
    }

    private static func get<T: Decodable>(absURL: URL) async throws -> T {
        var req = URLRequest(url: absURL)
        req.stillStamp()      // ★ 登录制：贴票
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw LabError("没接到服务器的回话") }
        guard (200..<300).contains(http.statusCode) else {
            throw 台子回错了(http.statusCode, data)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func snip(_ d: Data) -> String {
        let s = String(data: d.prefix(160), encoding: .utf8) ?? ""
        return s.isEmpty ? "（没有正文）" : s
    }
}
