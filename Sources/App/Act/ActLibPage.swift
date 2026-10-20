import CoreTransferable
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 角色（动作库）
//
// 安卓那边这一页是 `RoleActivity` 右上角「＋」进来的 `ActActivity`：
// 上面一张卡一只它，卡上写着这套动作好了几条；右上「＋」登记新角色。
//
// ★ 这一版只搬「看 + 登记」两件事。
//   动作视频上传（自己传 mp4 让台子抠像）和「装到手机上用」还没搬 ——
//   那两条各自都要一版，不在这一版里掺着做。

@MainActor
final class ActLibModel: ObservableObject {
    @Published var chars: [ActLab.Char] = []
    @Published var loading = false
    @Published var err: String?
    @Published var loadedOnce = false

    func load() async {
        guard !loading else { return }
        loading = true
        err = nil
        do {
            chars = try await ActLab.chars()
            loadedOnce = true
        } catch {
            err = "没取上台子：\(error.localizedDescription)"
        }
        loading = false
    }
}

// ★ @MainActor 必须标在 View 上：`@StateObject private var model = ActLibModel()`
//   这个默认值是在 View 的 init 里求值的，而 ActLibModel 是主线程隔离的 ——
//   不标，CI 就会报 "call to main actor-isolated initializer in a synchronous
//   nonisolated context"。v37/v38 都在这条上崩过一次。
@MainActor
struct ActLibPage: View {

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ActLibModel()
    /// 装了哪只、正在用哪只 —— 列表上要标出来
    @ObservedObject private var store = CatPackStore.shared

    @State private var showNew = false
    @State private var watching: ActLab.Char?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("一张卡一只它 · 点开能看每条动作，还能换到小窗里用它")
                        .font(.system(size: 11))
                        .foregroundStyle(Tw.gray500)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 14)

                    if let e = model.err {
                        errCard(e)
                    }

                    if model.chars.isEmpty && model.loading {
                        loadingRow
                    }

                    ForEach(model.chars) { c in
                        Button {
                            watching = c
                        } label: {
                            charCard(c)
                        }
                        .buttonStyle(PressStyle())
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                    }

                    if model.loadedOnce && model.chars.isEmpty && model.err == nil {
                        Text("台子上还没有角色。右上角「＋」登记一只。")
                            .font(.system(size: 12))
                            .foregroundStyle(Tw.gray400)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                    }

                    Spacer(minLength: 30)
                }
                .padding(.top, 4)
            }
            .refreshable { await model.load() }
        }
        .background(Tw.gray50.ignoresSafeArea())
        .task { await model.load() }
        .sheet(isPresented: $showNew) {
            NewRoleSheet { c in
                await model.load()
                guard let c else { return }
                // ★ 登记完直接把这只的动作墙打开 —— 他的原话是
                //   「在 APP 上直接制作新的一个角色并可以取回来使用」，
                //   所以「建完就接着做」这一步不该让他自己再点一次。
                //   等半秒是为了让上面这张表先收干净，两张表同时开会互相吃掉。
                try? await Task.sleep(nanoseconds: 600_000_000)
                watching = c
            }
            .presentationDetents([.large])
        }
        .sheet(item: $watching) { c in
            ActWallSheet(char: c) { await model.load() }
                .presentationDetents([.large])
        }
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tw.gray900)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Tw.gray100))
            }
            .buttonStyle(PressStyle(scale: 0.9))

            Text("角色")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Tw.gray900)

            Spacer(minLength: 8)

            Button {
                showNew = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Tw.gray900)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Tw.gray100))
            }
            .buttonStyle(PressStyle(scale: 0.9))
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    // MARK: - 一张卡

    private func charCard(_ c: ActLab.Char) -> some View {
        HStack(spacing: 13) {
            avatar(c)

            VStack(alignment: .leading, spacing: 4) {
                Text(c.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Tw.gray900)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if store.isCurrent(c.id) {
                        Text("正在用")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Tw.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Tw.red600))
                    }
                    Text(chanLabel(c))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(c.isPaid ? Tw.red600 : Tw.gray500)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(c.isPaid ? Tw.red600.opacity(0.10) : Tw.gray100)
                        )

                    Text("\(c.doneCount)/12 条动作好了")
                        .font(.system(size: 11))
                        .foregroundStyle(c.doneCount >= 12 ? Tw.green500 : Tw.gray500)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tw.gray300)
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Tw.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Tw.gray200, lineWidth: 1)
                )
        )
    }

    /// 通道标签：台子上有三种值 —— official（台子自带样板）/ free / paid。
    /// 一开始只写了「免费/付费」，样板猫就被标成「免费 · 12/12 条」，看着像用户自己传的。
    private func chanLabel(_ c: ActLab.Char) -> String {
        switch (c.channel ?? "free") {
        case "official": return "官方"
        case "paid":     return "付费"
        default:         return "免费"
        }
    }

    private func avatar(_ c: ActLab.Char) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Tw.gray100)
                .frame(width: 56, height: 56)

            if let u = c.imgURL {
                AsyncImage(url: u) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                    } else {
                        Image(systemName: "cat.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Tw.gray400)
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Image(systemName: "cat.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Tw.gray400)
            }
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.8)
            Text("正在从台子上取…")
                .font(.system(size: 12))
                .foregroundStyle(Tw.gray500)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
    }

    private func errCard(_ e: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(e)
                .font(.system(size: 12))
                .foregroundStyle(Tw.red600)
                .fixedSize(horizontal: false, vertical: true)
            Button("再试一次") {
                Task { await model.load() }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Tw.red600)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Tw.red600.opacity(0.06))
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }
}

// MARK: - 一只的动作墙
//
// ★ 这一版起，格子是**能点的**：点开就播那一条动作（真帧）。
//   前一版这里是纯 VStack，看着像列表、点着没反应 —— 也就是他说的
//   「只能看不能点、没有用它的通道」。
//
// ★ 数据从「整只猫的动作包」来（一次下一个 zip，43–63MB），
//   不下单条：台子的清单行里没有单条的任务号，拿不到单条包。
//   下完以后这条包同时也是「用它」要装的东西，一次下、两处用。

@MainActor
struct ActWallSheet: View {

    let char: ActLab.Char
    /// 装完 / 换走之后叫一声，让外面的列表刷新「正在用」那行
    var onChanged: () async -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = CatPackStore.shared

    @State private var pack: CatPack?
    @State private var loading = false
    @State private var err: String?
    @State private var previewing: ActPreview?
    @State private var using = false

    // MARK: 制作这条链要用的状态
    //
    // ★ 这一版把「自己做一只新角色」整条接上了。两条路各一个按钮：
    //   ① 免费通道：从相册选一段动作视频传上去，台子抠像
    //   ② 付费通道：一句话让台子按词库把 12 条各做一条（花豆包额度）
    //   两条都常驻显示 —— 不按「有没有东西」藏按钮（他从来找不到藏起来的入口）。

    /// 刚从相册选的那段视频
    @State private var videoItem: PhotosPickerItem?
    /// 正在上传 / 刚传完那句话
    @State private var upNote = ""
    @State private var upBusy = false
    /// 正在盯着的抠像任务
    @State private var actJobs: [ActLab.Job] = []
    /// 正在盯着的生成任务
    @State private var genJob = ""
    @State private var genState: ActLab.GenJob?
    @State private var genBusy = false
    /// 台子上现在好了几条（跟手机里那份比对，判断要不要更新）
    @State private var labDone = 0
    /// 点「一键做整套」前的确认
    @State private var askGen = false

    private let cols = [GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)]

    /// 正在播的那条（预览页要拿到动作本身）
    struct ActPreview: Identifiable {
        let id: String
        let pack: CatPack
        let act: CatPack.Act
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let p = store.progress, store.downloading == char.id {
                progressBar(p)
            }
            ScrollView {
                VStack(spacing: 0) {
                    if let err {
                        Text(err)
                            .font(.system(size: 12))
                            .foregroundStyle(Tw.red600)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                    }
                    grid
                    footNote
                }
            }
            workBar
            useBar
        }
        .background(Tw.gray50.ignoresSafeArea())
        .task {
            // ★ 先问台子「现在好了几条」，再决定要不要下包 ——
            //   一条都没有的时候下 40MB 是白下（而且那包是空的，读不出来会报错）。
            await refreshLab()
            await prepare()
            await watch()
        }
        .onChange(of: videoItem) { _, it in
            guard let it else { return }
            Task { await uploadVideo(it) }
        }
        .confirmationDialog("让台子做整套动作？", isPresented: $askGen, titleVisibility: .visible) {
            Button("做（会花豆包额度）") { Task { await startGen() } }
            Button("先不做", role: .cancel) {}
        } message: {
            Text("台子会按 12 个标准动作各生成一条，然后再抠像。"
                 + "这一步花的是你机器上的豆包额度；已经有、正在做的会自己跳过。")
        }
        .fullScreenCover(item: $previewing) { p in
            ActPreviewPage(pack: p.pack, act: p.act)
        }
    }

    // MARK: 顶

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(char.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Tw.gray900)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Tw.gray500)
            }
            Spacer(minLength: 0)
            Button("关上") { dismiss() }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tw.gray500)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var subtitle: String {
        if loading { return "正在把这套动作取到手机上…" }
        guard let p = pack else { return "\(char.doneCount)/12 条好了" }
        let ready = p.acts.count
        return "\(ready) 条动作在手机上 · 点一格就能看它怎么动"
    }

    private func progressBar(_ f: Double) -> some View {
        VStack(spacing: 5) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Tw.gray200)
                    Capsule().fill(Tw.red600)
                        .frame(width: max(6, g.size.width * CGFloat(min(1, max(0, f)))))
                }
            }
            .frame(height: 5)
            Text("取动作包 \(Int(min(1, f) * 100))% · 这套东西几十兆，一次下完以后就不用再下")
                .font(.system(size: 10.5))
                .foregroundStyle(Tw.gray500)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    // MARK: 格子

    private var grid: some View {
        LazyVGrid(columns: cols, spacing: 8) {
            ForEach(ActLab.official, id: \.key) { item in
                let act = pack?.act(item.key)
                Button {
                    guard let p = pack, let a = act else { return }
                    previewing = ActPreview(id: a.name, pack: p, act: a)
                } label: {
                    tile(label: item.label, act: act)
                }
                .buttonStyle(PressStyle())
                .disabled(act == nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private func tile(label: String, act: CatPack.Act?) -> some View {
        let done = act != nil
        return VStack(spacing: 5) {
            Image(systemName: done ? "play.circle.fill" : "circle.dotted")
                .font(.system(size: 18))
                .foregroundStyle(done ? Tw.red600 : Tw.gray300)
            Text(label)
                .font(.system(size: 11, weight: done ? .semibold : .regular))
                .foregroundStyle(done ? Tw.gray900 : Tw.gray400)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let a = act {
                Text("\(a.frames) 帧")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Tw.gray400)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Tw.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(done ? Tw.red600.opacity(0.28) : Tw.gray200, lineWidth: 1)
                )
        )
    }

    private var footNote: some View {
        Text(pack == nil
             ? "这一只的动作还没取下来。灰格子＝台子上还没有这一条。"
             : "点一格就看它怎么动。这台子上没有的动作会是灰的。")
            .font(.system(size: 11))
            .foregroundStyle(Tw.gray400)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
    }

    // MARK: 制作（这一版新接的两条路）

    private var workBar: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                PhotosPicker(selection: $videoItem, matching: .videos, photoLibrary: .shared()) {
                    pill(icon: "square.and.arrow.up", text: "传一段动作视频",
                         on: false, busy: upBusy)
                }
                .disabled(upBusy || genBusy)

                Button {
                    askGen = true
                } label: {
                    pill(icon: "wand.and.stars", text: "一键做整套",
                         on: false, busy: genBusy)
                }
                .buttonStyle(PressStyle())
                .disabled(upBusy || genBusy)
            }

            if !liveText.isEmpty {
                HStack(spacing: 6) {
                    if upBusy || genBusy || !actJobs.filter({ !$0.isDone && !$0.isBad }).isEmpty {
                        ProgressView().scaleEffect(0.6)
                    }
                    Text(liveText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Tw.gray500)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 2)
            }

            // 台子上比手机里多 —— 说明又做好了几条，得重下一遍才看得见
            if labDone > (pack?.acts.count ?? 0), !loading {
                Button {
                    Task { await refreshPack() }
                } label: {
                    pill(icon: "arrow.down.circle", text: "台子上多了 \(labDone - (pack?.acts.count ?? 0)) 条 · 更新到手机",
                         on: true, busy: false)
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    /// 一颗小按钮。`on` = 用红底（那是「有事可做」的那颗）。
    private func pill(icon: String, text: String, on: Bool, busy: Bool) -> some View {
        HStack(spacing: 6) {
            if busy {
                ProgressView().scaleEffect(0.6)
            } else {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(on ? Tw.white : Tw.gray900)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(on ? Tw.red600 : Tw.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(on ? .clear : Tw.gray200, lineWidth: 1)
                )
        )
    }

    /// 现在最该让他看见的那一句话。
    /// 顺序：正在上传 → 正在生成 → 正在抠像 → 空。
    private var liveText: String {
        if upBusy || !upNote.isEmpty { return upNote }
        if let g = genState, genBusy || !genJob.isEmpty || g.isDone || g.isBad {
            return "整套生成：" + g.line
        }
        if let j = actJobs.first(where: { !$0.isDone && !$0.isBad }) {
            return "抠像：" + (j.display?.isEmpty == false ? j.display! : (j.name ?? "")) + " · " + j.line
        }
        if let bad = actJobs.first(where: { $0.isBad }) {
            return "有一段没成：" + (bad.err?.isEmpty == false ? bad.err! : (bad.stage ?? ""))
        }
        return ""
    }

    // MARK: 盯台子

    /// 每 3 秒问一次：好了几条、抠到哪了、生成到哪了。
    /// 这个页面上才跑，关掉就停 —— 不做后台轮询。
    private func watch() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            await refreshLab()
        }
    }

    private func refreshLab() async {
        if let cs = try? await ActLab.chars(),
           let mine = cs.first(where: { $0.id == char.id }) {
            labDone = mine.doneCount
        }
        if let js = try? await ActLab.jobs(charId: char.id) {
            actJobs = js
        }
        if !genJob.isEmpty {
            if let g = try? await ActLab.genState(job: genJob) {
                genState = g
                if g.isDone || g.isBad {
                    genJob = ""
                    genBusy = false
                    // 做完立刻把手机里那份换新，不用他再点一次
                    await refreshPack()
                }
            }
        }
    }

    // MARK: 传一段视频（免费通道）

    private func uploadVideo(_ item: PhotosPickerItem) async {
        upBusy = true
        upNote = "正在读这段视频…"
        defer {
            upBusy = false
            videoItem = nil
        }
        do {
            guard let box = try await item.loadTransferable(type: MovieBox.self) else {
                upNote = "这段视频读不出来 —— 换一段（要相册里的视频，不是照片）"
                return
            }
            let mb = (try? FileManager.default.attributesOfItem(atPath: box.url.path)[.size] as? Int64) ?? 0
            upNote = "正在传 \(max(1, mb / 1_048_576)) MB… 传完台子就开始抠"
            let j = try await ActLab.submitVideo(charId: char.id, video: box.url)
            try? FileManager.default.removeItem(at: box.url)
            upNote = "收到了 · \(j.display ?? j.name ?? "这条动作") 正在抠像"
            actJobs = [j] + actJobs
            // 一上传完就盯紧一点
            await refreshLab()
        } catch {
            upNote = error.localizedDescription
        }
    }

    // MARK: 一键做整套（付费通道）

    private func startGen() async {
        genBusy = true
        genState = nil
        do {
            let r = try await ActLab.genStart(charId: char.id)
            genJob = r.job
            genState = ActLab.GenJob.stub(stage: "下单了，台子正在排队（\(r.acts.count) 条）")
            await refreshLab()
        } catch {
            genBusy = false
            genState = ActLab.GenJob.stub(stage: "没做起来：" + error.localizedDescription)
        }
    }

    /// 强制重下一遍动作包（台子上多了几条之后用）。
    private func refreshPack() async {
        loading = true
        do {
            pack = try await store.install(charId: char.id, force: true)
            await onChanged()
        } catch {
            err = "更新动作包没成：\(error.localizedDescription)"
        }
        loading = false
    }

    // MARK: 用它

    private var useBar: some View {
        VStack(spacing: 8) {
            let mine = store.isCurrent(char.id)

            Button {
                Task { await useThis() }
            } label: {
                HStack(spacing: 8) {
                    if using { ProgressView().tint(.white) }
                    Text(mine ? "正在用它 · 换回自带那只" : (using ? "正在换…" : "用它"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(mine ? Tw.red600 : Tw.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(mine ? Tw.white : (pack == nil ? Tw.gray300 : Tw.red600))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(mine ? Tw.red600 : .clear, lineWidth: 1.4)
                        )
                )
            }
            .buttonStyle(PressStyle())
            .disabled(pack == nil || using)

            Text(mine
                 ? "现在小窗里那只就是它。想换回去，再点一下。"
                 : "换了以后，小窗里那只就变成它 —— 动作、走路的节奏都是它自己的。")
                .font(.system(size: 10.5))
                .foregroundStyle(Tw.gray400)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(
            Tw.white.overlay(alignment: .top) { Rectangle().fill(Tw.gray200).frame(height: 0.5) }
        )
    }

    // MARK: 干活

    private func prepare() async {
        if let p = store.installed(char.id) {
            pack = p
            return
        }
        // ★ 台子上一条动作都没有 ⇒ 不下包。
        //   空包（只有说明书、没有帧）下下来是 40MB 白流量，读的时候还容易报「读不出来」。
        guard max(labDone, char.doneCount) > 0 else { return }
        loading = true
        err = nil
        do {
            pack = try await store.install(charId: char.id)
        } catch {
            err = "这套动作没取下来：\(error.localizedDescription)"
        }
        loading = false
    }

    private func useThis() async {
        guard let p = pack else { return }
        using = true
        let mine = store.isCurrent(char.id)
        store.use(mine ? nil : p)
        await onChanged()
        using = false
        dismiss()
    }
}

// MARK: - 看一条动作
//
// 真帧播放（不是示意图、不是占位）。裸帧是 384×216 的透明 webp，
// 底下铺一层暖色，跟房间里地面那个色接近，看起来才是「在地上」。

@MainActor
struct ActPreviewPage: View {

    let pack: CatPack
    let act: CatPack.Act

    @Environment(\.dismiss) private var dismiss
    @State private var frame = 0
    @State private var timer: Timer?

    /// 20 格/秒。素材是 50fps，按 20 放会慢一点，但手机上是「看清它怎么动」，
    /// 慢一点反而看得清；真按 50 放，肉眼看就是一闪。
    private let hz: Double = 20

    var body: some View {
        ZStack {
            Color(red: 0.949, green: 0.910, blue: 0.863).ignoresSafeArea()  // #F2E8DC，房间那个暖色

            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(act.display)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Tw.gray900)
                        Text("\(act.frames) 帧 · 原速 \(Int(act.fps)) 帧/秒 · \(act.category.isEmpty ? "动作" : act.category)")
                            .font(.system(size: 11))
                            .foregroundStyle(Tw.gray500)
                    }
                    Spacer(minLength: 0)
                    Button("关上") {
                        stop()
                        dismiss()
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tw.gray500)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 8)

                Spacer(minLength: 0)

                if let img = pack.image(act: act, index: frame) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12)
                        .id(frame)          // ★ 不加 id，SwiftUI 可能复用旧图不重绘
                } else {
                    Text("这一帧读不出来")
                        .font(.system(size: 12))
                        .foregroundStyle(Tw.red600)
                }

                Spacer(minLength: 0)

                Text(frame < act.frames
                     ? "第 \(frame + 1) / \(act.frames) 帧"
                     : "…")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Tw.gray400)
                    .padding(.bottom, 22)
            }
        }
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    private func start() {
        stop()
        let t = Timer(timeInterval: 1.0 / hz, repeats: true) { _ in
            Task { @MainActor in
                frame = (frame + 1) % max(1, act.frames)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}


// MARK: - 登记一个新角色
//
// 照安卓 `addCharDialog` 那三样：名字 / 一张照片 / 走哪条通道。
// 照片从相册选（PHPicker），选完立刻转成 JPEG —— 相册里常见的 HEIC，台子不一定认。

struct NewRoleSheet: View {

    /// 登记成功后回调：把新角色带出去，外面刷新列表并把它的动作墙打开
    var onDone: (ActLab.Char?) async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var channel = "free"
    @State private var picked: PhotosPickerItem?
    @State private var photo: Data?
    @State private var photoName = ""
    @State private var busy = false
    @State private var err: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    Text("它叫什么")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tw.gray500)
                        .padding(.bottom, 6)

                    TextField("比如 奶油", text: $name)
                        .font(.system(size: 15))
                        .foregroundStyle(Tw.gray900)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Tw.gray100)
                        )
                        .autocorrectionDisabled()

                    Text("它的一张照片")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tw.gray500)
                        .padding(.top, 20)
                        .padding(.bottom, 6)

                    PhotosPicker(selection: $picked, matching: .images) {
                        HStack(spacing: 8) {
                            Image(systemName: photo == nil ? "photo.badge.plus" : "checkmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(photo == nil ? Tw.gray900 : Tw.green500)
                            Text(photo == nil ? "点这里选它的一张照片" : photoName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Tw.gray900)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Tw.gray100)
                        )
                    }
                    .onChange(of: picked) { _, newItem in
                        Task { await takePhoto(newItem) }
                    }

                    Text("一张就够 · 正面清楚最好")
                        .font(.system(size: 11))
                        .foregroundStyle(Tw.gray400)
                        .padding(.top, 6)

                    Text("它走哪条通道")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tw.gray500)
                        .padding(.top, 20)
                        .padding(.bottom, 8)

                    HStack(spacing: 8) {
                        chanBox("免费", "自己传动作视频\n我们免费帮你抠像", "free")
                        chanBox("付费", "平台按角色照片\n帮你生成整套动作", "paid")
                    }

                    if let e = err {
                        Text(e)
                            .font(.system(size: 12))
                            .foregroundStyle(Tw.red600)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 14)
                    }

                    Button {
                        Task { await submit() }
                    } label: {
                        HStack(spacing: 8) {
                            if busy { ProgressView().tint(.white) }
                            Text(busy ? "正在登记…" : "登记这个角色")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(Tw.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(canSubmit ? Tw.red600 : Tw.gray300)
                        )
                    }
                    .disabled(!canSubmit)
                    .padding(.top, 22)

                    Text("登记完，这只就出现在台子的角色表里。"
                         + "免费那条要你自己在动作墙里传 12 段视频；付费那条台子按照片生成。")
                        .font(.system(size: 11))
                        .foregroundStyle(Tw.gray400)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                        .padding(.bottom, 30)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            .background(Tw.gray50.ignoresSafeArea())
            .navigationTitle("登记一个新角色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("先不登记") { dismiss() }
                        .foregroundStyle(Tw.gray500)
                }
            }
        }
    }

    private var canSubmit: Bool {
        !busy && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photo != nil
    }

    private func chanBox(_ title: String, _ sub: String, _ value: String) -> some View {
        let on = channel == value
        return Button {
            channel = value
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Tw.gray900)
                Text(sub)
                    .font(.system(size: 11))
                    .foregroundStyle(Tw.gray500)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(on ? Tw.red600.opacity(0.06) : Tw.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(on ? Tw.red600 : Tw.gray200, lineWidth: on ? 1.6 : 1)
                    )
            )
        }
        .buttonStyle(PressStyle())
    }

    // MARK: - 选照片

    private func takePhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        err = nil
        do {
            guard let raw = try await item.loadTransferable(type: Data.self),
                  let img = UIImage(data: raw),
                  let jpg = img.jpegData(compressionQuality: 0.9) else {
                err = "这张照片读不出来，换一张试试"
                return
            }
            photo = jpg
            // 只显示个名字用的信息：尺寸 + 大小，比一串哈希好认
            let px = "\(Int(img.size.width))×\(Int(img.size.height))"
            photoName = "\(px) · \(String(format: "%.1f", Double(jpg.count) / 1048576.0)) MB"
        } catch {
            err = "选照片失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 提交

    private func submit() async {
        let nm = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nm.isEmpty, let p = photo else { return }
        busy = true
        err = nil
        do {
            let c = try await ActLab.create(name: nm, channel: channel, photo: p)
            // 先收表，再把新角色交出去 —— 顺序反了会两张表打架
            dismiss()
            await onDone(c)
        } catch {
            err = "登记失败：\(error.localizedDescription)"
        }
        busy = false
    }
}


// MARK: - 相册里的一段视频

/// 从相册取一段视频，落到我们自己的临时文件上。
///
/// ★ 为什么不 `loadTransferable(type: Data.self)`：一段动作视频二三十兆，
///   读成 Data 等于整个塞进内存；而且 `upload(for:from:)` 用文件发能走流式。
/// ★ 相册给的那个 URL 是**临时的**，回调一返回系统就可能删掉 —— 必须当场复制出来。
struct MovieBox: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { sent in
            SentTransferredFile(sent.url)
        } importing: { received in
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent("still-up-\(UUID().uuidString).mp4")
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: received.file, to: dst)
            return Self(url: dst)
        }
    }
}

extension ActLab.GenJob {
    /// 本地先摆一句「下单了」用，别等台子回话才有字。
    static func stub(stage: String) -> ActLab.GenJob {
        ActLab.GenJob(job: nil, stage: nil, phase: stage, msg: nil, progress: nil,
                      allDone: nil, failed: nil, acts: nil, each: nil)
    }
}
