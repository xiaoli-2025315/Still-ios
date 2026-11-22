import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import Combine

// MARK: - 「相机」那一格：系统相机，拍完直接转 JPEG（不把 HEIC 交出去）
struct StillCameraPicker: UIViewControllerRepresentable {
    var onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: StillCameraPicker
        init(_ parent: StillCameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage,
               let jpg = img.jpegData(compressionQuality: 0.9) {
                parent.onImage(jpg)
            }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

// MARK: - 对话页（全屏）
//
// ★★★ v38 为什么把它从「一条飘在顶上的输入条」改成**一整页**：
//
//   顶部那条从 v36 折腾到 v37，两个版本都死在「键盘不弹」。复盘下来，
//   它踩的全是同一类坑：浮动视图 + 转场动画 + 顶部贴边 + 外部推焦点 ——
//   每一环都可能被系统静默吞掉，而且吞掉之后**什么都不报**，只能靠猜。
//
//   一整页没有这些坑：标准页面、输入条钉在底部、键盘升起时系统自己顶上来。
//   这是 iOS 上最不会出错的一种布局，做了十几年都是这么做的。
//
//   顺带，安卓那边本来也有一整个 `TalkActivity`（聊天页）——
//   这一页正好把它补上，两边对齐。

struct TalkPage: View {

    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var focus = TalkFocus.shared

    // ★ 2026-11-21：聊天输入框样式（设置里切，A/B/C/D 四档只换壳）— 跟设置页同一个 key
    @AppStorage(ComposerStyle.key) private var composerStyle = 1

    @State private var text = ""
    @State private var lines: [Line] = []
    @State private var busy = false
    /// ★ 2026-11-19：发送队列——生成中再发的先进队，一条回完才发下一条。
    @State private var 待发: [String] = []
    /// ★ 2026-11-19：翻历史时不强制弹回底部，浮一颗「最新消息」按钮。
    @State private var atBottom = true
    @State private var hasNew = false
    /// 外面推这个数 = 再抢一次焦点
    @State private var pulse = 0
    /// ★ 2026-10-30：语音模式（左边那颗切换）—— 对齐安卓聊天页
    @State private var voiceMode = false
    // ★ 2026-11-13：按住输入框直接起录（不再只是「切到语音模式」）
    @StateObject private var holdVoice = VoiceIn()
    // ★ 2026-11-14 12:13：键盘交回系统（safeAreaInset），不再自己记高度。
    @State private var holdActive = false
    /// ★ 手指是不是还按着 —— 跟「界面有没有切成录音条」分开。
    ///   语音授权是异步的，慢的时候手指已经松了才起录，靠这个把它收住。
    @State private var holdDown = false
    @State private var holdCancel = false
    @State private var holdStartAt = Date.distantPast
    @State private var holdHist: [CGFloat] = Array(repeating: 0.05, count: 24)
    @State private var holdTip = ""
    /// ★ 2026-10-31：左边那颗「猫列表」（安卓聊天页有侧栏，iOS 只有一只）
    @State private var showCats = false
    @State private var cats: [ActLab.Char] = []
    @State private var switching = ""

    // 群聊：入口、挑中的猫、建群中、加载中、失败提示；标题上的群名（空 = 单聊）
    @State private var showNewGroup = false
    @State private var groupCats: [ActLab.Char] = []
    @State private var picked: Set<String> = []
    @State private var creating = false
    @State private var loadingGroup = false
    @State private var groupErr: String? = nil
    @State private var groupTitle = ""

    // ★ 2026-11-10：侧栏（从左边出 + 顶上两个分页）、群列表、群设置
    @State private var drawerTab = 0              // 0 = 群聊，1 = 单人对话框
    @State private var groups: [CatBrain.GroupRow] = []
    @State private var groupListErr = ""
    @State private var loadingGroups = false
    @State private var showGroupSettings = false
    // ★ 2026-11-21：单聊的圆角设置浮卡（大圆动态形象 + 模型/Agent）
    @State private var showSingleSettings = false
    /// 群设置页自己留一份当前群，改完就地刷新（CatBrain.group 是静态值，视图不会自己重画）
    @State private var setNumber = ""
    @State private var setTitle = ""
    @State private var setMembers: [String] = []
    @State private var setNames: [String: String] = [:]
    @State private var setNameInput = ""
    @State private var setBusy = false
    @State private var setErr = ""

    // ★ 2026-11-19：聊天里的「对话 / 动作制作」两个入口和整套动作制作功能已移除；
    //   聊天仍可发消息、语音、选附件，动作请到独立的动作库／角色页制作。
    //   只加不删：老的「语音／键盘 → 整条按住说」那条路原样留着。
    @State private var showAttach = false
    @State private var progressText = ""
    @State private var showCamera = false
    @State private var showFile = false
    @State private var showPhotoPicker = false
    @State private var pickedPhoto: PhotosPickerItem? = nil

    struct Line: Identifiable {
        let id = UUID()
        let mine: Bool
        var text: String
        var cost: String? = nil     // 回复下面那行小字，拿不到花费就不显示
        var speaker: String? = nil  // 群聊里回话的那只猫
        var failed = false          // ★ 2026-11-20：台子明说没接这单，才显示「重试」
        var retryText = ""          // 重试要重发的原话（同一句，不再摆新气泡）
    }

    var body: some View {
        // ★★ 2026-11-10（他报的「侧栏不是从左侧出来而是从下边出」）：
        //   猫列表不再用系统那种「从底部升起的卡片」，换成贴左边进出的抽屉 + 遮罩，
        //   跟安卓 ChatV2Activity 的 Gravity.START 一个样子。
        ZStack(alignment: .leading) {
            // ★★ 2026-11-14 12:13（他说「做不出浮窗就别做了，把浮窗的设计改回去」）：
            //   浮层整套撤掉 —— 输入区回到页面流里，用系统的 safeAreaInset 正常贴底。
            //   聊天内容自动让位、不再被盖住；键盘也交回系统处理，不用自己接高度。
            VStack(spacing: 0) {
                header
                dialog
            }
            // 画布纯白（他 11-14 定的，不动）；写法对回 1.184.0，只是底色从近白改纯白
            .background(Tw.white.ignoresSafeArea())
            // 浮在这一页的小宠物，退出聊天页这一层跟着销毁（11-10 就有的功能，不动）
            .overlay { TalkFloatPet() }
            // ★ 输入条钉在底部 + safeAreaInset：键盘一升，系统把它整条顶起来，
            //   不用自己算键盘高度，也不会被挡住。两个面板也在这一节里，
            //   显示时占高度把聊天区挤上去，不盖聊天内容。
            .safeAreaInset(edge: .bottom, spacing: 0) { inputDock }
            .onAppear { boot() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showCats {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation { showCats = false } }
                    .zIndex(9)
                sideBar
                    .frame(width: min(UIScreen.main.bounds.width * 0.82, CGFloat(320)))
                    .transition(.move(edge: .leading))
                    .zIndex(10)
            }
        }
        .animation(.easeOut(duration: 0.22), value: showCats)
        .sheet(isPresented: $showNewGroup) { newGroupSheet }
        .sheet(isPresented: $showGroupSettings) { groupSettingsSheet }
        // ★ 2026-11-21：单聊圆角设置浮卡（不是全屏，是一张四周留白的卡）
        .sheet(isPresented: $showSingleSettings) {
            singleSettingsCard
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - 顶栏

    // ★ 2026-11-19（稿 v10）：顶栏中间那颗「会动的圆形宠物窗」取哪只 / 播哪段。
    //   单聊 = 当前这只 sit；群聊 = 最近说话那只 groom。全部取真数据，不编造。
    private var orbCharId: String {
        if let g = CatBrain.group {
            if let nm = CatTalk.lastSpeakerName, let id = g.names.first(where: { $0.value == nm })?.key {
                return id
            }
            return g.members.first ?? CatBrain.currentCharId
        }
        return CatBrain.currentCharId
    }
    private var orbAct: String { CatBrain.group == nil ? "sit" : "groom" }
    private var orbStatus: String {
        if let g = CatBrain.group {
            let n = g.members.count
            if let nm = CatTalk.lastSpeakerName, !nm.isEmpty { return "最近 \(nm) · \(n) 个成员" }
            return "\(n) 个成员"
        }
        return "在这儿"
    }

    private var header: some View {
        HStack(spacing: 10) {
            // ★ 2026-10-31：左边那颗「换一只」—— 安卓聊天页左边是猫列表
            // ★ 2026-11-10：现在拉开的是贴左边的会话栏（群聊 / 单人对话框两个分页）
            Button {
                openDrawer()
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tw.gray500)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Tw.gray100))
            }
            .buttonStyle(PressStyle(scale: 0.9))

            // ★ 2026-11-21（对齐安卓 3.92）：顶栏中间「圆窗 + 名字 + 状态」竖排。
            //   圆窗改成 OrbPet —— 按 orbCharId（单聊对方 / 群聊最近说话那只）
            //   播**那只自己的完整帧包**，不再用抽帧 GIF；跟主页/浮宠那只隔离。
            Spacer(minLength: 0)
            VStack(spacing: 3) {
                Group {
                    if OrbPet.hasFrame(orbCharId) {
                        OrbPet(charId: orbCharId, actName: orbAct, width: 58)
                    } else {
                        // 这只没做过动作、没帧包 —— 不编假画面，留个中性占位。
                        Image(systemName: "cat.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(Tw.gray400)
                    }
                }
                .frame(width: 58, height: 58)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                .background(Circle().fill(Tw.orbBlue))
                .shadow(color: Color.black.opacity(0.10), radius: 6, y: 3)

                Text(groupTitle.isEmpty ? (CatBrain.group == nil ? "它" : "群聊") : groupTitle)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(Tw.gray900)
                    .lineLimit(1)
                Text(busy ? "正在回…" : orbStatus)
                    .font(.system(size: 9))
                    .foregroundStyle(Tw.gray400)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

            // ★ 关闭这一页（真功能，保留）。
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tw.gray500)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Tw.gray100))
            }
            .buttonStyle(PressStyle(scale: 0.9))

            // ★ 2026-11-21（对齐安卓 3.90）：单聊右上角「设置」= 一张圆角浮卡
            //   （大圆动态形象 + 模型 / Agent 下拉）；群聊仍是原来的群设置（拉人/改群名/踢人）。
            //   常驻，不加显示条件。
            Button {
                if CatBrain.group == nil {
                    showSingleSettings = true
                } else {
                    syncSettings()
                    showGroupSettings = true
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tw.gray500)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Tw.gray100))
            }
            .buttonStyle(PressStyle(scale: 0.9))
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    // MARK: - 聊天记录

    private var dialog: some View {
        ScrollViewReader { sp in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if lines.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("还没聊过")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Tw.gray900)
                            Text("下面说第一句，它就会记住")
                                .font(.system(size: 12))
                                .foregroundStyle(Tw.gray400)
                        }
                        .padding(.top, 18)
                    }
                    ForEach(lines) { l in
                        bubble(l).id(l.id)
                    }
                    // ★ 2026-11-21：录音轻提示改成浮起样式，挪到输入条上方（见 inputDock），
                    //   不再占聊天流里一行。这里留注释说明去向。
                    // ★ 2026-11-19：这个锚点露出来 = 用户在最底部；滚走就不跟底。
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { atBottom = true; hasNew = false }
                        .onDisappear { atBottom = false }
                }
                .padding(.horizontal, 16)
                // ★ 2026-11-14 12:13：输入区回到页面流，滚动区不用再给浮层留一大块空白。
                .padding(.bottom, 12)
                // ★ 2026-11-21（对齐安卓 3.83 边缘渐隐）：靠近上下边缘的气泡渐隐，
                //   不是加遮带（那是被撤掉的旧做法），是内容自己在边缘淡出。
                .mask(
                    LinearGradient(gradient: Gradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.06),
                        .init(color: .black, location: 0.94),
                        .init(color: .clear, location: 1),
                    ]), startPoint: .top, endPoint: .bottom)
                )
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: lines.count) {
                if atBottom {
                    withAnimation(.easeOut(duration: 0.18)) { sp.scrollTo("bottom", anchor: .bottom) }
                } else {
                    hasNew = true       // 只浮按钮，不抢用户正在看的历史
                }
            }
            .overlay(alignment: .bottom) {
                if hasNew {
                    Button {
                        atBottom = true
                        hasNew = false
                        withAnimation(.easeOut(duration: 0.18)) {
                            sp.scrollTo("bottom", anchor: .bottom)
                        }
                    } label: {
                        Text("↓ 最新消息")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(Tw.accent))
                    }
                    .padding(.bottom, 10)
                    .transition(.opacity)
                }
            }
        }
    }

    private func bubble(_ l: Line) -> some View {
        HStack {
            if l.mine { Spacer(minLength: 40) }
            VStack(alignment: l.mine ? .trailing : .leading, spacing: 3) {
                if !l.mine, let s = l.speaker, !s.isEmpty {
                    Text(s)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Tw.gray400)
                }
                Text(l.text)
                    .font(.system(size: 14))
                    // 稿 v10：我方浅蓝底深字、对方浅灰描边深字，圆角22
                    .foregroundStyle(Tw.gray900)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: Tw.rBubble, style: .continuous)
                            .fill(l.mine ? Tw.accentSoft : Tw.gray200.opacity(0.55))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Tw.rBubble, style: .continuous)
                            .stroke(l.mine ? Color.clear : Tw.gray200, lineWidth: 1)
                    )
                    .textSelection(.enabled)
                // 每条回复下面一行小字：这次花了多少，只显示台子真给的数。
                if !l.mine, let c = l.cost {
                    Text(c)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Tw.gray400)
                }
                // ★ 2026-11-20：台子明说没接这单，才给「重试」（抄 OpenFuse）。
                //   点了把同一句填回这行重发，忙的时候不许叠。
                if !l.mine && l.failed {
                    Button {
                        guard !busy, 待发.isEmpty, !l.retryText.isEmpty else { return }
                        真发(l.retryText, 复用: l.id)
                    } label: {
                        Text("↻ 重试")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Tw.gray900)
                    }
                    .buttonStyle(PressStyle(scale: 0.94))
                    .disabled(busy || !待发.isEmpty)
                    .padding(.top, 2)
                }
            }
            if !l.mine { Spacer(minLength: 40) }
        }
    }

    // ★ 2026-11-21：单聊圆角设置浮卡的内容。建形象入口先关卡并照实提示去角色页
    //   （动作库是全屏页、从这层 sheet 里直接推会叠层，没把握就不硬来）。
    private var singleSettingsCard: some View {
        SingleSettingsCard(charId: CatBrain.currentCharId,
                           title: CatBrain.currentCharTitle,
                           onCreate: {
                               showSingleSettings = false
                               轻提示("去主页的「角色」页做动作")
                           })
    }

    // MARK: - 底部输入条
    //
    // 形态照安卓 `TalkBar`：白底圆角 + 右边一块红的「说」。

    /// ★ 2026-11-14 12:13：这一整块就是页面底部正常的一节（safeAreaInset 里），不是浮层。
    private var inputDock: some View {
        // ★ 2026-11-14 12:13：浮层撤掉，这一整块就是页面底部正常的一块。
        //   面板在最上面，显示时占高度、把聊天区挤上去，不盖聊天内容。
        VStack(spacing: 12) {
            if showAttach { attachPanel }

            // ★ 2026-11-21（对齐安卓 3.84）：录音轻提示**浮起来、往上移**——
            //   独立浮块（白底+描边+影子打背景），悬在输入条上方，不是聊天流里一行字。
            if !holdTip.isEmpty {
                Text(holdTip)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tw.gray900)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Tw.white))
                    .overlay(Capsule().stroke(Tw.gray200, lineWidth: 1))
                    .shadow(color: Tw.cardShadow, radius: 6, y: 3)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeOut(duration: 0.18), value: holdTip)
            }

            // ★★★ 2026-11-21（对齐安卓 3.83）：输入条整体放大 —— 高度 30→44、
            //   字号 14→16；发送键跟输入框同高（38）、自己浮在背景上。
            //   ★ 影子打在统一背景上：去掉原来「Capsule + offset(y:2) 灰纸片」，
            //     改用 SwiftUI .shadow，胶囊和发送键各自投影、彼此不叠影。
            VStack(spacing: 18) {
            HStack(spacing: 8) {
                // 左：相机（拍照）
                Button { showAttach.toggle() } label: {
                    Image(systemName: "camera")
                        .font(.system(size: 18))
                        .foregroundStyle(Tw.gray900)
                }
                .frame(width: 30)

                // ★ 手势挂在这块始终存在的容器上：录音时只是换掉里面的画面，手势不会断。
                //   不挂在整条胶囊上，免得把左边的相机、右边的语音圆钮和 ＋ 也盖住。
                ZStack {
                    if voiceMode {
                        // 老的整条录音键：按住说、上滑取消、24 根真音波
                        TalkHoldBar(onSaid: { t in text = t; send() })
                            .frame(height: 44)
                    } else if holdActive {
                        holdBar.frame(height: 44)
                    } else {
                        TalkField(text: $text, focusPulse: pulse, autoFocus: false,
                                  fontSize: 16,
                                  onSubmit: send,
                                  onBeginEdit: { PiPController.shared?.quiesceForTyping() },
                                  onEndEdit: { PiPController.shared?.resumeAfterTyping() })
                            .frame(height: 28)
                            .padding(.horizontal, 2)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 38)
                .simultaneousGesture(holdLongPress)
                .simultaneousGesture(holdDrag)
                // ★ 授权弹窗慢慢回来时手指早松了 ⇒ 立刻收掉，别在背后继续录。
                //   只在「有没有在录」变化时触发，不是每帧刷。
                .onChange(of: holdVoice.listening) {
                    if holdVoice.listening && !holdDown {
                        holdVoice.stop()
                        holdActive = false
                        holdHist = Array(repeating: 0.05, count: 24)
                    }
                }

                // 右：语音圆钮（点一下＝切到老的语音模式）
                Button {
                    voiceMode.toggle()
                    if voiceMode { focus.resign() }
                } label: {
                    Image(systemName: voiceMode ? "keyboard" : "waveform")
                        .font(.system(size: 16))
                        .foregroundStyle(Tw.gray900)
                        .frame(width: 34, height: 34)
                        // ★ 11:17：白底深描边圆钮，不再是浅灰实心块
                        .background(
                            Circle().fill(Tw.white)
                                .overlay(Circle().stroke(Tw.gray900, lineWidth: 1.5))
                        )
                }

                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button { showAttach.toggle() } label: {
                        Image(systemName: showAttach ? "xmark" : "plus")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Tw.gray900)
                    }
                    .frame(width: 34, height: 34)
                    // ★ 11:17：＋ 同样换成描边圆钮（原来只是无框细线）
                    .background(
                        Circle().fill(Tw.white)
                            .overlay(Circle().stroke(Tw.gray900, lineWidth: 1.5))
                    )
                } else {
                    // 发送键：与输入框同高（38）、红底、自己投影在背景上。
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Tw.white)
                            .frame(width: 38, height: 38)
                            .background(Capsule().fill(busy ? Tw.red600.opacity(0.45) : Tw.red600))
                    }
                    .disabled(busy)
                    .shadow(color: Tw.cardShadow, radius: 6, y: 3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // ★ 2026-11-21：统一背景上的浮起壳 —— 去掉原来
            //   「Capsule + offset(y:2) 灰纸片」，影子打在背景上、不与内部组件叠影。
            //   样式 A/B/C/D 只换壳（圆角/底色/描边），不动里面的输入/发送/语音。
            // ★ 2026-11-21：滑到「取消」时**整块输入框变红**（不是只有字红）。
            .background(
                RoundedRectangle(cornerRadius: ComposerStyle.radius(composerStyle), style: .continuous)
                    .fill(holdActive && holdCancel ? Color(hex: 0xFFDCD9) : ComposerStyle.fill(composerStyle))
            )
            .overlay(
                Group {
                    if holdActive && holdCancel {
                        RoundedRectangle(cornerRadius: ComposerStyle.radius(composerStyle), style: .continuous)
                            .stroke(Tw.red600, lineWidth: 1.5)
                    } else if let sc = ComposerStyle.stroke(composerStyle) {
                        RoundedRectangle(cornerRadius: ComposerStyle.radius(composerStyle), style: .continuous)
                            .stroke(sc, lineWidth: 1)
                    }
                }
            )
            .shadow(color: Tw.cardShadow, radius: 8, y: 3)
            // ★ 2026-11-13：长按直接说话的手势在上面那块输入区上，这里不再叠一层
            //   （叠在整条胶囊上会把相机／语音圆钮／＋ 都吃掉，正是「按也按不了」）。
            }
        }
        .sheet(isPresented: $showCamera) {
            StillCameraPicker { data in uploadAttach("拍照.jpg", data) }
                .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFile, allowedContentTypes: [.item]) { result in
            if let url = try? result.get(), let data = try? Data(contentsOf: url) {
                uploadAttach(url.lastPathComponent, data)
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    uploadAttach("照片.jpg", data)
                }
            }
        }
        // ★ 2026-11-14 12:13：左右 12 安全距离不变；上下留白让输入条外侧和纯白画布之间有间隔。
        //   输入条自己靠「清晰浅灰边框 + 白底 + 下沿轻影」独立出来；小选项是独立小胶囊，
        //   不打包成大卡片。键盘由 safeAreaInset 交回系统处理，不再自己接通知。
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 12)
        // 这一层占满整宽，输入条左右的 12 安全距离才稳
        .frame(maxWidth: .infinity)
    }

    // MARK: - 起

    // MARK: - 群聊

    // MARK: - 左边的会话栏（贴左边出，顶上两个分页）

    /// ★ 2026-11-10（他报的两处）：
    ///   ① 「建群聊」原来挂在顶栏下面那条独立横排，现在照安卓放进会话栏；
    ///   ② 侧栏从左边出来，不再是从底部升起的半屏卡片。
    ///   顶部两个分页「群聊 / 单人对话框」—— 群列表不再堆在单人列表下面。
    ///   底下「＋ 新建群聊」「回到单聊」两颗常驻，不藏在条件里。
    private var sideBar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("聊天")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Tw.gray900)
                Spacer(minLength: 0)
                Button("关上") { withAnimation { showCats = false } }
                    .font(.system(size: 13))
                    .foregroundStyle(Tw.gray500)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 10)

            HStack(spacing: 0) {
                drawerTabButton("群聊", 0)
                drawerTabButton("单人对话框", 1)
            }
            .padding(4)
            .background(Tw.gray100)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if drawerTab == 0 { groupTab } else { singleTab }

            VStack(spacing: 0) {
                Rectangle().fill(Tw.gray200).frame(height: 0.5)
                Button {
                    showNewGroup = true
                    loadGroupCats()
                } label: {
                    Text("＋ 新建群聊")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Tw.red600)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                }
                .buttonStyle(PressStyle(scale: 0.98))
                Rectangle().fill(Tw.gray100).frame(height: 0.5)
                Button {
                    leaveGroup()
                    withAnimation { showCats = false }
                } label: {
                    Text("回到单聊")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Tw.gray600)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                }
                .buttonStyle(PressStyle(scale: 0.98))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Tw.white.ignoresSafeArea())
        .overlay(alignment: .trailing) {
            Rectangle().fill(Tw.gray200).frame(width: 0.5)
        }
    }

    private func drawerTabButton(_ title: String, _ idx: Int) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { drawerTab = idx }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: drawerTab == idx ? .semibold : .regular))
                .foregroundStyle(drawerTab == idx ? Tw.gray900 : Tw.gray400)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(drawerTab == idx ? Tw.white : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    /// 群聊分页：台子真给过的群，点一个就进那个群。
    private var groupTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if loadingGroups {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.7)
                        Text("正在把群找来…")
                            .font(.system(size: 12))
                            .foregroundStyle(Tw.gray400)
                    }
                    .padding(.vertical, 14)
                } else if !groupListErr.isEmpty {
                    Text(groupListErr)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Tw.error)
                        .padding(.vertical, 14)
                } else if groups.isEmpty {
                    Text("还没有群 —— 点下面「＋ 新建群聊」凑一桌")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Tw.gray400)
                        .padding(.vertical, 14)
                } else {
                    ForEach(groups) { g in
                        Button {
                            Task { await enterGroup(g) }
                        } label: {
                            HStack(spacing: 8) {
                                Text(g.name.isEmpty ? "小群" : g.name)
                                    .font(.system(size: 14.5))
                                    .foregroundStyle(Tw.gray900)
                                Spacer(minLength: 0)
                                if CatBrain.group?.number == g.number {
                                    Text("在聊")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Tw.red600)
                                }
                            }
                            .padding(.vertical, 11)
                        }
                        .buttonStyle(.plain)
                        Rectangle().fill(Tw.gray100).frame(height: 0.5)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(maxHeight: .infinity)
    }

    /// 单人对话框分页：点一只就换成它来聊。
    private var singleTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(cats) { c in
                    Button {
                        Task { await pick(c) }
                    } label: {
                        HStack(spacing: 10) {
                            Text(c.name)
                                .font(.system(size: 14.5))
                                .foregroundStyle(Tw.gray900)
                            Spacer(minLength: 0)
                            if c.id == CatBrain.currentCharId {
                                Text("在用").font(.system(size: 11)).foregroundStyle(Tw.gray400)
                            } else if switching == c.id {
                                Text("在换…").font(.system(size: 11)).foregroundStyle(Tw.gray400)
                            }
                        }
                        .padding(.vertical, 11)
                    }
                    .buttonStyle(.plain)
                    Rectangle().fill(Tw.gray100).frame(height: 0.5)
                }
                if cats.isEmpty {
                    Text("没找到猫 —— 关上再开一次就好")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Tw.gray400)
                        .padding(.vertical, 14)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(maxHeight: .infinity)
    }

    /// 挑猫建群的那一页。
    private var newGroupSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let e = groupErr {
                    Text(e)
                        .font(.system(size: 13))
                        .foregroundStyle(Tw.error)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                } else if creating {
                    Text("正在把猫凑到一起…")
                        .font(.system(size: 13))
                        .foregroundStyle(Tw.gray400)
                        .padding()
                } else if loadingGroup {
                    Text("正在把猫找来…")
                        .font(.system(size: 13))
                        .foregroundStyle(Tw.gray400)
                        .padding()
                } else if picked.count < 2 {
                    Text("多挑几只，才好一起聊")
                        .font(.system(size: 11))
                        .foregroundStyle(Tw.gray400)
                        .padding(.vertical, 8)
                }
                List {
                    ForEach(groupCats) { c in
                        Button {
                            togglePick(c.id)
                        } label: {
                            HStack(spacing: 10) {
                                Text(c.title)
                                    .font(.system(size: 15))
                                    .foregroundStyle(Tw.gray900)
                                Spacer()
                                if picked.contains(c.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Tw.red600)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("拉几只猫一起聊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关上") { showNewGroup = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("建群") { Task { await createGroup() } }
                        .disabled(picked.count < 2 || creating)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func togglePick(_ id: String) {
        if picked.contains(id) { _ = picked.remove(id) }
        else { _ = picked.insert(id) }
    }

    private func loadGroupCats() {
        picked = []
        groupErr = nil
        loadingGroup = true
        Task {
            do {
                let list = try await ActLab.chars()
                groupCats = list.filter { $0.dropped != true }
            } catch {
                groupErr = "没连上，等会儿再试"
            }
            loadingGroup = false
        }
    }

    @MainActor
    private func createGroup() async {
        guard picked.count >= 2, !creating else { return }
        creating = true
        groupErr = nil
        defer { creating = false }
        let chosen = groupCats.filter { picked.contains($0.id) }
        let ids = chosen.map { $0.id }
        var names: [String: String] = [:]
        for c in chosen { names[c.id] = c.title }
        if let number = await CatBrain.createGroup(members: ids, names: names) {
            CatBrain.saveGroup(number: number, members: ids, names: names,
                               title: CatBrain.groupDefaultTitle)
            groupTitle = CatBrain.groupDefaultTitle
            showNewGroup = false
            drawerTab = 0
            loadGroups()        // ★ 新群要立刻出现在侧栏「群聊」里
        } else {
            groupErr = "没连上，等会儿再试"
        }
    }

    /// 退出群聊 / 回到单聊：清空当前群号（单聊时点了也无害）。
    private func leaveGroup() {
        CatBrain.clearGroup()
        groupTitle = ""
        showNewGroup = false
        syncSettings()
    }

    // MARK: - 会话栏 / 群设置的活

    private func openDrawer() {
        // 现在在群聊就停在「群聊」，单聊就停在「单人对话框」
        drawerTab = (CatBrain.group == nil) ? 1 : 0
        loadCats()
        loadGroups()
        withAnimation { showCats = true }
    }

    private func loadGroups() {
        loadingGroups = true
        Task {
            let r = await CatBrain.listGroups()
            loadingGroups = false
            if r.ok {
                groups = r.群
                groupListErr = ""
            } else {
                // ★ 查不到就说查不到，不把「还没连上」当成「一个群都没有」
                groupListErr = "没连上，等会儿再试"
            }
        }
    }

    /// 点侧栏里的一个群：把台子给的成员与群号装进当前群，标题换成台子上那个群名。
    @MainActor
    private func enterGroup(_ g: CatBrain.GroupRow) async {
        if cats.isEmpty, let l = try? await ActLab.chars() {
            cats = l.filter { $0.dropped != true }
        }
        var names: [String: String] = [:]
        for id in g.members {
            if let c = cats.first(where: { $0.id == id }) { names[id] = c.name }
        }
        let title = g.name.isEmpty ? "小群" : g.name
        CatBrain.saveGroup(number: g.number, members: g.members,
                           names: names, title: title)
        groupTitle = title
        lines = []
        boot()
        withAnimation { showCats = false }
    }

    // MARK: - 群设置（右上角「设置」→ 拉人 / 改群名 / 踢人）

    /// 名下这些猫里，还没进当前这个群的（拉人用）。
    private var 可拉的猫: [ActLab.Char] {
        cats.filter { !setMembers.contains($0.id) }
    }

    private func syncSettings() {
        let g = CatBrain.group
        setNumber = g?.number ?? ""
        setTitle = g?.title ?? ""
        setMembers = g?.members ?? []
        setNames = g?.names ?? [:]
        setNameInput = g?.title ?? ""
        setErr = ""
        loadCats()
    }

    private var groupSettingsSheet: some View {
        NavigationStack {
            List {
                if setNumber.isEmpty {
                    Section {
                        Text("现在没在群里 —— 先在左边「群聊」里点一个群，或者新建一个。")
                            .font(.system(size: 13))
                            .foregroundStyle(Tw.gray500)
                        Button("去群聊") {
                            showGroupSettings = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                openDrawer()
                            }
                        }
                    }
                } else {
                    Section("群名") {
                        HStack {
                            TextField("给这个群起个名", text: $setNameInput)
                                .font(.system(size: 14))
                            Button("保存") { Task { await saveGroupName() } }
                                .disabled(setBusy || setNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    Section("拉一只进来") {
                        if 可拉的猫.isEmpty {
                            Text("名下这些猫都已经在群里了")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Tw.gray400)
                        } else {
                            ForEach(可拉的猫) { c in
                                Button { Task { await addMember(c) } } label: {
                                    HStack {
                                        Text(c.name).foregroundStyle(Tw.gray900)
                                        Spacer(minLength: 0)
                                        Text("拉进来")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Tw.red600)
                                    }
                                }
                                .disabled(setBusy)
                            }
                        }
                    }
                    Section("群里的猫 · 点一下请它离开") {
                        ForEach(setMembers, id: \.self) { id in
                            Button { Task { await removeMember(id) } } label: {
                                HStack {
                                    Text(setNames[id] ?? id).foregroundStyle(Tw.gray900)
                                    Spacer(minLength: 0)
                                    Text("请它离开")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Tw.gray500)
                                }
                            }
                            .disabled(setBusy)
                        }
                    }
                }
                if !setErr.isEmpty {
                    Section {
                        Text(setErr).font(.system(size: 12.5)).foregroundStyle(Tw.error)
                    }
                }
            }
            .navigationTitle("群设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关上") { showGroupSettings = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { syncSettings() }
    }

    @MainActor
    private func saveGroupName() async {
        let n = setNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !setNumber.isEmpty, !setBusy else { return }
        setBusy = true
        defer { setBusy = false }
        let r = await CatBrain.renameGroup(number: setNumber, name: n)
        if r.ok {
            setTitle = n
            groupTitle = n
            CatBrain.saveGroup(number: setNumber, members: setMembers,
                               names: setNames, title: n)
            loadGroups()
            setErr = ""
        } else {
            setErr = r.错误
        }
    }

    @MainActor
    private func addMember(_ c: ActLab.Char) async {
        guard !setNumber.isEmpty, !setBusy else { return }
        setBusy = true
        defer { setBusy = false }
        let r = await CatBrain.addToGroup(number: setNumber, char: c.id)
        if r.ok {
            var m = setMembers
            if !m.contains(c.id) { m.append(c.id) }
            var n = setNames
            n[c.id] = c.name
            setMembers = m
            setNames = n
            CatBrain.saveGroup(number: setNumber, members: m, names: n, title: setTitle)
            loadGroups()
            setErr = ""
        } else {
            setErr = r.错误
        }
    }

    @MainActor
    private func removeMember(_ id: String) async {
        guard !setNumber.isEmpty, !setBusy else { return }
        setBusy = true
        defer { setBusy = false }
        let r = await CatBrain.removeFromGroup(number: setNumber, char: id)
        if r.ok {
            let m = setMembers.filter { $0 != id }
            var n = setNames
            n.removeValue(forKey: id)
            setMembers = m
            setNames = n
            CatBrain.saveGroup(number: setNumber, members: m, names: n, title: setTitle)
            loadGroups()
            setErr = ""
        } else {
            setErr = r.错误
        }
    }

    private func loadCats() {
        Task {
            if let list = try? await ActLab.chars() {
                cats = list.filter { $0.dropped != true }
            }
        }
    }

    @MainActor
    private func pick(_ c: ActLab.Char) async {
        guard c.id != CatBrain.currentCharId else { showCats = false; return }
        switching = c.id
        defer { switching = "" }
        do {
            let pack = try await CatPackStore.shared.install(charId: c.id)
            CatPackStore.shared.use(pack)
            CatBrain.currentCharId = c.id
            showCats = false
            lines = []
            boot()
        } catch {
            // 换失败就留在原地，不改当前这只
        }
    }

    private func boot() {
        // 冷启动把上次那个群找回来；单聊就是空标题。
        CatBrain.loadGroup()
        groupTitle = CatBrain.group?.title ?? ""
        铺记录()
        // ★ 2026-11-18（第三档·永久全存）：顺手去台子把这只的历史接回来。
        //   单独一个 Task，绝不让它把页面拖住；连不上就算了，接回来是空的也不重画。
        //   拉的过程中换了宠物，就把这批丢掉 —— 别把 A 的话塞进 B 的记录里。
        let 这只 = CatBrain.currentCharId
        Task {
            let 条 = await CatBrain.pullLog(char: 这只)
            guard !条.isEmpty else { return }
            await MainActor.run {
                guard 这只 == CatBrain.currentCharId else { return }
                if ChatLog.merge(条) > 0 { 铺记录() }
            }
        }
        // ★ 2026-10-31（他要求）：进聊天**不要**自动拉起键盘，点了输入框才起。
    }

    /// 把 ChatLog 里存的记录铺成界面上的一行行。
    /// ★ v48：整段记录都摆出来（以前只有最后一句）。
    ///   老数据只有 last 那一句 —— 记录是空的就退回它，别让人以为记录被清了。
    /// ★ 2026-11-18：从台子接回历史之后要重铺一次，所以单独抽出来，boot 和它共用。
    private func 铺记录() {
        let rows = ChatLog.all()
        if rows.isEmpty, let t = CatTalk.last() {
            lines = [Line(mine: true, text: t.mine), Line(mine: false, text: t.reply)]
        } else {
            lines = rows.flatMap {
                [Line(mine: true, text: $0.you), Line(mine: false, text: $0.cat)]
            }
        }
    }

    private func close() {
        TalkFocus.shared.resign()
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        // ★ v44：这一页也「让位」了（停喂帧、停播放、松开音频会话），
        //   视图被移除时不一定走 didEndEditing —— 这里显式还回去，
        //   否则进过一次聊天记录，猫的画和声音就一直停着。
        PiPController.shared?.resumeAfterTyping()
        dismiss()
    }

    // MARK: - 长按输入框＝按住直接说（对齐安卓，2026-11-13）

    /// ★ 2026-11-21（对齐安卓语音手感）：轻震一下。只做反馈，不出声、不改数据。
    private func 轻震() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 按住超过 0.35 秒就起录；短按仍然是打字，不抢键盘。
    private var holdLongPress: some Gesture {
        LongPressGesture(minimumDuration: 0.35, maximumDistance: 200)
            .onEnded { _ in
                guard !voiceMode, !holdDown else { return }
                holdDown = true
                holdActive = true
                holdStartAt = Date()
                holdCancel = false
                holdTip = ""
                focus.resign()
                holdVoice.start()
                轻震()          // 起录这一下，只震一次
            }
    }

    /// 手指还在时记「上滑取消」，松手就收尾。
    private var holdDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                guard holdDown, !voiceMode else { return }
                let 现在取消 = g.translation.height < -64
                // ★ 2026-11-21：滑进取消、从取消滑回来，各震一下（只在状态翻转那一瞬）
                if 现在取消 != holdCancel { 轻震() }
                holdCancel = 现在取消
            }
            .onEnded { g in
                guard holdDown, !voiceMode else { return }
                holdDown = false
                holdActive = false
                let tooShort = Date().timeIntervalSince(holdStartAt) < 0.6
                let cancelled = holdCancel || g.translation.height < -64
                let 机器话 = holdVoice.err        // ★ stop() 会清状态，先取走原话
                let said = holdVoice.stop()
                holdCancel = false
                holdHist = Array(repeating: 0.05, count: 24)
                // ★ 只说机器上真有的话：太短 / 机器原话，不编「没听清」这类理由。
                if tooShort { 轻提示("说话时间太短") }
                else if let e = 机器话, !e.isEmpty { 轻提示(e) }
                else if !cancelled && !said.isEmpty { text = said; send() }
            }
    }

    /// 一行小灰字，两秒后自己收掉。
    private func 轻提示(_ s: String) {
        holdTip = s
        // 明确写 @MainActor，别让改界面这句话卡在并发检查上（CI 一次编译很贵）。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if holdTip == s { holdTip = "" }
        }
    }

    /// 录音态：**只有机器真在录**才画音波、才写「松手发送」。
    /// 麦克风／语音识别没给，就照实把机器原话摆出来，不摆一条假录音条骗人
    /// （安卓那边同款坑当天已修，这里一并对齐）。
    private var holdBar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(holdVoice.listening && holdCancel
                      ? Tw.error.opacity(0.08) : Tw.gray50)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(holdVoice.listening && holdCancel
                            ? Tw.error.opacity(0.5) : Tw.gray200, lineWidth: 1))
            if holdVoice.listening {
                HStack(alignment: .center, spacing: 1.6) {
                    ForEach(0..<24, id: \.self) { i in
                        Capsule()
                            .fill(holdCancel ? Tw.error.opacity(0.55) : Tw.gray900.opacity(0.75))
                            .frame(width: 1.8, height: max(2, 26 * (0.06 + holdHist[i])))
                    }
                }
            }
            Text(holdVoice.listening
                 ? (holdCancel ? "松手取消" : "松手发送")
                 : (holdVoice.err ?? "正在等麦克风允许…"))
                .font(.system(size: 11))
                .foregroundStyle(holdVoice.listening
                                 ? (holdCancel ? Tw.error : Tw.gray400)
                                 : Tw.gray500)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 12)
        }
        .onReceive(Timer.publish(every: 0.06, on: .main, in: .common).autoconnect()) { _ in
            guard holdActive, holdVoice.listening else { return }
            holdHist.removeLast()
            holdHist.insert(max(0.05, CGFloat(holdVoice.level)), at: 0)
        }
    }

    /// ＋ 点开的三格：相机 / 相册 / 文件，三格都能真选、真传、真落盘。
    /// ★ 2026-11-14 12:13：加号面板回到页面流里；4 个图标 ＋ 内嵌相册缩略图照旧，不跳系统相册。
    private var attachPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("添加")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tw.gray900)
                Spacer(minLength: 0)
                Button("收起 ×") { showAttach = false }
                    .font(.system(size: 11))
                    .foregroundStyle(Tw.gray400)
            }
            HStack(spacing: 8) {
                ForEach(["相机", "相册", "文件", "打电话"], id: \.self) { s in
                    Button { pickAttach(s) } label: {
                        VStack(spacing: 5) {
                            Image(systemName: s == "相机" ? "camera"
                                  : (s == "相册" ? "photo"
                                     : (s == "文件" ? "paperclip" : "phone")))
                                .font(.system(size: 19))
                                .foregroundStyle(Tw.gray900)
                            Text(s).font(.system(size: 11)).foregroundStyle(Tw.gray500)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 11).fill(Tw.gray50))
                    }
                    .buttonStyle(.plain)
                }
            }
            // 缩略图直接摆在自己面板里，点一下就选中
            内嵌相册(收好: { arr in
                for (i, d) in arr.enumerated() {
                    uploadAttach("照片\(i + 1).jpg", d)
                }
                showAttach = false
            })
            .frame(maxHeight: 290)
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 16).fill(Tw.white)
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .stroke(Tw.gray200, lineWidth: 1))
        )
        // ★ 12:13：不再是浮层，撤掉那层大投影（会把四周白底染灰）；留圆角 + 细边框。
    }

    // ---------- 三格附件：真选、真传、真落盘 ----------

    /// ★ 2026-11-13：三格点下去就真的开相机／相册／文件，不再拦一道「先去写动作」。
    /// ★ 2026-11-14：相册改成「就在这儿选」，不跳系统相册；
    ///   打电话机器上没这功能，照实回一句，不做按了没反应的假按钮。
    private func pickAttach(_ s: String) {
        progressText = ""
        if s == "相机" { showAttach = false; showCamera = true }
        else if s == "文件" { showAttach = false; showFile = true }
        else if s == "相册" { /* 缩略图就在下面那块，不跳页 */ }
        else { progressText = "这个功能还没接 —— 机器上没有通话" }
    }

    /// 附件仍可选、可看；聊天里已不再能制作动作，如实告诉用户去哪做。
    private func uploadAttach(_ name: String, _ data: Data) {
        _ = data
        progressText = "收到 \(name)，聊天里已不能制作动作，请到角色页或动作库做"
    }

    // MARK: - 发

    private func send() {
        let m = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else { return }
        text = ""
        // 用户气泡统一在这里摆一次（排队/直发都摆），真发() 不再重复摆。
        lines.append(Line(mine: true, text: m))
        // ★ 2026-11-19：生成中不再吞掉——进队，等这条真回完再发下一条。
        //   「失败绝不隐式重发」：失败那条已摆在气泡里，不重发；只推后面排队的。
        if busy {
            待发.append(m)
            pulse += 1
            return
        }
        真发(m)
    }

    /// 真发一条（用户气泡已由 send() 摆好）。
    /// ★ 2026-11-20：复用 rid 非空＝重试——填回原来那行，不再摆新气泡、不重复记本地。
    private func 真发(_ m: String, 复用 rid0: UUID? = nil) {
        busy = true
        let rid: UUID
        if let 旧 = rid0, let i = lines.firstIndex(where: { $0.id == 旧 }) {
            // 重试：清掉上一轮的失败标记和错误文字，原地重来。
            rid = 旧
            lines[i].text = "（它在想…）"
            lines[i].failed = false
            lines[i].cost = nil
        } else {
            // 先摆一条空回复，流式收到字就往这条里填（主聊天页边收边显示）。
            let waiting = Line(mine: false, text: "（它在想…）")
            lines.append(waiting)
            rid = waiting.id
        }
        pulse += 1                     // 发完还留在输入态，想接着说就接着打

        Task { @MainActor in
            let reply = await CatTalk.say(m,
                onStream: { full in
                    // 台子给的「当前完整回话」直接写进去（片段已追加、重来已替换）。
                    if let i = lines.firstIndex(where: { $0.id == rid }) {
                        lines[i].text = full
                    }
                },
                onFinish: { cost in
                    if let cost,
                       let i = lines.firstIndex(where: { $0.id == rid }) {
                        lines[i].cost = cost
                    }
                },
                onFail: { _ in
                    // ★ 只认台子明说的失败。标在这行上，气泡底下才挂「重试」。
                    if let i = lines.firstIndex(where: { $0.id == rid }) {
                        lines[i].failed = true
                        lines[i].retryText = m
                    }
                })
            // 用返回值做最后对齐：中文错误提示、或断网回落的本地猫话，都落进气泡。
            if let i = lines.firstIndex(where: { $0.id == rid }) {
                lines[i].text = reply
                if CatBrain.group != nil {
                    lines[i].speaker = CatTalk.lastSpeakerName
                }
            }
            busy = false
            pulse += 1
            // ★ 2026-11-19：这条真回完了（成也罢败也罢），才发下一条。
            //   失败那条不重发、不跳过（已经在气泡里）；只推用户后来又发、还在队列里的。
            if !待发.isEmpty {
                let next = 待发.removeFirst()
                真发(next)
            }
        }
    }
}
