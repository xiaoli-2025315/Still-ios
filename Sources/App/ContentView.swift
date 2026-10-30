import Combine
import SwiftUI

// MARK: - 版本号
//
// 每次出包 +1，界面顶栏上直接显示。
// 用处只有一个：**一眼确认手机上跑的是哪一版** ——
// 折腾过一整天「改了没效果」，最后发现是手机里一直装着旧包。

enum AppVersion {
    /// ★★★ 每次发版**必须**同步改这里。
    ///   它曾经停在 "v30" 停了三个版本（v31/v32/v33 都忘了改）——
    ///   直接后果：他装完不知道手机上到底是不是新版，
    ///   排查「改了没效果」时连「装的是哪一版」都确定不了。
    static let tag = "v101"

    /// ★ v95（功能匹配）：比大小用的那个整数。跟 `project.yml` 的
    ///   `CURRENT_PROJECT_VERSION` 同一个数 —— 检查更新要靠它判「是不是新版」。
    ///   ★ 别用字符串比："v9" 会大于 "v94"，越更越显示有新版。
    static let build = 101
}

// MARK: - 入口
//
// ★ v36 起，界面本体搬到 `MainHomeView`：按安卓 `activity_main.xml` 摆
//   （顶栏 · 三屏 · 底栏三格）。这个文件只留版本号和灵动岛自测。
//
// ★ 旧的假状态栏 / 三个胶囊 / 底部常驻输入框全部撤掉了：
//   · 假状态栏是「装成主屏幕」那套玩法的残留，安卓没有，撤。
//   · 底部那条输入框他点了没反应（键盘不弹），换成顶上那条能自己聚焦的
//     `TalkSheet`（见 Talk/TalkSheet.swift）。
//   · 诊断面板收进右上角「我」里 —— 首页只留它自己。

struct ContentView: View {
    @ObservedObject private var auth = StillAuth.shared
    /// 手里那张票问过台子了没有 —— 没问过之前别闪一下登录页。
    @State private var checked = false

    var body: some View {
        Group {
            if !checked {
                // 只在冷启动的头一两百毫秒出现：背景色＋一个转圈，不要白屏。
                ZStack {
                    Cfg.Palette.bg.ignoresSafeArea()
                    ProgressView().tint(Cfg.Palette.faint)
                }
            } else if auth.signedIn {
                MainHomeView()
            } else {
                LoginView()
            }
        }
        .task {
            guard !checked else { return }
            // ★ v96：系统时间被改（或换时区）时，线索一律静默 ——
            //   不然把表往前调一调，冷却期就全废了
            HintClockWatch.装上()
            await auth.restore()
            checked = true
        }
        // ★★★ v94（他原话：「不管我当前在这个APP的任意界面，都弹出来」）：
        //   一批做完的汇报弹窗盖在**整个 App 的最外层**，所以他在哪一页都收得到，
        //   不用跑回制作页去找。
        .overlay { SettleBellView() }
    }
}

// MARK: - 灵动岛自测
//
// 打开 App 就让它上岛露 30 秒。两个用处：
//   · 小组件扩展如果真的起来了，岛上一定看得见 —— 比「去桌面加个组件」省事得多
//   · 顺手就是产品的一部分：你回来了，它听见了
enum IslandProbe {
    static func run() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            IslandBridge.shared.enter(roomName: "它在这儿")
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            IslandBridge.shared.leave()
        }
    }
}

#Preview {
    ContentView()
}
