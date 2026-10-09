import Foundation
import PhotosUI
import React

@objc(PhotoPickerTurboModule)
public class PhotoPickerTurboModule: NSObject {
    
    private var pendingPromiseResolve: RCTPromiseResolveBlock?
    private var pendingPromiseReject: RCTPromiseRejectBlock?

    // Safe Helper for Resolving Promise once
    private func resolvePromise(_ value: Any?) {
        guard let resolve = pendingPromiseResolve else { return }
        self.pendingPromiseResolve = nil
        self.pendingPromiseReject = nil
        resolve(value)
    }

    // Safe Helper for Rejecting Promise once
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
                case .authorized:
                    resolve("authorized")
                case .limited:
                    resolve("limited")
                case .denied:
                    resolve("denied")
                case .restricted:
                    resolve("restricted")
                case .notDetermined:
                    resolve("notDetermined")
                @unknown default:
                    resolve("denied")
                }
            }
        }
    }

    // MARK: - 2. Pick Media (PhotosUI)
    @objc
    public func pickMedia(_ options: NSDictionary, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                reject("E_MODULE_DESTROYED", "Module instance was deallocated", nil)
                return
            }

            // High Safety: Safeguard existing unfulfilled promise
            if self.pendingPromiseResolve != nil {
                self.rejectPromise(code: "E_CANCELLED", message: "A new picker session was started.")
            }

            self.pendingPromiseResolve = resolve
            self.pendingPromiseReject = reject

            guard let topViewController = self.getTopViewController() else {
                self.rejectPromise(code: "E_NO_VIEW_CONTROLLER", message: "Could not find a valid top UIViewController.")
                return
            }

            // Parse Options Safely
            let selectionLimit = options["selectionLimit"] as? Int ?? 1
            let filterType = options["filter"] as? String ?? "any"
            let preferredAssetRepresentationMode = options["preferredAssetRepresentationMode"] as? String ?? "automatic"

            // PHPicker Configuration
            var config = PHPickerConfiguration(photoLibrary: .shared())
            config.selectionLimit = max(0, selectionLimit)
            config.filter = self.parseFilter(filterType)

            switch preferredAssetRepresentationMode {
            case "current":
                config.preferredAssetRepresentationMode = .current
            case "compatible":
                config.preferredAssetRepresentationMode = .compatible
            default:
                config.preferredAssetRepresentationMode = .automatic
            }

            let picker = PHPickerViewController(configuration: config)
            picker.delegate = self
            
            // Anti-crash presentation check
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
        case "images":
            return .images
        case "videos":
            return .videos
        case "livePhotos":
            return .livePhotos
        case "depthEffectPhotos":
            if #available(iOS 15.0, *) {
                return .depthEffectPhotos
            }
            return .images
        case "bursts":
            if #available(iOS 16.0, *) {
                return .bursts
            }
            return .images
        case "cinematicVideos":
            if #available(iOS 16.0, *) {
                return .cinematicVideos
            }
            return .videos
        case "slomoVideos":
            if #available(iOS 15.0, *) {
                return .slomoVideos
            }
            return .videos
        case "timelapseVideos":
            if #available(iOS 15.0, *) {
                return .timelapseVideos
            }
            return .videos
        case "screenRecordings":
            if #available(iOS 15.0, *) {
                return .screenRecordings
            }
            return .videos
        case "any":
            return .any(of: [.images, .videos])
        default:
            return .images
        }
    }

    private func getTopViewController(base: UIViewController? = nil) -> UIViewController? {
        let baseVC = base ?? {
            if #available(iOS 13.0, *) {
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
        // Must dismiss picker UI on main thread immediately
        DispatchQueue.main.async {
            picker.dismiss(animated: true, completion: nil)
        }

        guard !results.isEmpty else {
            // User cancelled selection
            self.resolvePromise([])
            return
        }

        // Process asset loading concurrently off the main thread for high performance
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            var processedItems: [[String: Any]] = []
            
            // Using TaskGroup for memory-efficient concurrent item processing
            await withTaskGroup(of: [String: Any]?.self) { group in
                for result in results {
                    group.addTask {
                        return await self.processPickerResult(result)
                    }
                }

                for await item in group {
                    if let item = item {
                        processedItems.append(item)
                    }
                }
            }

            DispatchQueue.main.async {
                self.resolvePromise(processedItems)
            }
        }
    }

    // High performance item extractor with automatic disk temp writing (prevents RAM spikes)
    private func processPickerResult(_ result: PHPickerResult) async -> [String: Any]? {
        let provider = result.itemProvider
        let assetId = result.assetIdentifier

        // 1. Video Processing
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            return await withCheckedContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                    guard let srcUrl = url, error == nil else {
                        continuation.resume(returning: nil)
                        return
                    }

                    // Copy to persistent temp directory safely before provider purges original file
                    let tempDir = FileManager.default.temporaryDirectory
                    let destUrl = tempDir.appendingPathComponent(UUID().uuidString + "_" + srcUrl.lastPathComponent)
                    
                    do {
                        try FileManager.default.copyItem(at: srcUrl, to: destUrl)
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
                    } catch {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }

        // 2. Image Processing
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return await withCheckedContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
                    guard let srcUrl = url, error == nil else {
                        continuation.resume(returning: nil)
                        return
                    }

                    let tempDir = FileManager.default.temporaryDirectory
                    let destUrl = tempDir.appendingPathComponent(UUID().uuidString + "_" + srcUrl.lastPathComponent)

                    do {
                        try FileManager.default.copyItem(at: srcUrl, to: destUrl)
                        
                        // Extract Dimensions securely without loading image pixels into RAM
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
                    } catch {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }

        return nil
    }
}
