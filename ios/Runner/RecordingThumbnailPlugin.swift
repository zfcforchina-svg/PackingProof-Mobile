import AVFoundation
import CryptoKit
import Flutter
import UIKit

/// iOS equivalent of Android's RecordingThumbnailPlugin.
/// Uses AVAssetImageGenerator for efficient thumbnail extraction.
class RecordingThumbnailPlugin: NSObject {
    private let channel: FlutterMethodChannel
    private let queue = DispatchQueue(label: "packingproof.thumbnail", qos: .utility)

    init(messenger: FlutterBinaryMessenger) {
        self.channel = FlutterMethodChannel(
            name: "app.packingproof.mobile/recording_thumbnail",
            binaryMessenger: messenger
        )
        super.init()
        channel.setMethodCallHandler(handleMethodCall)
    }

    private func handleMethodCall(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard call.method == "generate" else {
            result(FlutterMethodNotImplemented)
            return
        }
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String
        else {
            result(FlutterError(code: "thumbnail_failed", message: "无法生成录像预览图", details: nil))
            return
        }
        queue.async { [weak self] in
            self?.generate(path: path, result: result)
        }
    }

    private func generate(path: String, result: @escaping FlutterResult) {
        let sourceURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            DispatchQueue.main.async {
                result(FlutterError(code: "thumbnail_failed", message: "录像文件不存在", details: nil))
            }
            return
        }

        // Cache key based on path + mtime + size
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = attrs?[.modificationDate] as? Date ?? Date()
        let size = attrs?[.size] as? Int64 ?? 0
        let raw = "v3-50|\(path)|\(Int64(modified.timeIntervalSince1970 * 1000))|\(size)"
        let key = SHA256.hash(data: Data(raw.utf8)).compactMap { String(format: "%02x", $0) }.joined()

        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("recording_thumbnails")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let targetURL = cacheDir.appendingPathComponent("\(key).jpg")

        // Return cached if exists
        if let cachedSize = try? targetURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, cachedSize > 0 {
            DispatchQueue.main.async { result(targetURL.path) }
            return
        }

        let asset = AVAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let duration = asset.duration
        let durationMs = CMTimeGetSeconds(duration) * 1000
        let frameMs = durationMs > 0 ? min(durationMs / 2, durationMs - 1) : 0
        let time = CMTime(value: Int64(frameMs), timescale: 1000)

        do {
            let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
            let image = UIImage(cgImage: cgImage)
            guard let data = image.jpegData(compressionQuality: 0.78) else {
                throw NSError(domain: "thumbnail", code: 1)
            }
            try data.write(to: targetURL, options: .atomic)
            DispatchQueue.main.async { result(targetURL.path) }
        } catch {
            DispatchQueue.main.async {
                result(FlutterError(code: "thumbnail_failed", message: "无法读取录像画面", details: nil))
            }
        }
    }

    func dispose() {
        channel.setMethodCallHandler(nil)
    }
}
