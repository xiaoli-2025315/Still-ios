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
    // ★ 2026-11-01 新增流程：参考图确认 → 制作中
    @State private var refChar: ActLab.Char?
    @State private var refPhoto = Data()
    @State private var sitingChar: ActLab.Char?
    /// 正在「用它」的那只（下包要一会儿，按钮上要转圈）
    @State private var usingId = ""
    /// ★ 2026-11-03（他定的）：坐立没做出来之前，不许出现「用它」
    @State private var sitReady: [String: Bool] = [:]
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
                                }

                    Spacer(minLength: 30)
                }
                .padding(.top, 4)
            }
            .refreshable { await model.load() }
        }
        .background(Tw.gray50.ignoresSafeArea())
        .task { await model.load() }
        // ★ 2026-11-03（他报的）：新角色不立刻出现 —— 从制作流程/充值页回来都要重拉。
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await model.load() }
        }
        .sheet(isPresented: $showNew) {
            NewRoleSheet { c, photo in
                await model.load()
                guard let c else { return }
                // ★ 2026-11-01（他定的流程）：登记完先到「参考图确认」，不是直接进制作页。
                try? await Task.sleep(nanoseconds: 500_000_000)
                refChar = c
                refPhoto = photo ?? Data()
            }
            .presentationDetents([.large])
        }
        // ① 参考图确认 → ② 制作中（只看坐立） → ③ 动作库
        .sheet(item: $refChar) { c in
            RefConfirmView(
                name: c.title,
                photo: refPhoto,
                charId: c.id,
                onPhotoChanged: { _ in },
                onStart: {
                    // 下单在参考图页里做（RefConfirmView.placeOrder），这里只导航
                    refChar = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { sitingChar = c }
                },
                onStartChannel: { _ in
                    // ★ 2026-11-03（查出来的真 bug）：参考图页**已经下过单**了，
                    //   这里以前又下一单 → 一次点击下两单（第二单被 409 顶掉，
                    //   但额度已经花掉，状态也会乱）。现在这里只管"跳制作页"。
                    refChar = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { sitingChar = c }
                },
                onBack: { refChar = nil }
            )
            .presentationDetents([.large])
        }
        .sheet(item: $sitingChar) { c in
            SitingView(
                char: c,
                onBackToRef: {
                    // ★ 2026-11-03：制作页退出 → 回角色列表。
                    //   并把"已下单"标记清掉：如果那一单其实是丢了（台子查不到），
                    //   再进这只角色时会回到参考图页，可以重新下单；
                    //   如果单还在做，状态一查就有，不会重复下单（参考图页会显示"已经在做了"）。
                    sitingChar = nil
                    refChar = nil
                },
                onNext: {
                    // ★ 2026-11-04（他报的：点过确认下一步，下次进来又要再点一遍）
                    UserDefaults.standard.set(true, forKey: "still.seensit." + c.id)
                    sitingChar = nil
                    // ★ 2026-11-03（他报的）：以前这里会弹旧的"生产页"（里面写着
                    //   「坐立好了，你看一眼」）—— 那不是他要的东西，而且挡住所有动作。
                    //   现在：确认下一步 = 直接进这一只的动作库。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { watching = c }
                }
            )
            .presentationDetents([.large])
        }

        .sheet(item: $watching) { c in
            // ★ 2026-10-30：点一格**直接进动作库**（home: false）——
            //   对齐安卓：点一格进去看它，没有"先看大框"这一层。
            RoleHomeView(char: c, home: false, onStudio: {
                // ★ 2026-11-03：不再进旧生产页 —— 就停在这一只的动作库里。
                watching = c
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

    // ★ 2026-11-04（他定的）：iOS 不要「删掉的角色可以放回来」这个口子 —— 整块删掉（连文案）。

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

    /// ★ 2026-11-01（他说的）：入口只有角色页点进来这一个。
    ///   进来落到哪一页，全看这只猫现在到哪一步 ——
    ///     坐立已经好了   → 动作库
    ///     点过「开始生成」 → 制作中（他上次退出的就是那页）
    ///     还没点过       → 参考图确认
    private func route(_ c: ActLab.Char) async {
        // ★★ 2026-11-05（他定的）：**一律以台子为准**，不再看手机本地那条"已下单"标记。
        //   规则：
        //   · 台子说"坐立好了"       → 没看过「做好了」就先看，看过直接进动作库
        //   · 台子说"在做（任一阶段）" → 直接回制作中页，接着看进度
        //   · 台子说"失败/被打断"    → 也进制作中页（那里写原因、有出路）
        //   · 台子说"没做 / 查不到"   → 回参考图页（可以重新下单）
        let st = await sitStatus(c.id)
        switch st {
        case "好了":
            let seen = UserDefaults.standard.bool(forKey: "still.seensit." + c.id)
            if !seen { sitingChar = c } else { watching = c }
        // ★★★ 2026-11-08：**做出来了 ≠ 手机里有了**。
        //   台子说「正在送到手机」时这一条还不算完成，不许显示「做好了」、
        //   「用它」也不该冒出来；等装好后台子改口说「好了」才会走上面那支。
        case "正在送到手机":
            sitingChar = c
        case "准备中", "排队中", "排队", "生成中", "等抠图", "抠像中", "失败", "没做成", "被打断":
            sitingChar = c
        default:
            refChar = c
            refPhoto = Data()
        }
    }

    /// 这只猫「坐立」现在是什么状态（以台子为准；查不到就当"没做"）
    private func sitStatus(_ id: String) async -> String {
        if let st = await ActLab.state(charId: id),
           let a = st.acts.first(where: { $0.act == "sit" }) {
            return a.状态
        }
        if let m = try? await ActLab.manifest(charId: id), m.names.contains("sit") {
            return "好了"
        }
        return "没做"
    }

    /// 这只猫的坐立做好了没有（以台子为准）
    private func sitDone(_ id: String) async -> Bool {
        if let st = await ActLab.state(charId: id),
           let a = st.acts.first(where: { $0.act == "sit" }) {
            return a.状态 == "好了"
        }
        if let m = try? await ActLab.manifest(charId: id) {
            return m.names.contains("sit")
        }
        return false
    }

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
            // ★ 坐立没做完之前不出现（他定的：最起码坐立做完进了动作库才能用它）
            if sitReady[c.id] != true {
                Text("还没做好")
                    .font(.system(size: 11))
                    .foregroundStyle(Tw.gray400)
                    .padding(.bottom, 8)
                    .task {
                        if sitReady[c.id] == nil {
                            sitReady[c.id] = await sitDone(c.id)
                        }
                    }
            } else {
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
        .onTapGesture { Task { await route(c) } }
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
            // ★ 2026-11-05（他定的：换不上必须让用户知道怎么办）：
            //   把原因同时写到台子诊断，界面上给出"重试"的出路。
            let msg = error.localizedDescription
            opErr = "换到「\(c.title)」没成：" + msg + "（再点一次「用它」可以重试）"
            await ActLab.diagSay("用它失败 char=\(c.id) 原因=\(msg)")
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

            // ★ 2026-11-03（他定的）：「用它」正在下包时，框里要有圆形进度
                                // ★ 2026-11-04（他定的）：安卓没有这个百分比环，而且它会来回跳 —— 整块删掉。


            if let u = c.imgURL {
                // ★★ 2026-11-07（他报的：每次点进来这些预览图都重新加载）：
                //   台子对图片回 no-store，系统 AsyncImage 每次都联网重下。
                //   换成落盘缓存：先读手机里那张（毫秒级），后台再校验有没有换过。
                StillCachedImage(url: u)
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
    var onDone: (ActLab.Char?, Data?) async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    /// ★ 2026-10-23：新链路里没有「免费/付费通道」那张卡了 —— 建角色就是要它做动作。
    ///   `channel` 还留着给台子（那边按它决定要不要生成整套）。
    @State private var channel = "paid"
    @State private var picked: PhotosPickerItem?
    @State private var photo: Data?
    @State private var photoName = ""
    /// ★ 白底提示词那块的小提示
    @State private var toldWhite = ""
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
    /// ★ 2026-11-02：台子支持 wan3.0 吗（探到了才在下拉条里出现）
    @State private var wanOk = false
    /// ★ 2026-11-03：余额（分）+ 单价（分）
    @State private var walletFree = -1
    @State private var walletPrice = 120

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
        if modelId == "wan" { return "wan3.0 · 阿里云" }
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
        // ★ 2026-11-02（他定的）：wan3.0 跟豆包**并列**，用户自己挑，不自动切换。
        //   它不占豆包额度，所以不需要豆包号。
        //   ★ 但要台子真支持才出现（没部署的台子不显示，点了必失败）。
        if wanOk { out.append(("wan3.0 · 阿里云", "wan", "")) }
        return out
    }

    private func pickCombo(_ r: (String, String, String)) {
        if r.1 == "wan" {
            modelId = "wan"
            modelName = "wan3.0 · 阿里云"
            slot = ""
            err = nil
            return
        }
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

                    Text("请上传统一白底的角色图 · 全身或半身都行 · 背景越干净抠图越准")

                    // ★★ 2026-11-07（他定的）：给个"怎么弄白底图"的快捷方式
                    HStack(spacing: 8) {
                        Button {
                            UIPasteboard.general.string =
                                "保留人物的样子、服装和姿势完全不变，全身完整入画，" +
                                "把背景换成纯白色（#FFFFFF），背景要干净、均匀、没有其他东西，" +
                                "不要投影，人物不要贴边。"
                            toldWhite = "提示词复制好了 —— 去豆包贴一下，拿到白底图再回来上传"
                        } label: {
                            Text("复制白底提示词")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Tw.gray900)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Capsule().fill(Tw.gray100))
                        }
                        .buttonStyle(.plain)

                        Button {
                            if let u = URL(string: "https://www.doubao.com/chat/") {
                                UIApplication.shared.open(u)
                            }
                        } label: {
                            Text("打开豆包")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Tw.gray900)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Capsule().fill(Tw.gray100))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 8)

                    Text(toldWhite.isEmpty
                         ? "已经有白底图就不用管；没有的话：复制提示词 → 打开豆包 → 改成白底全身图 → 回来上传"
                         : toldWhite)
                        .font(.system(size: 11))
                        .foregroundStyle(Tw.gray400)
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

                    // ★ 2026-11-03（他定的）：余额 + 充值 —— 没余额就做不了，
                    //   所以放在最显眼的位置，点「充值」直接开台子的充值页。
                    HStack(spacing: 10) {
                        Text(walletText)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(walletShort ? Tw.red600 : Tw.gray500)
                        Spacer()
                        Button {
                            openPay()
                        } label: {
                            Text("充值")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Tw.gray900)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(Tw.gray300, lineWidth: 1)
                                )
                        }
                        .buttonStyle(PressStyle(scale: 0.97))
                    }
                    .padding(.top, 14)

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
                    .task {
                        // ★ 探一次台子支不支持 wan（不支持就不显示那个选项）
                        if !wanOk { wanOk = await ActLab.wanAlive() }
                        await refreshWallet()
                    }
                    .onReceive(NotificationCenter.default.publisher(
                        for: UIApplication.didBecomeActiveNotification)) { _ in
                        Task { await refreshWallet() }
                    }
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
            await onDone(c, p)
        } catch {
            err = "登记失败：\(error.localizedDescription)"
        }
        busy = false
    }
    private var walletText: String {
        if walletFree < 0 { return "余额 …" }
        return String(format: "余额 %.2f 元 · 一条 %.2f 元",
                      Double(walletFree) / 100.0, Double(walletPrice) / 100.0)
    }

    private var walletShort: Bool {
        walletFree >= 0 && walletFree < walletPrice
    }

    private func refreshWallet() async {
        if let w = await ActLab.wallet() {
            walletFree = w.可用 ?? 0
            walletPrice = w.单价 ?? 120
        }
    }

    /// 打开台子的充值页（带登录票）。安卓也是打开这同一个网页。
    private func openPay() {
        let tk = Ticket.current.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let u = URL(string: ActLab.base + "/pay?t=" + tk) {
            UIApplication.shared.open(u)
        }
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
