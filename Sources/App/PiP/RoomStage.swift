import AVFoundation
import SwiftUI
import UIKit

// MARK: - 把「那间房」摆到屏幕上
//
// ★ 为什么必须真的摆出来，不能只喂给播放器：
//   画中画要的那块图层**必须真的在屏幕上**（否则 isPictureInPicturePossible
//   恒为 false，起不来还不报错）。而 AVPlayerLayer 只能有一个父 layer ——
//   所以 App 里的这间房和小窗里那间，是**同一块图层的两种呈现**，不是两份。

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct RoomStage: UIViewRepresentable {

    let controller: PiPController

    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.backgroundColor = UIColor(Cfg.Palette.bg)
        v.playerLayer.videoGravity = .resizeAspect
        v.layer.cornerRadius = 16
        v.layer.cornerCurve = .continuous
        v.layer.masksToBounds = true
        v.isUserInteractionEnabled = false
        controller.attach(layer: v.playerLayer)
        return v
    }

    func updateUIView(_ v: PlayerLayerView, context: Context) {
        if v.playerLayer.player !== controller.cat.player {
            controller.attach(layer: v.playerLayer)
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
