import SwiftUI
import PhotosUI

// MARK: - ① 参考图确认
//
// ★ 2026-11-01（他定的流程）：登记完之后**加一页**，屏幕中间一张参考图，
//   缓一下浮出一句「就用这张开始做？」，下面一颗「开始生成」。
//   这一页只干这一件事：没有名字输入、没有豆包号、没有别的动作。
//   · 想换图：**直接点那张图**（不另设「换一张」键）
//   · 返回：退回登记页，图还在

struct RefConfirmView: View {

    let name: String
    /// 登记时选的那张图
    @State private var photo: Data
    /// 换图之后要不要重新登记（图变了，台子上那张也得换）
    var onPhotoChanged: (Data) async -> Void
    /// 点「开始生成」
    var onStart: () -> Void
    var onBack: () -> Void

    @State private var pickItem: PhotosPickerItem?
    @State private var showPick = false
    @State private var swapBusy = false
    /// 三段落出现：图 → 问句 → 按钮
    @State private var step = 0

    init(name: String, photo: Data,
         onPhotoChanged: @escaping (Data) async -> Void,
         onStart: @escaping () -> Void,
         onBack: @escaping () -> Void) {
        self.name = name
        _photo = State(initialValue: photo)
        self.onPhotoChanged = onPhotoChanged
        self.onStart = onStart
        self.onBack = onBack
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { onBack() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Tw.gray500)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Tw.gray100))
                }
                .buttonStyle(PressStyle(scale: 0.9))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            Spacer(minLength: 12)

            // 参考图（点它就换）
            Button { showPick = true } label: {
                Group {
                    if let ui = UIImage(data: photo) {
                        Image(uiImage: ui)
                            .resizable()
                            .scaledToFit()
                    } else {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Tw.gray100)
                            .overlay(Text("没有图").foregroundStyle(Tw.gray400))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(maxHeight: UIScreen.main.bounds.height * 0.52)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 24)
                .opacity(step >= 1 ? 1 : 0)
                .offset(y: step >= 1 ? 0 : 10)
            }
            .buttonStyle(PressStyle(scale: 0.98))

            Spacer(minLength: 18)

            Text("就用这张开始做？")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Tw.gray900)
                .opacity(step >= 2 ? 1 : 0)
                .offset(y: step >= 2 ? 0 : 8)

            Spacer(minLength: 18)

            Button { onStart() } label: {
                HStack(spacing: 8) {
                    if swapBusy { ProgressView().tint(.white) }
                    Text("开始生成")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(Tw.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Capsule().fill(Tw.gray900))
            }
            .buttonStyle(PressStyle(scale: 0.97))
            .padding(.horizontal, 24)
            .disabled(swapBusy)
            .opacity(step >= 3 ? 1 : 0)

            Text("点一下那张图可以换一张")
                .font(.system(size: 11))
                .foregroundStyle(Tw.gray400)
                .padding(.top, 10)
                .opacity(step >= 3 ? 1 : 0)

            Spacer(minLength: 24)
        }
        .background(Tw.gray50.ignoresSafeArea())
        .photosPicker(isPresented: $showPick, selection: $pickItem, matching: .images)
        .onChange(of: pickItem) { _, item in
            guard let item else { return }
            Task {
                swapBusy = true
                if let d = try? await item.loadTransferable(type: Data.self) {
                    photo = d
                    await onPhotoChanged(d)     // 台子上那张也换掉
                }
                swapBusy = false
            }
        }
        .onAppear {
            // 缓缓浮出：图 → 问句 → 按钮
            withAnimation(.easeOut(duration: 0.45)) { step = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                withAnimation(.easeOut(duration: 0.45)) { step = 2 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.00) {
                withAnimation(.easeOut(duration: 0.40)) { step = 3 }
            }
        }
    }
}
