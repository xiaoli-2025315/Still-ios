import PhotosUI
import SwiftUI
import UIKit

// MARK: - 角色（动作库）
//
// 安卓那边这一页是 `RoleActivity` 右上角「＋」进来的 `ActActivity`：
// 上面一张卡一只它，卡上写着这套动作好了几条；右上「＋」登记新角色。
//
// ★ 这一版只搬「看 + 登记」两件事。
//   动作视频上传（自己传 mp4 让台子抠像）和「装到手机上用」还没搬 ——
//   那两条各自都要一版，不在这一版里掺着做。

@MainActor
final class ActLibModel: ObservableObject {
    @Published var chars: [ActLab.Char] = []
    @Published var loading = false
    @Published var err: String?
    @Published var loadedOnce = false

    func load() async {
        guard !loading else { return }
        loading = true
        err = nil
        do {
            chars = try await ActLab.chars()
            loadedOnce = true
        } catch {
            err = "没取上台子：\(error.localizedDescription)"
        }
        loading = false
    }
}

// ★ @MainActor 必须标在 View 上：`@StateObject private var model = ActLibModel()`
//   这个默认值是在 View 的 init 里求值的，而 ActLibModel 是主线程隔离的 ——
//   不标，CI 就会报 "call to main actor-isolated initializer in a synchronous
//   nonisolated context"。v37/v38 都在这条上崩过一次。
@MainActor
struct ActLibPage: View {

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ActLibModel()

    @State private var showNew = false
    @State private var watching: ActLab.Char?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("一张卡一只它 · 点开看这套动作好了几条")
                        .font(.system(size: 11))
                        .foregroundStyle(Tw.gray500)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 14)

                    if let e = model.err {
                        errCard(e)
                    }

                    if model.chars.isEmpty && model.loading {
                        loadingRow
                    }

                    ForEach(model.chars) { c in
                        Button {
                            watching = c
                        } label: {
                            charCard(c)
                        }
                        .buttonStyle(PressStyle())
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                    }

                    if model.loadedOnce && model.chars.isEmpty && model.err == nil {
                        Text("台子上还没有角色。右上角「＋」登记一只。")
                            .font(.system(size: 12))
                            .foregroundStyle(Tw.gray400)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                    }

                    Spacer(minLength: 30)
                }
                .padding(.top, 4)
            }
            .refreshable { await model.load() }
        }
        .background(Tw.gray50.ignoresSafeArea())
        .task { await model.load() }
        .sheet(isPresented: $showNew) {
            NewRoleSheet { await model.load() }
                .presentationDetents([.large])
        }
        .sheet(item: $watching) { c in
            ActWallSheet(char: c)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tw.gray900)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Tw.gray100))
            }
            .buttonStyle(PressStyle(scale: 0.9))

            Text("角色")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Tw.gray900)

            Spacer(minLength: 8)

            Button {
                showNew = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Tw.gray900)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Tw.gray100))
            }
            .buttonStyle(PressStyle(scale: 0.9))
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    // MARK: - 一张卡

    private func charCard(_ c: ActLab.Char) -> some View {
        HStack(spacing: 13) {
            avatar(c)

            VStack(alignment: .leading, spacing: 4) {
                Text(c.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Tw.gray900)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(c.isPaid ? "付费" : "免费")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(c.isPaid ? Tw.red600 : Tw.gray500)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(c.isPaid ? Tw.red600.opacity(0.10) : Tw.gray100)
                        )

                    Text("\(c.doneCount)/12 条动作好了")
                        .font(.system(size: 11))
                        .foregroundStyle(c.doneCount >= 12 ? Tw.green500 : Tw.gray500)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tw.gray300)
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Tw.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Tw.gray200, lineWidth: 1)
                )
        )
    }

    private func avatar(_ c: ActLab.Char) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Tw.gray100)
                .frame(width: 56, height: 56)

            if let u = c.imgURL {
                AsyncImage(url: u) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                    } else {
                        Image(systemName: "cat.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Tw.gray400)
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Image(systemName: "cat.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Tw.gray400)
            }
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.8)
            Text("正在从台子上取…")
                .font(.system(size: 12))
                .foregroundStyle(Tw.gray500)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
    }

    private func errCard(_ e: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(e)
                .font(.system(size: 12))
                .foregroundStyle(Tw.red600)
                .fixedSize(horizontal: false, vertical: true)
            Button("再试一次") {
                Task { await model.load() }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Tw.red600)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Tw.red600.opacity(0.06))
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }
}

// MARK: - 一只的动作墙

struct ActWallSheet: View {

    let char: ActLab.Char

    @Environment(\.dismiss) private var dismiss
    @State private var manifest: ActLab.Manifest?
    @State private var err: String?

    private let cols = [GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(char.title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Tw.gray900)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Tw.gray500)
                }
                Spacer(minLength: 0)
                Button("关上") { dismiss() }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tw.gray500)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ScrollView {
                if let e = err {
                    Text(e)
                        .font(.system(size: 12))
                        .foregroundStyle(Tw.red600)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }

                LazyVGrid(columns: cols, spacing: 8) {
                    ForEach(ActLab.official, id: \.key) { item in
                        tile(key: item.key, label: item.label)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(Tw.gray50.ignoresSafeArea())
        .task { await load() }
    }

    private var subtitle: String {
        guard let m = manifest else { return "正在看这套动作…" }
        var s = "\(char.doneCount)/12 条好了"
        if m.pending > 0 { s += " · \(m.pending) 条还在抠" }
        return s
    }

    private func tile(key: String, label: String) -> some View {
        let done = manifest?.names.contains(key) ?? false
        return VStack(spacing: 4) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dotted")
                .font(.system(size: 17))
                .foregroundStyle(done ? Tw.green500 : Tw.gray300)
            Text(label)
                .font(.system(size: 11, weight: done ? .semibold : .regular))
                .foregroundStyle(done ? Tw.gray900 : Tw.gray400)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Tw.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(done ? Tw.green500.opacity(0.35) : Tw.gray200, lineWidth: 1)
                )
        )
    }

    private func load() async {
        do {
            manifest = try await ActLab.manifest(charId: char.id)
        } catch {
            err = "清单没取上：\(error.localizedDescription)"
        }
    }
}

// MARK: - 登记一个新角色
//
// 照安卓 `addCharDialog` 那三样：名字 / 一张照片 / 走哪条通道。
// 照片从相册选（PHPicker），选完立刻转成 JPEG —— 相册里常见的 HEIC，台子不一定认。

struct NewRoleSheet: View {

    /// 登记成功后回调（让外面刷新列表）
    var onDone: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var channel = "free"
    @State private var picked: PhotosPickerItem?
    @State private var photo: Data?
    @State private var photoName = ""
    @State private var busy = false
    @State private var err: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    Text("它叫什么")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tw.gray500)
                        .padding(.bottom, 6)

                    TextField("比如 奶油", text: $name)
                        .font(.system(size: 15))
                        .foregroundStyle(Tw.gray900)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Tw.gray100)
                        )
                        .autocorrectionDisabled()

                    Text("它的一张照片")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tw.gray500)
                        .padding(.top, 20)
                        .padding(.bottom, 6)

                    PhotosPicker(selection: $picked, matching: .images) {
                        HStack(spacing: 8) {
                            Image(systemName: photo == nil ? "photo.badge.plus" : "checkmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(photo == nil ? Tw.gray900 : Tw.green500)
                            Text(photo == nil ? "点这里选它的一张照片" : photoName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Tw.gray900)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Tw.gray100)
                        )
                    }
                    .onChange(of: picked) { _, newItem in
                        Task { await takePhoto(newItem) }
                    }

                    Text("一张就够 · 正面清楚最好")
                        .font(.system(size: 11))
                        .foregroundStyle(Tw.gray400)
                        .padding(.top, 6)

                    Text("它走哪条通道")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tw.gray500)
                        .padding(.top, 20)
                        .padding(.bottom, 8)

                    HStack(spacing: 8) {
                        chanBox("免费", "自己传动作视频\n我们免费帮你抠像", "free")
                        chanBox("付费", "平台按角色照片\n帮你生成整套动作", "paid")
                    }

                    if let e = err {
                        Text(e)
                            .font(.system(size: 12))
                            .foregroundStyle(Tw.red600)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 14)
                    }

                    Button {
                        Task { await submit() }
                    } label: {
                        HStack(spacing: 8) {
                            if busy { ProgressView().tint(.white) }
                            Text(busy ? "正在登记…" : "登记这个角色")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(Tw.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(canSubmit ? Tw.red600 : Tw.gray300)
                        )
                    }
                    .disabled(!canSubmit)
                    .padding(.top, 22)

                    Text("登记完，这只就出现在台子的角色表里。"
                         + "免费那条要你自己在动作墙里传 12 段视频；付费那条台子按照片生成。")
                        .font(.system(size: 11))
                        .foregroundStyle(Tw.gray400)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                        .padding(.bottom, 30)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            .background(Tw.gray50.ignoresSafeArea())
            .navigationTitle("登记一个新角色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("先不登记") { dismiss() }
                        .foregroundStyle(Tw.gray500)
                }
            }
        }
    }

    private var canSubmit: Bool {
        !busy && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photo != nil
    }

    private func chanBox(_ title: String, _ sub: String, _ value: String) -> some View {
        let on = channel == value
        return Button {
            channel = value
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Tw.gray900)
                Text(sub)
                    .font(.system(size: 11))
                    .foregroundStyle(Tw.gray500)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(on ? Tw.red600.opacity(0.06) : Tw.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(on ? Tw.red600 : Tw.gray200, lineWidth: on ? 1.6 : 1)
                    )
            )
        }
        .buttonStyle(PressStyle())
    }

    // MARK: - 选照片

    private func takePhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        err = nil
        do {
            guard let raw = try await item.loadTransferable(type: Data.self),
                  let img = UIImage(data: raw),
                  let jpg = img.jpegData(compressionQuality: 0.9) else {
                err = "这张照片读不出来，换一张试试"
                return
            }
            photo = jpg
            // 只显示个名字用的信息：尺寸 + 大小，比一串哈希好认
            let px = "\(Int(img.size.width))×\(Int(img.size.height))"
            photoName = "\(px) · \(String(format: "%.1f", Double(jpg.count) / 1048576.0)) MB"
        } catch {
            err = "选照片失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 提交

    private func submit() async {
        let nm = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nm.isEmpty, let p = photo else { return }
        busy = true
        err = nil
        do {
            _ = try await ActLab.create(name: nm, channel: channel, photo: p)
            await onDone()
            dismiss()
        } catch {
            err = "登记失败：\(error.localizedDescription)"
        }
        busy = false
    }
}
