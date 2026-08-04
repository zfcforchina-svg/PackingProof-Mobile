import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Configure audio session for recording
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])
        try? audioSession.setActive(true)

        GeneratedPluginRegistrant.register(with: self)

        // Register PackingProof custom plugins when the first engine is created.
        // FlutterAppDelegate automatically notifies us via the plugin registry.
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}

// MARK: - FlutterPluginRegistry support for custom plugins

extension AppDelegate {
    /// Called by Flutter when each engine is created. Register our custom plugins here.
    override func registrar(forPlugin pluginKey: String) -> FlutterPluginRegistrar? {
        let registrar = super.registrar(forPlugin: pluginKey)
        if let registrar = registrar, pluginKey == "packing_proof_plugins" {
            // PackingProof plugins are registered once via the FlutterViewController flow.
            // The actual registration happens via +registerWithRegistrar: on PackingProofPlugin.
        }
        return registrar
    }
}
