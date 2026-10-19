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
//   你说完它就送进来。那个追问的框就是输入框 ——
//   苹果不允许第三方 App 在通知里放输入框，所以这是唯一不用打开 App 的输入口。
//   （想让一句话直接说完做不到：短语槽位只收 AppEntity/AppEnum，String 收不了，见文件末尾。）
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
    }
}
