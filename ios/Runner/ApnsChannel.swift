import Flutter
import UIKit
import UserNotifications

/// freizone/apns: hands Dart this device's APNs token, which the app registers
/// with each account's server as its push target (platform "apns") -- the iOS
/// counterpart of the FCM token on Android.
///
/// iOS issues the token asynchronously after registerForRemoteNotifications,
/// and calls back into the app delegate (AppDelegate forwards both outcomes
/// here). It is the same token on every launch unless the system replaces it,
/// and the app registers on every start and reconnect anyway, so there is no
/// separate refresh path: asking again is the refresh.
///
/// A build without the push entitlement (a free Apple ID) never gets a token;
/// Dart then reports push as unavailable, which is the truth.
final class ApnsChannel {
  static let shared = ApnsChannel()

  private var token: String?
  private var waiting: [FlutterResult] = []

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "freizone/apns",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "token":
        shared.requestToken(result)
      case "removeDelivered":
        // A notification the extension showed for an account: same id as the
        // app's own (in userInfo), but an identifier the system chose, so only
        // a lookup by userInfo finds it. See push_manager.dart's
        // clearMessageNotification.
        let id = (call.arguments as? [String: Any])?["id"] as? Int
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notifications in
          let matching = notifications
            .filter { ($0.request.content.userInfo["NotificationId"] as? Int) == id }
            .map { $0.request.identifier }
          center.removeDeliveredNotifications(withIdentifiers: matching)
          DispatchQueue.main.async { result(nil) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func requestToken(_ result: @escaping FlutterResult) {
    if let token {
      result(token)
      return
    }
    waiting.append(result)
    guard waiting.count == 1 else { return }
    UIApplication.shared.registerForRemoteNotifications()
    // Without an aps-environment entitlement iOS can stay silent instead of
    // reporting a failure; nobody waits forever for that.
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
      self?.finish(FlutterError(code: "timeout", message: "no APNs token within 15s", details: nil))
    }
  }

  func didRegister(deviceToken: Data) {
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    token = hex
    finish(hex)
  }

  func didFail(_ error: Error) {
    finish(FlutterError(code: "registration_failed", message: error.localizedDescription, details: nil))
  }

  private func finish(_ value: Any) {
    let pending = waiting
    waiting = []
    for result in pending { result(value) }
  }
}
