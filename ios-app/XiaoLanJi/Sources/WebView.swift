import SwiftUI
import WebKit
import Photos

/// 网页仍然是唯一的一份：https://cc-1853.github.io/xiaolanji/
/// App 只做两件网页做不到的事：① 读取实况照片的配对视频；② 把静帧和视频一起交回网页。
struct RootView: View {
    var body: some View {
        WebContainer()
            .ignoresSafeArea()
            .onAppear {
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in }
            }
    }
}

struct WebContainer: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []

        let bridge = LivePhotoBridge()
        context.coordinator.bridge = bridge
        cfg.userContentController.add(bridge, name: "xlj")
        cfg.userContentController.addUserScript(
            WKUserScript(source: Self.bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )

        let webView = WKWebView(frame: .zero, configuration: cfg)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.allowsBackForwardNavigationGestures = true
        webView.backgroundColor = UIColor(red: 0.969, green: 0.965, blue: 0.984, alpha: 1)
        bridge.webView = webView

        let url = URL(string: "https://cc-1853.github.io/xiaolanji/")!
        webView.load(URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator {
        var bridge: LivePhotoBridge?
    }

    /// 注入到网页的桥。网页只在 window.XLJNative 存在时改走原生相册；浏览器/PWA 里完全不生效。
    static let bridgeJS = """
    (function () {
      if (window.XLJNative) return;
      function bytes(b64) {
        var bin = atob(b64), len = bin.length, arr = new Uint8Array(len), i;
        for (i = 0; i < len; i++) arr[i] = bin.charCodeAt(i);
        return arr;
      }
      window.XLJNative = {
        isApp: true,
        pick: function () {
          return new Promise(function (resolve, reject) {
            var cb = '__xlj_cb_' + Date.now() + '_' + Math.floor(Math.random() * 1000000);
            window[cb] = function (payload) {
              try { delete window[cb]; } catch (e) { window[cb] = undefined; }
              if (!payload || payload.cancelled) { reject(new Error('cancelled')); return; }
              if (payload.error) { reject(new Error(payload.error)); return; }
              var out = [];
              (payload.items || []).forEach(function (it) {
                try {
                  out.push(new File([bytes(it.still)], it.name + '.jpg', { type: it.stillType || 'image/jpeg' }));
                  if (it.video) {
                    out.push(new File([bytes(it.video)], it.name + '.mov', { type: it.videoType || 'video/quicktime' }));
                  }
                } catch (e) {}
              });
              resolve(out);
            };
            window.webkit.messageHandlers.xlj.postMessage({ type: 'pick', callback: cb });
          });
        }
      };
    })();
    """
}
