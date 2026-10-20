import AppIntents
import Foundation

// MARK: - Siri 主路径
//
// 用户确认的主交互：用 Siri 跟它说话，**不打开 App、不打断你正在用的 App**。
//
// ★ 短语里的「还在」不是你手打的，是 \(.applicationName) —— 系统按 App 显示名替换。
//   好处是以后改名，Siri 认的短语跟着变，不用回来改代码。
//   App 显示名见 project.yml 的 CFBundleDisplayName。
//
// ★ 说法只有一种：先说「跟还在说句话」，Siri 会自己问「说什么？」，
//   你说完它就送进来 —— 这是**纯语音**那条，全程不打开 App。
//   想打字的话走下面那个 `AskStillIntent`。
//   （想让一句话直接说完做不到：短语槽位只收 AppEntity/AppEnum，String 收不了，见文件末尾。）
//
// ★★ 更正一条旧结论：以前这里写着「苹果不允许第三方 App 在通知里放输入框」——**那是错的**。
//   `UNTextInputNotificationAction` 从 iOS 9 就能用，通知拉开来就有一个系统画的输入框。
//   所以「在别的 App 里打字」是有路的：先出一条通知，再在通知上写。
//
// openAppWhenRun = false：在后台跑，前台不发生任何切换。

struct TalkToCatIntent: AppIntent {

    static var title: LocalizedStringResource = "跟它说句话"
    static var description = IntentDescription("对它说句话，它会当场动一下，然后回你一条通知。")

    static var openAppWhenRun: Bool { false }

    @Parameter(title: "你说的话", description: "你想对它说的话")
    var message: String

    static var parameterSummary: some ParameterSummary {
        Summary("跟它说 \(\.$message)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // 只有一条路，而且是纯后台的：
        //   壳挂着 → 角上那只猫当场抬头，你正在用的 App 一点都没被打断。
        //   壳没挂 → 只落一条通知。
        //
        // ★ 试过「借前台把壳叫出来」，放弃了：iOS 只允许前台起小窗，
        //   而借前台的两个口子都会打断你 ——
        //   一个弹「是否继续」，一个把 App 抢到眼前。
        //   为了省你点一下，去换一次打断，不划算。
        //   通知上留了「让它过来」，那一下是你主动的，按了就到位。
        //
        // ★ 这里 await 是有意的：Siri 说完那句问「说什么」的框不会马上消失，
        //   我们正好在这口气里把回话要回来（约 1 秒），而不是先给一句假的、
        //   过一会儿再换成真的 —— 换的那一下比等的那一下难看。
        await CatTalk.say(message)
        return .result()
    }
}

// MARK: - 打字那条：叫它出一条「能写字」的通知
//
// ★★★ 这是「在别的 App 里打不了字」的正解（v39）。
//   他一开始要的是「在微信里点一下就能给它打字」。iOS 没有悬浮窗权限，
//   那个做不到；但**通知自带一个系统输入框**（`UNTextInputNotificationAction`），
//   拉开通知就能写，写完点「说」，全程不离开他正在用的 App。
//
//   缺的从来不是输入框，是**入口** —— 原来这个入口挂在小窗的暂停键上，
//   而那个键被我们自己的 `controlsStyle` 删掉了（v39 已恢复）。
//   但键能不能回来不该押在一处，所以这里再给一条**零配置、不依赖小窗**的路：
//       说「嘿 Siri，叫还在出来说话」→ 后台发一条带输入框的通知 → 拉开来打字
//
//   `openAppWhenRun = false`：绝不把 App 抢到眼前，他还在原来的界面里。

struct AskStillIntent: AppIntent {

    static var title: LocalizedStringResource = "叫它出来说话"
    static var description = IntentDescription("不打开 App，直接来一条带输入框的通知，在上面写字给它。")

    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult {
        // 半秒后到 —— 让 Siri 那一屏先退掉，通知才看得见。
        Notifier.askInput(after: 0.8)
        return .result()
    }
}

// MARK: - 给「轻点背面」的那一个
//
// ★★ iOS 上「双击手机背面」不是一个 App 能自己注册的手势。
//   它是系统的「设置 → 辅助功能 → 触控 → 轻点背面」，
//   系统只允许你把**某一条快捷指令**绑上去，App 里没有任何 API 能直接接管。
//   所以这条路的形状是固定的：
//       轻点背面 → 跑一条快捷指令 → 这条快捷指令调我们下面这个 Intent
//                → 把 App 拉到前台 → 输入条弹出来、键盘自己起来
//
// ★ 为什么不用现成的 TalkToCatIntent（Siri 那条）：
//   那条 `openAppWhenRun = false`，故意在后台跑、不抢你的前台 ——
//   它会在快捷指令里问一句「你说的话」，但那个询问框不是 App 的输入条，
//   而且回完话就没了，你想接着说还得再来一次。
//   这条不一样：它打开 App、打开输入条，说完了还能接着说。

struct OpenStillTalkIntent: AppIntent {

    static var title: LocalizedStringResource = "打开还在的输入框"
    static var description = IntentDescription("打开还在，直接弹出输入条，键盘自己起来。可以绑定到「轻点背面」。")

    /// ★ 必须 true：我们要的就是把 App 叫到眼前，好让输入条有地方可弹。
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        StillIntentBridge.requestTalk()
        return .result()
    }
}

/// Intent 和界面之间的一根短管。
///
/// ★ 为什么不用 NotificationCenter：这个 Intent 可能跑在**另一个进程**里
///   （App 没活着的时候，系统直接把它拉起来执行），进程内的通知递不过去。
///   走 App Group 的 UserDefaults 才是两个进程都看得见的。
enum StillIntentBridge {

    private static let talkKey = "still.wantTalk"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: Cfg.appGroup) }

    /// Intent 侧：留一个「待办」就走。
    static func requestTalk() {
        defaults?.set(Date().timeIntervalSince1970, forKey: talkKey)
    }

    /// 界面侧：取走并清掉。
    ///
    /// ★ 只看「有没有」会把上次留下的旧标记也吃进来：装完打开 App 就莫名弹一次输入条，
    ///   像自己在动。所以配一个保鲜期 —— 超过 20 秒的标记当它没发生。
    static func consumeTalk() -> Bool {
        guard let d = defaults else { return false }
        let t = d.double(forKey: talkKey)
        guard t > 0 else { return false }
        d.set(0, forKey: talkKey)
        return Date().timeIntervalSince1970 - t < 20
    }
}

// MARK: - 让 Siri 装完就认识，不用去设置里绑
//
// ★ 这段是「零配置」的关键。没有它，用户必须自己去「快捷指令」里
//   建一条、选这个 Intent、起名字，才能用语音 —— 那就不叫零配置了。
//
// ★ 短语里必须出现 \(.applicationName)，这是苹果的硬要求：
//   不含 App 名的短语注册会失败，而且失败得很安静（Siri 就是"不认识"）。
//
// ★ 装完第一次要打开一次 App，系统才会索引这些短语。之后就一直有了。

struct StillShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkToCatIntent(),
            phrases: [
                // ★ 这里不能写 "跟\(.applicationName)说\(\.$message)"。
                //   试过，编译直接报：
                //   Invalid parameter type. AppEntity and AppEnum are the only allowed
                //   types for message
                //   —— 短语槽位只收 AppEntity / AppEnum，String 收不了。
                //   所以只能给「不带内容」的短语，剩下那半句交给 Siri 追问。
                "跟\(.applicationName)说句话",
                "对\(.applicationName)说句话"
            ],
            shortTitle: "跟它说句话",
            systemImageName: "bubble.left.and.bubble.right"
        )
        // ★ 打字那条。两句都是「叫它出来」的意思，不涉及说内容，
        //   所以不受上面那个「槽位只收 AppEntity」的限制。
        AppShortcut(
            intent: AskStillIntent(),
            phrases: [
                "叫\(.applicationName)出来说话",
                "给\(.applicationName)写句话",
                "跟\(.applicationName)打字说话"
            ],
            shortTitle: "叫它出来（打字）",
            systemImageName: "keyboard"
        )
    }
}
