import SwiftUI
import UIKit

// MARK: - 「它」页首页本体（2026-11-23 方向纠偏后）
//
// ★ 不是从「角色」按钮另开一页：这一块直接占住首页的「它」这一格，
//   跟聊天、记忆用同一条底栏、同一套浅色组件。
// ★ 卡里播的是 OrbPet / CatPack 那套透明动态帧包，不是 sit.gif 白底静图。
// ★ 没形象：加号 +「创作动态形象」；三颗功能键全灰 +「请先创建形象」。
//   老 HerPane 一行没删，要退回把 MainHomeView 里 case 0 换回去即可。

@MainActor
struct HerStagePane: View {
    @ObservedObject var pip: PiPController
    @ObservedObject private var packs = CatPackStore.shared
    var onHit: () -> Void = {}
    /// 点「创作动态形象」：回到角色页登记/做第一套动作（老流程一行没删）
    var onCreateImage: () -> Void = {}

    @State private var roles: [ActLab.Char] = []
    @State private var pos: Double = 0
    @State private var dragStart: Double = 0
    @State private var focus = 0
    @State private var panel = ""          // "" / "float" / "pinch" / "make" / "chat"
    @State private var hint = ""
    @State private var sqState = 0         // 0 browse / 1 paint / 2 squish
    @State private var sqTool = 0
    @State private var sqKey = 0
    @State private var hasPaint = false

    @State private var prompt = ""
    @State private var model = "wan"
    @State private var boundSlot = ""
    @State private var confirmShow = false
    @State private var chatLines: [ChatLine] = []
    @State private var banner = ""

    private struct ChatLine: Identifiable {
        let id = UUID()
        let text: String
        let mine: Bool
    }

    private let cardW: CGFloat = 142
    private let cardH: CGFloat = 214
    private let gap: CGFloat = 124

    // MARK: 当前角色

    private var currentRole: ActLab.Char? {
        roles.indices.contains(focus) ? roles[focus] : nil
    }

    private var currentHasFrame: Bool {
        guard let c = currentRole else { return false }
        return OrbPet.hasFrame(c.id)
    }

    private var stageLocked: Bool {
        !panel.isEmpty && panel != "float"
    }

    private var promptReady: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("它在这儿")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Tw.gray400)
                    .kerning(0.8)
                    .padding(.horizontal, 2)
                    .padding(.bottom, 4)

                ZStack {
                    if roles.isEmpty {
                        addCard
                    } else {
                        ForEach(roles.indices, id: \.self) { i in
                            roleCard(i)
                        }
                    }
                }
                .frame(height: 262)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { v in
                            if stageLocked { return }
                            let raw = dragStart - Double(v.translation.width / gap)
                            pos = max(-0.35, min(Double(max(0, roles.count - 1)) + 0.35, raw))
                        }
                        .onEnded { v in
                            if stageLocked { return }
                            guard !roles.isEmpty else { return }
                            let target = max(0, min(roles.count - 1, Int(pos.rounded())))
                            withAnimation(.easeOut(duration: 0.26)) {
                                focus = target
                                pos = Double(target)
                                dragStart = pos
                            }
                            onHit()
                        }
                )

                Text(currentRole?.title ?? "还没有形象")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Tw.gray900)
                    .frame(maxWidth: .infinity)
                Text(currentRole == nil ? "先做一只，它就有地方住了" : "左右拖动换一只")
                    .font(.system(size: 11))
                    .foregroundStyle(Tw.gray400)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 10)

                HStack(spacing: 8) {
                    actionButton("悬浮模式", enabled: currentHasFrame && sqState != 2) { showPanel("float") }
                    actionButton("捏捏它", enabled: currentHasFrame) { pinchTap() }
                    actionButton("制作动作", enabled: currentHasFrame && sqState != 2) { showPanel("make") }
                }

                if !currentHasFrame {
                    Text("请先创建形象")
                        .font(.system(size: 13))
                        .foregroundStyle(Tw.gray400)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10)
                }

                if !hint.isEmpty {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(Tw.gray500)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }

                ZStack {
                    if panel == "float" { floatPanel }
                    if panel == "pinch" { pinchPanel }
                    if panel == "make" { makePanel }
                    if panel == "chat" { chatPanel }
                }
                .frame(height: 214)
                .padding(.top, 4)

                if !banner.isEmpty {
                    Text(banner)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tw.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Tw.gray900))
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 18)
        }
        .scrollIndicators(.hidden)
        .background(Tw.white)
        .task { await load() }
        .alert("确认开始生成？", isPresented: $confirmShow) {
            Button("取消", role: .cancel) {}
            Button("确认生成") {
                Task { await submitJob() }
            }
        } message: {
            Text("角色：\(currentRole?.title ?? "它")\n用哪个来做：\(model == "wan" ? "wan" : "豆包号")\n时长：5s\n\n\(prompt)")
        }
    }

    // MARK: - 角色卡

    private var addCard: some View {
        VStack(spacing: 8) {
            Text("＋")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Tw.gray400)
            Text("创作动态形象")
                .font(.system(size: 13))
                .foregroundStyle(Tw.gray500)
        }
        .frame(width: cardW, height: cardH)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Tw.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Tw.gray200, lineWidth: 1)
                )
        )
        .onTapGesture { onCreateImage() }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func roleCard(_ i: Int) -> some View {
        if i < roles.count {
            let c = roles[i]
            let d = Double(i) - pos
            let ad = abs(d)
            let sc = max(0.74, 1 - ad * 0.13)
            let op = max(0.42, 1 - ad * 0.28)
            let on = (i == focus)

            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Tw.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(on ? Tw.gray400 : Tw.gray200, lineWidth: on ? 1.6 : 1)
                    )

                if OrbPet.hasFrame(c.id) {
                    OrbPet(charId: c.id, actName: "sit", width: cardW - 12)
                        .frame(width: cardW - 12, height: cardH - 36)
                        .clipped()
                } else {
                    VStack(spacing: 8) {
                        Text("＋")
                            .font(.system(size: 42, weight: .light))
                            .foregroundStyle(Tw.gray400)
                        Text("创作动态形象")
                            .font(.system(size: 11))
                            .foregroundStyle(Tw.gray500)
                    }
                }

                Text(c.title)
                    .font(.system(size: 13, weight: on ? .bold : .regular))
                    .foregroundStyle(on ? Tw.gray900 : Tw.gray500)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .background(Tw.white.opacity(0.82))
            }
            .frame(width: cardW, height: cardH)
            .scaleEffect(CGFloat(sc))
            .opacity(op)
            .offset(x: CGFloat(d) * gap, y: (1 - CGFloat(sc)) * 16)
            .onTapGesture {
                if !OrbPet.hasFrame(c.id) {
                    onCreateImage()
                } else if i != focus {
                    withAnimation(.easeOut(duration: 0.26)) {
                        focus = i
                        pos = Double(i)
                        dragStart = pos
                    }
                    onHit()
                }
            }
        }
    }

    // MARK: - 三颗功能键

    private func actionButton(_ label: String, enabled: Bool,
                              _ tap: @escaping () -> Void) -> some View {
        Button {
            onHit()
            tap()
        } label: {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(enabled ? Tw.gray900 : Tw.gray400)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(enabled ? Tw.white : Tw.gray100)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Tw.gray200, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(PressStyle(scale: 0.97))
        .disabled(!enabled)
    }

    private func showPanel(_ which: String) {
        panel = (panel == which) ? "" : which
        hint = ""
        if panel == "float" {
            if pip.active {
                pip.toggle()
                hint = "它先回去了。想它就再让它出来。"
            } else {
                pip.toggle()
                hint = "它出来了，浮在屏幕上"
            }
        }
    }

    private func pinchTap() {
        if sqState != 0 {
            exitPinch()
            return
        }
        panel = "pinch"
        sqState = 1
        sqTool = 0
        sqKey += 1
        hasPaint = false
        hint = "选笔或橡皮在它身上涂，涂完点确认"
    }

    private func confirmPinch() {
        guard hasPaint else { return }
        sqState = 2
        hint = "捏着呢：清除了才能换"
    }

    private func exitPinch() {
        sqState = 0
        sqKey += 1
        hasPaint = false
        panel = ""
        hint = ""
    }

    // MARK: - 三块面板

    private var floatPanel: some View {
        VStack(spacing: 10) {
            Button {
                onHit()
                if !pip.active { pip.toggle() }
                hint = "它出来了，浮在屏幕上"
            } label: {
                Text("让它出现在屏幕上")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tw.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Tw.gray900))
            }
            .buttonStyle(PressStyle(scale: 0.97))

            Button {
                onHit()
                pip.stop()
                hint = "它先回去了。想它就再让它出来。"
            } label: {
                Text("让它先回去")
                    .font(.system(size: 13))
                    .foregroundStyle(Tw.gray900)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        Capsule().fill(Tw.white)
                            .overlay(Capsule().stroke(Tw.gray200, lineWidth: 1))
                    )
            }
            .buttonStyle(PressStyle(scale: 0.97))
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var pinchPanel: some View {
        if let c = currentRole {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Tw.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Tw.gray200, lineWidth: 1)
                        )
                    OrbPet(charId: c.id, actName: "sit", width: 132)
                        .frame(width: 132, height: 150)
                        .clipped()
                    StageSquish(state: $sqState, tool: $sqTool, key: $sqKey, hasPaint: $hasPaint)
                        .frame(width: 132, height: 150)
                }
                .frame(width: 150, height: 190)

                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        toolGlyph(system: "pencil", selected: sqTool == 0) { sqTool = 0 }
                        toolGlyph(system: "eraser", selected: sqTool == 1) { sqTool = 1 }
                    }
                    HStack(spacing: 8) {
                        smallButton("取消", primary: false) { exitPinch() }
                        smallButton("确认", primary: true, enabled: hasPaint) { confirmPinch() }
                    }
                    if sqState == 2 {
                        smallButton("清除", primary: true) { exitPinch() }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func toolGlyph(system: String, selected: Bool,
                           _ tap: @escaping () -> Void) -> some View {
        Button {
            onHit()
            tap()
        } label: {
            ZStack {
                Circle()
                    .fill(selected ? Tw.gray100 : Tw.white)
                    .overlay(Circle().stroke(Tw.gray200, lineWidth: 1))
                    .frame(width: 52, height: 52)
                Image(systemName: system)
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(selected ? Tw.gray900 : Tw.gray500)
            }
        }
        .buttonStyle(PressStyle(scale: 0.94))
    }

    private func smallButton(_ label: String, primary: Bool, enabled: Bool = true,
                             _ tap: @escaping () -> Void) -> some View {
        Button {
            onHit()
            tap()
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? (primary ? Tw.white : Tw.gray500) : Tw.gray400)
                .frame(width: 62, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(enabled ? (primary ? Tw.gray900 : Tw.white) : Tw.gray100)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(primary ? Color.clear : Tw.gray200, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(PressStyle(scale: 0.94))
        .disabled(!enabled)
    }

    private var makePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $prompt)
                .font(.system(size: 13))
                .foregroundStyle(Tw.gray900)
                .scrollContentBackground(.hidden)
                .frame(height: 56)
                .overlay(
                    Group {
                        if prompt.isEmpty {
                            Text("描述它要做什么动作，比如：它伸个懒腰，然后回头看看你。")
                                .font(.system(size: 13))
                                .foregroundStyle(Tw.gray400)
                                .padding(.horizontal, 4)
                                .padding(.top, 2)
                        }
                    }, alignment: .topLeading
                )

            HStack(spacing: 8) {
                Menu {
                    Button { model = "wan" } label: { Text("wan") }
                    if boundSlot.isEmpty {
                        Button { openDoubaoLogin() } label: { Text("绑定豆包账号") }
                    } else {
                        Button { model = "doubao" } label: { Text("豆包号（\(boundSlot)）") }
                    }
                } label: {
                    Text("用哪个来做：\(model == "wan" ? "wan" : "豆包号") ▾")
                        .font(.system(size: 11))
                        .foregroundStyle(Tw.gray500)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Tw.white).overlay(Capsule().stroke(Tw.gray200, lineWidth: 1)))
                }
                Text("5 秒")
                    .font(.system(size: 11))
                    .foregroundStyle(Tw.gray500)
                Spacer(minLength: 0)
                Button {
                    onHit()
                    if promptReady { confirmShow = true }
                } label: {
                    ZStack {
                        Circle()
                            .fill(promptReady ? Tw.gray900 : Tw.gray200)
                            .frame(width: 30, height: 30)
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(promptReady ? Tw.white : Tw.gray100)
                    }
                }
                .buttonStyle(PressStyle(scale: 0.94))
                .disabled(!promptReady)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Tw.gray100)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Tw.gray200, lineWidth: 1)
                )
        )
    }

    private var chatPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("和它的聊天")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Tw.gray900)
                .frame(maxWidth: .infinity)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(chatLines) { line in
                        HStack {
                            if line.mine { Spacer(minLength: 0) }
                            Text(line.text)
                                .font(.system(size: 12))
                                .foregroundStyle(line.mine ? Tw.white : Tw.gray900)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(line.mine ? Tw.gray900 : Tw.white)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .stroke(line.mine ? Color.clear : Tw.gray200, lineWidth: 1)
                                        )
                                )
                            if !line.mine { Spacer(minLength: 0) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Tw.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Tw.gray200, lineWidth: 1)
                )
        )
    }

    // MARK: - 数据 / 下单

    private func load() async {
        do {
            let cs = try await ActLab.chars()
            await MainActor.run {
                roles = cs
                if focus >= cs.count { focus = 0 }
                pos = Double(focus)
                dragStart = pos
            }
        } catch {
            // 没连上台子就留空，卡上照实显示加号，不编假角色。
        }
        do {
            let st = try await ActLab.loginState()
            if st.loggedIn {
                await MainActor.run { boundSlot = st.name; model = "doubao" }
            }
        } catch { }
    }

    private func openDoubaoLogin() {
        NotificationCenter.default.post(name: Notification.Name("StillOpenDoubaoLogin"), object: nil)
        hint = "先去绑一个豆包号，一人只绑一个"
    }

    private func addLine(_ text: String, _ mine: Bool) {
        chatLines.append(ChatLine(text: text, mine: mine))
    }

    private func submitJob() async {
        guard let c = currentRole else { return }
        let charId = c.id
        let roleName = c.title
        let desc = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let useModel = model
        let slot = boundSlot
        guard !desc.isEmpty else { return }

        panel = "chat"
        banner = ""
        chatLines.removeAll()
        addLine("正在把动作交给它做…", true)
        do {
            let d1 = try await ActLab.rawPost("/api/act/draft", body: ["char": charId, "描述": desc])
            let j1 = (try? JSONSerialization.jsonObject(with: d1) as? [String: Any]) ?? [:]
            guard j1["ok"] as? Bool == true else {
                let why = (j1["错误"] as? String) ?? "没接上台子"
                addLine(why, false)
                return
            }
            let job = (j1["单号"] as? String) ?? ""
            addLine("回执 \(job)，开工中…", true)
            var startBody: [String: Any] = ["单号": job]
            if useModel == "doubao" && !slot.isEmpty { startBody["账号"] = slot }
            let path = useModel == "wan" ? "/api/act/draft/wan" : "/api/act/draft/start"
            let d2 = try await ActLab.rawPost(path, body: startBody)
            let j2 = (try? JSONSerialization.jsonObject(with: d2) as? [String: Any]) ?? [:]
            addLine((j2["ok"] as? Bool == true) ? "它开始做了，做好了会告诉你"
                                                : ((j2["错误"] as? String) ?? "开工没成"), false)
            await poll(job: job, charId: charId)
        } catch {
            addLine("没接上台子：\(error.localizedDescription)", false)
        }
        _ = roleName
    }

    private func poll(job: String, charId: String) async {
        for _ in 0..<120 {
            do {
                let d = try await ActLab.rawPost("/api/act/draft/state", body: ["单号": job])
                let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
                let st = (j["状态"] as? String) ?? ""
                if st == "装好了" || st == "已完成" || st == "做好了" {
                    addLine("✓ 做完了，动作已存进它的记忆", false)
                    banner = "给它做的动作好了"
                    // 把新包装进手机，卡片立刻从加号变成透明动态帧。
                    _ = try? await CatPackStore.shared.install(charId: charId, force: true)
                    roles = (try? await ActLab.chars()) ?? roles
                    return
                }
            } catch {
                // 查不到状态不等于失败，继续等，不诱导重复下单。
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }
}

// MARK: - 捏捏画布接线（复用老 SquishView，只把「涂没涂」送到按钮）
struct StageSquish: UIViewRepresentable {
    @Binding var state: Int
    @Binding var tool: Int
    @Binding var key: Int
    @Binding var hasPaint: Bool

    func makeUIView(context: Context) -> SquishView {
        let v = SquishView()
        let flag = $hasPaint
        v.onMaskChanged = { flag.wrappedValue = $0 }
        return v
    }

    func updateUIView(_ v: SquishView, context: Context) {
        if v.lastKey != key {
            v.lastKey = key
            v.clearAll()
        }
        v.applyState(state, tool: tool)
    }
}
