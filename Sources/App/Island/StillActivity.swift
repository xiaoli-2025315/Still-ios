import Foundation
import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - 灵动岛
//
// 这是整个 iOS 版里，唯一一个「猫能出现在 App 之外」的地方。
//
// 为什么只有这里可以：
//   · 小组件 = 系统渲染的静态快照，几秒到几十分钟才刷一次，没法演连续动作
//   · 桌面浮层 = iOS 没有，也不给
//   · Live Activity = 系统允许你持续更新的一小块区域，专门给「正在进行的事」
//
// ⚠️ 审核风险（真实存在，不是保守）：Apple 要求 Live Activity 只用于「有明确起止的
// 进行中任务」。宠物状态属于擦边。真上架前建议准备一段说明：
// 它的「进行中任务」是「它此刻正在某个组件里待着」，有起止、可结束。
// 另外 Live Activity 有 12 小时上限，且 payload 上限 4KB —— 别往里塞大图。

// MARK: - 注册给系统
//
// Live Activity 的界面必须由 Widget Extension 提供 —— ActivityConfiguration 是 Widget 协议。
// 所以这个文件虽然放在 Island/ 目录，target membership 要勾 Widget Extension，
// 别勾主 App。上 Xcode 时最容易漏的就是这一步。

struct StillLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StillActivityAttributes.self) { context in
            // 锁屏横幅
            StillLockScreenView(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    CatView(pose: context.state.phase == .walking ? .walk : .sit, width: 40)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PawMark(color: Cfg.Palette.honey)
                        .frame(width: 16, height: 16)
                        .opacity(0.5)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(expandedTitle(context.state))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.white)
                        Text(expandedSub(context.state))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 2)
                }
            } compactLeading: {
                CatView(pose: .sit, width: 20)
            } compactTrailing: {
                Text(context.state.roomName)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            } minimal: {
                CatView(pose: .sit, width: 16)
            }
            .widgetURL(URL(string: "still://open"))
        }
    }

    private func expandedTitle(_ s: StillActivityAttributes.ContentState) -> String {
        s.phase == .walking ? "它正在挪过去" : "它在「\(s.roomName)」里"
    }
    private func expandedSub(_ s: StillActivityAttributes.ContentState) -> String {
        s.phase == .walking ? "从这个组件走到那个组件" : "待着，没打算走"
    }
}


@available(iOS 16.2, *)
struct StillLockScreenView: View {

    let state: StillActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            CatView(pose: state.phase == .walking ? .walk : .sit, width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.phase == .walking ? "它在走" : "还在 · \(state.roomName)")
                    .font(.system(size: 14, weight: .medium))
                Text(state.phase == .walking ? "从这儿走到那儿" : "它在这儿待着")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .activityBackgroundTint(Cfg.Palette.bg)
    }
}

// MARK: - 锁屏横幅
