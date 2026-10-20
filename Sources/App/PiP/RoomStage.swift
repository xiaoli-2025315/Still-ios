import AVFoundation
import SwiftUI
import UIKit

// MARK: - 把「那间房」摆到屏幕上
//
// ★ 为什么必须真的摆出来，不能只喂给播放器：
//   画中画要的那块图层**必须真的在屏幕上**（否则 isPictureInPicturePossible
//   恒为 false，起不来还不报错）。
//
// ★ v35 起这里有两套（按 `Cfg.liveFramePiP` 选一套，不是两套同时跑）：
//   · 实时流（默认）：一块 `AVSampleBufferDisplayLayer`，画面是我们
//     一帧一帧自己喂进去的 —— 字就画在帧上，所以小窗里也能看见。
//     整个 App 只要两块图层都指向同一块，前景和小窗就不会「一个有字一个没有」。
//   · 播片（v34 的形态，退路）：一块 `AVPlayerLayer`，系统直接放 mp4。
//     稳，但插不进任何东西 —— 小窗里就没有字。

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

final class LiveStageView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

/// 两种房型共用的样子。**必须共用** —— 否则换开关时房间的圆角、底色会变，
/// 看起来像另一个 App。
private func styleStage(_ v: UIView) {
    // ★ v41：房间换成毛玻璃了（素材本身就是雾面玻璃底），
    //   这层底色只在片子和窗口比例对不上时露出来 —— 也跟着换成同一块冷白，
    //   否则边上会露出一圈旧暖色，看着像贴了两张底。
    v.backgroundColor = UIColor(red: 0xEE / 255.0, green: 0xF2 / 255.0, blue: 0xF8 / 255.0, alpha: 1)
    v.layer.cornerRadius = 16
    v.layer.cornerCurve = .continuous
    v.layer.masksToBounds = true
    v.isUserInteractionEnabled = false
}

struct RoomStage: UIViewRepresentable {

    let controller: PiPController

    func makeUIView(context: Context) -> UIView {
        if Cfg.liveFramePiP {
            let v = LiveStageView()
            styleStage(v)
            controller.attach(live: v.displayLayer)
            return v
        }
        let v = PlayerLayerView()
        styleStage(v)
        controller.attach(layer: v.playerLayer)
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {
        if let live = v as? LiveStageView {
            controller.attach(live: live.displayLayer)
        } else if let pl = v as? PlayerLayerView {
            controller.attach(layer: pl.playerLayer)
        }
    }
}

// MARK: - 房门口那条控制条
//
// 小窗里收不到触摸（系统的硬限制），所以按钮全在这儿。

struct RoomStageBar: View {

    @ObservedObject var controller: PiPController
    @State private var pending = 0

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(controller.active ? Cfg.Palette.sage : Cfg.Palette.faint.opacity(0.5))
                    .frame(width: 7, height: 7)

                if controller.missingAssets.isEmpty {
                    Text(controller.note)
                        .font(.system(size: 12))
                        .foregroundStyle(Cfg.Palette.faint)
                        .lineLimit(1)
                } else {
                    // 素材没进包时优先报这个 —— 否则只会看到一片黑，无从下手
                    Text("素材没进包：\(controller.missingAssets.joined(separator: "、"))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if !controller.clip.isEmpty {
                    Text(label(controller.clip))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Cfg.Palette.accent)
                }
            }

            HStack(spacing: 8) {
                pill(controller.active ? "收回小窗" : "放进小窗",
                     on: controller.active,
                     filled: true,
                     enabled: controller.deviceSupportsPiP) {
                    controller.toggle()
                }

                pill("叫它来",
                     on: false,
                     filled: false,
                     enabled: true) {
                    Notifier.summonNow()
                    refresh(after: 1.2)
                }

                pill(pending > 0 ? "提醒 · \(pending)" : "重排提醒",
                     on: false,
                     filled: false,
                     enabled: true) {
                    Notifier.reschedule()
                    refresh(after: 1.5)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.55))
        )
        .onAppear { refresh() }
    }

    private func refresh(after seconds: Double = 0) {
        if seconds <= 0 {
            Notifier.pendingCount { pending = $0 }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                Notifier.pendingCount { pending = $0 }
            }
        }
    }

    /// 素材名 → 人话。译不出来就直接显示原名，免得看不出它在播什么。
    private func label(_ s: String) -> String {
        switch s {
        case "empty":       return "空房间"
        case "sit_look":    return "坐着张望"
        case "groom":       return "舔毛"
        case "sleep_curl":  return "蜷着睡"
        case "sleep_flat":  return "趴着睡"
        case "wake_up":     return "睡醒"
        case "walk":        return "走动"
        case "hunt1", "hunt2": return "扑着玩"
        case "roll":        return "翻滚"
        case "lifted", "lifted2": return "被拎起"
        default:            return s
        }
    }

    private func pill(_ title: String, on: Bool, filled: Bool, enabled: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(filled || on ? .white : Cfg.Palette.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(filled || on ? Cfg.Palette.accent : Cfg.Palette.accent.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}
