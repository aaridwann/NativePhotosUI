import Foundation
import PhotosUI
import React
import UniformTypeIdentifiers

@objc(PhotoPickerTurboModule)
public class PhotoPickerTurboModule: NSObject {
    
    private var pendingPromiseResolve: RCTPromiseResolveBlock?
    private var pendingPromiseReject: RCTPromiseRejectBlock?

    private func resolvePromise(_ value: Any?) {
        guard let resolve = pendingPromiseResolve else { return }
        self.pendingPromiseResolve = nil
        self.pendingPromiseReject = nil
        resolve(value)
    }

    private func rejectPromise(code: String, message: String, error: Error? = nil) {
        guard let reject = pendingPromiseReject else { return }
        self.pendingPromiseResolve = nil
        self.pendingPromiseReject = nil
        reject(code, message, error)
    }

    // MARK: - 1. Request Permission
    @objc
    public func requestPermission(_ accessLevel: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        let level: PHAccessLevel = (accessLevel == "addOnly") ? .addOnly : .readWrite
        
        PHPhotoLibrary.requestAuthorization(for: level) { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized: resolve("authorized")
                case .limited: resolve("limited")
                case .denied: resolve("denied")
                case .restricted: resolve("restricted")
                case .notDetermined: resolve("notDetermined")
                @unknown default: resolve("denied")
                }
            }
        }
    }

    // MARK: - 2. Pick Media
    @objc
    public func pickMedia(_ options: NSDictionary, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                reject("E_MODULE_DESTROYED", "Module instance was deallocated", nil)
                return
            }

            if self.pendingPromiseResolve != nil {
                self.rejectPromise(code: "E_CANCELLED", message: "A new picker session was started.")
            }

            self.pendingPromiseResolve = resolve
            self.pendingPromiseReject = reject

            guard let topViewController = self.getTopViewController() else {
                self.rejectPromise(code: "E_NO_VIEW_CONTROLLER", message: "Could not find a valid top UIViewController.")
                return
            }

            let selectionLimit = options["selectionLimit"] as? Int ?? 1
            let filterType = options["filter"] as? String ?? "any"
            let preferredAssetRepresentationMode = options["preferredAssetRepresentationMode"] as? String ?? "automatic"

            var config = PHPickerConfiguration(photoLibrary: .shared())
            config.selectionLimit = max(0, selectionLimit)
            config.filter = self.parseFilter(filterType)

            switch preferredAssetRepresentationMode {
            case "current": config.preferredAssetRepresentationMode = .current
            case "compatible": config.preferredAssetRepresentationMode = .compatible
            default: config.preferredAssetRepresentationMode = .automatic
            }

            let picker = PHPickerViewController(configuration: config)
            picker.delegate = self
            
            if topViewController.isBeingDismissed || topViewController.isBeingPresented {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    topViewController.present(picker, animated: true, completion: nil)
                }
            } else {
                topViewController.present(picker, animated: true, completion: nil)
            }
        }
    }

    // MARK: - Helpers
    private func parseFilter(_ filterStr: String) -> PHPickerFilter {
        switch filterStr {
        case "images": return .images
        case "videos": return .videos
        case "livePhotos": return .livePhotos
        case "depthEffectPhotos":
            if #available(iOS 16.0, *) { return .depthEffectPhotos }
            return .images
        case "bursts":
            if #available(iOS 16.0, *) { return .bursts }
            return .images
        case "cinematicVideos":
            if #available(iOS 16.0, *) { return .cinematicVideos }
            return .videos
        case "slomoVideos":
            if #available(iOS 15.0, *) { return .slomoVideos }
            return .videos
        case "timelapseVideos":
            if #available(iOS 15.0, *) { return .timelapseVideos }
            return .videos
        case "screenRecordings":
            if #available(iOS 15.0, *) { return .screenRecordings }
            return .videos
        case "any": return .any(of: [.images, .videos])
        default: return .images
        }
    }

    private func getTopViewController(base: UIViewController? = nil) -> UIViewController? {
        let baseVC = base ?? {
            if #available(iOS 15.0, *) {
                let windowScene = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .first(where: { $0.activationState == .foregroundActive })
                
                let window = windowScene?.windows.first(where: { $0.isKeyWindow }) ?? windowScene?.windows.first
                return window?.rootViewController
            } else if #available(iOS 13.0, *) {
                return UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap { $0.windows }
                    .first(where: { $0.isKeyWindow })?
                    .rootViewController
            } else {
                return UIApplication.shared.keyWindow?.rootViewController
            }
        }()

        if let nav = baseVC as? UINavigationController {
            return getTopViewController(base: nav.visibleViewController)
        }
        if let tab = baseVC as? UITabBarController, let selected = tab.selectedViewController {
            return getTopViewController(base: selected)
        }
        if let presented = baseVC?.presentedViewController {
            return getTopViewController(base: presented)
        }
        return baseVC
    }
}

// MARK: - PHPickerViewControllerDelegate
extension PhotoPickerTurboModule: PHPickerViewControllerDelegate {
    
    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        DispatchQueue.main.async {
            picker.dismiss(animated: true, completion: nil)
        }

        guard !results.isEmpty else {
            self.resolvePromise([])
            return
        }

        Task(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            // Menjaga presisi urutan hasil sesuai urutan seleksi user
            let count = results.count
            var orderedResults = Array<[String: Any]?>(repeating: nil, count: count)
            
            await withTaskGroup(of: (Int, [String: Any]?).self) { group in
                for (index, result) in results.enumerated() {
                    group.addTask {
                        let item = await self.processPickerResult(result)
                        return (index, item)
                    }
                }

                for await (index, item) in group {
                    orderedResults[index] = item
                }
            }

            let processedItems = orderedResults.compactMap { $0 }

            DispatchQueue.main.async {
                self.resolvePromise(processedItems)
            }
        }
    }

    private func processPickerResult(_ result: PHPickerResult) async -> [String: Any]? {
        let provider = result.itemProvider
        let assetId = result.assetIdentifier

        // Ambil identifier type paling presisi dari ketersediaan provider
        let typeIdentifier: String
        let isVideo: Bool

        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            typeIdentifier = UTType.movie.identifier
            isVideo = true
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            typeIdentifier = UTType.image.identifier
            isVideo = false
        } else if let firstType = provider.registeredTypeIdentifiers.first {
            typeIdentifier = firstType
            isVideo = false
        } else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { srcUrl, error in
                guard let srcUrl = srcUrl, error == nil else {
                    continuation.resume(returning: nil)
                    return
                }

                let tempDir = FileManager.default.temporaryDirectory
                let fileName = "\(UUID().uuidString)_\(srcUrl.lastPathComponent)"
                let destUrl = tempDir.appendingPathComponent(fileName)

                do {
                    // Gunakan moveItem atau fast-copy fallback untuk efisiensi Disk I/O
                    if FileManager.default.fileExists(atPath: destUrl.path) {
                        try FileManager.default.removeItem(at: destUrl)
                    }
                    try FileManager.default.moveItem(at: srcUrl, to: destUrl)
                } catch {
                    // Fallback ke copy jika moveItem antar-volume dibatasi OS
                    do {
                        try FileManager.default.copyItem(at: srcUrl, to: destUrl)
                    } catch {
                        continuation.resume(returning: nil)
                        return
                    }
                }

                if isVideo {
                    let asset = AVURLAsset(url: destUrl)
                    let duration = CMTimeGetSeconds(asset.duration)

                    var meta: [String: Any] = [
                        "uri": destUrl.absoluteString,
                        "type": "video",
                        "name": destUrl.lastPathComponent,
                        "duration": duration.isNaN ? 0 : duration
                    ]
                    if let id = assetId { meta["assetId"] = id }
                    continuation.resume(returning: meta)
                } else {
                    var width: CGFloat = 0
                    var height: CGFloat = 0
                    if let imageSource = CGImageSourceCreateWithURL(destUrl as CFURL, nil),
                       let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {
                        width = properties[kCGImagePropertyPixelWidth] as? CGFloat ?? 0
                        height = properties[kCGImagePropertyPixelHeight] as? CGFloat ?? 0
                    }

                    var meta: [String: Any] = [
                        "uri": destUrl.absoluteString,
                        "type": "image",
                        "name": destUrl.lastPathComponent,
                        "width": width,
                        "height": height
                    ]
                    if let id = assetId { meta["assetId"] = id }
                    continuation.resume(returning: meta)
                }
            }
        }
    }
}