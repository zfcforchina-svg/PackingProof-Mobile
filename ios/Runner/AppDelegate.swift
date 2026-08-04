import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
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
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

        let messenger = engineBridge.binaryMessenger
        let registry = engineBridge.textures

        // Camera plugin (uses texture registry)
        continuousCameraPlugin = ContinuousCameraPlugin(
            registry: registry,
            messenger: messenger
        )

        // LAN backup plugin
        lanBackupPlugin = LanBackupPlugin(messenger: messenger)

        // Video export plugin
        videoExportPlugin = VideoExportPlugin(messenger: messenger)

        // Thumbnail plugin
        recordingThumbnailPlugin = RecordingThumbnailPlugin(messenger: messenger)

        // Watermark plugin
        videoWatermarkPlugin = VideoWatermarkPlugin(messenger: messenger)

        // Order info receiver plugin
        orderInfoReceiverPlugin = OrderInfoReceiverPlugin(messenger: messenger)

        // Max volume control channel
        maxVolumeChannel = FlutterMethodChannel(
            name: "app.packingproof.mobile/system_volume",
            binaryMessenger: messenger
        )
        maxVolumeChannel?.setMethodCallHandler { [weak self] call, result in
            switch call.method {
            case "beginSession", "boost":
                // iOS volume control is limited by design; use MPVolumeView if needed
                result(nil)
            case "endSession", "disable":
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    override func applicationWillResignActive(_ application: UIApplication) {
        orderInfoReceiverPlugin?.onHostBackground()
        super.applicationWillResignActive(application)
    }

    override func applicationDidBecomeActive(_ application: UIApplication) {
        orderInfoReceiverPlugin?.onHostForeground()
        super.applicationDidBecomeActive(application)
    }

    override func applicationWillTerminate(_ application: UIApplication) {
        continuousCameraPlugin?.disposeCamera()
        continuousCameraPlugin = nil
        lanBackupPlugin?.dispose()
        lanBackupPlugin = nil
        videoExportPlugin?.dispose()
        videoExportPlugin = nil
        recordingThumbnailPlugin?.dispose()
        recordingThumbnailPlugin = nil
        videoWatermarkPlugin?.dispose()
        videoWatermarkPlugin = nil
        orderInfoReceiverPlugin?.dispose()
        orderInfoReceiverPlugin = nil
        maxVolumeChannel?.setMethodCallHandler(nil)
        maxVolumeChannel = nil
    }
}
