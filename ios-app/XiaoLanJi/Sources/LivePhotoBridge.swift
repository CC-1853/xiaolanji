import Foundation
import WebKit
import Photos
import PhotosUI
import UIKit

/// iOS 网页拿不到 Live Photo 的配对视频，只能靠原生代码从照片库里读。
/// 这里把「静帧 + 配对 MOV」一起送回网页，网页原有的 addImages() 会按同名文件自动配成实况。
final class LivePhotoBridge: NSObject, WKScriptMessageHandler, PHPickerViewControllerDelegate {

    weak var webView: WKWebView?
    private var callbackName: String?

    // MARK: - JS -> Native

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              body["type"] as? String == "pick" else { return }
        callbackName = body["callback"] as? String
        DispatchQueue.main.async { [weak self] in self?.presentPicker() }
    }

    // MARK: - 相册

    private func presentPicker() {
        guard let root = webView?.window?.rootViewController else {
            reply(["error": "无法打开相册"])
            return
        }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] newStatus in
                DispatchQueue.main.async {
                    if newStatus == .authorized || newStatus == .limited {
                        self?.presentPicker()
                    } else {
                        self?.reply(["error": "需要允许访问相册"])
                    }
                }
            }
            return
        }

        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 9
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        root.present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else {
            reply(["cancelled": true])
            return
        }

        let identifiers = results.compactMap { $0.assetIdentifier }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            var assets: [PHAsset] = []
            fetched.enumerateObjects { asset, _, _ in assets.append(asset) }

            var items: [[String: Any]] = []
            var totalBytes = 0
            let payloadLimit = 8 * 1024 * 1024   // evaluateJavaScript 一次能稳妥承载的体积
            for (index, asset) in assets.enumerated() {
                if totalBytes > payloadLimit { break }
                let resources = PHAssetResource.assetResources(for: asset)
                let isVideoName: (PHAssetResource) -> Bool = {
                    $0.originalFilename.lowercased().hasSuffix(".mov")
                }
                guard let still = resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto })
                        ?? resources.first(where: { !isVideoName($0) }),
                      let stillData = self.read(still), !stillData.isEmpty else { continue }

                // 相册静帧可能是 HEIC，网页 canvas 解不了；统一转成体积可控的 JPEG。
                let converted = self.jpeg(from: stillData)
                let imageData = converted ?? stillData
                let name = String(format: "XLJ_%d", index)
                var item: [String: Any] = [
                    "name": name,
                    "still": imageData.base64EncodedString(),
                    "stillType": converted != nil ? "image/jpeg" : self.mime(for: still.originalFilename, fallback: "image/jpeg")
                ]
                totalBytes += imageData.count

                if let paired = resources.first(where: { $0.type == .pairedVideo || isVideoName($0) }),
                   let videoData = self.read(paired),
                   !videoData.isEmpty,
                   videoData.count < 6 * 1024 * 1024,
                   totalBytes + videoData.count < payloadLimit + 2 * 1024 * 1024 {
                    item["video"] = videoData.base64EncodedString()
                    item["videoType"] = "video/quicktime"
                    totalBytes += videoData.count
                }
                items.append(item)
            }
            self.reply(["items": items])
        }
    }

    private func read(_ resource: PHAssetResource) -> Data? {
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        PHAssetResourceManager.default().requestData(
            for: resource,
            options: options,
            dataReceivedHandler: { data in box.data.append(data) },
            completionHandler: { error in
                box.error = error
                semaphore.signal()
            }
        )
        _ = semaphore.wait(timeout: .now() + 90)
        return box.error == nil ? box.data : nil
    }

    /// 把静帧统一成 JPEG：HEIC 在 WKWebView 的 canvas 里不一定能解码，大图也会拖慢回传。
    private func jpeg(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 1600
        var out = image
        if max(image.size.width, image.size.height) > maxSide {
            let scale = maxSide / max(image.size.width, image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
            image.draw(in: CGRect(origin: .zero, size: size))
            if let scaled = UIGraphicsGetImageFromCurrentImageContext() { out = scaled }
            UIGraphicsEndImageContext()
        }
        return out.jpegData(compressionQuality: 0.85)
    }

    private func mime(for filename: String, fallback: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "heic", "heif": return "image/heic"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "jpg", "jpeg": return "image/jpeg"
        default: return fallback
        }
    }

    // MARK: - Native -> JS

    private func reply(_ payload: [String: Any]) {
        guard let callback = callbackName,
              let webView = webView,
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        callbackName = nil
        let script = "window['\(callback)'] && window['\(callback)'](\(json))"
        DispatchQueue.main.async {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    private final class Box {
        var data = Data()
        var error: Error?
    }
}
