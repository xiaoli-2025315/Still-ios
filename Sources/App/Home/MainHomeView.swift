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
    static let gray900  = Color(hex: 0x111827)
    static let red600   = Color(hex: 0xDC2626)
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
                if tab == 0 { HomeComposer() }
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
        // ★ 对话页用 fullScreenCover 展示：它是**独立的一层呈现**，
        //   有自己完整的视图树和生命周期 —— 键盘在这里不会像飘在主页上那样被吞掉。
        .fullScreenCover(isPresented: $talkOpen) {
            TalkPage()
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

    // MARK: - 底栏三格（安卓 tab_her / tab_comm / tab_rank）

    private var bottomBar: some View {
        HStack(spacing: 0) {
            tabItem(0, "它", "pawprint.fill")
            tabItem(1, "社区", "person.2.fill")
            tabItem(2, "排行", "trophy.fill")
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
                        StatusPanelView(engine: core.engine)
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
                Text("双击背面叫它出来")
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
                actionPill("重排提醒", primary: false) {
                    Notifier.reschedule()
                }
            }
            HStack(spacing: 8) {
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // 它的房间
                RoomStage(controller: pip)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.bottom, 8)

                // ★ 这一行是**真的状态**，不是文案：
                //   小窗能不能起、卡在哪一步，全在这儿写着。真机上第一眼看它。
                Text(pip.note)
                    .font(.system(size: 12))
                    .foregroundStyle(pip.active ? Tw.green500 : Tw.gray500)
                    .lineLimit(2)
                    .padding(.horizontal, 4)

                // 自检：版本 · 点了几下 · 键盘 · 小窗
                HStack(spacing: 6) {
                    Text("自检")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Tw.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Tw.gray300))
                    // ★ v45：把**屏幕点尺寸**摆在这儿。
                    //   要是这一行还是 320x480，就说明 UILaunchScreen 没写进包里的 plist，
                    //   一眼就能看出来，不用再等我猜一轮。
                    Text("\(AppVersion.tag) · 屏\(MainHomeView.screenTag) · 键盘\(focus.keyboardUp ? "已起" : "未起") · 小窗\(pip.possible ? "可起" : "不可起")")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Tw.gray400)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 16)

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

                // ★ v44：原来那颗「跟它说话」的大红按钮没了。
                //   他要的是「跟豆包一样，主页放个输入框直接打」——
                //   输入框常驻在页面底部（Talk/HomeComposer.swift），
                //   这里再留一颗按钮就是同一条路走两遍。
                //   它回的话也跟着挪到输入框正上方，发完立刻能看见，不用滚。

                // 角色：安卓「它」这屏上的第一格入口 —— 点进去才是下一层
                // （一张卡一只它 · 右上「＋」登记新角色 · 点开看这套动作好了几条）
                HStack(spacing: 10) {
                    tile("角色", "一只它 · 这套动作好了几条", "cat.fill") { onRole() }
                }
                .padding(.bottom, 10)

                HStack(spacing: 10) {
                    tile("放进小窗", pip.active ? "收回" : "切出去它就跟着",
                         "pip.fill") { pip.toggle() }
                    tile("叫它来", "敲一下它就来", "hand.wave.fill") { Notifier.summonNow() }
                }
                .padding(.bottom, 10)

                HStack(spacing: 10) {
                    tile("重排提醒", "按行程重算", "bell.fill") { Notifier.reschedule() }
                    tile("更多", "诊断 · 时间机器", "ellipsis.circle.fill") { openMe() }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 18)
        }
        .scrollIndicators(.hidden)
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
            Text("正在从台子上取…")
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
                    Text("正在从台子上取…")
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
