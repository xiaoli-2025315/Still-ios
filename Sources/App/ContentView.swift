import SwiftUI

// MARK: - 版本号
//
// 每次出包 +1，App 状态栏和组件名都用它。
// 用处只有一个：**一眼确认手机上跑的是哪一版。**
enum AppVersion {
    static let tag = "v7"
}

// MARK: - 主界面
//
// 上面是它的家（桌面画布），下面这块是给你看的状态。
// 中间不做分割动画，也不加标题栏 —— 你打开的应该是「它的房间」，不是一个 App。

struct ContentView: View {

    @StateObject private var engine = PetEngine()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .bottom) {
            Cfg.Palette.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                FakeStatusBar()
                HomeCanvasView(engine: engine)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)

                StatusPanelView(engine: engine)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .onAppear {
            engine.start()
            IslandProbe.run()
        }
        .onDisappear { engine.stop() }
        // iOS 17 的 onChange 用零参数形式（单参数已废弃）
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .active:
                engine.start()
            case .background:
                engine.stop()
                engine.save()
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
            //   折腾了一整天「改了没效果」，最后发现是手机上一直装着旧包 ——
            //   没有这个标记，用户（我也）没法判断他装的到底是哪一版。
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
