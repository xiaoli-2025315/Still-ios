import AVFoundation
import SwiftUI
import UIKit

// MARK: - 扫一扫
//
// 安卓那个「扫一扫」（`ScanActivity`）扫的是**派遣单**：
// 别人把猫派给你，你照一下那张码，它就到你这儿了。
//
// ★ 认两种码：
//   · 台子的岔路口链接（https://…/in?from=…&name=…&note=…）
//   · 带 scheme 的（stillapp://in?…）
//   别的码不擅自打开 —— 先把内容摆出来，问一句「要不要丢给浏览器」。
//
// ★ 相机这条路只用 AVFoundation，取景用 previewLayer（自己画帧会黑屏，安卓那边栽过两次）。

final class ScanModel: NSObject, ObservableObject {

    let session = AVCaptureSession()

    @Published var found: String?
    @Published var err: String?

    private var done = false
    private var configured = false

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setup()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async {
                    if ok { self.setup() } else { self.err = "相机没被允许 —— 去设置里打开" }
                }
            }
        default:
            err = "相机被关了 —— 去「设置 → 还在 → 相机」打开"
        }
    }

    private func setup() {
        guard !configured else { run(); return }
        configured = true

        session.beginConfiguration()
        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: cam),
              session.canAddInput(input) else {
            session.commitConfiguration()
            err = "这台机器打不开相机"
            return
        }
        session.addInput(input)

        let out = AVCaptureMetadataOutput()
        if session.canAddOutput(out) {
            session.addOutput(out)
            out.setMetadataObjectsDelegate(self, queue: .main)
            out.metadataObjectTypes = [.qr]
        }
        session.commitConfiguration()
        run()
    }

    private func run() {
        guard !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
        }
    }

    func stop() {
        DispatchQueue.global(qos: .utility).async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func again() {
        done = false
        found = nil
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !done else { return }
        guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let s = obj.stringValue, !s.isEmpty else { return }
        done = true
        SoundKit.shared.tap()
        found = s
    }
}

@MainActor
struct ScanPage: View {

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ScanModel()
    /// 扫到的结果要不要拿去开画布
    @State private var openCanvas: String?
    @State private var askBrowser = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CamPreview(session: model.session)
                .ignoresSafeArea()

            // 取景框
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.85), lineWidth: 2)
                .frame(width: 230, height: 230)

            VStack {
                topBar
                Spacer(minLength: 0)
                Text(model.err ?? "对着那张码照一下 —— 就是别人派它来的那张")
                    .font(.system(size: 12))
                    .foregroundStyle(model.err == nil ? .white.opacity(0.8) : Tw.red600)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                    .padding(.bottom, 30)
            }

            if let s = model.found {
                resultCard(s)
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .sheet(item: Binding(get: { openCanvas.map { CanvasTarget(url: $0) } },
                             set: { if $0 == nil { openCanvas = nil } })) { t in
            CanvasPage(url: t.url)
        }
        .confirmationDialog("这不像是「还在」的码", isPresented: $askBrowser, titleVisibility: .visible) {
            Button("用浏览器打开") {
                if let s = model.found, let u = URL(string: s) { UIApplication.shared.open(u) }
            }
            Button("算了", role: .cancel) {}
        } message: {
            Text(model.found ?? "")
        }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.black.opacity(0.35)))
            }
            .buttonStyle(PressStyle(scale: 0.9))

            Text("扫一扫")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    /// 扫到什么，先摊开给人看，再决定要不要开。
    private func resultCard(_ s: String) -> some View {
        let q = URLComponents(string: s)?.queryItems ?? []
        let get = { (k: String) in q.first(where: { $0.name == k })?.value ?? "" }

        return VStack(alignment: .leading, spacing: 8) {
            Text(isOurs(s) ? "接住这张派遣单" : "扫到的内容")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Tw.gray900)

            if isOurs(s) {
                Text("「\(get("from").isEmpty ? "它的主人" : get("from"))」派来的 · \(get("name").isEmpty ? "一只猫" : get("name"))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tw.gray900)
                if !get("note").isEmpty {
                    Text(get("note"))
                        .font(.system(size: 12))
                        .foregroundStyle(Tw.gray600)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !get("until").isEmpty {
                    Text("到 \(get("until")) 回去")
                        .font(.system(size: 11))
                        .foregroundStyle(Tw.gray500)
                }
            } else {
                Text(s)
                    .font(.system(size: 12))
                    .foregroundStyle(Tw.gray600)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button {
                    if isOurs(s) {
                        openCanvas = canvasLink(s)
                    } else {
                        askBrowser = true
                    }
                } label: {
                    Text(isOurs(s) ? "让它进来" : "用浏览器打开")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Tw.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Tw.red600)
                        )
                }
                .buttonStyle(PressStyle())

                Button {
                    model.again()
                } label: {
                    Text("再扫一次")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tw.gray900)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Tw.gray100)
                        )
                }
                .buttonStyle(PressStyle())
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Tw.white)
        )
        .padding(.horizontal, 20)
    }

    private func isOurs(_ s: String) -> Bool {
        guard let u = URL(string: s) else { return false }
        let scheme = (u.scheme ?? "").lowercased()
        let host = (u.host ?? "").lowercased()
        return scheme == "stillapp" || host.hasSuffix("workbuddy.host")
    }

    /// 把派遣单换成画布那一页（保留查询参数：谁派的、叫什么、来干什么）
    private func canvasLink(_ s: String) -> String {
        let q = URLComponents(string: s)?.percentEncodedQuery ?? ""
        return ActLab.base + "/canvas" + (q.isEmpty ? "" : "?" + q)
    }
}

struct CanvasTarget: Identifiable {
    let url: String
    var id: String { url }
}
