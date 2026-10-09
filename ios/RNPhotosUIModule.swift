
import Foundation
import Photos
import PhotosUI
import React

@objc(RNPhotosUIModuleSwift)
public class RNPhotosUIModuleSwift: NSObject, PHPickerViewControllerDelegate {
    
    // MARK: - Properties
    
    private var pendingPromiseResolve: RCTPromiseResolveBlock?
    private var pendingPromiseReject: RCTPromiseRejectBlock?
    
    // Serial queue untuk proteksi akses state thread-safe
    private let stateQueue = DispatchQueue(label: "com.rnphotosui.statequeue", qos: .userInitiated)
    
    // Thread-safe helper untuk reset state promise setelah selesai
    private func resetPromise() {
        stateQueue.async {
            self.pendingPromiseResolve = nil
            self.pendingPromiseReject = nil
        }
    }

    // MARK: - Bridge / Setup Setup
    
    @objc public static func requiresMainQueueSetup() -> Bool {
        return false
    }

    // MARK: - Permission Handlers
    
    @objc public func getPermissionStatus(_ accessLevelStr: String,
                                          resolve: @escaping RCTPromiseResolveBlock,
                                          reject: @escaping RCTPromiseRejectBlock) {
        let level = parseAccessLevel(accessLevelStr)
        let status = PHPhotoLibrary.authorizationStatus(for: level)
        resolve(mapPermissionStatus(status))
    }

    @objc public func requestPermission(_ accessLevelStr: String,
                                         resolve: @escaping RCTPromiseResolveBlock,
                                         reject: @escaping RCTPromiseRejectBlock) {
        let level = parseAccessLevel(accessLevelStr)
        
        PHPhotoLibrary.requestAuthorization(for: level) { status in
            DispatchQueue.main.async {
                resolve(self.mapPermissionStatus(status))
            }
        }
    }

    // MARK: - Present Picker
    
    @objc public func presentPicker(_ options: NSDictionary,
                                    resolve: @escaping RCTPromiseResolveBlock,
                                    reject: @escaping RCTPromiseRejectBlock) {
        
        // Proteksi Concurrent Presenting
        var isAlreadyPending = false
        stateQueue.sync {
            if self.pendingPromiseResolve != nil {
                isAlreadyPending = true
            } else {
                self.pendingPromiseResolve = resolve
                self.pendingPromiseReject = reject
            }
        }
        
        if isAlreadyPending {
            reject("E_PICKER_BUSY", "Pickerviewcontroller sedang aktif dipanggil.", nil)
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            guard let presentingVC = RCTPresentedViewController() else {
                self.rejectAndCleanup(code: "E_NO_VIEW_CONTROLLER", message: "Tidak dapat menemukan Top View Controller untuk menampilkan picker.")
                return
            }

            var config = PHPickerConfiguration(photoLibrary: .shared())
            
            // 1. Config selection limit
            if let limit = options["selectionLimit"] as? Int {
                config.selectionLimit = max(0, limit)
            } else {
                config.selectionLimit = 1 // Default ke single select
            }

            // 2. Config filter types
            if let filterStr = options["filter"] as? String {
                config.filter = self.parsePickerFilter(filterStr)
            }

            // 3. Config Preferred Asset Representation Mode
            if let representationStr = options["preferredAssetRepresentationMode"] as? String {
                config.preferredAssetRepresentationMode = self.parseRepresentationMode(representationStr)
            }

            let picker = PHPickerViewController(configuration: config)
            picker.delegate = self
            
            // Mencegah memory leak / retained presentation jika dikaitkan secara fleksibel
            presentingVC.present(picker, animated: true, completion: nil)
        }
    }

    // MARK: - PHPickerViewControllerDelegate
    
    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true, completion: nil)
        
        guard !results.isEmpty else {
            resolveAndCleanup(result: [])
            return
        }

        // Jalankan pengolahan file di Background Concurrent Queue agar UI Thread tetap 60fps+
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let group = DispatchGroup()
            let lockQueue = DispatchQueue(label: "com.rnphotosui.resultslock")
            var outputResults: [[String: Any]] = []

            for result in results {
                group.enter()
                self.processPickerResult(result) { itemDict in
                    if let itemDict = itemDict {
                        lockQueue.async {
                            outputResults.append(itemDict)
                            group.leave()
                        }
                    } else {
                        group.leave()
                    }
                }
            }

            // Tunggu semua proses pembacaan file selesai
            group.notify(queue: .main) {
                self.resolveAndCleanup(result: outputResults)
            }
        }
    }

    // MARK: - File Processing & Memory Safety
    
    private func processPickerResult(_ result: PHPickerResult, completion: @escaping ([String: Any]?) -> Void) {
        let provider = result.itemProvider
        
        // Tentukan MediaType
        let mediaType: String
        let typeIdentifier: String
        
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            mediaType = "video"
            typeIdentifier = UTType.movie.identifier
        } else if provider.hasItemConformingToTypeIdentifier(UTType.livePhoto.identifier) {
            mediaType = "livePhoto"
            typeIdentifier = UTType.livePhoto.identifier
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            mediaType = "image"
            typeIdentifier = UTType.image.identifier
        } else {
            completion(nil)
            return
        }

        // Menggunakan loadFileRepresentation untuk menyalin file langsung tanpa memasukkan raw data ke memory
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] (url, error) in
            guard let self = self, let sourceURL = url, error == nil else {
                completion(nil)
                return
            }

            // Pindahkan file ke directory Caches sementara agar aman dari auto-deletion Sandbox system
            let tempFilename = UUID().uuidString + "_" + sourceURL.lastPathComponent
            let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(tempFilename)

            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

                var item: [String: Any] = [
                    "uri": destinationURL.absoluteString,
                    "mediaType": mediaType,
                    "fileName": sourceURL.lastPathComponent,
                    "mimeType": self.getMimeType(for: destinationURL)
                ]

                // Dapatkan ukuran file (fileSize)
                if let resourceValues = try? destinationURL.resourceValues(forKeys: [.fileSizeKey]),
                   let fileSize = resourceValues.fileSize {
                    item["fileSize"] = fileSize
                }

                // Dapatkan Dimensi (Width & Height) tanpa memuat seluruh gambar ke RAM
                if mediaType == "image" || mediaType == "livePhoto" {
                    if let imageSource = CGImageSourceCreateWithURL(destinationURL as CFURL, nil),
                       let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {
                        item["width"] = properties[kCGImagePropertyPixelWidth] as? Int
                        item["height"] = properties[kCGImagePropertyPixelHeight] as? Int
                    }
                } else if mediaType == "video" {
                    let asset = AVURLAsset(url: destinationURL)
                    if let track = asset.tracks(withMediaType: .video).first {
                        let size = track.naturalSize.applying(track.preferredTransform)
                        item["width"] = Int(abs(size.width))
                        item["height"] = Int(abs(size.height))
                    }
                }

                completion(item)
            } catch {
                completion(nil)
            }
        }
    }

    // MARK: - Promise Safe Resolvers
    
    private func resolveAndCleanup(result: Any) {
        stateQueue.sync {
            self.pendingPromiseResolve?(result)
            self.pendingPromiseResolve = nil
            self.pendingPromiseReject = nil
        }
    }

    private func rejectAndCleanup(code: String, message: String) {
        stateQueue.sync {
            self.pendingPromiseReject?(code, message, nil)
            self.pendingPromiseResolve = nil
            self.pendingPromiseReject = nil
        }
    }

    // MARK: - Utility & Helper Methods

    private func parseAccessLevel(_ level: String) -> PHAccessLevel {
        switch level {
        case "addOnly":
            return .addOnly
        default:
            return .readWrite
        }
    }

    private func mapPermissionStatus(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "authorized"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .limited:
            return "limited"
        case .notDetermined:
            fallthrough
        @unknown default:
            return "notDetermined"
        }
    }

    private func parsePickerFilter(_ filter: String) -> PHPickerFilter {
        switch filter {
        case "images":
            return .images
        case "videos":
            return .videos
        case "livePhotos":
            return .livePhotos
        default:
            return PHPickerFilter.any(of: [.images, .videos, .livePhotos])
        }
    }

    private func parseRepresentationMode(_ mode: String) -> PHPickerConfiguration.AssetRepresentationMode {
        switch mode {
        case "current":
            return .current
        case "compatible":
            return .compatible
        default:
            return .automatic
        }
    }

    private func getMimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension) {
            return type.preferredMIMEType ?? "application/octet-stream"
        }
        return "application/octet-stream"
    }
}
