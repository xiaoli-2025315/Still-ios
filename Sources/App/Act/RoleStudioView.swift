import SwiftUI
import UIKit
import ImageIO

// MARK: - 生产页
//
// ★★★ 2026-10-23（他定的新链路，iOS 照着安卓重写一遍）：
//
//   进来中间只有**一个大框，只做坐立** —— 转着圈、底下写着做到百分之几。
//   坐立一好，成片就放出来给他看，底下出现「确认，继续做其它动作」。
//   **他点了，别的动作才一格一格冒出来**（比坐立那个小），每格自己转圈、好了换成动图。
//   全套好了 ⇒ 进完成页。
//
//   随时退出去再进来：进度都在机器上，接着看就行 —— 任务号按角色存在手机里。
//
// ★ 这套判断跟安卓 `RoleStudioActivity` **一条一条对齐**，两边不能各判各的：
//   ① 先在「我这些趟」里找这只猫的那一趟（正在跑 → 排着 → 最近）；
//   ② 一条都没有 ⇒ 看动作墙上已经有什么：有 sit 就是做好了、有别的就直接进第二批；
//      什么都没有 ⇒ 下一单只做坐立。
//   ③ 坐立好了但不点确认，就一直停在那儿等 —— 不替他做决定。

// MARK: - 台子给的透明动图
//
/// SwiftUI 的 `Image` 拿到 GIF 只会画第一帧。这里把它拆成帧自己播。
/// 台子那边给的是 `/assets/acts/<角色>/<动作>.gif`，透明底。
final class GifBox: ObservableObject {

    @Published var img: UIImage?

    private var frames: [UIImage] = []
    private var idx = 0
    private var timer: Timer?
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
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        task = URLSession.shared.dataTask(with: req) { [weak self] d, _, _ in
            guard let d, let src = CGImageSourceCreateWithData(d as CFData, nil) else { return }
            var out: [UIImage] = []
            let n = min(CGImageSourceGetCount(src), self?.cap ?? 90)
            for i in 0..<n {
                if let cg = CGImageSourceCreateImageAtIndex(src, i, nil) {
                    out.append(UIImage(cgImage: cg))
                }
            }
            guard !out.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, self.now == key else { return }
                self.frames = out
                self.idx = 0
                self.img = out[0]
                self.play()
            }
        }
        task?.resume()
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
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
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

struct RingProgress: View {

    var pct: Int
    var size: CGFloat = 92
    var line: CGFloat = 9

    var body: some View {
        ZStack {
            Circle()
                .stroke(Tw.gray200, lineWidth: line)
            Circle()
                .trim(from: 0, to: max(0.015, min(1, Double(pct) / 100)))
                .stroke(Tw.red600,
                        style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.55), value: pct)
            VStack(spacing: 0) {
                Text("\(pct)")
                    .font(.system(size: size * 0.26, weight: .bold, design: .rounded))
                    .foregroundStyle(Tw.gray900)
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: size * 0.13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Tw.gray400)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 这一趟的账

@MainActor
final class StudioModel: ObservableObject {

    let charId: String
    let charName: String

    @Published var note = ""
    @Published var err = ""

    @Published var sitPct = 0
    /// 坐立**整条走完**了：生成 → 抠图 → 抽帧回来、手机真能播。
    /// ★ 只有它为真，才放行「确认，继续做其它动作」。
    @Published var sitReady = false
    /// 台子说抠好了、正在把片子取回来（这时候框里还是加载态，不许亮「好了」）
    @Published var sitFetching = false
    /// 现在在等什么（排队／机器忙／没接活）—— 直接显示给他看，别让他以为坏了
    @Published var wait = ""
    @Published var stage2 = false
    @Published var allDone = false
    @Published var leftover = 0
    @Published var pendingCount = 0
    /// 每条动作各到哪了（只有第二阶段才画格子）
    @Published var pct: [String: Int] = [:]
    @Published var done: Set<String> = []

    private var jobId = ""
    private var alive = true
    /// 下单这段时间别再问「要不要下单」—— 不然一秒下一单。
    private var quietUntil = Date.distantPast
    private var lookedAtWall = false

    /// ★ 从动作库「接着做剩下的 N 个」进来：坐立早有了，别再摆一遍等坐立那一屏
    let skipToStage2: Bool

    init(char: ActLab.Char, skipToStage2: Bool = false) {
        charId = char.id
        charName = char.title
        self.skipToStage2 = skipToStage2
        jobId = UserDefaults.standard.string(forKey: "still.genjob." + char.id) ?? ""
    }

    func stop() { alive = false }

    /// 2.2 秒看一眼机器。★ 安卓也是这个节奏，两边看到的东西才对得上。
    func loop() async {
        while alive {
            await tick()
            try? await Task.sleep(nanoseconds: 2_200_000_000)
        }
    }

    func tick() async {
        guard alive else { return }
        do {
            let mine = try await ActLab.genMine()
            if let j = mine.of(charId) {
                apply(j)
            } else if !lookedAtWall || Date() > quietUntil {
                await autoStart()
            }
        } catch {
            // 断网、台子睡着 —— 等下一轮，别把红字糊到脸上
        }
    }

    /// 这一只猫在后台**已经有一趟在跑、或者排在队里**。
    ///
    /// ★★★ 2026-10-23（他原话，归成「下单回执」这一类）：
    ///   「我点击一次这个按钮之后，他确实出现了制作没错，但当我退出了这个页面之后，
    ///     他就消失了…后厨已经在做了，但我验证他做的方式却是要在下一单」。
    ///   ⇒ 进制作页时，只要这只猫已经有一趟，就不许再下一单。
    private func hasRunningBatch() async -> Bool {
        guard let m = try? await ActLab.genMine() else { return false }
        for list in [m.当前, m.队列] {
            for j in list ?? [] where j.char == charId { return true }
        }
        return false
    }

    /// 机器上没有这一趟 ⇒ 看动作墙上已经做到哪儿了，决定「下一批坐立」还是「直接进第二阶段」。
    private func autoStart() async {        if Date() < quietUntil { return }
        lookedAtWall = true
        quietUntil = Date().addingTimeInterval(5)

        // ★ 从「接着做剩下的 N 个」进来 ⇒ 直接进第二半，坐立那一屏不再走一遍
        if skipToStage2 && !stage2 {
            stage2 = true
            await prefetchSit()
            // ★★★ 2026-10-23（「下单回执」）：这一只**已经在跑/在排**了，就只挂进度，
            //   绝不再下一单 —— 他退出去再进来一次，以前等于又下一单，
            //   而他根本没法知道上一单到底开没开工。
            if await hasRunningBatch() {
                note = "这一批已经在做了，不用再点"
                return
            }
            await order("")
            return
        }

        var hasSit = false
        var have = 0
        if let m = try? await ActLab.manifest(charId: charId) {
            have = m.names.count
            hasSit = m.names.contains("sit")
        }
        if hasSit {
            // ★★★ 2026-10-23（他点名的）：**第一页就干一件事 —— 等坐立真的走完**。
            //   台子上有 ≠ 手机能播：还得取回来、解得开才算。
            //   ★ 别的动作已经有一些了，也**不许自动进第二阶段** ——
            //     必须他亲自点「确认」。
            _ = have
            note = "正在把坐立接回来…"
            await prefetchSit()
            return
        }
        await order("sit")
    }

    /// 坐立成片在台子上的地址（跟大框里放的是**同一条**，别下两遍）。
    /// ★ 宽度跟大框里那张**用同一档**（520）—— 不然要下一遍两份。
    private var sitURL: URL? { GifView.makeURL(charId, "sit", width: 520) }

    /// 台子说「抠好了」不等于手机能播 —— 真的取回来、解得出帧，才算这一条做好了。
    func prefetchSit() async {
        if sitReady || sitFetching { return }
        sitFetching = true
        defer { sitFetching = false }
        guard let u = sitURL else { return }
        guard let (d, _) = try? await URLSession.shared.data(from: u),
              let src = CGImageSourceCreateWithData(d as CFData, nil),
              CGImageSourceGetCount(src) > 0 else { return }
        sitReady = true
        note = ""
    }

    /// 下一单。`action` 留空 = 词库全做（机器自己会跳过已经有的）。
    func order(_ action: String) async {
        if Date() < quietUntil { return }
        quietUntil = Date().addingTimeInterval(8)
        note = action.isEmpty ? "正在安排其它动作…" : "正在安排「坐立」…"
        do {
            let r = try await ActLab.genStart(charId: charId, action: action)
            jobId = r.job
            UserDefaults.standard.set(r.job, forKey: "still.genjob." + charId)
            note = ""
            quietUntil = .distantPast
        } catch {
            note = ""
            err = "还没安排好：" + error.localizedDescription
            // ★ 失败就歇 8 秒再试 —— 不连点（连点会把豆包额度白烧掉，10-23 出过事）
            quietUntil = Date().addingTimeInterval(8)
        }
    }

    /// 他点了「确认，继续做其它动作」。
    func confirmRest() async {
        stage2 = true
        await order("")
    }

    /// 第一批没做完、或者还有剩：接着做下一批。
    func nextBatch() async {
        await order("")
    }

    // MARK: 把机器的进度画上去

    /// 还没开工的时候，告诉用户「在等什么」—— 他原话：
    /// 「因为他正在排队但用户不知道…这样用户才不会感觉我们的APP坏了或者很慢」。
    private func waitLine(_ j: ActLab.GenJob) -> String {
        guard j.queued == true else { return "" }
        // ★ 闸门那行原因（"不是本人下单，先止血"那种）是给机器自己看的，不该糊到用户脸上。
        if j.gateOff == true {
            return "机器这会儿没接活 —— 你的单已经排上了，一开就做"
        }
        let ahead = j.ahead ?? 0
        if ahead > 0 { return "前面还有 \(ahead) 条在做 —— 轮到它就自动开始" }
        if j.busy == true { return "机器正忙着别的角色 —— 一空出来就轮到它" }
        return "排上队了，马上开始"
    }

    private func apply(_ j: ActLab.GenJob) {
        // ★ 第二阶段里，「只做过坐立」的那条旧单还挂在「最近」里 —— 它永远写着全完成，
        //   会把这一页骗成「整套都好了」。这种单一律不认。
        if stage2, let e = j.each, e.count == 1, (e[0].act ?? "") == "sit" { return }

        err = ""
        wait = waitLine(j)
        if !wait.isEmpty { note = wait }

        let each = j.each ?? []
        var sitMatte = false
        var doneN = 0
        for s in each {
            let act = s.act ?? ""
            if s.matteDone { doneN += 1 }
            if act == "sit" {
                if s.matteDone { sitMatte = true; sitPct = 100 }
                else if j.queued != true {
                    let p = s.pct ?? 0
                    if p > 0 { sitPct = max(sitPct, p) }
                    // ★ 生成阶段台子没有百分比：让它一点点往前走（最多 90），
                    //   别死停在 0 让人以为卡死了。
                    else { sitPct = min(90, sitPct + 2) }
                }
                continue
            }
            if s.matteDone {
                done.insert(act)
                pct[act] = 100
            } else {
                pct[act] = s.pct ?? 0
            }
        }

        // ★ 抠好了 ⇒ 去把片子接回来；**接到能播**才算做好（见 prefetchSit）。
        //   注意别在这里先把 sitFetching 设成 true —— prefetchSit 开头就拿它当闸门。
        if sitMatte && !sitReady {
            Task { await prefetchSit() }
        }

        let fin = (j.allDone == true) || (j.matteAllDone == true)
        if stage2 {
            leftover = (j.leftover ?? []).count
            allDone = fin && leftover == 0
        }
        pendingCount = (j.pending ?? []).count
    }

    /// 动作墙上已经做好了哪些（重进页面时，格子不至于全是空转圈）
    func syncWall() async {
        guard let m = try? await ActLab.manifest(charId: charId) else { return }
        for n in m.names where n != "sit" {
            done.insert(n)
            pct[n] = 100
        }
        // ★ 墙上有坐立 ≠ 手机能播 —— 还是走同一条「取回来、解得开」的判定
        if m.names.contains("sit") { await prefetchSit() }
    }

    /// 这一批里有几条已经做好了（分母用的是词库条数，别写死数字）
    var doneCount: Int { done.count + (sitReady ? 1 : 0) }
}

// MARK: - 页面

struct RoleStudioView: View {

    let char: ActLab.Char

    @Environment(\.dismiss) private var dismiss
    @StateObject private var m: StudioModel
    /// 全套好了 ⇒ 完成页（就在这一页上面叠着开，关掉还回得来）
    @State private var showHome = false

    init(char: ActLab.Char, stage2: Bool = false) {
        self.char = char
        _m = StateObject(wrappedValue: StudioModel(char: char, skipToStage2: stage2))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 12) {
                    hero
                    if !m.err.isEmpty {
                        Text(m.err)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Tw.red600)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if m.stage2 { grid }
                    if let tail = tailCard { tail }
                    Spacer(minLength: 16)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            bottomBar
        }
        .background(Tw.gray50.ignoresSafeArea())
        .task {
            await m.syncWall()
            await m.loop()
        }
        .onDisappear { m.stop() }
        .sheet(isPresented: $showHome) {
            RoleHomeView(char: char, showcase: true)
                .presentationDetents([.large])
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tw.gray500)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Tw.gray100))
            }
            .buttonStyle(PressStyle(scale: 0.9))

            VStack(alignment: .leading, spacing: 1) {
                Text("给「\(char.title)」做动作")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Tw.gray900)
                Text(subLine)
                    .font(.system(size: 11))
                    .foregroundStyle(Tw.gray400)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var subLine: String {
        if m.allDone { return "整套都做好了" }
        if m.stage2 {
            return m.leftover > 0
                ? "这一批好了，还有 \(m.leftover) 段没做"
                : "其它动作正在做（\(m.doneCount)/\(ActLab.total)）"
        }
        if m.sitReady { return "坐立好了，等你确认" }
        if !m.note.isEmpty { return m.note }
        return "先做坐立 · 做好了再问你"
    }

    // MARK: 中间那个大框 —— 先只做坐立

    private var hero: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(m.sitReady ? Tw.gray100 : Tw.gray100)

            if m.sitReady {
                GifView(url: GifView.makeURL(m.charId, "sit", width: 520))
                    .padding(10)
                    .transition(.opacity)
                VStack {
                    HStack {
                        Text("坐立 · 好了")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Tw.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Tw.green500))
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
            } else {
                VStack(spacing: 12) {
                    RingProgress(pct: m.sitPct)
                    Text("坐立")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tw.gray900)
                    Text(m.sitFetching ? "做好了，正在把它接回来…"
                         : (m.note.isEmpty ? "机器正在画 · 画好这一条再来问你" : m.note))
                        .font(.system(size: 11))
                        .foregroundStyle(Tw.gray400)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                }
            }
        }
        .frame(height: 320)
        .animation(.easeOut(duration: 0.3), value: m.sitReady)
    }

    // MARK: 确认之后，别的动作一格一格冒出来

    private var grid: some View {
        let rest = ActLab.official.filter { $0.key != "sit" }
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                   GridItem(.flexible(), spacing: 10)],
                         spacing: 10) {
            ForEach(Array(rest.enumerated()), id: \.element.key) { i, a in
                cell(a.key, a.label)
                    .transition(.opacity.combined(with: .offset(y: 14)))
                    .animation(.easeOut(duration: 0.32).delay(Double(i) * 0.05),
                               value: m.stage2)
            }
        }
    }

    private func cell(_ key: String, _ label: String) -> some View {
        let ok = m.done.contains(key)
        let p = m.pct[key] ?? 0
        return ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Tw.gray100)
            if ok {
                GifView(url: GifView.makeURL(m.charId, key, width: 260))
                    .padding(6)
            } else {
                VStack(spacing: 7) {
                    RingProgress(pct: p, size: 54, line: 6)
                    Text("正在做")
                        .font(.system(size: 10))
                        .foregroundStyle(Tw.gray400)
                }
            }
            VStack {
                Spacer(minLength: 0)
                HStack {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ok ? Tw.gray900 : Tw.gray500)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Tw.white.opacity(ok ? 0.86 : 0.6)))
                    Spacer(minLength: 0)
                }
                .padding(7)
            }
        }
        .aspectRatio(1.35, contentMode: .fit)
        .animation(.easeOut(duration: 0.25), value: ok)
    }

    // MARK: 底下那张卡（确认 / 接着做 / 进去看看）

    private var tailCard: AnyView? {
        if m.pendingCount > 0 {
            return AnyView(card(
                title: "有 \(m.pendingCount) 条做不出来",
                desc: "已经做好的那些随时能用。差的这几条，进动作库那边会问你怎么处置。"))
        }
        if m.allDone {
            return AnyView(card(
                title: "整套都做好了",
                desc: "\(ActLab.total) 条动作都在它身上了，进去看看。"))
        }
        if m.stage2 && m.leftover > 0 {
            return AnyView(card(
                title: "这一批好了，还有 \(m.leftover) 段没做",
                desc: "机器一趟只做一半，剩下的接着做就行 —— 做好的不会重画，不白花额度。"))
        }
        if m.sitReady && !m.stage2 {
            return AnyView(card(
                title: "坐立好了，你看一眼",
                desc: "上面这段就是它坐着的样子。行的话点下面，我把别的动作也做出来 —— 每一条都会长出来给你看。"))
        }
        return nil
    }

    private func card(title: String, desc: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(Tw.gray900)
            Text(desc)
                .font(.system(size: 11.5))
                .foregroundStyle(Tw.gray500)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Tw.white))
    }

    // MARK: 最底下那颗主键

    private var bottomBar: some View {
        Group {
            if m.allDone {
                Button { showHome = true } label: { bigLabel("下一步：进去看看它") }
                    .buttonStyle(PressStyle())
            } else if m.stage2 && m.leftover > 0 && !m.note.isEmpty {
                bigLabel(m.note).opacity(0.6)
            } else if m.sitReady && !m.stage2 {
                Button { Task { await m.confirmRest() } } label: {
                    bigLabel("确认，继续做其它动作")
                }
                .buttonStyle(PressStyle())
            } else {
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private func bigLabel(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Tw.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Tw.red600))
    }
}
