import SwiftUI
import Photos
import UIKit

// ★ 2026-11-14：加号面板里的「内嵌相册预览」。
//   读这台手机相册里真有的照片缩略图，直接画在自己的面板里，不跳到系统相册那一整页。
//   ★ 不用 @MainActor：@StateObject 的默认值是在 View 的 init 里求值的，
//     而 View 的 init 默认不在主线程隔离里 —— 标了就会在真编译时报错（这个项目踩过两次）。
//     所以这里一律用 DispatchQueue.main.async 回主线程再改 @Published。

final class 相册缩略: ObservableObject {
    @Published private(set) var 图: [UIImage] = []
    /// 只写机器上真有的话，不编「没听清」这类理由
    @Published var 说明 = ""
    private var 取过 = false

    func 取() {
        guard !取过 else { return }
        取过 = true
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if s == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] n in
                DispatchQueue.main.async { self?.按权限(n) }
            }
        } else {
            按权限(s)
        }
    }

    private func 按权限(_ s: PHAuthorizationStatus) {
        if s == .authorized || s == .limited {
            读()
        } else {
            说明 = "没给看相册的权限"
        }
    }

    private func 读() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let op = PHFetchOptions()
            op.fetchLimit = 12
            op.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let assets = PHAsset.fetchAssets(with: .image, options: op)
            let mgr = PHImageManager.default()
            let size = CGSize(width: 240, height: 240)
            let opt = PHImageRequestOptions()
            opt.isSynchronous = true
            var out: [UIImage] = []
            assets.enumerateObjects { asset, _, _ in
                var got: UIImage?
                mgr.requestImage(for: asset, targetSize: size,
                                 contentMode: .aspectFill, options: opt) { im, _ in
                    got = im
                }
                if let im = got { out.append(im) }
            }
            DispatchQueue.main.async {
                self?.图 = out
                if out.isEmpty { self?.说明 = "这台手机相册里还没有照片" }
            }
        }
    }
}

/// 面板里的缩略图网格：点一下就选中，底部计数，按「收好」才真的交出去。
struct 内嵌相册: View {
    @StateObject private var 库 = 相册缩略()
    @State private var 选中: Set<Int> = []
    var 收好: ([UIImage]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("相册")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tw.gray900)
                Spacer(minLength: 0)
                Text("直接在这儿选，不跳到系统相册")
                    .font(.system(size: 10))
                    .foregroundStyle(Tw.gray400)
            }
            if !库.说明.isEmpty {
                Text(库.说明)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Tw.gray400)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 4),
                      spacing: 5) {
                ForEach(库.图.indices, id: \.self) { i in
                    let 选了 = 选中.contains(i)
                    Button {
                        if 选了 { 选中.remove(i) } else { 选中.insert(i) }
                    } label: {
                        Image(uiImage: 库.图[i])
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 66)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(选了 ? Tw.red600 : Tw.gray200,
                                        lineWidth: 选了 ? 2 : 1))
                            .overlay(alignment: .topTrailing) {
                                if 选了 {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 15))
                                        .foregroundStyle(Tw.red600)
                                        .padding(3)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text(选中.isEmpty ? "还没选照片" : "已选 \(选中.count) 张")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Tw.gray500)
                Spacer(minLength: 0)
                Button {
                    guard !选中.isEmpty else { return }
                    收好(选中.sorted().map { 库.图[$0] })
                    选中 = []
                } label: {
                    Text("收好")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Tw.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Tw.red600))
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear { 库.取() }
    }
}
