import SwiftUI

// MARK: - 做动作：进度这一页
//
// 安卓那边是三件套一起给的：
//   ① 一颗大数字 + 一条大进度条（一进页面就在，3 秒刷一次）
//   ② 每一条动作一行字：排着队 / 已发给豆包正在画 / 画好了正送进台子 / 已经拿回来了
//   ③ 收尾三档：重新收一遍（不花额度）/ 接着做下一批 / 重做一遍
// 这一页就是把这三件套补齐 —— 以前 iOS 上只有动作墙底下那一行小字。
//
// ★ 任务号存在手机里（按角色存）：退出去了再进来，还在盯着同一趟，不会以为「没这回事」。

@MainActor
final class GenModel: ObservableObject {

    let charId: String

    @Published var job = ""
    @Published var state: ActLab.GenJob?
    @Published var busy = false
    @Published var note = ""
    @Published var err: String?

    init(charId: String) {
        self.charId = charId
        job = UserDefaults.standard.string(forKey: Self.key(charId)) ?? ""
    }

    static func key(_ id: String) -> String { "still.genjob." + id }

    private func remember(_ j: String) {
        job = j
        if j.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.key(charId))
        } else {
            UserDefaults.standard.set(j, forKey: Self.key(charId))
        }
    }

    /// 进度条该画多少（0…1）。停了的趟画满 —— 它已经结束了，不该停在 1%。
    var bar: Double { state?.barValue ?? 0 }

    /// 那颗大数字。不是真在跑的时候不显示百分比（1% 那个坑就在这儿）。
    var bigNumber: String {
        guard let s = state else { return "—" }
        if s.isDone { return "100%" }
        if s.stopped { return "已停" }
        if let p = s.progress, p > 1 { return "\(p)%" }
        return "…"
    }

    var headline: String {
        if !note.isEmpty { return note }
        if let s = state { return s.line }
        // ★ v93：以前这里写「点下面的『做整套』或『重做一遍』」—— 这一页根本没有「做整套」
        //   这颗键（只有 重新收一遍 / 接着做下一批 / 重做一遍 / 停这一次）⇒ 点了没处点。
        //   改成一句**真的有出路**的话。
        if job.isEmpty { return "还没做。点下面的键就能开始。" }
        return "正在问服务器…（问不通会一直自己再问）"
    }

    func poll() async {
        guard !job.isEmpty else { return }
        do {
            let s = try await ActLab.genState(job: job)
            state = s
            err = nil
            if s.isDone || s.isBad {
                // 收尾了就把它记下来，但任务号留着 —— 还能「重新收一遍」
                remember(job)
            }
        } catch {
            let msg = error.localizedDescription
            // 台子重启后老任务号会 404：别一直转圈，直说
            if msg.contains("404") || msg.contains("没这个任务") {
                remember("")
                state = nil
                err = "这一趟服务器上已经没有了（机器重启过）。已经在墙上的那些不受影响。"
            } else {
                err = msg
            }
        }
    }

    func start(replace: Bool) async {
        busy = true
        err = nil
        note = replace ? "正在下单重做…" : "正在下单…"
        do {
            let r = try await ActLab.genStart(charId: charId, replace: replace)
            remember(r.job)
            state = ActLab.GenJob.stub(stage: "下单了，服务器正在排队（\(r.acts.count) 条）")
            note = ""
        } catch {
            note = ""
            err = "没做起来：\(error.localizedDescription)"
        }
        busy = false
    }

    func stopNow() async {
        guard !job.isEmpty else { return }
        busy = true
        do {
            note = try await ActLab.genStop(job: job)
            await poll()
        } catch {
            err = error.localizedDescription
        }
        busy = false
    }

    func refetch() async {
        busy = true
        err = nil
        do {
            note = try await ActLab.genRefetch(charId: charId)
            await poll()
        } catch {
            err = "没收到：\(error.localizedDescription)"
        }
        busy = false
    }

    /// ★ 2026-10-23（他要的）：那些做不出来的条，**由他说了算** ——
    ///   `明天自动`＝明天额度刷新了机器自己补上；`放弃`＝这条以后不再提。
    func decide(_ 选: String) async {
        guard !job.isEmpty else { return }
        busy = true
        err = nil
        do {
            note = try await ActLab.genDecide(job: job, 选: 选)
            await poll()
        } catch {
            err = "没办成：\(error.localizedDescription)"
        }
        busy = false
    }
}

@MainActor
struct GenProgressPage: View {

    let char: ActLab.Char
    /// 做完 / 收完 → 让动作墙重下一遍包
    var onChanged: () async -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: GenModel
    @State private var askReplace = false

    init(char: ActLab.Char, onChanged: @escaping () async -> Void = {}) {
        self.char = char
        self.onChanged = onChanged
        _model = StateObject(wrappedValue: GenModel(charId: char.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 14) {
                    bigCard
                    if let s = model.state, let each = s.each, !each.isEmpty {
                        eachCard(each)
                    }
                    // ★ 2026-10-23：有做不出来的条 ⇒ 停在这儿等他一句话（不再一直转圈）
                    if let pd = model.state?.pending, !pd.isEmpty {
                        decideCard(pd)
                    }
                    if let e = model.err {
                        Text(e)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Tw.red600)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    tailCard
                    Spacer(minLength: 10)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 20)
            }
            buttons
        }
        .background(Tw.gray50.ignoresSafeArea())
        .task {
            await model.poll()
            await loop()
        }
        .confirmationDialog("重做一遍？", isPresented: $askReplace, titleVisibility: .visible) {
            Button("重做（会花豆包额度）") {
                Task {
                    await model.start(replace: true)
                    await onChanged()
                }
            }
            Button("先不做", role: .cancel) {}
        } message: {
            // ★ v93：以前这里提「修一下」—— 整个 App 都没有这颗键，指了等于没指。
            Text("服务器会按那套动作清单把动作重新画一遍，然后重新把背景去掉。"
                 + "这一步花的是你豆包账号的额度 —— 只是想补几条的话，点「接着做下一批」更省。")
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
                Text("退出去也接着做 · 回来看还在这儿")
                    .font(.system(size: 11))
                    .foregroundStyle(Tw.gray400)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    // MARK: 大数字 + 大进度条
    //
    // ★ 这两样必须在页面上**一进来就看见** —— 他要的就是「制作进度条能一直显示」。

    private var bigCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.bigNumber)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(model.state?.isBad == true ? Tw.red600 : Tw.gray900)
                    .monospacedDigit()
                Spacer(minLength: 0)
                if model.busy {
                    ProgressView().scaleEffect(0.8)
                }
            }

            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Tw.gray200)
                    Capsule()
                        .fill(model.state?.isBad == true ? Tw.gray400 : Tw.red600)
                        .frame(width: max(6, g.size.width * CGFloat(model.bar)))
                }
            }
            .frame(height: 8)

            Text(model.headline)
                .font(.system(size: 12))
                .foregroundStyle(Tw.gray600)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Tw.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Tw.gray200, lineWidth: 1)
                )
        )
    }

    // MARK: 每一条一行

    private func eachCard(_ each: [ActLab.GenJob.GenSeg]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("每一条动作")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tw.gray500)
                .padding(.bottom, 8)

            ForEach(Array(each.enumerated()), id: \.offset) { pair in
                let i = pair.offset
                let s = pair.element
                HStack(spacing: 8) {
                    Text(displayName(s.act ?? ""))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Tw.gray900)
                        .frame(width: 74, alignment: .leading)
                    Text(s.line)
                        .font(.system(size: 11))
                        .foregroundStyle(colour(s))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if s.matteDone {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Tw.green500)
                    }
                }
                .padding(.vertical, 7)

                if i < each.count - 1 {
                    Rectangle().fill(Tw.gray100).frame(height: 0.6)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Tw.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Tw.gray200, lineWidth: 1)
                )
        )
    }

    private func colour(_ s: ActLab.GenJob.GenSeg) -> Color {
        if s.matteDone { return Tw.green500 }
        if s.stage?.contains("卡在豆包") == true { return Tw.red600 }
        if s.saved { return Tw.gray600 }
        return Tw.gray500
    }

    private func displayName(_ key: String) -> String {
        ActLab.official.first(where: { $0.key == key })?.label ?? key
    }

    // MARK: 收尾

    private var tailCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let r = model.state?.redo, !r.isEmpty {
                Text("这 \(r.count) 条豆包那边已经画好了，只是没捡回来：\(r.map(displayName).joined(separator: "、"))")
                    .font(.system(size: 11))
                    .foregroundStyle(Tw.gray500)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let l = model.state?.leftover, !l.isEmpty {
                Text("还有 \(l.count) 条留在下一批：\(l.map(displayName).joined(separator: "、"))")
                    .font(.system(size: 11))
                    .foregroundStyle(Tw.gray500)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("做动作花的是你豆包账号的额度。去掉背景不花额度。")
                .font(.system(size: 10.5))
                .foregroundStyle(Tw.gray400)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var buttons: some View {
        VStack(spacing: 8) {
            let canRedo = !(model.state?.redo ?? []).isEmpty
            let canNext = !(model.state?.leftover ?? []).isEmpty
            let running = !(model.state?.stopped ?? true) && !model.job.isEmpty

            HStack(spacing: 8) {
                Button {
                    Task {
                        await model.refetch()
                        await onChanged()
                    }
                } label: {
                    pill("重新收一遍", on: canRedo, busy: model.busy)
                }
                .buttonStyle(PressStyle())
                .disabled(model.busy)

                Button {
                    Task {
                        await model.start(replace: false)
                        await onChanged()
                    }
                } label: {
                    pill(canNext ? "接着做下一批（还有 \(model.state?.leftover?.count ?? 0) 段）" : "接着做下一批",
                         on: canNext, busy: model.busy)
                }
                .buttonStyle(PressStyle())
                .disabled(model.busy)
            }

            HStack(spacing: 8) {
                Button {
                    askReplace = true
                } label: {
                    pill("重做一遍", on: false, busy: false)
                }
                .buttonStyle(PressStyle())
                .disabled(model.busy)

                Button {
                    Task { await model.stopNow() }
                } label: {
                    pill(running ? "停这一次" : "已经停了", on: false, busy: model.busy)
                }
                .buttonStyle(PressStyle())
                .disabled(model.busy || !running || model.job.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Tw.white.overlay(alignment: .top) {
            Rectangle().fill(Tw.gray200).frame(height: 0.5)
        })
    }

    /// ★ 2026-10-23（他要的）：**做不出来那几段的处置卡** —— 两颗键，他说了算。
    ///   以前这些段只会让整趟一直挂着"还在跑"，永远不收尾。
    private func decideCard(_ list: [ActLab.GenJob.Pending]) -> some View {
        let why = list.compactMap { $0.why }.first ?? ""
        return VStack(alignment: .leading, spacing: 10) {
            Text("有 \(list.count) 段没做出来")
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(Tw.gray900)
            if !why.isEmpty {
                Text(why)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tw.gray500)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // ★ v93：以前写「在墙上随时能用」—— 这一页没有通往墙的键，是句空话。
            //   改成说清楚**做好的还在、差的在这儿就能定**。
            Text("已经做好的那几个都还在，不受影响。差的这几段你说了算：")
                .font(.system(size: 11.5))
                .foregroundStyle(Tw.gray500)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { Task { await model.decide("明天自动") } } label: {
                    pill("明天有额度了自动做", on: true, busy: model.busy)
                }
                .buttonStyle(PressStyle())
                .disabled(model.busy)

                Button { Task { await model.decide("放弃") } } label: {
                    pill("这段不要了", on: false, busy: model.busy)
                }
                .buttonStyle(PressStyle())
                .disabled(model.busy)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Tw.white)
        )
    }

    private func pill(_ text: String, on: Bool, busy: Bool) -> some View {
        HStack(spacing: 6) {
            if busy { ProgressView().scaleEffect(0.55) }
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(on ? Tw.white : Tw.gray900)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(on ? Tw.red600 : Tw.gray100)
        )
    }

    /// 3 秒问一次。停在后台就自己结束了（页面关了 Task 取消）。
    private func loop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            await model.poll()
        }
    }
}
