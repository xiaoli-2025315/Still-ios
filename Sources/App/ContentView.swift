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
    static let tag = "v58"
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
    var body: some View {
        MainHomeView()
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
