import SwiftUI
import UIKit
import UserNotifications

@main
struct StillApp: App {

    // 通知点击必须由 AppDelegate 接 —— SwiftUI 的 onOpenURL 接不到通知。
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.light)
        }
    }
}

extension Notification.Name {
    /// 点了「它来找你」那条通知
    static let stillSummon = Notification.Name("still.summon.tapped")
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// 点通知进来的。
    ///
    /// ★ 为什么标记和通知两条路都留：冷启动时通知回调可能比 ContentView 的
    ///   onAppear 更早，那一下 post 出去没有人接；而热启动时 onAppear 又不会再跑。
    ///   两条都留着，谁先到都不会漏。
    static var pendingSummon = false

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // 通知上的按钮得先登记，否则系统不认识那颗「让它过来」。
        Notifier.registerCategories()
        // ★★★ 2026-10-21：**先迁移名字，再通知 Siri 重拼**（顺序不能反）。
        //
        //   老版本的名字只存在 App Group 快照里。Siri 那份名字表现在读的是 App
        //   自己的沙盒（见 PetName 那段注释）。不先搬过来，升级上来的用户第一次
        //   进 App 时 Siri 会报「还在」—— 明明他没改名，名字却像丢了。
        //   迁移是幂等的：standard 里有值就什么都不做。
        PetName.migrateIfNeeded()

        // ★★★ 2026-10-21：让 Siri 把「跟<它的名字>说句话」重新拼一遍。
        //
        //   「带名字」的那两句短语（跟 \(\.$pet) 说句话）是**参数化短语**：
        //   系统要拿 App 递给它的名字表（PetBook.all()）才能把句子拼出来。
        //   不调这一行，名字改过之后短语还是旧的 ——「改了名，Siri 还在叫旧名字」。
        //
        //   ★ 这也是「装完要打开一次 App」的真正原因：苹果要求 App 至少跑过一趟，
        //     短语才会被索引。豆包方案里那句「App 被杀掉要自己处理唤醒」同理。
        StillShortcuts.updateAppShortcutParameters()
        return true
    }

    /// App 就在眼前的时候它来敲门 —— 照常演出来，别吞掉。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// 你点了那条通知。
    ///
    /// 这一刻是整条链子的转折点：点通知 = 系统把 App 拉到前台，
    /// 而「起小窗」这个动作**必须**发生在 App 还在前台的时候。
    /// 死结是它自己解开的，不是绕过去的。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        // ★ 必须先分辨是哪一种通知。
        //   summon（它来找你）点开 = 叫小窗，是整条链子的转折点。
        //   talk（它回你的话）点开 = 只是看一眼那句话，不该顺手把猫也放出来 ——
        //   否则你说一句话、点一下通知，屏幕上就多一只猫，很唐突。
        let info = response.notification.request.content.userInfo

        // ★★ 通知上那个输入框：系统把字交回来了。
        //   这一刻他多半还在别的 App 里，我们是在后台被叫起来的 ——
        //   所以这里**什么都不弹**，只把话送到，回话走小窗或下一条通知。
        //
        // ★ 类型名是 `UNTextInputNotificationResponse`，不是 `UNTextNotificationResponse`
        //   （少个 Input，编译直接 cannot find type in scope，踩过一次）。
        if response.actionIdentifier == Notifier.askAction {
            let typed = (response as? UNTextInputNotificationResponse)?.userText ?? ""
            Notifier.handleTyped(typed)
            completionHandler()
            return
        }

        // 「让它过来」那颗按钮：不用翻 App，直接把它放到角上。
        // 这个 action 带 .foreground，所以 App 已经被系统拉到前台了 ——
        // 正好，起小窗要的就是这一瞬前台。
        if response.actionIdentifier == Notifier.raiseAction {
            AppDelegate.pendingSummon = true
            NotificationCenter.default.post(name: .stillSummon, object: nil)
            completionHandler()
            return
        }

        if (info["summon"] as? Bool) == true {
            AppDelegate.pendingSummon = true
            NotificationCenter.default.post(name: .stillSummon, object: nil)
        }
        completionHandler()
    }
}
