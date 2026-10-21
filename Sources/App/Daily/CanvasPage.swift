import SwiftUI
import WebKit

// MARK: - 工作台（网页画布）
//
// 安卓那边的「工作台」是一页网页（台子的 `/canvas`）——它本来就是为手机浏览器做的。
// iOS 这一版直接开一个 WebView 装它：不重做一遍界面，两边看到的是同一个工作台。
//
// 扫一扫扫到派遣单也是用这一页：把那张码上的参数原样带过去，
// 对方就会看到猫掉进画布里（客人模式）。

struct WebBox: UIViewRepresentable {

    let url: String
    var onChange: (Bool) -> Void = { _ in }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = context.coordinator
        v.allowsBackForwardNavigationGestures = true
        if let u = URL(string: url) {
            v.load(URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 40))
        }
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {}

    func makeCoordinator() -> Coord { Coord(onChange: onChange) }

    final class Coord: NSObject, WKNavigationDelegate {
        let onChange: (Bool) -> Void
        init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onChange(false)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onChange(true)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onChange(true)
        }
    }
}

@MainActor
struct CanvasPage: View {

    let url: String
    var title: String = "工作台"

    @Environment(\.dismiss) private var dismiss
    @State private var loading = true
    @State private var failed = false
    @State private var reloadKey = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .top) {
                WebBox(url: url) { bad in
                    loading = false
                    failed = bad
                }
                .id(reloadKey)

                if loading {
                    ProgressView()
                        .padding(.top, 40)
                }
                if failed {
                    VStack(spacing: 8) {
                        Text("这页没打开")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Tw.gray900)
                        Text("可能是网断了，或者这台机器刚好在重启。")
                            .font(.system(size: 11))
                            .foregroundStyle(Tw.gray500)
                        Button {
                            failed = false
                            loading = true
                            reloadKey += 1
                        } label: {
                            Text("再开一次")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Tw.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(Tw.red600))
                        }
                        .buttonStyle(PressStyle())
                    }
                    .padding(.top, 50)
                }
            }
        }
        .background(Tw.gray50.ignoresSafeArea())
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

            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Tw.gray900)

            Spacer(minLength: 0)

            Button {
                loading = true
                failed = false
                reloadKey += 1
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tw.gray500)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Tw.gray100))
            }
            .buttonStyle(PressStyle(scale: 0.9))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Tw.white.overlay(alignment: .bottom) {
            Rectangle().fill(Tw.gray200).frame(height: 0.5)
        })
    }
}
