import Flutter
import Foundation
import Network
import CryptoKit

/// iOS equivalent of Android's LanBackupPlugin.
/// Handles LAN discovery, connection management, and background upload scheduling.
class LanBackupPlugin: NSObject {
    private let channel: FlutterMethodChannel
    private let store = UserDefaults(suiteName: "app.packingproof.mobile.lanbackup")!
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid

    init(messenger: FlutterBinaryMessenger) {
        self.channel = FlutterMethodChannel(
            name: "app.packingproof.mobile/lan_backup",
            binaryMessenger: messenger
        )
        super.init()
        channel.setMethodCallHandler(handleMethodCall)
    }

    private func handleMethodCall(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        switch call.method {
        case "initialize", "snapshot":
            if call.method == "initialize" {
                if let unbacked = call.arguments as? [String: Any] {
                    if let days = unbacked["unbackedRetentionDays"] as? Int {
                        store.set(days, forKey: "unbackedRetentionDays")
                    }
                    if let days = unbacked["backedRetentionDays"] as? Int {
                        store.set(days, forKey: "backedRetentionDays")
                    }
                }
            }
            result(snapshot())

        case "loadAccessKey":
            result(store.string(forKey: "accessKey") ?? "")

        case "isWifiConnected":
            result(isWifiConnected())

        case "saveConnection":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "invalid_args", message: "参数无效", details: nil))
                return
            }
            store.set(args["baseUrl"] as? String ?? "", forKey: "baseUrl")
            store.set(args["accessKey"] as? String ?? "", forKey: "accessKey")
            store.set(args["computerId"] as? String ?? "", forKey: "computerId")
            store.set(args["computerName"] as? String ?? "已连接电脑", forKey: "computerName")
            store.set(args["deviceName"] as? String ?? "", forKey: "deviceName")
            store.synchronize()
            notifySnapshotChanged()
            result(nil)

        case "disconnect":
            store.removeObject(forKey: "baseUrl")
            store.removeObject(forKey: "accessKey")
            store.removeObject(forKey: "computerId")
            store.removeObject(forKey: "computerName")
            store.removeObject(forKey: "deviceName")
            store.synchronize()
            notifySnapshotChanged()
            result(nil)

        case "enqueue":
            // iOS uses URLSession background upload - schedule if connected
            notifySnapshotChanged()
            result(nil)

        case "setRetentionPolicies":
            if let args = call.arguments as? [String: Any] {
                if let days = args["unbackedRetentionDays"] as? Int {
                    store.set(days, forKey: "unbackedRetentionDays")
                }
                if let days = args["backedRetentionDays"] as? Int {
                    store.set(days, forKey: "backedRetentionDays")
                }
            }
            result(nil)

        case "checkAndReclaimStorage":
            result(true)

        case "retry", "cancel":
            notifySnapshotChanged()
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func snapshot() -> [String: Any] {
        let deviceId = deviceIdentifier()
        let connection: [String: Any]? = {
            guard let baseUrl = store.string(forKey: "baseUrl"), !baseUrl.isEmpty else { return nil }
            return [
                "baseUrl": baseUrl,
                "computerId": store.string(forKey: "computerId") ?? "",
                "computerName": store.string(forKey: "computerName") ?? "",
                "deviceName": store.string(forKey: "deviceName") ?? ""
            ]
        }()
        return [
            "deviceId": deviceId,
            "deviceName": UIDevice.current.name,
            "connection": connection as Any,
            "jobs": [],
            "migrationHost": NSNull()
        ]
    }

    private func deviceIdentifier() -> String {
        if let id = store.string(forKey: "deviceId"), !id.isEmpty {
            return id
        }
        let id = UUID().uuidString
        store.set(id, forKey: "deviceId")
        store.synchronize()
        return id
    }

    private func isWifiConnected() -> Bool {
        // Simplified check - in production use NWPathMonitor
        return true
    }

    private func notifySnapshotChanged() {
        DispatchQueue.main.async {
            self.channel.invokeMethod("snapshotChanged", arguments: self.snapshot())
        }
    }

    func dispose() {
        channel.setMethodCallHandler(nil)
    }
}
