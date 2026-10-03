import Flutter
import UserNotifications

/// The app's UNUserNotificationCenter delegate on iOS: decides how a
/// notification appears while the app is on screen, and carries a tap through
/// to Dart (freizone/notifications).
///
/// Ours rather than a plugin's because of who would otherwise hold the role.
/// firebase_messaging is linked into the iOS build (the dependency is there for
/// Android) and makes itself the delegate at launch, with or without Firebase
/// configured; flutter_local_notifications never sets one. A tap would then end
/// at firebase_messaging, which forwards only to a delegate that was already in
/// place -- so Dart never heard about it, for the app's own notifications as
/// much as for the extension's. Installed early (see AppDelegate), this is the
/// delegate firebase_messaging finds and forwards to.
///
/// Every notification Freizone shows carries the same marks, whoever showed it:
/// the app through flutter_local_notifications, or the Notification Service
/// Extension (see its WakeSync.content): a `payload` for the tap, and present*
/// flags for the foreground.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
  static let shared = NotificationRouter()

  private var channel: FlutterMethodChannel?
  /// A tap that arrived before Dart asked for it -- the one that launched the
  /// app, typically.
  private var pendingPayload: String?
  private var dartReady = false

  func install() {
    UNUserNotificationCenter.current().delegate = self
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "freizone/notifications",
      binaryMessenger: registrar.messenger()
    )
    shared.channel = channel
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "takeLaunchPayload":
        // Dart has its tap handler from here on, so later taps go straight to it.
        shared.dartReady = true
        result(shared.pendingPayload)
        shared.pendingPayload = nil
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    // Whatever the notification says about itself; a notification without the
    // flags -- the gateway's bare placeholder, when the extension could not
    // replace it -- is not shown over the app, whose live stream is already
    // fetching what it is about.
    let info = notification.request.content.userInfo
    var options: UNNotificationPresentationOptions = []
    if info["presentBanner"] as? Bool == true { options.insert(.banner) }
    if info["presentList"] as? Bool == true { options.insert(.list) }
    if info["presentSound"] as? Bool == true { options.insert(.sound) }
    if info["presentBadge"] as? Bool == true { options.insert(.badge) }
    completionHandler(options)
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    defer { completionHandler() }
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
    // No payload (the bare placeholder) still opens the app; there is just no
    // chat to jump to.
    guard let payload = response.notification.request.content.userInfo["payload"] as? String
    else { return }
    if dartReady, let channel {
      channel.invokeMethod("tapped", arguments: payload)
    } else {
      pendingPayload = payload
    }
  }
}
