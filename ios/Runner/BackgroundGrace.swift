import Flutter
import UIKit

/// freizone/lifecycle: keeps the app running in the background just long enough
/// for Dart to let go of its accounts (AppSession.suspendCore).
///
/// iOS suspends an app within moments of it leaving the screen, and terminates
/// it outright if it is suspended while holding a file lock in the App Group
/// container -- which an open account is. Closing an account may first have to
/// wait for a send that is still running, so the app asks for background time
/// the moment it enters the background and hands it back once Dart reports
/// that everything is closed. If Dart never does, the expiration handler hands
/// it back anyway; the system allows about 30 seconds.
final class BackgroundGrace: NSObject {
  static let shared = BackgroundGrace()

  private var task: UIBackgroundTaskIdentifier = .invalid

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "freizone/lifecycle",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "accountsReleased":
        shared.end()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private override init() {
    super.init()
    let center = NotificationCenter.default
    center.addObserver(
      self, selector: #selector(didEnterBackground),
      name: UIScene.didEnterBackgroundNotification, object: nil)
    center.addObserver(
      self, selector: #selector(willEnterForeground),
      name: UIScene.willEnterForegroundNotification, object: nil)
  }

  @objc private func didEnterBackground() {
    guard task == .invalid else { return }
    task = UIApplication.shared.beginBackgroundTask(withName: "freizone.release-accounts") {
      [weak self] in self?.end()
    }
  }

  @objc private func willEnterForeground() {
    end()
  }

  private func end() {
    guard task != .invalid else { return }
    UIApplication.shared.endBackgroundTask(task)
    task = .invalid
  }
}
