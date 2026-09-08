import SwiftUI

@main
struct StillApp: App {

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.light)
                // 小组件和灵动岛点进来时，直接进主界面
                .onOpenURL { url in
                    guard url.host == "open" else { return }
                    // 目前只需要唤醒主界面，引擎在 onAppear 里自己会跑起来
                }
        }
    }
}
