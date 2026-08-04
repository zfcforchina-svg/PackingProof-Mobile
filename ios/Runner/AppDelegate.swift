import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
    private var continuousCameraPlugin: ContinuousCameraPlugin?
    private var lanBackupPlugin: LanBackupPlugin?
    private var videoExportPlugin: VideoExportPlugin?
    private var recordingThumbnailPlugin: RecordingThumbnailPlugin?
    private var videoWatermarkPlugin: VideoWatermarkPlugin?
    private var orderInfoReceiverPlugin: OrderInfoReceiverPlugin?
    private var maxVolumeChannel: FlutterMethodChannel?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Configure audio session for recording
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])
        try? audioSession.setActive(true)

        GeneratedPluginRegistrant.register(with: self)

        guard let controller = window?.rootViewController as? FlutterViewController else {
            return super.application(application, didFinishLaunchingWithOptions: launchOptions)
        }

        let messenger = controller.binaryMessenger
        let registry = controller.engine?.textures ?? controller.textureRegistry

        // Register all custom iOS plugins
        continuousCameraPlugin = ContinuousCameraPlugin(registry: registry, messenger: messenger)
        lanBackupPlugin = LanBackupPlugin(messenger: messenger)
        videoExportPlugin = VideoExportPlugin(messenger: messenger)
        recordingThumbnailPlugin = RecordingThumbnailPlugin(messenger: messenger)
        videoWatermarkPlugin = VideoWatermarkPlugin(messenger: messenger)
        orderInfoReceiverPlugin = OrderInfoReceiverPlugin(messenger: messenger)

        maxVolumeChannel = FlutterMethodChannel(
            name: "app.packingproof.mobile/system_volume",
            binaryMessenger: messenger
        )
        maxVolumeChannel?.setMethodCallHandler { call, result in
            switch call.method {
            case "beginSession", "boost", "endSession", "disable":
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    override func applicationWillTerminate(_ application: UIApplication) {
        continuousCameraPlugin?.disposeCamera()
        lanBackupPlugin?.dispose()
        videoExportPlugin?.dispose()
        recordingThumbnailPlugin?.dispose()
        videoWatermarkPlugin?.dispose()
        orderInfoReceiverPlugin?.dispose()
        maxVolumeChannel?.setMethodCallHandler(nil)
        super.applicationWillTerminate(application)
    }
}
