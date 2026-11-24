import SwiftUI

// MARK: - 单聊右上角的圆角设置浮卡（对齐安卓 3.90）
//
// ★★★ 2026-11-21：点单聊右上角「设置」→ 一张不铺满的圆角卡：
//   · 顶部一颗大圆 104pt，按当前这只角色播**自己的完整帧包**（OrbPet，谁的播谁）；
//     有形象就只显示形象，没形象才显示「＋ / 创建动态形象」。
//   · 下方一张圆角卡两行：模型 / Agent 框架，点行下拉展开。
//     模型目前只有智谱一项；Agent 拉台子真实列表（跟「我」页同一个 AgentStore）。
//   · 群聊不走这里（仍用原来的群设置 sheet）。
//   ★ 一切决定都写本地 UserDefaults，接口只加不改，不动老设置页。

@MainActor
struct SingleSettingsCard: View {
    @Environment(\.dismiss) private var dismiss

    /// 当前单聊对象（单聊里就是这只；跟顶栏圆窗同一个来源）
    let charId: String
    let title: String
    /// 点「创建动态形象」——★ 2026-11-24 第⑤组：交给外层关卡片、在聊天里发起做形象流程
    var onCreate: () -> Void = {}
    /// ★ 2026-11-24：点「聊天记录搜索」——交给外层打开全屏搜索页
    var onSearch: () -> Void = {}

    @AppStorage("设置·模型") private var 模型选择 = "智谱 GLM-4-Flash"
    @AppStorage("设置·Agent") private var agent选择 = "陪伴 Agent"
    @State private var expandModel = false
    @State private var expandAgent = false

    /// 这只有没有形象可播 —— 真查本地包，没包就显示加号，不编假画面。
    private var hasPet: Bool { OrbPet.hasFrame(charId) }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部大圆：有形象只显示形象，没形象才显示加号+说明
            ZStack {
                Circle().fill(Tw.gray100)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                if hasPet {
                    OrbPet(charId: charId, actName: "sit", width: 104)
                        .clipShape(Circle())
                } else {
                    Button(action: onCreate) {
                        VStack(spacing: 10) {
                            Image(systemName: "plus")
                                .font(.system(size: 32, weight: .light))
                                .foregroundStyle(Tw.gray500)
                            Text("创建动态形象")
                                .font(.system(size: 10))
                                .foregroundStyle(Tw.gray500)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 104, height: 104)

            Text(title.isEmpty ? "它" : title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Tw.gray900)
                .padding(.top, 12)
            Text("在这儿")
                .font(.system(size: 10))
                .foregroundStyle(Tw.gray500)
                .padding(.top, 2)

            // 下方圆角卡：模型 / Agent 两行下拉
            VStack(spacing: 0) {
                设置行(icon: "gearshape", title: "模型", value: 模型选择) {
                    withAnimation { expandModel.toggle() }
                }
                if expandModel {
                    VStack(spacing: 0) {
                        选项行(name: "智谱 GLM-4-Flash", note: "消耗 1 倍", chosen: 模型选择 == "智谱 GLM-4-Flash") {
                            模型选择 = "智谱 GLM-4-Flash"
                            withAnimation { expandModel = false }
                        }
                        Text("倍数对应在同类任务下，模型额度消耗的比例")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Tw.gray500)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                    }
                    .transition(.opacity)
                }
                Divider().padding(.leading, 44)
                设置行(icon: "person.2", title: "Agent 框架", value: agent选择) {
                    withAnimation { expandAgent.toggle() }
                }
                if expandAgent {
                    VStack(spacing: 0) {
                        选项行(name: "陪伴 Agent", note: "日常聊天陪伴", chosen: agent选择 == "陪伴 Agent") {
                            agent选择 = "陪伴 Agent"; withAnimation { expandAgent = false }
                        }
                        选项行(name: "任务 Agent", note: "帮忙处理具体事情", chosen: agent选择 == "任务 Agent") {
                            agent选择 = "任务 Agent"; withAnimation { expandAgent = false }
                        }
                    }
                    .transition(.opacity)
                }
                Divider().padding(.leading, 44)
                // ★ 2026-11-24：聊天记录搜索（只搜当前这只的对话）
                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onSearch() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15))
                            .foregroundStyle(Tw.red600)
                            .frame(width: 24)
                        Text("聊天记录搜索")
                            .font(.system(size: 14))
                            .foregroundStyle(Tw.red600)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundStyle(Tw.gray400)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Tw.gray50)
            )
            .padding(.top, 18)
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .background(Color.white)
    }

    private func 设置行(icon: String, title: String, value: String, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(Tw.gray600)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(Tw.gray900)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 12))
                    .foregroundStyle(Tw.gray500)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11))
                    .foregroundStyle(Tw.gray400)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func 选项行(name: String, note: String, chosen: Bool, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.system(size: 13))
                        .foregroundStyle(Tw.gray900)
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(Tw.gray500)
                }
                Spacer()
                if chosen {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Tw.gray900)
                }
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
