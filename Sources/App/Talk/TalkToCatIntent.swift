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

    // ★★★ 2026-10-21：这一格是「它叫什么」。
    //
    //   原来短语写死成 \(.applicationName) —— 系统把它替换成 **App 显示名「还在」**。
    //   你要的是**喊猫自己的名字**（「跟小黄说句话」），那 App 名和猫名是两回事，
    //   必须另外给它一个「可以点名的它」。
    //
    //   做法：把「它」做成 AppEntity（Swift 里「能被点名、系统能拿去填句子」的类型）。
    //   短语写成「跟 \(\.$pet) 说句话」，系统就会拿 `PetBook.all()` 给的名字表
    //   去把那句话拼出来 —— 猫现在叫什么，Siri 就认什么。
    //
    //   ★ 这里**不能**带默认值。写成 `var pet: PetEntity = PetBook.here()`
    //     编译直接报（v54(2) CI 就是这么挂的）：
    //       error: extra argument 'wrappedValue' in call
    //     @Parameter 没有「接一个现成值」的初始化器，AppEntity 这类参数
    //     在 Swift 里也不允许声明默认值。
    //
    //   ★ 所以做成 Optional：
    //     ① 短语里能填就填（「跟小黄说句话」→ 系统把 pet 填成小黄）
    //     ② 兜底那句「跟<App名>说句话」不含 pet，这时它是 nil，也不会反问「哪一只」
    //
    //   ★ 这一格**只用来拼短语**，perform() 里不读它 —— 真回话时名字由
    //     CatTalk 从 PetName 现取。名字只留一个来源，不会出现
    //     「短语喊小黄、回话自称还在」这种一半对一半不对的状态。
    //
    //   ★★★ 2026-10-22 更正：这一格**已经从所有短语里拿掉了**。
    //     原因见 `StillShortcuts` 里那段（任意字符串的参数没法被 Siri 填，
    //     带它的短语整条作废，只回「不支持」）。
    //     参数本身留着：快捷指令 App 里那个动作还能选「哪一只」，
    //     只是念出来的句子里不再有它的位置。
    @Parameter(title: "它", description: "它叫什么名字")
    var pet: PetEntity?

    // ★★★ 2026-10-21 真机第二次翻车（他：「我试了就是他说不支持，然后他触发的是让我打开还在」）：
    //
    //   版本对（1.55.0/55）、系统也认识这个 App（设置→Siri 与搜索里有「还在」），
    //   但说「用还在跟奶娃说句话」只换来「不支持」+「打开还在」。
    //
    //   根因在**这里**：`var message: String` 是**非可选、又没默认值**的参数。
    //   苹果对 App Shortcut 的硬规矩：这种参数系统没法预览、也没法预填，
    //   **整条短语就不被采用**（编译能过、元数据也能导出，但 Siri 不认）。
    //   于是只剩 App 名能匹配上 → Siri 只能建议「打开还在」。
    //
    //   两条一起改：
    //     ① `String?` —— 可选参数系统才肯收；配 `requestValueDialog` 让它开口问。
    //     ② 他要是没答（直接跳过），perform 里兜底弹一条带输入框的通知，
    //        让他在通知上把话打完 —— 绝不出现「喊了之后什么也没有」。
    //
    //   ★ 为什么不能改成 `default: ""`：那样 Siri 不会问「说什么」，
    //     直接拿空话去执行，他就白喊了一句。要的是**追问**，不是沉默。
    @Parameter(title: "你说的话", description: "你想对它说的话",
               requestValueDialog: IntentDialog("你要跟它说什么？"))
    var message: String?

    static var parameterSummary: some ParameterSummary {
        Summary("跟 \(\.$pet) 说 \(\.$message)")
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
        // ★ 2026-10-21：`message` 现在是可选的（不这样短语根本不生效，见上面那段注释）。
        //   他说了话 → 照常回；没说话就跳过了 → 弹一条带输入框的通知，
        //   让他在通知上打完 —— 不能出现「喊完它，什么都发生」。
        let said = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // ★★★ 诊断版（v58 起）：**进来先留一条，证明 Siri 到底有没有调到这儿。**
        //
        //   他真机上无论怎么喊都是「不支持」，我一直没有证据区分两件事：
        //     ① 系统根本没把这句话交给 App（注册/索引那一层）
        //     ② 交进来了，但执行中途被拒（执行体那一层）
        //   这条通知就是把这两件事切开的那一刀。
        //
        //   ★ 2026-10-22：真凶已经查到（短语里那个任意字符串的参数），
        //     这条留着只为了确认 v60 修好没有 —— 所以**只发前 5 次**，
        //     之后自动闭嘴，不会长期多响一条。
        let diagKey = "still.diag.talkCount"
        let n = UserDefaults.standard.integer(forKey: diagKey)
        if n < 5 {
            UserDefaults.standard.set(n + 1, forKey: diagKey)
            Notifier.tellReply("① Siri 进来了：\(said.isEmpty ? "（没带内容）" : said)",
                               catName: PetName.current)
        }

        guard !said.isEmpty else {
            Notifier.askInput(after: 0.6)
            return .result()
        }

        await CatTalk.say(said)
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

// MARK: - 「它」＝ 一个能点名的东西
//
// ★★★ 2026-10-21（你的原话：「我想做到他这个 planb 里可以直接叫宠物名字的方法」）。
//
//   为什么必须多这一层：Siri 短语里能填的那一格，**只收 AppEntity / AppEnum**，
//   String 直接编译报错（这条我们早就踩过，见下面 StillShortcuts 里的注释）。
//   「它的名字」正好是「系统可以先知道、再拿来说」的东西 —— 包成 AppEntity 就合法了。
//
//   ★ 跟签名一点关系都没有：
//     不需要 App Group、不需要独立的 App Intent Extension、不需要任何 entitlement。
//     豆包那套之所以要开发者账号，是因为它多造了一个**进程**；
//     我们从头到尾都在 App 自己这个进程里，重签也好、App Group 丢了也好，不影响。

struct PetEntity: AppEntity {

    var id: String
    var name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "它"

    static var defaultQuery = PetQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct PetQuery: EntityQuery {

    // ★★★ 2026-10-21 真机踩到的坑（他截图里那句「很抱歉，"还在"还不支持使用 Siri 执行此操作」）：
    //
    //   原来这里只有一句 `PetBook.all().filter { identifiers.contains($0.id) }` ——
    //   只认 `self` / `still` 这两个**内部编号**。可 Siri 从用户嘴里抽出来的
    //   是**名字本身**（「奶娃」），不是编号。于是：
    //        Siri 抽到「奶娃」 → 交给 entities(for:) → 过滤完是空数组
    //        → 参数解析失败 → Siri 只能回「这个 App 不支持用 Siri 做这件事」。
    //   在他看来就是「喊了没反应、还说不支持」，而代码里其实什么都没报错。
    //
    //   ★ 修法：**这儿只有一只猫**。所以任何标识符都该落到它身上 —
    //     认识的按认识的给，不认识的就当「你喊的正是它」。
    //     这样「用还在跟奶娃说句话」里的奶娃能不能查到都不影响能跑，
    //     也顺手兜住「刚改完名、系统索引还没跟上」和「名字存在老 App Group 里」两种错位。
    func entities(for identifiers: [String]) async throws -> [PetEntity] {
        let all = PetBook.all()
        var out = all.filter { identifiers.contains($0.id) }
        let known = Set(out.map { $0.id })
        for raw in identifiers where !known.contains(raw) {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            out.append(PetEntity(id: id, name: PetName.clean(id)))
        }
        return out.isEmpty ? [PetBook.here()] : out
    }

    func suggestedEntities() async throws -> [PetEntity] {
        PetBook.all()
    }
}

/// 它现在叫什么。
///
/// ★ 名字从 `SharedStore` 里读 —— 就是你在 App 里「改名字」改的那个。
///   读不到（没改过 / App Group 被重签弄丢了）就是默认的「还在」，
///   跟界面、通知里显示的完全是同一个来源，不会出现「通知叫小黄、Siri 叫还在」。
enum PetBook {

    /// 当前那一只。
    static func here() -> PetEntity {
        all()[0]
    }

    /// 名字表。第一条永远是当前那只。
    ///
    /// ★ 改成别的名字之后，「还在」仍然留在表里：
    ///   你叫惯了旧名字、或者刚改完名 Siri 还没重新索引，都不至于哑火。
    static func all() -> [PetEntity] {
        // ★★ 2026-10-21：名字改从 `PetName.current` 读，**不再直接读 App Group 快照**。
        //   这里是 Siri 拼短语时唯一取名字的地方，所以它必须是最稳的一条路：
        //   主 App 和这个 Intent 是同一个进程同一个沙盒 ⇒ `UserDefaults.standard`
        //   一定读得到，重签丢了 App Group 也不影响。
        let name = PetName.current
        var out = [PetEntity(id: "self", name: name)]
        if name != PetName.fallback {
            out.append(PetEntity(id: "still", name: PetName.fallback))
        }
        return out
    }
}

// MARK: - 让 Siri 装完就认识，不用去设置里绑
//
// ★ 这段是「零配置」的关键。没有它，用户必须自己去「快捷指令」里
//   建一条、选这个 Intent、起名字，才能用语音 —— 那就不叫零配置了。
//
// ★ 短语里**每一条**都必须出现 \(.applicationName)，这是苹果的硬要求：
//   少一条，整个 AppIntents 元数据导不出来，Siri 就是"不认识"（有报错，但只在 CI 日志里）。
//   ★ 注意不是「每组里有一条就行」—— 是每一条。踩过两次。
//
// ★ 装完第一次要打开一次 App，系统才会索引这些短语。之后就一直有了。

struct StillShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkToCatIntent(),
            phrases: [
                // ★★★ 2026-10-22：**短语里不能再有 \(\.$pet)。** 这是查了四版之后的真凶。
                //
                //   苹果 DTS 工程师（Ed Ford）在开发者论坛 thread/771507 里写得很死：
                //     "App Shortcuts need to have defined values for the parameters,
                //      such as those defined by an AppEnum. **A parameter in an App
                //      Shortcut with a large range of values, such as arbitrary
                //      strings** … won't work with that parameter part of the
                //      invocation phrase."
                //     "**If you remove that parameter from the invocation phrase,
                //      you'll see the App Shortcuts appear.**"
                //
                //   「它叫什么」恰恰就是"任意字符串"：名字是用户自己起的，系统没有一张
                //   有限的表可以提前铺开，所以 Siri **没法把那一格填上** ——
                //   整条短语作废，只剩 App 名能匹配上，于是只回一句「不支持」。
                //
                //   ★ 为什么前四版都没查出来：编译器不报错，`root.ssu.yaml` 里三句话
                //     原原本本都在，快捷指令 App 里也能看到这个动作 ——
                //     **只有 Siri 那一层不认**。所以拆包、验元数据全都"通过"。
                //
                //   ★ 名字这一格留着（`pet` 参数还在，快捷指令里能选），
                //     只是**不再出现在要念出来的句子里的参数位**。
                //     反正只有一只猫，念 App 名就够了；它自己叫什么，
                //     回话和通知里照旧显示，不会对不上。
                "跟\(.applicationName)说句话",
                "用\(.applicationName)跟它说句话",
                "用\(.applicationName)对它说句话"
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
