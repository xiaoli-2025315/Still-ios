import SwiftUI

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
        .onAppear { engine.start() }
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

// MARK: - 伪装的状态栏
// 让它看着像你真的在主屏幕上，而不是在浏览一个 App

struct FakeStatusBar: View {
    var body: some View {
        HStack {
            Text(timeString)
                .font(.system(size: 14, weight: .semibold))
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
