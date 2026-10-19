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
