import AVFoundation
import Flutter
import UIKit

/// iOS equivalent of Android's VideoWatermarkPlugin.
/// Uses AVVideoComposition + CoreAnimation overlay for timestamp/tracking-number watermark.
class VideoWatermarkPlugin: NSObject {
    private let channel: FlutterMethodChannel
    private var exportSession: AVAssetExportSession?
    private var pendingResult: FlutterResult?
    private var pendingOutput: URL?

    init(messenger: FlutterBinaryMessenger) {
        self.channel = FlutterMethodChannel(
            name: "app.packingproof.mobile/video_watermark",
            binaryMessenger: messenger
        )
        super.init()
        channel.setMethodCallHandler(handleMethodCall)
    }

    private func handleMethodCall(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard call.method == "apply" else {
            result(FlutterMethodNotImplemented)
            return
        }
        guard let args = call.arguments as? [String: Any] else {
            result(FlutterError(code: "invalid_watermark", message: "录像水印参数无效", details: nil))
            return
        }
        applyWatermark(args, result: result)
    }

    private func applyWatermark(_ args: [String: Any], result: @escaping FlutterResult) {
        guard pendingResult == nil else {
            result(FlutterError(code: "watermark_busy", message: "正在保存上一段录像", details: nil))
            return
        }
        guard let inputPath = args["inputPath"] as? String,
              let outputPath = args["outputPath"] as? String,
              let startedAtMs = args["startedAtMs"] as? Int64
        else {
            result(FlutterError(code: "invalid_watermark", message: "录像水印参数无效", details: nil))
            return
        }

        let trackingNumber = args["trackingNumber"] as? String ?? ""
        let inputURL = URL(fileURLWithPath: inputPath)
        let outputURL = URL(fileURLWithPath: outputPath)

        guard FileManager.default.fileExists(atPath: inputPath) else {
            result(FlutterError(code: "missing_input", message: "录像文件不存在", details: nil))
            return
        }
        try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: outputURL)

        let asset = AVAsset(url: inputURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            result(FlutterError(code: "watermark_failed", message: "无法读取视频轨道", details: nil))
            return
        }

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            result(FlutterError(code: "watermark_failed", message: "无法创建合成轨道", details: nil))
            return
        }
        try? compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: videoTrack, at: .zero)
        if let audioTrack = asset.tracks(withMediaType: .audio).first,
           let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? compAudio.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: audioTrack, at: .zero)
        }

        // Watermark layer
        let videoSize = videoTrack.naturalSize
        let watermarkLayer = createWatermarkLayer(
            videoSize: videoSize,
            startedAtMs: startedAtMs,
            trackingNumber: trackingNumber
        )
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: videoSize)

        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: videoSize)
        parentLayer.addSublayer(videoLayer)
        parentLayer.addSublayer(watermarkLayer)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = videoSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            result(FlutterError(code: "watermark_failed", message: "无法创建导出会话", details: nil))
            return
        }
        session.videoComposition = videoComposition
        session.outputURL = outputURL
        session.outputFileType = .mp4

        pendingResult = result
        pendingOutput = outputURL
        exportSession = session

        session.exportAsynchronously { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                let r = self.pendingResult
                self.pendingResult = nil
                self.pendingOutput = nil
                self.exportSession = nil
                switch session.status {
                case .completed:
                    r?(outputPath)
                default:
                    try? FileManager.default.removeItem(at: outputURL)
                    r?(FlutterError(code: "watermark_failed",
                                    message: session.error?.localizedDescription ?? "录像水印生成失败",
                                    details: nil))
                }
            }
        }
    }

    private func createWatermarkLayer(videoSize: CGSize, startedAtMs: Int64, trackingNumber: String) -> CATextLayer {
        let layer = CATextLayer()
        let fontSize: CGFloat = max(28, min(56, videoSize.height * 0.026))
        layer.fontSize = fontSize
        layer.foregroundColor = UIColor.white.cgColor
        layer.backgroundColor = UIColor.black.withAlphaComponent(0.45).cgColor
        layer.alignmentMode = .right
        layer.contentsScale = UIScreen.main.scale

        let startedAt = Date(timeIntervalSince1970: TimeInterval(startedAtMs) / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        // Update layer text at compose time via CoreAnimation
        let text = formatter.string(from: startedAt) + (trackingNumber.isEmpty ? "" : "\nOrder:\(trackingNumber)")
        layer.string = text

        let textSize = (text as NSString).size(withAttributes: [.font: UIFont.boldSystemFont(ofSize: fontSize)])
        let padding: CGFloat = 12
        layer.frame = CGRect(
            x: videoSize.width - textSize.width - padding * 2,
            y: videoSize.height - textSize.height - padding * 2,
            width: textSize.width + padding * 2,
            height: textSize.height + padding * 2
        )
        layer.cornerRadius = 6
        layer.masksToBounds = true

        return layer
    }

    func dispose() {
        exportSession?.cancelExport()
        exportSession = nil
        pendingOutput.map { try? FileManager.default.removeItem(at: $0) }
        pendingOutput = nil
        pendingResult?(FlutterError(code: "watermark_cancelled", message: "录像水印生成已取消", details: nil))
        pendingResult = nil
        channel.setMethodCallHandler(nil)
    }
}
