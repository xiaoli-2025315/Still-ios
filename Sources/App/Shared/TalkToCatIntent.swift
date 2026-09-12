import AppIntents
import Foundation

// MARK: - Siri 主路径
//
// 用户确认的主交互：用 Siri 跟它说话，它从灵动岛回你，**不打开 App、不打断你正在用的 App**。
//
// 「跟豆豆说 你好」这种唤醒词，是用户在「设置 → Siri 与搜索」里给这个 Intent 录的；
// 这里给一个合理的默认标题，真正的猫名由 App 内设置决定（存在 App Group 里，
// 通过 SharedStore 读）。Siri 把「你好」当作 message 参数带进来。
//
// openAppWhenRun = false：语音在后台跑，回话推到灵动岛，前台不发生任何切换。

struct TalkToCatIntent: AppIntent {

    static var title: LocalizedStringResource = "跟它说"
    static var description = IntentDescription("对它说句话，它会从灵动岛里回你，不用打开 App。")

    // 关键：不打开 App。系统会在后台唤起 App 跑这个 Intent，回话推到灵动岛。
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "你说的话", description: "你想对它说的话")
    var message: String

    static var parameterSummary: some ParameterSummary {
        Summary("跟它说 \(\.$message)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let name = SharedStore.load().catName ?? "还在"
        let reply = CatBrain.reply(to: message, catName: name)
        IslandBridge.shared.speak(reply: reply, catName: name)
        return .result()
    }
}
