import SwiftUI
import UIKit

// MARK: - 主界面
//
// ★★ 这一版（v36）起，界面按 **安卓 `activity_main.xml`** 摆，不再是自己另做一套：
//   顶栏（它在哪 · 右上「我」）→ 三屏（它 / 社区 / 排行）→ 底栏三格。
//   颜色取 Tailwind 官方色板，跟安卓 `res/values/colors.xml` 是同一批值。
//
//   为什么这件事拖到现在才做：iOS 这边原来是「假状态栏 + 一个方房间 + 三个胶囊 +
//   一条常驻输入框」，安卓是「顶栏 + 三屏 + 底栏」。两套壳子从没对齐过。
//   现在先把壳子和三屏对齐；v41 起「角色」那一层搬过来了（Act/ 目录），
//   陪伴 / 酒馆那两层还差。

// MARK: - 色板（Tailwind 官方默认值，一个都没自己调）

enum Tw {
    static let gray50   = Color(hex: 0xF9FAFB)
    static let gray100  = Color(hex: 0xF3F4F6)
    static let gray200  = Color(hex: 0xE5E7EB)
    static let gray300  = Color(hex: 0xD1D5DB)
    static let gray400  = Color(hex: 0x9CA3AF)
    static let gray500  = Color(hex: 0x6B7280)
    static let gray600  = Color(hex: 0x4B5563)
    static let gray700  = Color(hex: 0x374151)
    static let gray900  = Color(hex: 0x111827)
    static let red600   = Color(hex: 0xDC2626)
    // 2026-10-24：礼物那张卡用的浅红底 + 浅红边（Tailwind red-50 / red-200）
    static let red50    = Color(hex: 0xFEF2F2)
    static let red200   = Color(hex: 0xFECACA)
    static let green500 = Color(hex: 0x22C55E)
    static let white    = Color.white
}

// MARK: - 台子上的数据

struct StaffItem: Decodable, Identifiable {
    let id: String
    let name: String
    let owner: String?
    let tagline: String?
    let note: String?
    let skills: [String]?
    let hires: Int?
    let on: Bool?
}

struct WantItem: Decodable, Identifiable {
    let id: String
    let by: String?
    let what: String
    let note: String?
    let contact: String?
    let done: Bool?
}

private struct StaffResp: Decodable { let staff: [StaffItem]? }
private struct WantResp: Decodable { let wants: [WantItem]? }

// MARK: - 房间框的边长
// 拖猫的时候要把手指位移换算成 720 画布的像素，所以得知道框有多大。

private struct StageWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// ★ 这个类**不要**标 `@MainActor`：
///   `@StateObject private var feed = LabFeed()` 这个默认值是在 View 的 init 里求值的，
///   而 View 的 init 不是主线程隔离的 —— 标了就会报
///   「Call to main actor-isolated initializer in a synchronous nonisolated context」。
///   改成在 `Task` 里算完再 `MainActor.run` 写回，效果一样，编译不炸。
final class LabFeed: ObservableObject {

    /// 台子。跟安卓 `CatRoster.LAB_URL` 是同一个。
    static let base = "https://still-ui-design.app.workbuddy.host"

    @Published var staff: [StaffItem] = []
    @Published var wants: [WantItem] = []
    @Published var loading = false
    @Published var err: String?

    private var loadedOnce = false

    func loadIfNeeded() {
        guard !loadedOnce, !loading else { return }
        load()
    }

    func load() {
        guard !loading else { return }
        loading = true
        err = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let s: StaffResp = try await self.get("/api/staff")
                let w: WantResp = try await self.get("/api/wants")
                await MainActor.run {
                    self.staff = s.staff ?? []
                    self.wants = w.wants ?? []
                    self.loadedOnce = true
                    self.loading = false
                }
            } catch {
                await MainActor.run {
                    self.err = "没取上：\(error.localizedDescription)"
                    self.loading = false
                }
            }
        }
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard let u = URL(string: Self.base + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: u)
        req.stillStamp()      // ★ 登录制：贴票
        req.timeoutInterval = 12
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - 全局那几个「活的东西」
//
// ★★★ 为什么要单拎出来一个壳：`PetEngine` 的主循环是 **30Hz**，
//   它一有更新，凡是「观察它」的 View 整棵都会重建 —— 一秒 30 次。
//   v36 就是让主界面直接观察了引擎，结果：
//     · 按钮按下去还没来得及抬手，整棵树已经被重建掉了 ⇒ 点了没反应
//     · 抢键盘那一下（异步）被反复打断 ⇒ 键盘不弹
//     · 切后台的时机被拖后 ⇒ 小窗起不来
//   这三个毛病是同一个根。修法就是**别让主界面观察它**：
//   引擎照跑，只有真正显示它的那张诊断卡去观察；主界面拿的是同一个实例。

@MainActor
final class AppCore {
    static let shared = AppCore()
    let engine = PetEngine()
    let pip = PiPController()
    let feed = LabFeed()
    private init() {}
}

// MARK: - 主视图

@MainActor
struct MainHomeView: View {

    /// 不观察 —— 只拿来调 start / stop
    private let core = AppCore.shared
    /// 这两个更新很稀（小窗开合、播到哪一段、社区数据），可以观察
    @ObservedObject private var pip = AppCore.shared.pip
    @ObservedObject private var feed = AppCore.shared.feed

    @Environment(\.scenePhase) private var scenePhase

    /// 0 它 / 1 社区 / 2 排行
    @State private var tab = 0
    @State private var showMe = false
    /// 顶部那条输入框开着没有
    @State private var talkOpen = false
    /// 点过几个按钮 —— 自检用：按了没反应时，先看这个数字动没动
    @State private var taps = 0
    /// 角色（动作库）那一页开着没有
    @State private var actOpen = false
    /// ★ v64：小窗上按了那个键 —— 要在**中间**弹一个小框问它说什么（不是整页对话页）。
    @State private var quickAsk = false
    @State private var quickText = ""

    private func hit() { taps += 1 }

    /// 屏幕的点尺寸。有刘海的机器不会出现 320x480 —— 出现就是还跑在兼容模式里。
    static var screenTag: String {
        let b = UIScreen.main.bounds
        return "\(Int(b.width))x\(Int(b.height))"
    }

    // MARK: - 说一句
    //
    // ★ v44：这里不再有任何「跟它说话」的入口函数。
    //   v39 走的是系统弹窗（UIAlertController + addTextField），
    //   那一版解决了「弹得出来」，但没解决「键盘起不来」——
    //   而且多一道弹窗就多一道我们自己控制不了的时序。
    //   现在输入框常驻在主页（见 Talk/HomeComposer.swift），点一下就是系统原生聚焦。

    var body: some View {
        ZStack(alignment: .bottom) {
            Tw.gray50.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                content
                // ★ v44：输入框直接摆在主页上（他要的「跟豆包一样」）。
                //   只在「它」这一屏出现 —— 社区 / 排行两屏不跟猫说话。
                // ★ 2026-10-30：常驻输入框删掉 —— 安卓首页没有输入框，聊天在第二格。
            //   （HomeComposer 文件先留着，里面的 Siri 提示和键盘探针还在用。）
                bottomBar
            }

            // 输入条：v38 起不再飘在这里了。
            // ★ 顶部那条从 v36 折腾到 v37 都死在「键盘不弹」，根子是浮动视图 + 转场动画 +
            //   顶部贴边，每一环都可能被系统静默吞掉。现在改成**一整页对话页**
            //   （见 Talk/TalkPage.swift），输入条钉在页面底部 —— 那是最不容易出错的布局。

            if showMe {
                meSheet
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(4)
            }
        }
        // ★ v95：第一回进首页，把「它在这儿 / 叫它来 / 我」三处挖亮讲一遍。
        //   只讲一遍。讲过就记在本地，再也不弹。
        .overlayPreferenceValue(CoachAnchorKey.self) { CoachOverlay(册: "首页v1", 锚: $0) }
        // ★ 对话页用 fullScreenCover 展示：它是**独立的一层呈现**，
        //   有自己完整的视图树和生命周期 —— 键盘在这里不会像飘在主页上那样被吞掉。
        .fullScreenCover(isPresented: $talkOpen) {
            TalkPage()
        }
        // ★★★ v64：小窗上那个键按下去 ＝「问它」。
        //
        //   他的原话：「问它点了就会和豆包那样弹出一个小窗跟我画中画又不冲突，
        //   你只要做一件事，就是原本这个暂停键触发的是跟它说话，现在换成问它就好了」。
        //
        //   ⇒ 不要再打开整页对话页（太重、也不是他的意思），
        //     就在**屏幕中间**弹一个跟豆包一样的小框：一个输入框、取消、说。
        //   ★ 用 `alert` 而不是自绘：系统框自带键盘、自带焦点、写完点一下就收，
        //     外观跟豆包那个几乎一致，也不用我们管键盘什么时候起来。
        .alert("对\(PetName.current)说什么？", isPresented: $quickAsk) {
            TextField("说点什么…", text: $quickText)
            Button("取消", role: .cancel) { quickText = "" }
            Button("说") {
                let s = quickText.trimmingCharacters(in: .whitespacesAndNewlines)
                quickText = ""
                guard !s.isEmpty else { return }
                Task { _ = await CatTalk.say(s) }
            }
        } message: {
            Text("说完它会当场动一下")
        }
        // ★★★ v65：小窗上那个键把 App 叫到前台，走的就是这个 activity。
        //   `requestSceneSessionActivation` 传过来的 `NSUserActivity`，
        //   到前台后由这里接住 —— 接住就弹框，一步都不绕。
        .onContinueUserActivity("com.still.Still.talk") { _ in
            quickAsk = true
        }
        // 角色（动作库）：安卓那边是「它」这屏上的「角色」格子点进去的那一页
        .fullScreenCover(isPresented: $actOpen) {
            ActLibPage()
        }
        .onAppear(perform: boot)
        .onDisappear {
            core.engine.stop()
            pip.stop()
        }
        // 热启动：App 已经在后台活着，点了通知
        .onReceive(NotificationCenter.default.publisher(for: .stillSummon)) { _ in
            AppDelegate.pendingSummon = false
            pip.summonFromNotification()
        }
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .active:
                core.engine.start()
                pip.backInForeground()
                // 从「轻点背面」那条快捷指令进来的：把输入条弹出来
                if StillIntentBridge.consumeTalk() { talkOpen = true }
                // 小窗上按了那个键：只要一个小框，不打开整页
                if StillIntentBridge.consumeQuickAsk() { quickAsk = true }
            case .background:
                core.engine.stop()
                core.engine.save()
                pip.leaveApp()
            default:
                break
            }
        }
    }

    // MARK: - 起

    private func boot() {
        PiPController.shared = pip
        core.engine.start()
        pip.start()
        // ★ 上次装过台子上的猫：启动这一刻就把它交给帧泵。
        //   漏了这一句，重启 App 后小窗会变回自带那只，而角色页里还写着「正在用」。
        pip.catSwitched()
        IslandProbe.run()
        Notifier.requestAuthorization { _ in Notifier.reschedule() }

        if AppDelegate.pendingSummon {
            AppDelegate.pendingSummon = false
            pip.summonFromNotification()
        }

        // 冷启动也可能是「轻点背面」拉起来的 —— onAppear 早于 scenePhase 变 active。
        if StillIntentBridge.consumeTalk() { talkOpen = true }
        // 冷启动也可能是「小窗上按了那个键」拉起来的
        if StillIntentBridge.consumeQuickAsk() { quickAsk = true }
    }

    // MARK: - 顶栏（安卓 where_dot / where_room / me_btn）

    private var topBar: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(pip.active ? Tw.green500 : Tw.gray300)
                .frame(width: 8, height: 8)

            Text(pip.active ? "小窗" : "桌面")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Tw.gray900)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(AppVersion.tag)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Tw.red600)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Tw.red600.opacity(0.10)))

            Button {
                hit()
                showMe = true
            } label: {
                Image(systemName: "person.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Tw.gray900)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Tw.gray100))
            }
            .buttonStyle(PressStyle(scale: 0.9))
            // ★ v95：给引导留个记号
            .coachAnchor("我")
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    // MARK: - 三屏

    private var content: some View {
        Group {
            switch tab {
            case 0: HerPane(pip: pip, openMe: { showMe = true },
                            onHit: hit, taps: taps,
                            onRole: { actOpen = true })
            case 1: CommPane(feed: feed)
            default: RankPane(feed: feed)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: tab) {
            if tab != 0 { feed.loadIfNeeded() }
        }
    }

    // MARK: - 底栏（对齐安卓现状：只有两格）
    //
    // ★ 2026-10-30：安卓那边 MainActivity L124-135 已经改成
    //   第二格文案「聊天」、点了直接去聊天页；第三格「排行」直接 setVisibility(GONE)。
    //   所以这边也只要两格。

    private var bottomBar: some View {
        HStack(spacing: 0) {
            tabItem(0, "它", "pawprint.fill")
            chatTabItem()
        }
        .padding(.top, 6)
        .background(
            Tw.white
                .overlay(alignment: .top) {
                    Rectangle().fill(Tw.gray200).frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    /// 第二格「聊天」：不切屏，直接开对话页（跟安卓 tab_comm → 去聊天页() 一致）。
    private func chatTabItem() -> some View {
        Button {
            hit()
            talkOpen = true
        } label: {
            VStack(spacing: 3) {
                Capsule()
                    .fill(Color.clear)
                    .frame(width: 16, height: 2.5)
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Tw.gray400)
                Text("聊天")
                    .font(.system(size: 10))
                    .foregroundStyle(Tw.gray400)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 3)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func tabItem(_ i: Int, _ title: String, _ icon: String) -> some View {
        Button {
            hit()
            tab = i
        } label: {
            VStack(spacing: 3) {
                // 选中的那一条小横杠（安卓 tab_*_bar）
                Capsule()
                    .fill(i == tab ? Tw.gray900 : Color.clear)
                    .frame(width: 16, height: 2.5)
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(i == tab ? Tw.gray900 : Tw.gray400)
                Text(title)
                    .font(.system(size: 10, weight: i == tab ? .bold : .regular))
                    .foregroundStyle(i == tab ? Tw.gray900 : Tw.gray400)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 3)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.93))
    }

    // MARK: - 「我」：从下面升上来的那一层
    //
    // 原来这些东西是散在首页上的（假状态栏、三个胶囊、一个诊断折角）。
    // 安卓是把它们全收进右上角「我」里 —— 首页只留它自己。

    private var meSheet: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.24)
                .ignoresSafeArea()
                .onTapGesture { showMe = false }

            VStack(spacing: 0) {
                HStack {
                    Text("我")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Tw.gray900)
                    Spacer()
                    Button {
                        hit()
                        showMe = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Tw.gray500)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Tw.gray100))
                    }
                    .buttonStyle(PressStyle(scale: 0.9))
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 10)

                ScrollView {
                    VStack(spacing: 10) {
                        howToBackTap
                        // ★ 只有这一张卡观察 30Hz 的引擎 —— 主界面不观察，
                        //   否则整棵树一秒重建 30 次，按钮和键盘都会被冲掉。
                        SettingsPage()   // ★ 2026-10-30：对齐安卓，散装面板收成设置页
                        roomControls
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
            .frame(maxHeight: 620)
            .background(
                Tw.white
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .ignoresSafeArea(edges: .bottom)
            )
        }
    }

    /// 「轻点背面」怎么接上 —— 这一段是给手指看的说明书。
    ///
    /// ★ 为什么必须写在这儿：iOS 的「双击背面」是系统辅助功能，
    ///   App 里没有任何代码能直接接管它，只能由你把它绑到一条快捷指令上。
    ///   不把这一步写清楚，它就永远只是个「没法呼出」的传说。
    private var howToBackTap: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Tw.red600)
                Text("放上去之后，它会自己出去玩，也会自己回来")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Tw.gray900)
            }
            Text("① 先到「快捷指令」建一条：搜「还在」→ 选「打开还在的输入框」→ 存成「叫猫」")
                .font(.system(size: 11.5))
                .foregroundStyle(Tw.gray500)
                .fixedSize(horizontal: false, vertical: true)
            Text("② 设置 → 辅助功能 → 触控 → 轻点背面 → 双击 → 选「叫猫」")
                .font(.system(size: 11.5))
                .foregroundStyle(Tw.gray500)
                .fixedSize(horizontal: false, vertical: true)
            Text("绑一次就好。以后双击手机背面，输入条直接弹出来，键盘自己起来。")
                .font(.system(size: 11.5))
                .foregroundStyle(Tw.gray400)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Tw.red600.opacity(0.06))
        )
    }

    private var roomControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                actionPill(pip.active ? "收回小窗" : "放进小窗", primary: true) {
                    pip.toggle()
                }
                // ★ v44：「跟它说话」这颗没了 —— 主页底部那个输入框就是它。
                //   这一格换成聊天记录，历史对话还是在单独的页里看。
                actionPill("聊天记录", primary: false) {
                    showMe = false
                    talkOpen = true
                }
            }
            HStack(spacing: 8) {
                actionPill("叫它来", primary: false) {
                    Notifier.summonNow()
                }
                // ★ 2026-10-23（他的原话）：「重排提醒这些去掉」——
                //   这一格原来在这儿，是三条路里最后漏掉的一处（另两处：更多网格、房间条）。
                //   它只是"把通知按行程重算一遍"的排障键，用户看不懂也不会用。
                actionPill("发一条能打字的通知", primary: false) {
                    Notifier.askInput(after: 1.0)
                    showMe = false
                }
            }
            Text(pip.note)
                .font(.system(size: 11))
                .foregroundStyle(Tw.gray400)

            // ★ v42：输入体检。装一次就能看出键盘为什么起不来 ——
            //   它自己管自己的刷新，不会把这一屏带着每秒重建。
            KeyboardDiagStrip()
        }
    }

    private func actionPill(_ t: String, primary: Bool, _ run: @escaping () -> Void) -> some View {
        Button {
            hit()
            run()
        } label: {
            Text(t)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(primary ? Tw.white : Tw.gray900)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(primary ? Tw.red600 : Tw.gray100)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

// MARK: - ① 它

struct HerPane: View {

    @ObservedObject var pip: PiPController
    var openMe: () -> Void
    var onHit: () -> Void = {}
    /// 自检里那行「点了几下」——按了没反应时，先看这个数字动没动
    var taps: Int = 0
    /// 点「角色」那一格 —— 打开动作库（安卓 RoleActivity／ActActivity 那一层）
    var onRole: () -> Void = {}
    /// 键盘到底起来没有，要跟着变，所以得观察
    @ObservedObject private var focus = TalkFocus.shared

    // MARK: 这一版新加的几层（都从这一屏进，不藏在别处）

    // MARK: 主页框里的「抓起来 / 拖动 / 走回中间」（2026-10-23）
    /// 框的边长 —— 手指位移要换算成 720 画布的像素，没它就只能按比例瞎猜
    @State private var stageW: CGFloat = 0
    /// 猫现在的偏移（720 画布像素，`0,0` = 正中）
    @State private var catDX: Double = 0
    @State private var catDY: Double = 0
    /// 拎起来了没有。没拎起来的时候拖动**不接管手指**（否则主页翻不了页）
    @State private var grabbing = false
    /// 长按已经触发过（正在挣扎）—— 松手时不能再当成"点了一下"
    @State private var holding = false
    /// 长按计时器（手指按住 0.5 秒没动就挣扎）
    @State private var holdTimer: Timer?
    /// 松手之后「过一会儿自己走回去」的那一趟
    @State private var backWork: DispatchWorkItem?
    /// 往回走时的逐帧推进
    @State private var walkTimer: Timer?

    /// 框里那一串手势 —— 一按上就归它，主页不许跟着动。
    ///
    /// ★★★ 2026-10-24 他明确要求「安卓 iOS 一样」：**在展示框里划，不该带着整页往下滚**。
    ///   以前这里只在"已经拎起来"时才接管手指（`including: grabbing ? .all : .subviews`），
    ///   没拎起来的时候一划就被外面的 ScrollView 收走 —— 于是同一个手指既要滚页面、
    ///   又要挪角色，两件事打架，手感又涩又飘（他的原话）。
    ///   现在改成**按下这一毫秒就接管**（`minimumDistance: 0`），整个框里只有一件事：
    ///   跟猫玩。要翻页就去框外面划。
    ///
    ///   三种手势各归各的：
    ///     · 按住不动 0.5 秒 → 拎起来（挣扎）
    ///     · 一动 → 也算拎起来，之后跟着手指走
    ///     · 按一下就走 → 放下（点一下是"拎起来"，再点一下是"放下"）
    private var catDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let d = hypot(Double(v.translation.width), Double(v.translation.height))
                if d < 1 {
                    // 刚按下：起一个长按计时（跟安卓那边同一个 0.5 秒）
                    if !grabbing && holdTimer == nil {
                        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                            holdTimer = nil
                            if !grabbing { holding = true; grabCat() }
                        }
                    }
                } else if d > 6 {
                    holdTimer?.invalidate()
                    holdTimer = nil
                    if !grabbing { grabCat() }   // 一动就拎起来，不用先点一下
                }
                guard grabbing else { return }
                let s = stageScale
                // ★ 量化到 0.5pt：手指每帧 0.02 的抖动会一路传到帧泵，
                //   看起来就是"发飘"。取整之后同样的手感，画面稳很多。
                func q(_ x: Double) -> Double { (x * 2).rounded() / 2 }
                pushPose(dx: q(catDX + Double(v.translation.width) * s),
                         dy: q(catDY + Double(v.translation.height) * s))
            }
            .onEnded { v in
                holdTimer?.invalidate()
                holdTimer = nil
                if holding {            // 长按过：松手就当"放下"，别再算成点了一下
                    holding = false
                    if grabbing { dropCat() }
                    return
                }
                let d = hypot(Double(v.translation.width), Double(v.translation.height))
                if !grabbing {
                    if d <= 6 { grabCat() }   // 原地一下 = 拎起来
                    return
                }
                let s = stageScale
                catDX = clampX(catDX + Double(v.translation.width) * s)
                catDY = clampY(catDY + Double(v.translation.height) * s)
                dropCat()
            }
    }

    /// 框上 1pt 等于画布里的几个像素。
    private var stageScale: Double {
        stageW > 0 ? 720.0 / Double(stageW) : 1
    }

    /// 别让它被拖出画面（拖出屏幕外就找不回来了，而且这一拖是「它不见了」级别的 bug）
    private func clampX(_ v: Double) -> Double { min(240, max(-240, v)) }
    private func clampY(_ v: Double) -> Double { min(120, max(-160, v)) }

    private func pushPose(dx: Double, dy: Double, mirror: Bool = false) {
        pip.setCatPose(dx: dx, dy: dy, zoom: 1, mirror: mirror)
    }

    /// 点一下框：没拎起来就拎起来，已经拎着就放下。
    private func tapCat() {
        if grabbing { dropCat() } else { grabCat() }
    }

    /// ★ 2026-10-31：拎起来 / 放下都要有反馈（统一那套：轻震动 + 点按音）
    private func feel() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        SoundKit.shared.tap()
    }

    /// 拎起来的反馈
    private func grabCat() {
        cancelBack()
        stopWalk()
        grabbing = true
        pip.grabCat()          // 立刻开始挣扎（被测到的时候要有反应）
        SoundKit.shared.meow()
        feel()
    }

    /// 放下：先坐在原地，5 秒后自己走回正中。
    private func dropCat() {
        grabbing = false
        pip.dropCat()
        feel()                 // ★ 放下也给一次：轻震动 + 点按音
        scheduleWalkBack()
    }

    private func cancelBack() {
        backWork?.cancel()
        backWork = nil
    }

    private func stopWalk() {
        walkTimer?.invalidate()
        walkTimer = nil
    }

    /// 松手之后那 5 秒。
    /// ★ 为什么不是马上走：他原话是「持续一段时间后都自动走到中心位置」——
    ///   放下的那一刻它先坐着缓一下，再自己回去，才像活的东西。
    private func scheduleWalkBack() {
        cancelBack()
        guard catDX != 0 || catDY != 0 else { return }
        let w = DispatchWorkItem { walkBack() }
        backWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: w)
    }

    /// 走回正中。**用走动那段素材，不是滑回去** —— 滑回去看着像在拖图片。
    private func walkBack() {
        guard !grabbing else { return }
        let d = (catDX * catDX + catDY * catDY).squareRoot()
        if d < 6 {
            catDX = 0; catDY = 0
            pushPose(dx: 0, dy: 0)
            return
        }

        let secs = min(3.2, max(0.9, d / 220.0))
        let fromX = catDX, fromY = catDY
        // 往右走（终点在右边）时把猫翻过来 —— 素材里的猫是朝左拍的
        let mirror = catDX < 0
        pip.pinWalk(secs + 0.4)

        stopWalk()
        let t0 = Date()
        let t = Timer(timeInterval: 1.0 / 20.0, repeats: true) { timer in
            // 中途又被拎起来：立刻停，别跟手指抢
            if grabbing {
                timer.invalidate()
                walkTimer = nil
                return
            }
            let p = min(1.0, Date().timeIntervalSince(t0) / secs)
            // 缓入缓出：起步和收尾都慢一点，看起来像「走」，不像被匀速拖
            let e = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
            let nx = fromX * (1 - e), ny = fromY * (1 - e)
            catDX = nx; catDY = ny
            pushPose(dx: nx, dy: ny, mirror: mirror)
            if p >= 1 {
                timer.invalidate()
                walkTimer = nil
                catDX = 0; catDY = 0
                pushPose(dx: 0, dy: 0)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        walkTimer = t
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // 它的房间
                //
                // ★★★ 2026-10-23（他的原话）：「因为 IOS 无法在桌面和画中画互动，
                //   安卓是可以通过点击浮窗互动的，那把这套互动改到主页去，
                //   点击抓起以及移动这些都搬到主页那个框框里去」。
                //
                //   所以这个框现在能碰了：
                //     · 点一下 → 拎起来（挣扎），再点一下 / 松手 → 放下；
                //     · 拎着的时候拖 → 它跟着手指走；
                //     · 松手后原地待 5 秒 → 自己走回正中。
                //
                //   ★ 为什么先「点」再「拖」，而不是一按就能拖：
                //     这个框在 ScrollView 里。一按就抢触摸的话，**从猫身上起手的滑动
                //     就再也翻不了页了**（这个框占了大半屏，会变成「主页滑不动」）。
                //     所以拿起来的动作归「点」，拖动只在「已经拿起来」时接管手指。
                //
                //   ★ 原来这里有个长按菜单（带它进现实 / 角色 / 背包 / 派它出门 / 扫一扫…）。
                //     里边七样**下面每一格都有可见的入口**（角色·带它进现实 / 扫一扫·派它出门 /
                //     背包·工作台 / 放进小窗·叫它来），所以撤掉不丢功能 ——
                //     而且长按菜单跟「按住猫」本来就会打架。
                RoomStage(controller: pip)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(key: StageWidthKey.self, value: g.size.width)
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contentShape(Rectangle())
                    .onPreferenceChange(StageWidthKey.self) { w in
                        if w > 0 { stageW = w }
                    }
                    .onTapGesture { tapCat() }
                    .highPriorityGesture(catDrag)
                    // 这一页重新出现时，猫回正中 ——
                    // 界面上的偏移和帧泵里的偏移必须是同一个数，不能一个清零一个还记着
                    .onAppear {
                        stopWalk()
                        cancelBack()
                        grabbing = false
                        catDX = 0
                        catDY = 0
                        pip.resetCatPose()
                    }
                    .onDisappear {
                        stopWalk()
                        cancelBack()
                    }
                    // ★ v95：给引导留个记号 —— 镂空蒙层才知道该把哪儿挖亮
                    .coachAnchor("房间")
                    .padding(.bottom, 8)

                // ★ 这一行是**真的状态**，不是文案：
                //   小窗能不能起、卡在哪一步，全在这儿写着。真机上第一眼看它。
                Text(pip.note)
                    .font(.system(size: 12))
                    .foregroundStyle(pip.active ? Tw.green500 : Tw.gray500)
                    .lineLimit(2)
                    .padding(.horizontal, 4)


                // 小标题（安卓 .cap）
                HStack(spacing: 8) {
                    Text("它")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Tw.gray900)
                    Text("下面直接打字说，或者点一格")
                        .font(.system(size: 11))
                        .foregroundStyle(Tw.gray400)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 11)

                // ★ 方案 D（2026-10-24）：它自己买礼物送给你 —— 算力回收。
                //   规矩：**不预告、不询问**，界面上只说「它给你带了东西」，点开才知道是什么。
                //   人事前只授权一次（一个每月额度），之后它自己决定。详见 `Credit.swift` 顶上。
                GiftCardsView()

                // ★ v44：原来那颗「跟它说话」的大红按钮没了。
                //   他要的是「跟豆包一样，主页放个输入框直接打」——
                //   输入框常驻在页面底部（Talk/HomeComposer.swift），
                //   这里再留一颗按钮就是同一条路走两遍。
                //   它回的话也跟着挪到输入框正上方，发完立刻能看见，不用滚。

                // ★ 2026-10-30：首页排布对齐安卓 —— 两张卡 + 一颗黑主键。
                //   安卓那屏是：展示框 →「角色 / 陪伴」两卡 →「让它出现在屏幕上」→ 底栏。
                HStack(spacing: 12) {
                    homeCard("角色", "做动作 · 换一只", "cat.fill") { onRole() }
                    homeCard("陪伴", pip.active ? "收回小窗" : "睡在你桌面上", "pip.fill") {
                        pip.toggle()
                    }
                }
                .padding(.bottom, 12)

                // 一颗黑主键（安卓那颗「让它出现在屏幕上」）
                Button {
                    SoundKit.shared.tap()
                    if !pip.active { pip.toggle() } else { Notifier.summonNow() }
                } label: {
                    Text(pip.active ? "让它回到小窗" : "让它出现在屏幕上")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Tw.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .background(Capsule().fill(Tw.gray900))
                }
                .buttonStyle(PressStyle(scale: 0.97))
                .padding(.bottom, 10)
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 18)
        }
        .scrollIndicators(.hidden)
    }

    /// 首页那两张卡（安卓「角色 / 陪伴」同款）：白底 + 1px 描边 + 标题 + 小字。
    private func homeCard(_ title: String, _ sub: String, _ icon: String,
                          tap: @escaping () -> Void) -> some View {
        Button {
            SoundKit.shared.tap()
            tap()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(Tw.gray900)
                    .padding(.bottom, 2)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tw.gray900)
                Text(sub)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tw.gray400)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Tw.white)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Tw.gray200, lineWidth: 1))
            )
        }
        .buttonStyle(PressStyle(scale: 0.97))
    }

    private func tile(_ title: String, _ sub: String, _ icon: String,
                      _ run: @escaping () -> Void) -> some View {
        Button {
            onHit()
            run()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(Tw.gray900)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tw.gray900)
                Text(sub)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Tw.gray400)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Tw.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Tw.gray200, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

// MARK: - ② 社区

struct CommPane: View {

    @ObservedObject var feed: LabFeed
    @State private var sub = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                chip("员工墙 · \(feed.staff.count)", 0)
                chip("需求墙 · \(feed.wants.count)", 1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 2)
            .padding(.bottom, 10)

            if feed.loading && feed.staff.isEmpty && feed.wants.isEmpty {
                loadingView
            } else if let e = feed.err, feed.staff.isEmpty {
                errorView(e)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        if sub == 0 {
                            ForEach(feed.staff) { s in staffCard(s) }
                            if feed.staff.isEmpty { emptyText("墙上还没有员工。") }
                        } else {
                            ForEach(feed.wants) { w in wantCard(w) }
                            if feed.wants.isEmpty { emptyText("还没有人提需求。") }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.hidden)
            }
        }
        .onAppear { feed.loadIfNeeded() }
    }

    private func chip(_ t: String, _ i: Int) -> some View {
        Button { sub = i } label: {
            Text(t)
                .font(.system(size: 12, weight: sub == i ? .semibold : .regular))
                .foregroundStyle(sub == i ? Tw.white : Tw.gray600)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(sub == i ? Tw.gray900 : Tw.gray100)
                )
        }
        .buttonStyle(PressStyle(scale: 0.94))
    }

    private func staffCard(_ s: StaffItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill((s.on ?? true) ? Tw.green500 : Tw.gray300)
                    .frame(width: 6, height: 6)
                Text(s.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Tw.gray900)
                if let o = s.owner, !o.isEmpty {
                    Text("· \(o) 的")
                        .font(.system(size: 11))
                        .foregroundStyle(Tw.gray400)
                }
                Spacer(minLength: 0)
                if let h = s.hires {
                    Text("被请 \(h)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Tw.gray400)
                }
            }
            if let t = s.tagline, !t.isEmpty {
                Text(t)
                    .font(.system(size: 12))
                    .foregroundStyle(Tw.gray600)
            }
            if let sk = s.skills, !sk.isEmpty {
                Text(sk.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(Tw.gray400)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func wantCard(_ w: WantItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(w.what)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Tw.gray900)
            if let n = w.note, !n.isEmpty {
                Text(n)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tw.gray500)
            }
            HStack(spacing: 6) {
                if let b = w.by, !b.isEmpty {
                    Text(b)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Tw.gray400)
                }
                Spacer(minLength: 0)
                Text((w.done ?? false) ? "已接" : "等人接")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle((w.done ?? false) ? Tw.green500 : Tw.red600)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func emptyText(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 12))
            .foregroundStyle(Tw.gray400)
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("正在从服务器上取…")
                .font(.system(size: 12))
                .foregroundStyle(Tw.gray400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ e: String) -> some View {
        VStack(spacing: 12) {
            Text(e)
                .font(.system(size: 12))
                .foregroundStyle(Tw.gray500)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Button { feed.load() } label: {
                Text("再试一次")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Tw.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Tw.gray900))
            }
            .buttonStyle(PressStyle(scale: 0.94))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - ③ 排行
//
// 安卓两个榜排同一份名单：酒馆榜看被请次数，生命体榜看挂了几样本事。
// 数据源一样是 /api/staff —— 台子上没有单独的榜接口，别去编一个。

struct RankPane: View {

    @ObservedObject var feed: LabFeed
    @State private var which = 0

    private var rows: [StaffItem] {
        if which == 0 {
            return feed.staff.sorted { ($0.hires ?? 0) > ($1.hires ?? 0) }
        }
        return feed.staff.sorted { ($0.skills?.count ?? 0) > ($1.skills?.count ?? 0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                chip("酒馆榜", 0)
                chip("AI 生命体榜", 1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 2)
            .padding(.bottom, 10)

            if feed.loading && feed.staff.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在从服务器上取…")
                        .font(.system(size: 12))
                        .foregroundStyle(Tw.gray400)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let e = feed.err, feed.staff.isEmpty {
                VStack(spacing: 12) {
                    Text(e)
                        .font(.system(size: 12))
                        .foregroundStyle(Tw.gray500)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                    Button { feed.load() } label: {
                        Text("再试一次")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Tw.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(Tw.gray900))
                    }
                    .buttonStyle(PressStyle(scale: 0.94))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, s in
                            row(i + 1, s)
                            if i < rows.count - 1 {
                                Rectangle().fill(Tw.gray100).frame(height: 0.5)
                                    .padding(.leading, 44)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.hidden)
            }
        }
        .onAppear { feed.loadIfNeeded() }
    }

    private func chip(_ t: String, _ i: Int) -> some View {
        Button { which = i } label: {
            Text(t)
                .font(.system(size: 12, weight: which == i ? .semibold : .regular))
                .foregroundStyle(which == i ? Tw.white : Tw.gray600)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(which == i ? Tw.gray900 : Tw.gray100))
        }
        .buttonStyle(PressStyle(scale: 0.94))
    }

    private func row(_ n: Int, _ s: StaffItem) -> some View {
        HStack(spacing: 10) {
            Text("\(n)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(n <= 3 ? Tw.red600 : Tw.gray400)
                .frame(width: 22, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(s.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Tw.gray900)
                if let t = s.tagline, !t.isEmpty {
                    Text(t)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Tw.gray400)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Text(which == 0 ? "\(s.hires ?? 0) 次" : "\(s.skills?.count ?? 0) 样本事")
                .font(.system(size: 11))
                .foregroundStyle(Tw.gray500)
        }
        .padding(.vertical, 11)
    }
}
