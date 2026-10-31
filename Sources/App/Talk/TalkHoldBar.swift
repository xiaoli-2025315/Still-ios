import SwiftUI
import Combine
import AVFoundation

// MARK: - 聊天页那条「按住 说话」
//
// ★ 2026-10-31（他报的）：原来只有那颗小话筒能按，整条按不了；
//   而且音波是 12 根，跟安卓（24 根）不一样。这里重做：
//   · 整条都是录音键（DragGesture 铺满）
//   · 按住说、上滑 64pt 取消、不到 0.6 秒提示「说话时间太短」
//   · 说话时画 24 根真音波（数据来自 VoiceIn.level，跟安卓同一条 RMS 曲线）

struct TalkHoldBar: View {
    var onSaid: (String) -> Void

    @StateObject private var voice = VoiceIn()
    @State private var cancel = false
    @State private var startedAt = Date.distantPast
    @State private var hist: [CGFloat] = Array(repeating: 0.05, count: 24)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(voice.listening ? (cancel ? Tw.gray100 : Tw.gray50) : Tw.gray50)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(cancel ? Tw.red600.opacity(0.5) : Tw.gray200, lineWidth: 1))

            if voice.listening {
                HStack(alignment: .center, spacing: 1.6) {
                    ForEach(0..<24, id: \.self) { i in
                        Capsule()
                            .fill(cancel ? Tw.red600.opacity(0.55) : Tw.gray900.opacity(0.75))
                            .frame(width: 1.8,
                                   height: max(2, 26 * (0.06 + hist[i])))
                    }
                }
                .animation(.linear(duration: 0.06), value: hist)
                Text(cancel ? "松手取消" : "松手发送")
                    .font(.system(size: 11))
                    .foregroundStyle(cancel ? Tw.red600 : Tw.gray400)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 12)
            } else {
                Text("按住 说话")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Tw.gray500)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if !voice.listening {
                        voice.start()
                        startedAt = Date()
                        cancel = false
                    }
                    cancel = g.translation.height < -64
                }
                .onEnded { g in
                    let tooShort = Date().timeIntervalSince(startedAt) < 0.6
                    let cancelled = g.translation.height < -64
                    let text = voice.stop()
                    cancel = false
                    hist = Array(repeating: 0.05, count: 24)
                    if tooShort || cancelled { return }
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        onSaid(text)
                    }
                }
        )
        // 音量 → 24 根（每 60ms 推一格）
        .onReceive(Timer.publish(every: 0.06, on: .main, in: .common).autoconnect()) { _ in
            guard voice.listening else { return }
            hist.removeLast()
            hist.insert(max(0.05, CGFloat(voice.level)), at: 0)
        }
    }
}
