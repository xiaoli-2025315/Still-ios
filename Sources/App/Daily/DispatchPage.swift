import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

// MARK: - 派它出门
//
// 安卓那页（`DispatchActivity`）干的事：写一张派遣单 → 变成一张二维码 →
// 对方扫一下，猫就掉进他手机里。对方不用装东西（先落到台子的 /in 那一页）。
//
// 派遣单上四样东西，跟安卓一字不差：
//   from  谁派的     name  它叫什么     note  来干什么     until  几时回去
//   （skills 是可选的「它会什么」，一起带上）
//
// ★ 链接格式必须是 `…/in?from=&name=&note=&until=` —— 台子那一页认的就是这个，
//   改了对方就看不到派遣单，只剩一只没名字的猫。

@MainActor
struct DispatchPage: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = CatPackStore.shared

    @State private var pet = ""
    @State private var me = ""
    @State private var to = ""
    @State private var what = "来陪你一会儿"
    @State private var until = ""
    @State private var skills = ""
    @State private var link = ""
    @State private var qr: UIImage?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !link.isEmpty {
                        qrCard
                    }
                    field("它叫什么", "小雪", $pet)
                    field("谁派的（写在派遣单上）", "它的主人", $me)
                    field("派给谁", "比如 王阿姨", $to)
                    field("去干什么", "来陪你一会儿", $what)
                    field("几时回来", "比如 今晚 9 点（可以不填）", $until)
                    field("它会什么（可以不填，逗号分开）", "比如 陪你写东西, 提醒喝水", $skills)

                    Button {
                        make()
                    } label: {
                        Text(link.isEmpty ? "生成派遣单" : "重新生成")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Tw.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Tw.red600)
                            )
                    }
                    .buttonStyle(PressStyle())
                    .padding(.top, 18)

                    Text("对方扫这张码，它就到对方手机上了。"
                         + "上面那些字会原样写在派遣单上 —— 他打开就知道是谁派来的。")
                        .font(.system(size: 11))
                        .foregroundStyle(Tw.gray400)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                        .padding(.bottom, 26)
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
            }
        }
        .background(Tw.gray50.ignoresSafeArea())
        .onAppear {
            if pet.isEmpty { pet = store.current?.title ?? "小雪" }
            if me.isEmpty { me = "它的主人" }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tw.gray500)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Tw.gray100))
            }
            .buttonStyle(PressStyle(scale: 0.9))

            VStack(alignment: .leading, spacing: 1) {
                Text("派它出门")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Tw.gray900)
                Text("把它的二维码给对方扫一下")
                    .font(.system(size: 11))
                    .foregroundStyle(Tw.gray400)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var qrCard: some View {
        VStack(spacing: 10) {
            if let qr {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 210, height: 210)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Tw.white))
            }

            Text("「\(me.isEmpty ? "它的主人" : me)」派 \(pet.isEmpty ? "它" : pet) 去 \(to.isEmpty ? "你那儿" : to)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tw.gray900)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if !what.isEmpty {
                Text(what)
                    .font(.system(size: 11))
                    .foregroundStyle(Tw.gray500)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 8) {
                ShareLink(item: URL(string: link) ?? URL(string: ActLab.base)!) {
                    Text("分享这张码")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Tw.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Tw.red600)
                        )
                }

                Button {
                    if let qr { UIImageWriteToSavedPhotosAlbum(qr, nil, nil, nil) }
                } label: {
                    Text("存到相册")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Tw.gray900)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Tw.gray100)
                        )
                }
                .buttonStyle(PressStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Tw.red600.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Tw.red600.opacity(0.18), lineWidth: 1)
                )
        )
        .padding(.bottom, 6)
    }

    private func field(_ title: String, _ hint: String, _ binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Tw.gray500)
            TextField(hint, text: binding)
                .font(.system(size: 14))
                .foregroundStyle(Tw.gray900)
                .autocorrectionDisabled()
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Tw.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(Tw.gray200, lineWidth: 1)
                        )
                )
        }
        .padding(.top, 12)
    }

    private func make() {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "from", value: me.isEmpty ? "它的主人" : me),
            URLQueryItem(name: "name", value: pet.isEmpty ? "小雪" : pet),
            URLQueryItem(name: "note", value: what.isEmpty ? "来陪你一会儿" : what),
        ]
        if !until.isEmpty { items.append(URLQueryItem(name: "until", value: until)) }
        if !skills.isEmpty {
            let s = skills.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: ",")
            if !s.isEmpty { items.append(URLQueryItem(name: "skills", value: s)) }
        }

        var comp = URLComponents(string: ActLab.base + "/in")!
        comp.queryItems = items
        guard let url = comp.url else { return }
        link = url.absoluteString
        qr = Self.qrImage(link)
        SoundKit.shared.tap()
    }

    /// 生成二维码。用系统的 CoreImage，不引任何库。
    static func qrImage(_ s: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(s.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage else { return nil }
        let scale = 300 / out.extent.width
        let scaled = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
