import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import Combine

/// ★ 2026-11-13：台子上真挂着的一个豆包号位（不是写死的「豆包1」）。
fileprivate struct 号位项: Identifiable {
    var id: String { slot }
    let slot: String
    let 名字: String
    let 登着没: Bool
}

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

    @State private var text = ""
    @State private var lines: [Line] = []
    @State private var busy = false
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
    /// 群设置页自己留一份当前群，改完就地刷新（CatBrain.group 是静态值，视图不会自己重画）
    @State private var setNumber = ""
    @State private var setTitle = ""
    @State private var setMembers: [String] = []
    @State private var setNames: [String: String] = [:]
    @State private var setNameInput = ""
    @State private var setBusy = false
    @State private var setErr = ""

    // ★★★ 2026-11-12（照 v0.6 图稿）：输入框上方常驻小选项 ＋ 动作制作面板。
    //   只加不删：老的「语音／键盘 → 整条按住说」那条路原样留着。
    @State private var showMake = false
    @State private var useTemplate = false
    @State private var makeText = ""
    @State private var pickedTpl = ""          // 词库里真有的 id
    @State private var pickedName = ""
    @State private var showAttach = false
    @State private var makeBusy = false
    @State private var pendingCard = false
    @State private var draftNo = ""
    @State private var draftState = ""
    @State private var draftTime = ""
    @State private var draftName = ""
    // ★ 2026-11-12：开工前查登录、真开工回执、机器原话、附件清单
    @State private var draftJob = ""
    @State private var draftAct = ""
    @State private var loginText = "豆包1"
    /// ★ 2026-11-13（他定的）：「就是要能选登录的豆包号还有我们的 wan 路线」。
    ///   台子上号位清单、模型清单、wan 通道都是真的，这两排不再是点不动的字。
    @State private var 做法 = "doubao"            // doubao / wan
    @State private var 选中号 = ""                // 空＝让机器自己挑
    @State private var 模型说 = "豆包 · Seedance 2.0 mini"
    @State private var 号位: [号位项] = []
    @State private var machineErr = ""
    @State private var progressText = ""
    @State private var attachNames: [String] = []
    /// ★ 2026-11-13：写动作之前先选的附件，先收着，回执一出来就补交
    @State private var pendingAttach: [(String, Data)] = []
    @State private var showCamera = false
    @State private var showFile = false
    @State private var showPhotoPicker = false
    @State private var pickedPhoto: PhotosPickerItem? = nil

    private struct Tpl: Identifiable {
        var id: String { key }
        let key: String
        let name: String
    }
    /// 中文名来自台子 act_queue.py 的现行 9 条清单，左边是词库里的真 id。
    private let 已有动作: [Tpl] = [
        Tpl(key: "sit", name: "端坐"), Tpl(key: "hunt1", name: "捕猎"),
        Tpl(key: "hunt2", name: "抓咬"), Tpl(key: "sleep", name: "熟睡"),
        Tpl(key: "struggle", name: "挣扎"), Tpl(key: "walk_r", name: "行走"),
        Tpl(key: "groom", name: "舔毛"), Tpl(key: "inhale", name: "吸入"),
        Tpl(key: "exhale", name: "呼出")
    ]

    struct Line: Identifiable {
        let id = UUID()
        let mine: Bool
        var text: String
        var cost: String? = nil     // 回复下面那行小字，拿不到花费就不显示
        var speaker: String? = nil  // 群聊里回话的那只猫
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
            .onAppear { boot(); loadDraft() }
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
    }

    // MARK: - 顶栏

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

            VStack(alignment: .leading, spacing: 1) {
                Text(groupTitle.isEmpty ? "跟它还说话" : groupTitle)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Tw.gray900)
                Text(busy ? "它在想…" : (groupTitle.isEmpty ? "说一句，它就应一句" : "几只猫一起听着"))
                    .font(.system(size: 11))
                    .foregroundStyle(Tw.gray400)
            }
            Spacer(minLength: 0)

            // ★ 2026-11-10：群聊右上角的「设置」—— 拉人 / 改群名 / 踢人。
            //   常驻，不加显示条件：没在群里时点开会照实说「先在左边点一个群」。
            Button {
                syncSettings()
                showGroupSettings = true
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
                    // ★ 提交后面板收起，确认卡／回执卡就是聊天记录里的一条。
                    if pendingCard { makeConfirmCard }
                    if !draftNo.isEmpty { makeReceiptCard }
                    if !machineErr.isEmpty { machineCard }
                    if !progressText.isEmpty {
                        Text(progressText)
                            .font(.system(size: 11))
                            .foregroundStyle(Tw.gray400)
                    }
                    // ★ 2026-11-13：录音的轻提示单独一行，不占动作制作那行进度文字
                    if !holdTip.isEmpty {
                        Text(holdTip)
                            .font(.system(size: 11))
                            .foregroundStyle(Tw.gray400)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                // ★ 2026-11-14 12:13：输入区回到页面流，滚动区不用再给浮层留一大块空白。
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: lines.count) {
                withAnimation(.easeOut(duration: 0.18)) { sp.scrollTo("bottom", anchor: .bottom) }
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
                    .foregroundStyle(l.mine ? Tw.white : Tw.gray900)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            // ★ 2026-11-14：画布改纯白了，对方气泡也得跟着换极浅灰，
                            //   不然白气泡贴在白画布上等于没有边界。仍是 Tailwind 官方值。
                            .fill(l.mine ? Tw.red600 : Tw.gray50)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(l.mine ? Color.clear : Tw.gray200, lineWidth: 1)
                    )
                    .textSelection(.enabled)
                // 每条回复下面一行小字：这次花了多少，只显示台子真给的数。
                if !l.mine, let c = l.cost {
                    Text(c)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Tw.gray400)
                }
            }
            if !l.mine { Spacer(minLength: 40) }
        }
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
            if showMake { makePanel }

            // ★ 2026-11-14 11:17：小选项和输入条之间的留白拉开（豆包约是我们两倍）。
            VStack(spacing: 18) {
            // ★ 只保留输入框上方这排「💬 对话｜✦ 动作制作」；
            //   图里那排「拍题答疑／AI 创作」不要。跟输入栏同在底部这一节里。
            HStack(spacing: 6) {
                smallChip("💬 对话 ⌄", false)
                    .shadow(color: Color.black.opacity(0.08), radius: 3, y: 1)
                // ★ 2026-11-13：默认不高亮，只有真的在做动作才红
                Button { showMake = true } label: { smallChip("✦ 动作制作", showMake) }
                    .shadow(color: Color.black.opacity(0.08), radius: 3, y: 1)
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                // 左：相机（拍照）
                Button { showAttach.toggle() } label: {
                    Image(systemName: "camera")
                        .font(.system(size: 16))
                        .foregroundStyle(Tw.gray900)
                }
                .frame(width: 24)

                // ★ 手势挂在这块始终存在的容器上：录音时只是换掉里面的画面，手势不会断。
                //   不挂在整条胶囊上，免得把左边的相机、右边的语音圆钮和 ＋ 也盖住。
                ZStack {
                    if voiceMode {
                        // 老的整条录音键：按住说、上滑取消、24 根真音波
                        TalkHoldBar(onSaid: { t in text = t; send() })
                            .frame(height: 30)
                    } else if holdActive {
                        holdBar.frame(height: 30)
                    } else {
                        TalkField(text: $text, focusPulse: pulse, autoFocus: false,
                                  onSubmit: send,
                                  onBeginEdit: { PiPController.shared?.quiesceForTyping() },
                                  onEndEdit: { PiPController.shared?.resumeAfterTyping() })
                            .frame(height: 22)
                            .padding(.horizontal, 2)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 30)
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
                        .font(.system(size: 14))
                        .foregroundStyle(Tw.gray900)
                        .frame(width: 28, height: 28)
                        // ★ 11:17：白底深描边圆钮，不再是浅灰实心块
                        .background(
                            Circle().fill(Tw.white)
                                .overlay(Circle().stroke(Tw.gray900, lineWidth: 1.5))
                        )
                }

                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button { showAttach.toggle() } label: {
                        Image(systemName: showAttach ? "xmark" : "plus")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Tw.gray900)
                    }
                    .frame(width: 28, height: 28)
                    // ★ 11:17：＋ 同样换成描边圆钮（原来只是无框细线）
                    .background(
                        Circle().fill(Tw.white)
                            .overlay(Circle().stroke(Tw.gray900, lineWidth: 1.5))
                    )
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Tw.white)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(busy ? Tw.red600.opacity(0.45) : Tw.red600))
                    }
                    .disabled(busy)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // ★ 2026-11-14 11:17（两张实机截图对比后）：边框本身够清楚，糊掉边界的是
            //   两层大 shadow（radius 20 / y 10），把四周白底染成一片灰。撤掉它们，
            //   改成「只贴下沿一条 2px 浅灰影」；圆角 999 → 20，跟安卓同口径。
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Tw.gray200)
                        .offset(y: 2)
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Tw.white)
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Tw.gray300, lineWidth: 1.5))
                }
            )
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
        .onChange(of: showMake) { on in
            if on { Task { await checkLogin() } }
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
                        .foregroundStyle(Tw.red600)
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
                        .foregroundStyle(Tw.red600)
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
                        Text(setErr).font(.system(size: 12.5)).foregroundStyle(Tw.red600)
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
        // ★ v48：整段记录都摆出来（以前只有最后一句）。
        //   老数据只有 last 那一句 —— 记录是空的就退回它，别让人以为记录被清了。
        let rows = ChatLog.all()
        if rows.isEmpty, let t = CatTalk.last() {
            lines = [Line(mine: true, text: t.mine), Line(mine: false, text: t.reply)]
        } else {
            lines = rows.flatMap {
                [Line(mine: true, text: $0.you), Line(mine: false, text: $0.cat)]
            }
        }
        // ★ 2026-10-31（他要求）：进聊天**不要**自动拉起键盘，点了输入框才起。
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

    // ==================================================================
    // ★★★ 2026-11-12（照 v0.6 图稿）：聊天里做一个新动作
    // ==================================================================

    private func smallChip(_ s: String, _ on: Bool) -> some View {
        Text(s)
            .font(.system(size: 11, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? Tw.red600 : Tw.gray500)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(on ? Tw.red600.opacity(0.08) : Tw.white)
                    // ★ 2026-11-14 09:50：撤掉大卡片后，这两个小胶囊在纯白上也要看得见边界。
                    .overlay(Capsule().stroke(on ? Tw.red600.opacity(0.35) : Tw.gray300,
                                              lineWidth: 1))
            )
    }

    /// ★ 2026-11-14：下拉浮层里的一行，大标题 ＋ 一行灰小字，选中打勾。
    private func 下拉项(_ 标题: String, _ 小字: String, _ 选中: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(标题)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Tw.gray900)
                Text(小字)
                    .font(.system(size: 10))
                    .foregroundStyle(Tw.gray400)
            }
            if 选中 {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tw.red600)
            }
        }
    }

    // MARK: - 长按输入框＝按住直接说（对齐安卓，2026-11-13）

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
            }
    }

    /// 手指还在时记「上滑取消」，松手就收尾。
    private var holdDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                guard holdDown, !voiceMode else { return }
                holdCancel = g.translation.height < -64
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

    /// 一行小灰字，两秒后自己收掉；不碰动作制作那边的进度文字。
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
                      ? Tw.red600.opacity(0.08) : Tw.gray50)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(holdVoice.listening && holdCancel
                            ? Tw.red600.opacity(0.5) : Tw.gray200, lineWidth: 1))
            if holdVoice.listening {
                HStack(alignment: .center, spacing: 1.6) {
                    ForEach(0..<24, id: \.self) { i in
                        Capsule()
                            .fill(holdCancel ? Tw.red600.opacity(0.55) : Tw.gray900.opacity(0.75))
                            .frame(width: 1.8, height: max(2, 26 * (0.06 + holdHist[i])))
                    }
                }
            }
            Text(holdVoice.listening
                 ? (holdCancel ? "松手取消" : "松手发送")
                 : (holdVoice.err ?? "正在等麦克风允许…"))
                .font(.system(size: 11))
                .foregroundStyle(holdVoice.listening
                                 ? (holdCancel ? Tw.red600 : Tw.gray400)
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

    /// 底部动作制作面板（Agent 模式）
    private var makePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { useTemplate = false } label: { smallChip("自定义动作", !useTemplate) }
                Button { useTemplate = true } label: { smallChip("已有动作", useTemplate) }
                Spacer(minLength: 0)
                Button { showMake = false } label: {
                    Image(systemName: "xmark").font(.system(size: 15))
                        .foregroundStyle(Tw.gray500)
                }
            }
            if useTemplate {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 6) {
                    ForEach(已有动作) { t in
                        Button {
                            pickedTpl = t.key
                            pickedName = t.name
                        } label: { smallChip(t.name, pickedTpl == t.key) }
                    }
                }
            } else {
                Text("写下这个动作在做什么，一行一句。写完由纯代码套进固定骨架，不改写你的字。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tw.gray500)
            }
            // ★ 2026-11-14 12:13：三个下拉都是系统菜单（普通弹窗），每行「大标题＋灰小字」，选中回填、自动收起。
            HStack(spacing: 6) {
                Menu {
                    Button {
                        做法 = "doubao"; 存选择()
                    } label: { 下拉项("不花钱的豆包", "写新动作也能做 · 用登着的号",
                                 做法 == "doubao") }
                    Button {
                        做法 = "wan"; 存选择()
                    } label: { 下拉项("要花钱的 wan", "1.20 元 / 条 · 只做已有 9 个动作",
                                 做法 == "wan") }
                } label: {
                    smallChip("做法　" + (做法 == "wan" ? "要花钱的 wan" : "不花钱的豆包") + " ⌄",
                              做法 == "wan")
                }
                smallChip("5.00 秒 · 固定", false)
            }
            HStack(spacing: 6) {
                Menu {
                    Button {
                        选中号 = ""; 存选择()
                    } label: { 下拉项("让机器自己挑", "默认 · 挑一个登着的", 选中号.isEmpty) }
                    ForEach(号位) { x in
                        Button {
                            guard x.登着没 else { return }
                            选中号 = x.slot
                            存选择()
                        } label: {
                            下拉项(x.名字,
                                   x.登着没 ? "登着 · 手机上登的豆包" : "没登录 · 这一个选不了",
                                   选中号 == x.slot)
                        }
                        .disabled(!x.登着没)
                    }
                    Text("没问到别的号位 · 只列机器上真有的")
                } label: { smallChip("豆包号　" + 号位显示() + " ⌄", false) }
            }
            Menu {
                Button {
                    存选择()
                } label: { 下拉项(模型说, "用你登着的豆包号做 · 已接通", true) }
                Text("现在只接通这一个 · 别的还没加")
            } label: {
                Text("模型　" + 模型说 + "　⌄")
                    .font(.system(size: 11))
                    .foregroundStyle(Tw.gray400)
            }
            TextEditor(text: $makeText)
                .frame(height: 62)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 9).fill(Tw.gray50))
                .overlay(alignment: .topLeading) {
                    if makeText.isEmpty {
                        Text("描述你想创作的动作或选择动作模板")
                            .font(.system(size: 12))
                            .foregroundStyle(Tw.gray400)
                            .padding(.top, 13)
                            .padding(.leading, 12)
                    }
                }
            Button { submitDraft() } label: {
                Text("写好了")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Tw.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Tw.red600))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16).fill(Tw.white)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Tw.gray200, lineWidth: 1))
        )
        .padding(10)
    }

    private var makeConfirmCard: some View {
        draftCard(title: draftName.isEmpty ? "新动作" : draftName,
                  rows: [("时长", "5.00 秒"), ("时间轴", "固定，你写的字不改"),
                         ("用哪个做", (做法 == "wan" ? "要花钱的 wan" : "不花钱的豆包")
                          + " · " + 号位显示())],
                  note: nil, button: "开始制作", action: submitToServer)
    }

    private var makeReceiptCard: some View {
        var rows: [(String, String)] = [("状态", draftState), ("单号", draftNo)]
        if !draftJob.isEmpty { rows.append(("这一趟的单号", draftJob)) }
        rows.append(("时间", draftTime))
        for n in attachNames { rows.append(("附件", n)) }
        return draftCard(title: "写好了 · " + draftName,
                  rows: rows,
                  note: "已经交给它去做了，退出再进还看得到做到哪了。",
                  button: nil, action: {},
                  extras: [("看看做到哪了", { refreshDraft() }),
                           ("再做一个", { newOne() })])
    }

    /// 台子明说没接这单时，原话摆出来 + 一颗重试，不自己判失败。
    private var machineCard: some View {
        draftCard(title: "没接这单", rows: [], note: machineErr,
                  button: "再试一次", action: { retryStart() })
    }

    private func draftCard(title: String, rows: [(String, String)], note: String?,
                           button: String?, action: @escaping () -> Void,
                           extras: [(String, () -> Void)] = []) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tw.gray900)
            ForEach(rows.indices, id: \.self) { i in
                HStack {
                    Text(rows[i].0).font(.system(size: 11.5)).foregroundStyle(Tw.gray500)
                    Spacer(minLength: 0)
                    Text(rows[i].1).font(.system(size: 11.5)).foregroundStyle(Tw.gray900)
                }
            }
            if let n = note {
                Text(n).font(.system(size: 11)).foregroundStyle(Tw.gray400)
            }
            if let b = button {
                Button(action: action) {
                    Text(b).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tw.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Tw.red600))
                }
                .padding(.top, 6)
            }
            if !extras.isEmpty {
                HStack(spacing: 6) {
                    ForEach(extras.indices, id: \.self) { i in
                        Button(action: extras[i].1) {
                            Text(extras[i].0)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Tw.gray900)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 9).fill(Tw.gray50))
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Tw.white)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tw.gray200, lineWidth: 1))
        )
    }

    private func submitDraft() {
        let s = makeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if useTemplate && pickedTpl.isEmpty { return }
        if !useTemplate && s.isEmpty { return }
        draftName = useTemplate ? pickedName : "新动作"
        machineErr = ""
        progressText = ""
        pendingCard = true
        showMake = false
    }

    // ---------- 写稿 → 点开始制作 → 真开工（免费豆包链）→ 回执落盘 ----------

    private func postJSON(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: ActLab.base + path)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.stillStamp()
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// ★ 他点「开始制作」才真的开工。已经有单在跑时任何一次进入都不许再下单。
    private func submitToServer() {
        guard !makeBusy else { return }
        guard draftNo.isEmpty else { refreshDraft(); return }
        makeBusy = true
        let body: [String: Any] = [
            "char": CatBrain.currentCharId,
            "描述": makeText.trimmingCharacters(in: .whitespacesAndNewlines),
            "模板": useTemplate ? pickedTpl : ""
        ]
        Task { @MainActor in
            defer { makeBusy = false }
            do {
                let d = try await postJSON("/api/act/draft", body)
                guard (d["ok"] as? Bool) == true else {
                    machineErr = d["错误"] as? String ?? "没连上台子"
                    return
                }
                let no = d["单号"] as? String ?? ""
                guard !no.isEmpty else { return }
                draftNo = no
                draftAct = d["动作名"] as? String ?? ""
                draftName = d["显示名"] as? String ?? draftName
                draftState = d["状态"] as? String ?? ""
                draftTime = d["时间"] as? String ?? ""
                flushPending()
                applyStart(try await postJSON(startPath(), startBody(no)))
            } catch {
                machineErr = "没连上台子，等会儿再试"
            }
        }
    }

    private func applyStart(_ s: [String: Any]) {
        if (s["ok"] as? Bool) == true {
            draftState = s["状态"] as? String ?? draftState
            draftTime = s["时间"] as? String ?? draftTime
            draftJob = s["job"] as? String ?? ""
            pendingCard = false
            machineErr = ""
            saveDraft()
        } else {
            // ★ 只认机器明说的失败，原话原样摆出来，不替它编理由。
            machineErr = s["错误"] as? String ?? "生成那边没接这单"
        }
    }

    private func retryStart() {
        guard !draftNo.isEmpty, !makeBusy else { return }
        makeBusy = true
        let no = draftNo
        Task { @MainActor in
            defer { makeBusy = false }
            do { applyStart(try await postJSON(startPath(), startBody(no))) }
            catch { machineErr = "没连上台子，等会儿再试" }
        }
    }

    /// 退出再进 / 点按钮：只问台子「做到哪了」，只显示机器真写的字。
    private func refreshDraft() {
        guard !draftNo.isEmpty else { return }
        let no = draftNo
        Task { @MainActor in
            do {
                let o = try await postJSON("/api/act/draft/state", ["单号": no])
                guard (o["ok"] as? Bool) == true else { return }
                if let s = o["状态"] as? String, !s.isEmpty { draftState = s }
                if let j = o["job"] as? String, !j.isEmpty { draftJob = j }
                if let a = o["动作名"] as? String, !a.isEmpty { draftAct = a }
                saveDraft()
                if let say = o["进度说"] as? String, !say.isEmpty {
                    progressText = say
                } else if let g = o["进度"] as? [String: Any],
                          let st = (g["阶段"] as? String) ?? (g["stage"] as? String)
                                   ?? (g["状态"] as? String),
                          !st.isEmpty {
                    progressText = "做到哪了　" + st
                }
                if let a = o["附件"] as? [[String: Any]], !a.isEmpty {
                    attachNames = a.compactMap { x in
                        guard let n = x["名字"] as? String else { return nil }
                        return n + "　" + String((x["字节"] as? Int) ?? 0) + " 字节"
                    }
                }
            } catch { /* 不编失败理由 */ }
        }
    }

    private func getJSON(_ path: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: ActLab.base + path)!)
        req.timeoutInterval = 15
        req.stillStamp()
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// ★ 2026-11-13：拉台子上真挂着的号位与真模型名（只读，不登、不改状态）。
    private func checkLogin() async {
        do {
            let a = try await getJSON("/api/login/accounts")
            let arr = a["账号"] as? [[String: Any]] ?? []
            号位 = arr.compactMap { x in
                guard let s = x["slot"] as? String, !s.isEmpty else { return nil }
                return 号位项(slot: s,
                              名字: x["名字"] as? String ?? ("豆包" + s),
                              登着没: x["登着没"] as? Bool ?? false)
            }
            loginText = 号位.isEmpty ? "没问到登着的号" : "\(号位.count) 个豆包号"
        } catch {
            loginText = "没问到"
        }
        do {
            let m = try await getJSON("/api/gen/models")
            if let arr = m["模型"] as? [[String: Any]] {
                for x in arr where (x["接没接通"] as? Bool) == true {
                    if let n = x["名字"] as? String, !n.isEmpty { 模型说 = n; break }
                }
            }
        } catch { /* 不编 */ }
    }

    private func 号位显示() -> String {
        if 选中号.isEmpty { return "机器自己挑" }
        if let x = 号位.first(where: { $0.slot == 选中号 }) { return x.名字 }
        return "豆包" + 选中号 + " 号"
    }

    private func startPath() -> String {
        做法 == "wan" ? "/api/act/draft/wan" : "/api/act/draft/start"
    }

    private func startBody(_ no: String) -> [String: Any] {
        if 做法 == "wan" { return ["单号": no] }
        if 选中号.isEmpty { return ["单号": no] }
        return ["单号": no, "账号": 选中号]
    }

    private func 存选择() {
        let d = UserDefaults.standard
        d.set(做法, forKey: "act_draft_way")
        d.set(选中号, forKey: "act_draft_slot")
    }

    private func 读选择() {
        let d = UserDefaults.standard
        做法 = d.string(forKey: "act_draft_way") ?? "doubao"
        选中号 = d.string(forKey: "act_draft_slot") ?? ""
    }

    private func newOne() {
        draftNo = ""; draftState = ""; draftTime = ""; draftJob = ""; draftAct = ""
        draftName = "新动作"; machineErr = ""; progressText = ""; attachNames = []
        makeText = ""; useTemplate = false; pickedTpl = ""; pickedName = ""
        let d = UserDefaults.standard
        for k in ["act_draft_no", "act_draft_state", "act_draft_time",
                  "act_draft_name", "act_draft_job", "act_draft_act"] {
            d.removeObject(forKey: k)
        }
        showMake = true
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

    private func uploadAttach(_ name: String, _ data: Data) {
        guard !draftNo.isEmpty else {
            pendingAttach.append((name, data))
            progressText = "先收着了 \(name)，写好动作一起交上去"
            return
        }
        let no = draftNo
        Task { @MainActor in
            do {
                var comp = URLComponents(string: ActLab.base + "/api/act/draft/file")!
                comp.queryItems = [URLQueryItem(name: "单号", value: no),
                                   URLQueryItem(name: "名字", value: name)]
                var req = URLRequest(url: comp.url!)
                req.httpMethod = "POST"
                req.timeoutInterval = 60
                req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                req.stillStamp()
                req.httpBody = data
                let (d, _) = try await URLSession.shared.data(for: req)
                let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
                if (o["ok"] as? Bool) == true {
                    let n = o["名字"] as? String ?? name
                    let b = (o["字节"] as? Int) ?? data.count
                    attachNames.append(n + "　" + String(b) + " 字节")
                } else if let e = o["错误"] as? String {
                    progressText = e
                }
            } catch { /* 不编失败理由 */ }
        }
    }

    /// ★ 2026-11-13：写动作之前先选的附件，回执一出来就补交，一件不落。
    private func flushPending() {
        guard !draftNo.isEmpty, !pendingAttach.isEmpty else { return }
        let list = pendingAttach
        pendingAttach = []
        for (n, d) in list { uploadAttach(n, d) }
    }

    private func saveDraft() {
        let d = UserDefaults.standard
        d.set(draftNo, forKey: "act_draft_no")
        d.set(draftState, forKey: "act_draft_state")
        d.set(draftTime, forKey: "act_draft_time")
        d.set(draftName, forKey: "act_draft_name")
        d.set(draftJob, forKey: "act_draft_job")
        d.set(draftAct, forKey: "act_draft_act")
        存选择()
    }

    /// 退出再进还看得到做到哪了；开机只认存下来的回执，不下任何判决。
    private func loadDraft() {
        let d = UserDefaults.standard
        draftNo = d.string(forKey: "act_draft_no") ?? ""
        draftState = d.string(forKey: "act_draft_state") ?? ""
        draftTime = d.string(forKey: "act_draft_time") ?? ""
        draftName = d.string(forKey: "act_draft_name") ?? "新动作"
        draftJob = d.string(forKey: "act_draft_job") ?? ""
        draftAct = d.string(forKey: "act_draft_act") ?? ""
        读选择()
        if !draftNo.isEmpty { refreshDraft() }
    }

    // MARK: - 发

    private func send() {
        let m = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty, !busy else { return }

        text = ""
        busy = true
        lines.append(Line(mine: true, text: m))
        // 先摆一条空回复，流式收到字就往这条里填（主聊天页边收边显示）。
        let waiting = Line(mine: false, text: "（它在想…）")
        lines.append(waiting)
        let rid = waiting.id
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
        }
    }
}
