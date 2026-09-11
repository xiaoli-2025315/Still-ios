import Combine
import SwiftUI

// MARK: - 版本号
//
// 每次出包 +1，App 状态栏上直接显示。
// 用处只有一个：**一眼确认手机上跑的是哪一版** ——
// 折腾过一整天「改了没效果」，最后发现是手机里一直装着旧包。

enum AppVersion {
    /// 唯一来源是 Cfg.version —— 别在这儿另写一个字面量
    static let tag = Cfg.version
}

// MARK: - 主界面
//
// 打开就是**那间房** —— 它此刻就在你眼前。
// 切出去，它自己决定这一次跟不跟你：跟，就缩成小窗在角上陪着你；
// 不跟，桌面干干净净，等它想来了敲你一下（通知）。
//
// 整条链子：
//   它在屋里过日子 → 你切出去 → 它决定跟不跟
//   → 跟：小窗在角上，它走了就剩一间空房，然后小窗自己收
//   → 不跟：过一会儿来一条通知 → 你点 → 一闪 → 它已经在角上了，你原来的事没被打断

struct ContentView: View {

    @StateObject private var engine = PetEngine()
    @StateObject private var pip = PiPController()
    @State private var showPanel = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .bottom) {
            Cfg.Palette.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                FakeStatusBar()

                Spacer(minLength: 6)

                // 方形 —— 捏到最小档拿到的是 130×130 的方块，方构图才住得下猫
                RoomStage(controller: pip)
                    .aspectRatio(1, contentMode: .fit)
                    .padding(.horizontal, 22)

                Spacer(minLength: 6)

                RoomStageBar(controller: pip)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)

                // 诊断默认收起来。
                // 你打开的应该是它的房间，不是一个调试台 —— 但排障的时候得够得着。
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { showPanel.toggle() }
                } label: {
                    Text(showPanel ? "收起诊断" : "诊断")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Cfg.Palette.faint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.white.opacity(0.6)))
                }
                .buttonStyle(.plain)

                if showPanel {
                    ScrollView {
                        StatusPanelView(engine: engine)
                            .padding(.horizontal, 12)
                    }
                    .frame(maxHeight: 300)
                    .padding(.bottom, 8)
                    .transition(.opacity)
                }
            }
        }
        .onAppear {
            engine.start()
            pip.start()
            IslandProbe.run()
            // ★ 必须等权限问完再排期。
            //   第一次打开时「问权限」和「排通知」是并发的 —— 没授权时 add 会静默失败，
            //   表现就是「第一天好好的，装完当天一条都不来」，很难归因。
            Notifier.requestAuthorization { _ in Notifier.reschedule() }

            // 冷启动就是「点通知进来的」那一种
            if AppDelegate.pendingSummon {
                AppDelegate.pendingSummon = false
                pip.summonFromNotification()
            }
        }
        .onDisappear {
            engine.stop()
            pip.stop()
        }
        // 热启动那一种 —— App 已经在后台活着，你点了通知
        .onReceive(NotificationCenter.default.publisher(for: .stillSummon)) { _ in
            AppDelegate.pendingSummon = false
            pip.summonFromNotification()
        }
        // iOS 17 的 onChange 用零参数形式（单参数已废弃）
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .active:
                engine.start()
                // 你回到屋里了，小窗该收 —— 不然会同时有两只猫
                pip.backInForeground()
            case .background:
                engine.stop()
                engine.save()
                // 你切出去 —— 它在这里决定这一次跟不跟你
                pip.leaveApp()
            default:
                break
            }
        }
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

// MARK: - 伪装的状态栏
// 让它看着像你真的在主屏幕上，而不是在浏览一个 App

struct FakeStatusBar: View {
    var body: some View {
        HStack(spacing: 5) {
            Text(timeString)
                .font(.system(size: 14, weight: .semibold))
            // ★ 版本号直接写在状态栏上。
            //   一整天「改了没效果」的教训 —— 没有这个标记，
            //   没法判断手机上装的到底是哪一版。
            Text(AppVersion.tag)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Cfg.Palette.accent)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Cfg.Palette.accent.opacity(0.16)))
            Spacer()
            HStack(spacing: 4) {
                signalBars
                Image(systemName: "wifi").font(.system(size: 11))
                BatteryGlyph()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .frame(height: 30)
        .foregroundStyle(Cfg.Palette.ink)
    }

    private var timeString: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: Date())
    }

    private var signalBars: some View {
        HStack(alignment: .bottom, spacing: 1.6) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 0.6)
                    .frame(width: 2.6, height: 3 + CGFloat(i) * 2.4)
            }
        }
        .frame(height: 11)
    }
}

struct BatteryGlyph: View {
    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2.4)
                .strokeBorder(Cfg.Palette.ink.opacity(0.4), lineWidth: 1)
                .frame(width: 20, height: 10)
            RoundedRectangle(cornerRadius: 1.4)
                .fill(Cfg.Palette.ink)
                .frame(width: 14, height: 7)
                .padding(.leading, 1.6)
        }
        .frame(width: 20, height: 10)
    }
}

#Preview {
    ContentView()
}
