import AVFoundation
import Flutter
import UIKit

/// iOS equivalent of Android's VideoExportPlugin.
/// Uses AVAssetExportSession for efficient hardware-accelerated trimming.
class VideoExportPlugin: NSObject {
    private let channel: FlutterMethodChannel
    private var exportSession: AVAssetExportSession?
    private var pendingResult: FlutterResult?

    init(messenger: FlutterBinaryMessenger) {
        self.channel = FlutterMethodChannel(
            name: "app.packingproof.mobile/video_export",
            binaryMessenger: messenger
        )
        super.init()
        channel.setMethodCallHandler(handleMethodCall)
    }

    private func handleMethodCall(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        switch call.method {
        case "export":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "invalid_export", message: "分享视频参数无效", details: nil))
                return
            }
            export(args, result: result)
        case "progress":
            result(Double(exportSession?.progress ?? 0) * 100)
        case "cancel":
            exportSession?.cancelExport()
            exportSession = nil
            pendingResult?(FlutterError(code: "export_cancelled", message: "已取消生成分享视频", details: nil))
            pendingResult = nil
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func export(_ args: [String: Any], result: @escaping FlutterResult) {
        guard pendingResult == nil else {
            result(FlutterError(code: "export_busy", message: "已有分享视频正在生成", details: nil))
            return
        }
        guard let inputPath = args["inputPath"] as? String,
              let outputPath = args["outputPath"] as? String,
              let startMs = args["startMs"] as? Int64,
              let endMs = args["endMs"] as? Int64,
              startMs >= 0, endMs > startMs
        else {
            result(FlutterError(code: "invalid_export", message: "分享视频参数无效", details: nil))
            return
        }

        let inputURL = URL(fileURLWithPath: inputPath)
        let outputURL = URL(fileURLWithPath: outputPath)
        try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: outputURL)

        let asset = AVAsset(url: inputURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            result(FlutterError(code: "export_failed", message: "无法创建导出会话", details: nil))
            return
        }

        let startTime = CMTime(value: startMs, timescale: 1000)
        let endTime = CMTime(value: endMs, timescale: 1000)
        session.timeRange = CMTimeRange(start: startTime, end: endTime)
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        pendingResult = result
        exportSession = session

        session.exportAsynchronously { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                let r = self.pendingResult
                self.pendingResult = nil
                self.exportSession = nil
                switch session.status {
                case .completed:
                    r?(outputPath)
                case .cancelled:
                    r?(FlutterError(code: "export_cancelled", message: "已取消生成分享视频", details: nil))
                default:
                    r?(FlutterError(code: "export_failed",
                                    message: session.error?.localizedDescription ?? "分享视频生成失败",
                                    details: nil))
                }
            }
        }
    }

    func dispose() {
        exportSession?.cancelExport()
        exportSession = nil
        pendingResult?(FlutterError(code: "export_cancelled", message: "已取消生成分享视频", details: nil))
        pendingResult = nil
        channel.setMethodCallHandler(nil)
    }
}
