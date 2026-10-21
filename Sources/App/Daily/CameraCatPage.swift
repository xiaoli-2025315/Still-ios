import AVFoundation
import Photos
import SwiftUI
import UIKit

// MARK: - 带它进现实（相机 + 猫）
//
// 安卓那边这一页（`CameraCatActivity`）做的是「把猫贴进相机实时画面里」。
// iPhone 这一版给的是**免费、不联网、不按秒计费**的那条：
// 相机实时取景 + 它站在画面里 + 拍照/录像直接存相册。
//
// ★ 为什么不做「实时换脸（Decart）」：
//   那条要一把 Decart 的 key、按 $0.02/秒 计费，而且它是给整张画面做扩散生成的，
//   在手机上跑要 WebRTC + 服务端算力。先把**人人能用、不花钱**这条给全 ——
//   想接付费实时那条，给我一把 key，我再单开一版（这版不掺进去，免得误触扣费）。
//
// ★ 相机不引任何第三方：AVFoundation 就够。取景用 AVCaptureVideoPreviewLayer
//   （不是自己画帧）—— 这是唯一不会「黑屏」的做法。

// MARK: - 相机

final class CamModel: NSObject, ObservableObject {

    let session = AVCaptureSession()

    @Published var ready = false
    @Published var err: String?
    @Published var recording = false
    @Published var note = ""

    private let movie = AVCaptureMovieFileOutput()
    private let photoOut = AVCapturePhotoOutput()
    private var videoIn: AVCaptureDeviceInput?
    private var configured = false
    private var position: AVCaptureDevice.Position = .back

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setup()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async {
                    if ok { self.setup() } else { self.err = "相机没被允许 —— 去「设置 → 还在 → 相机」打开" }
                }
            }
        default:
            err = "相机被关了 —— 去「设置 → 还在 → 相机」打开"
        }
        // 录像要收音，顺手要一下（不给也能录，只是没声）
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    private func setup() {
        guard !configured else {
            run()
            return
        }
        configured = true

        session.beginConfiguration()
        session.sessionPreset = .high

        if let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
           let input = try? AVCaptureDeviceInput(device: cam),
           session.canAddInput(input) {
            session.addInput(input)
            videoIn = input
        } else {
            session.commitConfiguration()
            err = "这台机器打不开相机"
            return
        }

        if let mic = AVCaptureDevice.default(for: .audio),
           let mi = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(mi) {
            session.addInput(mi)
        }

        if session.canAddOutput(movie) { session.addOutput(movie) }
        if session.canAddOutput(photoOut) { session.addOutput(photoOut) }

        session.commitConfiguration()
        run()
    }

    private func run() {
        guard !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
            DispatchQueue.main.async { self.ready = true }
        }
    }

    func stop() {
        DispatchQueue.global(qos: .utility).async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// 前后镜头切换
    func flip() {
        guard !recording, let old = videoIn else { return }
        let want: AVCaptureDevice.Position = (position == .back) ? .front : .back
        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: want),
              let input = try? AVCaptureDeviceInput(device: cam) else { return }

        session.beginConfiguration()
        session.removeInput(old)
        if session.canAddInput(input) {
            session.addInput(input)
            videoIn = input
            position = want
        } else {
            session.addInput(old)
        }
        session.commitConfiguration()
    }

    func toggleRecord() {
        if recording {
            movie.stopRecording()
            return
        }
        guard ready else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("still-cam-\(UUID().uuidString).mov")
        movie.startRecording(to: url, recordingDelegate: self)
        recording = true
        note = "正在录 · 再点一下停"
    }

    func snap() {
        guard ready else { return }
        let settings = AVCapturePhotoSettings()
        photoOut.capturePhoto(with: settings, delegate: self)
        note = "拍了一张"
    }

    private func saveVideo(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            guard st == .authorized || st == .limited else {
                DispatchQueue.main.async { self.note = "没被允许存相册 —— 到设置里打开" }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { ok, e in
                try? FileManager.default.removeItem(at: url)
                DispatchQueue.main.async {
                    self.note = ok ? "录好了，已经存进相册" : "没存上：\(e?.localizedDescription ?? "")"
                }
            }
        }
    }

    private func savePhoto(_ data: Data) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            guard st == .authorized || st == .limited else {
                DispatchQueue.main.async { self.note = "没被允许存相册 —— 到设置里打开" }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, data: data, options: nil)
            }) { ok, e in
                DispatchQueue.main.async {
                    self.note = ok ? "拍好了，已经存进相册" : "没存上：\(e?.localizedDescription ?? "")"
                }
            }
        }
    }
}

extension CamModel: AVCaptureFileOutputRecordingDelegate {

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        DispatchQueue.main.async { self.recording = false }
        if let e = error {
            DispatchQueue.main.async { self.note = "这段没录成：\(e.localizedDescription)" }
            return
        }
        saveVideo(outputFileURL)
    }
}

extension CamModel: AVCapturePhotoCaptureDelegate {

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            DispatchQueue.main.async { self.note = "这张没拍成" }
            return
        }
        savePhoto(data)
    }
}

// MARK: - 取景层

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CamPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.preview.session = session
        v.preview.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ v: PreviewUIView, context: Context) {
        if v.preview.session !== session { v.preview.session = session }
    }
}

// MARK: - 页面

@MainActor
struct CameraCatPage: View {

    @Environment(\.dismiss) private var dismiss
    @StateObject private var cam = CamModel()
    @ObservedObject private var store = CatPackStore.shared
    /// 猫站在哪儿（0…1 的横向位置）
    @State private var catX: CGFloat = 0.5
    @State private var catScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CamPreview(session: cam.session)
                .ignoresSafeArea()

            if !cam.ready {
                VStack(spacing: 8) {
                    if let e = cam.err {
                        Text(e)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.9))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    } else {
                        ProgressView().tint(.white)
                        Text("正在打开相机…")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }

            catLayer

            VStack {
                topBar
                Spacer(minLength: 0)
                if !cam.note.isEmpty {
                    Text(cam.note)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.4)))
                        .padding(.bottom, 8)
                }
                controls
            }
        }
        .onAppear { cam.start() }
        .onDisappear { cam.stop() }
    }

    // MARK: 猫

    private var catLayer: some View {
        GeometryReader { g in
            Group {
                if let p = store.current,
                   let a = (p.act("sit") ?? p.acts.first),
                   let img = p.image(act: a, index: 0) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                } else {
                    CatView(pose: .sit, width: 160)
                }
            }
            .frame(width: g.size.width * 0.52 * catScale)
            .position(x: g.size.width * catX, y: g.size.height * 0.72)
            .gesture(
                DragGesture()
                    .onChanged { v in
                        catX = min(0.9, max(0.1, v.location.x / g.size.width))
                    }
            )
            .onTapGesture {
                catScale = catScale > 1.2 ? 0.75 : catScale + 0.2
            }
        }
        .allowsHitTesting(true)
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.black.opacity(0.35)))
            }
            .buttonStyle(PressStyle(scale: 0.9))

            VStack(alignment: .leading, spacing: 1) {
                Text("带它进现实")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text("拖一下猫能挪位置 · 点它变大变小")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 0)

            Button { cam.flip() } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.black.opacity(0.35)))
            }
            .buttonStyle(PressStyle(scale: 0.9))
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    // MARK: 底部

    private var controls: some View {
        HStack(spacing: 30) {
            Button { cam.snap() } label: {
                VStack(spacing: 4) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 18))
                    Text("拍一张")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.white)
                .frame(width: 62, height: 62)
                .background(Circle().fill(Color.white.opacity(0.18)))
            }
            .buttonStyle(PressStyle(scale: 0.93))
            .disabled(!cam.ready || cam.recording)

            Button { cam.toggleRecord() } label: {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.9), lineWidth: 3)
                        .frame(width: 76, height: 76)
                    RoundedRectangle(cornerRadius: cam.recording ? 6 : 32, style: .continuous)
                        .fill(Tw.red600)
                        .frame(width: cam.recording ? 30 : 62, height: cam.recording ? 30 : 62)
                }
            }
            .buttonStyle(PressStyle(scale: 0.94))
            .disabled(!cam.ready)

            VStack(spacing: 4) {
                Image(systemName: "cat.fill")
                    .font(.system(size: 18))
                Text(store.current == nil ? "自带那只" : "它")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: 62, height: 62)
            .background(Circle().fill(Color.white.opacity(0.10)))
        }
        .padding(.bottom, 26)
    }
}
