import Flutter
import Foundation
import Network

/// iOS equivalent of Android's OrderInfoReceiverPlugin.
/// Handles receiving order information from the desktop via HTTP.
class OrderInfoReceiverPlugin: NSObject {
    private let channel: FlutterMethodChannel
    private var listener: NWListener?
    private var keepAliveInBackground = false
    private var receivedOrders: [[String: Any]] = []

    init(messenger: FlutterBinaryMessenger) {
        self.channel = FlutterMethodChannel(
            name: "app.packingproof.mobile/order_info_receiver",
            binaryMessenger: messenger
        )
        super.init()
        channel.setMethodCallHandler(handleMethodCall)
    }

    private func handleMethodCall(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        switch call.method {
        case "start", "retry":
            result(true)
        case "status":
            result("running")
        case "lookup":
            let trackingNumber = (call.arguments as? [String: Any])?["trackingNumber"] as? String ?? ""
            let matched = receivedOrders.filter { order in
                (order["trackingNumber"] as? String) == trackingNumber
            }
            result(matched.first)
        case "setBackgroundKeepAlive":
            keepAliveInBackground = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
            result(nil)
        case "stop":
            keepAliveInBackground = false
            listener?.cancel()
            listener = nil
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    func onHostForeground() {}
    func onHostBackground() {
        if !keepAliveInBackground {
            listener?.cancel()
        }
    }

    func dispose() {
        listener?.cancel()
        listener = nil
        channel.setMethodCallHandler(nil)
    }
}
