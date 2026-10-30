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
    /// ★ 2026-10-21：已经被「整个删掉」的那些。列表底下那行「放回来」用。
    @Published var dropped: [ActLab.Char] = []
    @Published var loading = false
    @Published var err: String?
    @Published var loadedOnce = false

    func load() async {
        guard !loading else { return }
        loading = true
        err = nil
        do {
            // ★ 一次把「已删掉的」也拉回来：分两次请求的话，删完那一刻
            //   墙上没了、回收那行也没出来，中间会空一拍。
            let all = try await ActLab.chars(includingDropped: true)
            chars = all.filter { !$0.isDropped }
            dropped = all.filter { $0.isDropped }
            loadedOnce = true
        } catch {
            // ★★★ 2026-10-25：「没连上服务器」这句骗了他很久。
            //   台子好好在那儿，是**不认这张票**（401）—— 那是去重新登录，不是等网络。
            //   两种事的补救办法完全不同，说错了就把人往错路上引。
            if let le = error as? ActLab.LabError, le.needLogin {
                err = le.message
            } else {
                err = "没连上服务器：\(error.localizedDescription)"
            }
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
    /// ★ 2026-10-23：建完角色直接进生产页（不再让他自己去动作墙里找）
    @State private var studio: ActLab.Char?
    /// 从动作库「接着做剩下的 N 个」进来 —— 生产页直接从「其余动作」那一半开始
    @State private var studioStage2 = false
    /// 正在「用它」的那只（下包要一会儿，按钮上要转圈）
    @State private var usingId = ""
    /// 正在问「真要删吗」的那一只（非 nil 就弹确认框）
    @State private var askingDrop: ActLab.Char?
    /// 删 / 放回来 失败时的一句人话（显示在列表上方，不弹第二个 alert）
    @State private var opErr: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // ★ 2026-10-30：照安卓那句（ActListV2Activity L58）
                    Text("点一格进去看它；长按可以删掉。")
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

                    if let e = opErr {
                        Text(e)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Tw.red600)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 10)
                    }

                    // ★ 2026-10-30：两列网格，最后一格「＋ 登记新角色」（对齐安卓 ActListV2Activity）
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                        GridItem(.flexible(), spacing: 12)],
                              spacing: 12) {
                        ForEach(model.chars) { c in
                            charCard(c)
                        }
                        登记格()
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)

                    if model.loadedOnce && model.chars.isEmpty && model.err == nil {
                        Text("服务器上还没有角色。点右上角「＋」登记一只。")
                            .font(.system(size: 12))
                            .foregroundStyle(Tw.gray400)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                    }

                    // ★ 2026-10-21：「删角色」这功能的自救口。
                    //   删错了不用来找我 —— 下面这行点一下就回墙上，素材本来就没删。
                    if !model.dropped.isEmpty {
                        droppedRow
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
                // ★ 2026-10-23：建完不落地到列表让他自己找 —— 直接进生产页做坐立。
                //   等这半秒是为了让上面这张表先收干净，两张表同时开会互相吃掉。
                try? await Task.sleep(nanoseconds: 500_000_000)
                studioStage2 = false
                studio = c
            }
            .presentationDetents([.large])
        }
        .sheet(item: $studio) { c in
            RoleStudioView(char: c, stage2: studioStage2)
                .presentationDetents([.large])
        }
        .sheet(item: $watching) { c in
            // ★ 2026-10-30：点一格**直接进动作库**（home: false）——
            //   对齐安卓：点一格进去看它，没有"先看大框"这一层。
            RoleHomeView(char: c, home: false, onStudio: {
                // 「接着做剩下的 N 个」⇒ 关掉大框页，直接进生产页的第二半
                watching = nil
                studioStage2 = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { studio = c }
            })
            .presentationDetents([.large])
        }
        // ★ 删角色：先问一次，并把后果说成人话（几条动作一起撤、手机上那份也会清、能不能恢复）。
        //   不弹第二个 alert —— 两个 alert 挂在一个视图上，SwiftUI 只会生效一个，
        //   这是踩过的坑。失败原因走列表上方那行红字（opErr）。
        .alert(
            "把「\(askingDrop?.title ?? "")」整个删掉？",
            isPresented: Binding(
                get: { askingDrop != nil },
                set: { if !$0 { askingDrop = nil } }
            ),
            presenting: askingDrop
        ) { c in
            Button("删掉", role: .destructive) { Task { await drop(c) } }
            Button("算了", role: .cancel) { }
        } message: { c in
            Text("它已经做好的 \(c.doneCount) 条动作会一起从墙上撤下，"
                 + "手机上装了这只的话也会一起清掉。\n"
                 + "素材不会丢，删完列表底下会出现「放回来」。")
        }
    }

    // MARK: - 删 / 放回来

    /// 删掉一整个角色。台子撤下 + 手机上这份清掉 + 正在用就换回自带那只。
    /// ★ 三步都得做：只撤台子不清本地，App 里还留着；只清本地不撤台子，下拉又回来了。
    private func drop(_ c: ActLab.Char) async {
        opErr = nil
        do {
            let say = try await ActLab.dropChar(c.id)
            // 正在用的那只：先换回 App 自带的，否则 remove 会拒绝删（它不许删正在用的）
            if store.isCurrent(c.id) { store.use(nil) }
            store.remove(c.id)
            _ = say
            await model.load()
        } catch {
            opErr = "没删掉：\(error.localizedDescription)"
        }
    }

    private func restore(_ c: ActLab.Char) async {
        opErr = nil
        do {
            try await ActLab.restoreChar(c.id)
            await model.load()
        } catch {
            opErr = "没放回来：\(error.localizedDescription)"
        }
    }

    /// 列表底下那行「已删掉 N 个」。
    private var droppedRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("已删掉 \(model.dropped.count) 个（素材都还在，点「放回来」就回去了）")
                .font(.system(size: 11))
                .foregroundStyle(Tw.gray400)

            ForEach(model.dropped) { c in
                HStack(spacing: 8) {
                    Text(c.title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Tw.gray600)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        Task { await restore(c) }
                    } label: {
                        Text("放回来")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Tw.red600)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Tw.red600.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
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

    /// 一格角色（对齐安卓：图 + 名字 + 动作数 + 「用它/在用」；点进动作库、长按删）
    private func charCard(_ c: ActLab.Char) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            avatar(c)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 6)

            Text(c.title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Tw.gray900)
                .lineLimit(1)

            Text("\(c.doneCount)/\(ActLab.total) 条动作好了")
                .font(.system(size: 11))
                .foregroundStyle(c.doneCount >= ActLab.total ? Tw.green500 : Tw.gray500)
                .lineLimit(1)

            // 「用它 / 在用」—— 描边胶囊，不是红块（安卓同款）
            Button {
                Task { await useIt(c) }
            } label: {
                HStack(spacing: 4) {
                    if usingId == c.id { ProgressView().scaleEffect(0.5) }
                    Text(store.isCurrent(c.id) ? "在用" : (usingId == c.id ? "在换…" : "用它"))
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(store.isCurrent(c.id) ? Tw.gray400 : Tw.gray900)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .overlay(
                    Capsule().stroke(store.isCurrent(c.id) ? Tw.gray200 : Tw.gray300, lineWidth: 1)
                )
            }
            .buttonStyle(PressStyle(scale: 0.95))
            .disabled(store.isCurrent(c.id) || !usingId.isEmpty)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Tw.white)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Tw.gray200, lineWidth: 1))
        )
        // 点一格 = 进它的动作库（安卓同一条）
        .contentShape(Rectangle())
        .onTapGesture { watching = c }
        // 长按 = 删掉（只有允许删的才有反应）
        .onLongPressGesture(minimumDuration: 0.6) {
            if c.dropAllowed { askingDrop = c }
        }
    }

    /// 最后一格「＋ 登记新角色」
    private func 登记格() -> some View {
        Button {
            showNew = true
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Tw.gray400)
                Text("登记新角色")
                    .font(.system(size: 12))
                    .foregroundStyle(Tw.gray400)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Tw.gray50)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Tw.gray200, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            )
        }
        .buttonStyle(PressStyle(scale: 0.97))
    }

    private func useIt(_ c: ActLab.Char) async {
        if !usingId.isEmpty { return }
        usingId = c.id
        defer { usingId = "" }
        do {
            let p = try await CatPackStore.shared.install(charId: c.id)
            CatPackStore.shared.use(p)
        } catch {
            opErr = "换到「\(c.title)」没成：" + error.localizedDescription
        }
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
            Text("正在从服务器上取…")
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

    // MARK: 这一版新加的口子（全部常驻，不按条件藏）
    /// 做动作的进度页
    @State private var showGen = false
    /// 登录豆包
    @State private var showLogin = false
    @State private var loginState: ActLab.LoginState?
    /// 长按一格 → 换视频（先记住是哪一格，再用系统的选择器）
    @State private var pendingSlot = ""
    @State private var slotItem: PhotosPickerItem?
    @State private var showSlotPicker = false
    /// 长按一格 → 改到别的格 / 删掉这一格
    @State private var renameFrom = ""
    @State private var askRename = false
    @State private var retireSlot = ""
    @State private var askRetire = false
    /// 一键修复：要不要连已经好了的也重抠
    @State private var askRepair = false
    /// ★ v95（功能匹配）：重摆 / 退回 —— 台子上有、手机上以前没入口
    @State private var askRealign = false
    @State private var askUndo = false
    @State private var alignBusy = false
    /// ★ v95（功能匹配）：认一认 —— 非 nil 就挂上那个看不见的小网页
    @State private var recogURL: URL? = nil
    /// 上次跑识别的时刻（防连环跑）
    @State private var lastRecogAt = Date.distantPast
    /// 页面上那句反馈（贴在墙上，不弹窗）
    @State private var hint = ""

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
            banner
            if let p = store.progress, store.downloading == char.id {
                progressBar(p)
            }
            if !hint.isEmpty {
                hintRow
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
            genJob = UserDefaults.standard.string(forKey: GenModel.key(char.id)) ?? ""
            await refreshLab()
            await prepare()
            await watch()
        }
        .onChange(of: videoItem) { _, it in
            guard let it else { return }
            Task { await uploadVideo(it) }
        }
        .onChange(of: slotItem) { _, it in
            guard let it else { return }
            Task { await uploadToSlot(it) }
        }
        .confirmationDialog("让服务器做整套动作？", isPresented: $askGen, titleVisibility: .visible) {
            Button("做（会花豆包额度）") { Task { await startGen() } }
            Button("先不做", role: .cancel) {}
        } message: {
            Text("服务器会按 12 个标准动作各做一条，然后再把背景去掉。"
                 + "这一步花的是你机器上的豆包额度；已经有、正在做的会自己跳过。")
        }
        .confirmationDialog("把「\(labelOf(renameFrom))」改到哪一格？",
                            isPresented: $askRename, titleVisibility: .visible) {
            ForEach(ActLab.official.filter { $0.key != renameFrom }, id: \.key) { a in
                Button(a.label) { Task { await renameSlot(renameFrom, to: a.key) } }
            }
            Button("先不改", role: .cancel) {}
        } message: {
            Text("改完这一格就归到那个动作上了。目标格已经有东西的话，会拒一下。")
        }
        .confirmationDialog("把「\(labelOf(retireSlot))」从墙上退下来？",
                            isPresented: $askRetire, titleVisibility: .visible) {
            Button("退下来", role: .destructive) { Task { await retire(retireSlot) } }
            Button("先不退", role: .cancel) {}
        } message: {
            Text("退下来只是不显示这一格，文件一个都不删，以后还能恢复。")
        }
        .confirmationDialog("把「\(char.title)」重新摆一遍大小？",
                            isPresented: $askRealign, titleVisibility: .visible) {
            Button("摆（不花额度）") { Task { await realignNow() } }
            Button("先不摆", role: .cancel) {}
        } message: {
            Text("这只猫已经做好的动作，按「坐立」那把尺子再摆一遍：\n"
                 + "· 身高统一、脚都踩在同一条线上 —— 换猫时不会一大一小\n"
                 + "· 不重新抠、不花额度、原来的视频一个都不动\n"
                 + "· 摆之前会先留一份备份，摆得不如从前能退回去")
        }
        .confirmationDialog("把「\(char.title)」退回摆之前？",
                            isPresented: $askUndo, titleVisibility: .visible) {
            Button("退回去", role: .destructive) { Task { await undoNow() } }
            Button("先不退", role: .cancel) {}
        } message: {
            Text("这一只所有动作都退回上一次重摆之前的样子。只还原画面大小，不删任何动作；"
                 + "没重摆过的动作，退不退都一样。")
        }
        .confirmationDialog("修一下", isPresented: $askRepair, titleVisibility: .visible) {
            Button("只修卡住的（不花额度）") { Task { await repair(force: false) } }
            Button("连已经好了的也重抠一遍") { Task { await repair(force: true) } }
            Button("先不修", role: .cancel) {}
        } message: {
            Text("拿机器上原来那段源视频重新抠 —— 不重新生成、不花豆包额度、也不用你重传。")
        }
        .sheet(isPresented: $showGen) {
            GenProgressPage(char: char) { await refreshAll() }
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showLogin) {
            DoubaoLoginPage()
                .presentationDetents([.large])
        }
        .photosPicker(isPresented: $showSlotPicker, selection: $slotItem, matching: .videos)
        .fullScreenCover(item: $previewing) { p in
            ActPreviewPage(pack: p.pack, act: p.act)
        }
        // ★ v95（功能匹配）：那个看不见的小网页（认一认）。
        //   1×1、透明、摆在屏幕外 —— 只有它有，苹果上传的视频才能进到格子里。
        .overlay(alignment: .topLeading) {
            if let u = recogURL {
                RecogRunner(url: u, onDone: {
                    recogURL = nil
                    hint = "认完了 —— 已经归到格子里了"
                    Task { await refreshAll() }
                }, onGiveUp: {
                    recogURL = nil
                    if hint.contains("认一认") { hint = "" }
                })
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: 常驻横幅
    //
    // ★★★ 他要的是「制作进度条能一直显示」。所以它不随「有没有在跑」消失：
    //   在跑 → 红色、带百分比；没在跑 → 灰色一行，写着这台机器现在闲不闲。

    private var banner: some View {
        Button {
            showGen = true
        } label: {
            VStack(spacing: 6) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(running ? Tw.red600 : Tw.gray300)
                        .frame(width: 7, height: 7)
                    Text(bannerTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(running ? Tw.gray900 : Tw.gray500)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    Text(running ? (percentText.isEmpty ? "看进度" : percentText) : "进度")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(running ? Tw.red600 : Tw.gray400)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Tw.gray300)
                }

                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Tw.gray200)
                        Capsule()
                            .fill(running ? Tw.red600 : Tw.gray300)
                            .frame(width: max(4, g.size.width * CGFloat(bannerValue)))
                    }
                }
                .frame(height: 4)

                Text(bannerSub)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Tw.gray500)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(running ? Tw.red600.opacity(0.06) : Tw.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(running ? Tw.red600.opacity(0.22) : Tw.gray200, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(PressStyle(scale: 0.99))
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private var running: Bool {
        if let s = genState, !s.stopped { return true }
        return !actJobs.filter { !$0.isDone && !$0.isBad }.isEmpty
    }

    private var bannerValue: Double {
        if let s = genState, !genJob.isEmpty { return s.barValue }
        if let j = actJobs.first(where: { !$0.isDone && !$0.isBad }) {
            return min(0.99, max(0.03, Double(j.pct ?? 0) / 100))
        }
        if labDone > 0 { return min(1, Double(labDone) / Double(ActLab.total)) }
        return 0
    }

    private var percentText: String {
        if let s = genState, !genJob.isEmpty {
            if s.stopped { return "已停" }
            if let p = s.progress, p > 1 { return "\(p)%" }
            return ""
        }
        if let j = actJobs.first(where: { !$0.isDone && !$0.isBad }) {
            return "\(j.pct ?? 0)%"
        }
        return ""
    }

    private var bannerTitle: String {
        if let s = genState, !genJob.isEmpty, !s.stopped { return "正在给「\(char.title)」做动作" }
        if let j = actJobs.first(where: { !$0.isDone && !$0.isBad }) {
            return "正在抠：\(j.display?.isEmpty == false ? j.display! : (j.name ?? "一条动作"))"
        }
        if labDone >= ActLab.total { return "「\(char.title)」这套已经齐了 · \(labDone)/\(ActLab.total)" }
        return "「\(char.title)」现在没在跑 · 好了 \(labDone)/\(ActLab.total) 条"
    }

    private var bannerSub: String {
        if let s = genState, !genJob.isEmpty {
            return s.line + (s.isDone || s.isBad ? "" : "（退出去也接着做）")
        }
        if let j = actJobs.first(where: { !$0.isDone && !$0.isBad }) {
            return "\(j.line) · 不花额度"
        }
        if let bad = actJobs.first(where: { $0.isBad }) {
            return "有一段没成：\(bad.err?.isEmpty == false ? bad.err! : (bad.stage ?? "")) —— 点「修一下」"
        }
        return "点这一行看进度 · 想补几条就传视频，或点「做整套」"
    }

    private var hintRow: some View {
        HStack(spacing: 6) {
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(Tw.gray600)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                hint = ""
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Tw.gray400)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func labelOf(_ key: String) -> String {
        ActLab.official.first(where: { $0.key == key })?.label ?? key
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
        guard let p = pack else { return "\(char.doneCount)/\(ActLab.total) 条好了" }
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
                    tile(item.key, item.label, act)
                }
                .buttonStyle(PressStyle())
                // ★ 长按一格：改格 / 换视频 / 删格（安卓那套「修改通道」）
                .contextMenu {
                    Button {
                        pendingSlot = item.key
                        showSlotPicker = true
                    } label: {
                        Label("换一段视频（按到这一格）", systemImage: "video.badge.plus")
                    }
                    Button {
                        renameFrom = item.key
                        askRename = true
                    } label: {
                        Label("改到别的格", systemImage: "arrow.left.arrow.right")
                    }
                    Button(role: .destructive) {
                        retireSlot = item.key
                        askRetire = true
                    } label: {
                        Label("把这一格退下来", systemImage: "trash")
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    /// 一格。有真帧就显示第一帧（不再只是一个图标），在抠就显示进度。
    private func tile(_ key: String, _ label: String, _ act: CatPack.Act?) -> some View {
        let live = cellProgress(key)
        let done = act != nil
        return VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Tw.gray100)

                if let a = act, let img = pack?.image(act: a, index: 0) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .padding(1)
                } else if let live {
                    VStack(spacing: 2) {
                        Text("\(Int(live.value * 100))%")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Tw.red600)
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Tw.gray200)
                                Capsule().fill(Tw.red600)
                                    .frame(width: max(3, g.size.width * CGFloat(live.value)))
                            }
                        }
                        .frame(height: 3)
                        .padding(.horizontal, 12)
                    }
                } else {
                    Image(systemName: "circle.dotted")
                        .font(.system(size: 17))
                        .foregroundStyle(Tw.gray300)
                }
            }
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(label)
                .font(.system(size: 11, weight: done ? .semibold : .regular))
                .foregroundStyle(done ? Tw.gray900 : Tw.gray400)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if let live {
                Text(live.stage)
                    .font(.system(size: 8.5))
                    .foregroundStyle(Tw.red600)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else if let a = act {
                Text("\(a.frames) 帧")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Tw.gray400)
            } else {
                Text("还没有")
                    .font(.system(size: 9))
                    .foregroundStyle(Tw.gray300)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Tw.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(done ? Tw.red600.opacity(0.28)
                                     : (live == nil ? Tw.gray200 : Tw.red600.opacity(0.16)),
                                lineWidth: 1)
                )
        )
    }

    /// 这一格正在走到哪一步（抠像优先，其次是生成那趟的逐条状态）。
    private func cellProgress(_ key: String) -> (value: Double, stage: String)? {
        if let j = actJobs.first(where: { ($0.name ?? "") == key }) {
            if j.isDone { return nil }
            return (min(0.99, max(0.03, Double(j.pct ?? 0) / 100)), j.line)
        }
        if let s = genState?.each?.first(where: { $0.act == key }), !s.matteDone {
            return (min(0.99, max(0.03, Double(s.pct ?? 0) / 100)), s.line)
        }
        return nil
    }

    private var footNote: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pack == nil
                 ? "这一只的动作还没取下来。灰格子＝服务器上还没有这一条。"
                 : "点一格就看它怎么动。服务器上没有的动作会是灰的。")
                .font(.system(size: 11))
                .foregroundStyle(Tw.gray400)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                    showGen = true
                } label: {
                    pill(icon: "chart.bar.fill", text: "做动作 · 看进度",
                         on: true, busy: genBusy)
                }
                .buttonStyle(PressStyle())
            }

            HStack(spacing: 8) {
                Button {
                    askRepair = true
                } label: {
                    pill(icon: "wrench.and.screwdriver.fill", text: "修一下",
                         on: false, busy: false)
                }
                .buttonStyle(PressStyle())

                Button {
                    showLogin = true
                } label: {
                    pill(icon: "person.crop.circle.badge.checkmark",
                         text: (loginState?.loggedIn == true) ? "豆包：已登录" : "登录豆包",
                         on: false, busy: false)
                }
                .buttonStyle(PressStyle())
            }

            // ★★★ v95（功能匹配）：重摆 / 退回。
            //   台子上这两个口子早就有了（不重抠、不花额度，按「坐立」统一身高和脚线；
            //   摆之前留备份，随时能退）—— 可手机上一颗键都没有。
            //   ★ 跟「修一下」同一条规矩：常驻，不按任何条件藏。
            HStack(spacing: 8) {
                Button {
                    askRealign = true
                } label: {
                    pill(icon: "arrow.up.and.down.square",
                         text: alignBusy ? "正在摆…" : "重新摆一遍大小",
                         on: false, busy: alignBusy)
                }
                .buttonStyle(PressStyle())
                .disabled(alignBusy)

                Button {
                    askUndo = true
                } label: {
                    pill(icon: "arrow.uturn.backward.square",
                         text: "退回摆之前", on: false, busy: false)
                }
                .buttonStyle(PressStyle())
                .disabled(alignBusy)
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
                    pill(icon: "arrow.down.circle", text: "服务器上多了 \(labDone - (pack?.acts.count ?? 0)) 条 · 更新到手机",
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
            return "去掉背景：" + (j.display?.isEmpty == false ? j.display! : (j.name ?? "")) + " · " + j.line
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
        if loginState == nil {
            loginState = try? await ActLab.loginState()
        }
        // ★ v95（功能匹配）：有待认领的（抠完了还没定名字）→ 自动认一认。
        //   安卓 v2.26 就有，苹果一直缺 ⇒ 上传的视频停在 x_ 临时名，永远进不了格子。
        await maybeRecog()

        if !genJob.isEmpty {
            if let g = try? await ActLab.genState(job: genJob) {
                let wasDone = genState?.isDone ?? false
                genState = g
                if (g.isDone || g.isBad) && !wasDone {
                    genBusy = false
                    // 做完立刻把手机里那份换新，不用他再点一次
                    await refreshPack()
                }
            }
        }
    }

    /// 进度页回来说「完了」之后：重问台子，多出来的话顺手更新到手机。
    private func refreshAll() async {
        await refreshLab()
        if labDone > (pack?.acts.count ?? 0) {
            await refreshPack()
        }
        await onChanged()
    }

    // MARK: 一键修复 / 改格 / 删格 / 换视频 / 重摆 / 退回

    /// ★ v95（功能匹配）：有待认领的就起那个看不见的小网页认一认。
    ///   5 分钟内不重复跑（认完到服务器改名中间要一会儿，跑第二遍是白跑）。
    private func maybeRecog() async {
        guard recogURL == nil else { return }
        guard Date().timeIntervalSince(lastRecogAt) > 300 else { return }
        guard let n = try? await ActLab.pendingRecog(), n > 0 else { return }
        guard let u = ActLab.recogURL else { return }
        lastRecogAt = Date()
        hint = "刚抠完的新动作 —— 正在认一认该进哪个格子…"
        recogURL = u
    }

    /// ★ v95（功能匹配）：让台子把这只猫已经做好的动作重新摆一遍大小。
    ///   摆是在服务器后台跑的 —— 这儿下单，然后每 3 秒问一句「摆到哪儿了」。
    private func realignNow() async {
        alignBusy = true
        hint = "正在叫服务器摆…"
        do {
            try await ActLab.realign(charId: char.id, dry: false)
            hint = "正在摆…"
            // 最多盯 4 分钟（3 秒一次）
            for _ in 0..<80 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let st = try? await ActLab.realignState() else { continue }
                if st.running == true {
                    hint = "正在摆 · \(st.progress ?? "")"
                    continue
                }
                if st.done == true {
                    let seen = st.seen ?? 0
                    let moved = st.moved ?? 0
                    var s = "摆完了：看过 \(seen) 条，动了 \(moved) 条"
                    if let es = st.errors, !es.isEmpty {
                        s += "；\(es.count) 条没能摆"
                    }
                    if moved > 0 { s += "（看着不如从前就按「退回摆之前」）" }
                    hint = s
                    await refreshAll()
                    alignBusy = false
                    return
                }
            }
            hint = "摆了太久还没回话 —— 过一会儿回来看看"
        } catch {
            hint = "没能开始摆：\(error.localizedDescription)"
        }
        alignBusy = false
    }

    private func undoNow() async {
        alignBusy = true
        hint = "正在退回去…"
        do {
            let r = try await ActLab.alignUndo(charId: char.id)
            let n = r.back?.count ?? 0
            hint = n > 0 ? "退回去 \(n) 条 —— 现在跟摆之前一样了"
                         : "没有能退的（这只猫没重摆过，或者备份已经被清掉了）"
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await refreshPack()
        } catch {
            hint = "没退成：\(error.localizedDescription)"
        }
        alignBusy = false
    }

    private func repair(force: Bool) async {
        hint = force ? "正在叫服务器把每一条都重做一遍…" : "正在叫服务器修卡住的那些…"
        do {
            hint = try await ActLab.actRepair(charId: char.id, force: force)
            await refreshLab()
        } catch {
            hint = "没修起来：\(error.localizedDescription)"
        }
    }

    private func renameSlot(_ from: String, to: String) async {
        hint = "正在把「\(labelOf(from))」改到「\(labelOf(to))」…"
        do {
            try await ActLab.actRename(charId: char.id, name: from, to: to)
            hint = "改好了 · 服务器要重新整理一遍，约半分钟"
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await refreshPack()
        } catch {
            hint = "改不了：\(error.localizedDescription)"
        }
    }

    private func retire(_ slot: String) async {
        hint = "正在把「\(labelOf(slot))」退下来…"
        do {
            try await ActLab.actRetire(charId: char.id, name: slot)
            hint = "「\(labelOf(slot))」退下来了 —— 文件还在，以后能恢复"
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await refreshPack()
        } catch {
            hint = "退不下来：\(error.localizedDescription)"
        }
    }

    /// 长按某一格 → 换视频：传上去，然后把它按到这一格上。
    private func uploadToSlot(_ item: PhotosPickerItem) async {
        let slot = pendingSlot
        upBusy = true
        upNote = "正在读这段视频…"
        defer {
            upBusy = false
            slotItem = nil
            pendingSlot = ""
        }
        do {
            guard let box = try await item.loadTransferable(type: MovieBox.self) else {
                upNote = "这段视频读不出来 —— 换一段（要相册里的视频，不是照片）"
                return
            }
            upNote = "正在传给服务器…"
            let msg = try await ActLab.replaceVideo(charId: char.id, slot: slot, video: box.url)
            try? FileManager.default.removeItem(at: box.url)
            upNote = ""
            hint = msg
            await refreshLab()
        } catch {
            upNote = ""
            hint = "没换成：\(error.localizedDescription)"
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
            upNote = "正在传 \(max(1, mb / 1_048_576)) MB… 传完服务器就开始去掉背景"
            let j = try await ActLab.submitVideo(charId: char.id, video: box.url)
            try? FileManager.default.removeItem(at: box.url)
            upNote = "收到了 · \(j.display ?? j.name ?? "这条动作") 正在去掉背景"
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
            UserDefaults.standard.set(r.job, forKey: GenModel.key(char.id))
            genState = ActLab.GenJob.stub(stage: "下单了，服务器正在排队（\(r.acts.count) 条）")
            await refreshLab()
        } catch {
            genBusy = false
            genState = ActLab.GenJob.stub(stage: "没做起来：" + error.localizedDescription)
        }
    }

    /// 强制重下一遍动作包（台子上多了几条之后用）。
    private func refreshPack() async {
        // 台子上一条都还没有 ⇒ 没有包可下（空包 40MB，还读不出来）
        guard labDone > 0 else { return }
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
    /// ★ 2026-10-23：新链路里没有「免费/付费通道」那张卡了 —— 建角色就是要它做动作。
    ///   `channel` 还留着给台子（那边按它决定要不要生成整套）。
    @State private var channel = "paid"
    @State private var picked: PhotosPickerItem?
    @State private var photo: Data?
    @State private var photoName = ""
    @State private var busy = false
    @State private var err: String?

    // ★★★ 2026-10-23（他的原话）：「就是要合并成一条，并且要加一个添加按钮
    //   在这个下拉条下面，用来添加新模型和新的豆包账号」。
    //   以前是两条（用哪个模型 · 用哪个豆包号）—— 现在**一条就定下这两样**，
    //   下面一颗「＋ 添加」：加新豆包号 / 加新模型，二选一。
    @State private var models: [Mdl] = [Mdl(id: "doubao", 名字: "豆包 · Seedance 2.0 mini", 接没接通: true)]
    @State private var modelId = "doubao"
    @State private var modelName = "豆包 · Seedance 2.0 mini"
    @State private var slot = "1"
    @State private var accounts: [Acc] = []
    /// 下拉条下面那颗「＋ 添加」点了之后：选加什么
    @State private var showAddWhat = false
    /// 加豆包号＝登一个新号
    @State private var showLogin = false
    /// 加模型＝填名字 + 它的钥匙
    @State private var showAddModel = false

    struct Acc: Identifiable {
        let slot: String
        let name: String
        let ok: Bool
        var id: String { slot }
    }

    struct Mdl: Identifiable {
        let id: String
        let 名字: String
        let 接没接通: Bool
    }

    private var acctLabel: String {
        if let a = accounts.first(where: { $0.slot == slot }) {
            return "\(a.name) · \(a.ok ? "已登录" : "没登录")"
        }
        return "豆包\(slot) · 还没登号"
    }

    /// 下拉条上现在写着什么：模型 + 号。只有一个模型时就不重复写模型名了。
    private var comboLabel: String {
        let m = models.first(where: { $0.id == modelId })
        let tag = (m?.接没接通 == false) ? "（还没接好）" : ""
        if models.count > 1, let m { return "\(m.名字) · \(acctLabel)\(tag)" }
        return acctLabel + tag
    }

    /// 下拉里那一列：一个「模型 × 豆包号」一行。
    private var comboRows: [(String, String, String)] {
        var out: [(String, String, String)] = []
        let list = accounts.isEmpty ? [Acc(slot: "1", name: "豆包1", ok: false)] : accounts
        for m in models {
            for a in list {
                let tag = m.接没接通 ? "" : "（还没接好）"
                let t = models.count > 1 ? "\(m.名字) · \(a.name) · \(a.ok ? "已登录" : "没登录")\(tag)"
                                         : "\(a.name) · \(a.ok ? "已登录" : "没登录")\(tag)"
                out.append((t, m.id, a.slot))
            }
        }
        return out
    }

    private func pickCombo(_ r: (String, String, String)) {
        if let m = models.first(where: { $0.id == r.1 }), !m.接没接通 {
            // ★ 不做假按钮：还没接好的模型选了也不装作能用 —— 明说，手上还是拿豆包做。
            err = "「\(m.名字)」还没接好 —— 先用豆包给你做"
            if let first = models.first(where: { $0.接没接通 }) { modelId = first.id; modelName = first.名字 }
        } else {
            modelId = r.1
            modelName = models.first(where: { $0.id == r.1 })?.名字 ?? modelName
            err = nil
        }
        slot = r.2
    }

    private func dropdownRow(_ s: String) -> some View {
        HStack(spacing: 8) {
            Text(s)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Tw.gray900)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tw.gray400)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Tw.gray100))
    }

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

                    Text("用哪个来做")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tw.gray500)
                        .padding(.top, 20)
                        .padding(.bottom, 6)

                    Menu {
                        ForEach(comboRows, id: \.0) { r in
                            Button(r.0) { pickCombo(r) }
                        }
                    } label: {
                        dropdownRow(comboLabel)
                    }

                    // ★★★ 2026-10-23（他的原话）：「要加一个添加按钮在这个下拉条下面，
                    //   用来添加新模型和新的豆包账号」—— 加号就在下拉条下面，不用跑到别处。
                    Button { showAddWhat = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold))
                            Text("添加新模型 / 新豆包号")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(Tw.gray700)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(Tw.gray300, lineWidth: 1)
                        )
                    }
                    .padding(.top, 8)
                    .confirmationDialog("添加什么", isPresented: $showAddWhat, titleVisibility: .visible) {
                        Button("添加豆包账号") { showLogin = true }
                        Button("添加新模型") { showAddModel = true }
                        Button("先不加", role: .cancel) {}
                    }

                    Text("做动作花的是这个号的额度。号在你手机上登录，服务器只记着用哪个。")
                        .font(.system(size: 11))
                        .foregroundStyle(Tw.gray400)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)

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
                            Text(busy ? "正在登记…" : "下一步")
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

                    Text("点「下一步」就进去做动作：先做一条坐立给你看，"
                         + "你点头它才接着把别的动作一条条做出来。")
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
            .task { await loadAccounts(); await loadModels() }
            // ★ 登完一个新号回来，下拉条里要出现它
            .sheet(isPresented: $showLogin) {
                DoubaoLoginPage()
                    .presentationDetents([.large])
            }
            .onChange(of: showLogin) { _, now in
                if !now { Task { await loadAccounts() } }
            }
            // ★ 加一个新模型
            .sheet(isPresented: $showAddModel) {
                AddModelSheet { Task { await loadModels() } }
                    .presentationDetents([.medium])
            }
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

    /// 台子上记着哪些豆包号。拿不到就空着 —— 显示「还没登号」，不装作有。
    private func loadAccounts() async {
        guard let d = try? await ActLab.rawGet("/api/login/accounts", timeout: 15),
              let obj = try? JSONSerialization.jsonObject(with: d),
              let o = obj as? [String: Any],
              let arr = o["账号"] as? [[String: Any]] else { return }
        var out: [Acc] = []
        for x in arr {
            let s = (x["slot"] as? String) ?? "1"
            let n = (x["名字"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "豆包\(s)"
            let ok = (x["登着没"] as? Bool) ?? false
            out.append(Acc(slot: s, name: n, ok: ok))
        }
        accounts = out
        if !out.isEmpty, !out.contains(where: { $0.slot == slot }) {
            slot = out[0].slot
        }
    }

    /// 这台机器上有哪些模型 —— 他自己加的那些也会在这里出现。拿不到就只留内置那个。
    private func loadModels() async {
        guard let d = try? await ActLab.rawGet("/api/gen/models", timeout: 15),
              let obj = try? JSONSerialization.jsonObject(with: d),
              let o = obj as? [String: Any],
              let arr = o["模型"] as? [[String: Any]] else { return }
        var out: [Mdl] = []
        for x in arr {
            let id = (x["id"] as? String) ?? ""
            let n = (x["名字"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "没名字的模型"
            let on = (x["接没接通"] as? Bool) ?? false
            out.append(Mdl(id: id, 名字: n, 接没接通: on))
        }
        guard !out.isEmpty else { return }
        models = out
        if !out.contains(where: { $0.id == modelId }) {
            modelId = out[0].id
            modelName = out[0].名字
        }
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


// MARK: - 添加新模型
//
// ★★★ 2026-10-23（他的原话）：「添加按钮…用来添加新模型和新的豆包账号」。
//   ★ 存是真存、列表里是真出现 —— 但**接没接好不骗人**：
//   刚记下的模型机器还没真拿它做过东西，所以标「还没接好」，
//   选它的时候明说「先用豆包给你做」。

struct AddModelSheet: View {

    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var key = ""
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

                    TextField("比如 方舟 · Seedance", text: $name)
                        .font(.system(size: 15))
                        .foregroundStyle(Tw.gray900)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Tw.gray100))
                        .autocorrectionDisabled()

                    Text("它的钥匙（key）")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tw.gray500)
                        .padding(.top, 18)
                        .padding(.bottom, 6)

                    TextField("没有就先空着", text: $key)
                        .font(.system(size: 14))
                        .foregroundStyle(Tw.gray900)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Tw.gray100))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Text("钥匙先存在服务器上。等那边接好了，"
                         + "这里会亮成「已接好」，那时候就能挑它来做。")
                        .font(.system(size: 11))
                        .foregroundStyle(Tw.gray400)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)

                    if let e = err {
                        Text(e)
                            .font(.system(size: 12))
                            .foregroundStyle(Tw.red600)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 14)
                    }

                    Button { Task { await save() } } label: {
                        HStack(spacing: 8) {
                            if busy { ProgressView().tint(.white) }
                            Text(busy ? "正在记…" : "记下来")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(Tw.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(canSave ? Tw.red600 : Tw.gray300))
                    }
                    .disabled(!canSave)
                    .padding(.top, 22)

                    Spacer(minLength: 30)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }
            .background(Tw.gray50.ignoresSafeArea())
            .navigationTitle("添加新模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("算了") { dismiss() }
                        .foregroundStyle(Tw.gray500)
                }
            }
        }
    }

    private var canSave: Bool {
        !busy && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() async {
        let nm = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nm.isEmpty else { return }
        busy = true
        err = nil
        do {
            _ = try await ActLab.rawPost("/api/gen/models",
                                         body: ["名字": nm, "钥匙": key.trimmingCharacters(in: .whitespacesAndNewlines)])
            dismiss()
            onDone()
        } catch {
            err = "没记下来：\(error.localizedDescription)"
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
    static func stub(stage: String, progress: Int? = nil, failed: Bool = false) -> ActLab.GenJob {
        ActLab.GenJob(job: nil, char: nil, stage: nil, phase: stage, msg: nil, progress: progress,
                      allDone: nil, matteAllDone: nil, failed: failed ? true : nil, done: nil,
                      acts: nil, each: nil, redo: nil, leftover: nil, pending: nil)
    }
}
