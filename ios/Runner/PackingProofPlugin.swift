import Flutter
import UIKit

/// Central plugin registrar for all PackingProof iOS native plugins.
/// Registered automatically by GeneratedPluginRegistrant.
public class PackingProofPlugin: NSObject, FlutterPlugin {
    private var continuousCameraPlugin: ContinuousCameraPlugin?
    private var lanBackupPlugin: LanBackupPlugin?
    private var videoExportPlugin: VideoExportPlugin?
    private var recordingThumbnailPlugin: RecordingThumbnailPlugin?
    private var videoWatermarkPlugin: VideoWatermarkPlugin?
    private var orderInfoReceiverPlugin: OrderInfoReceiverPlugin?
    private var maxVolumeChannel: FlutterMethodChannel?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = PackingProofPlugin()
        let messenger = registrar.messenger()
        let textures = registrar.textures()

        instance.continuousCameraPlugin = ContinuousCameraPlugin(
            registry: textures,
            messenger: messenger
        )
        instance.lanBackupPlugin = LanBackupPlugin(messenger: messenger)
        instance.videoExportPlugin = VideoExportPlugin(messenger: messenger)
        instance.recordingThumbnailPlugin = RecordingThumbnailPlugin(messenger: messenger)
        instance.videoWatermarkPlugin = VideoWatermarkPlugin(messenger: messenger)
        instance.orderInfoReceiverPlugin = OrderInfoReceiverPlugin(messenger: messenger)

        instance.maxVolumeChannel = FlutterMethodChannel(
            name: "app.packingproof.mobile/system_volume",
            binaryMessenger: messenger
        )
        instance.maxVolumeChannel?.setMethodCallHandler { call, result in
            switch call.method {
            case "beginSession", "boost", "endSession", "disable":
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    public func detachFromEngine(for registrar: any FlutterPluginRegistrar) {
        continuousCameraPlugin?.disposeCamera()
        lanBackupPlugin?.dispose()
        videoExportPlugin?.dispose()
        recordingThumbnailPlugin?.dispose()
        videoWatermarkPlugin?.dispose()
        orderInfoReceiverPlugin?.dispose()
        maxVolumeChannel?.setMethodCallHandler(nil)
    }
}
