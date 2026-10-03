import Flutter
import UIKit

/// iOS half of lib/util/secure_screen.dart, standing in for Android's
/// FLAG_SECURE on the recovery-phrase screen.
///
/// iOS has no equivalent flag and cannot block a screenshot at all, so this
/// covers what it can: the snapshot the system takes for the app switcher
/// (the window is covered while the scene is inactive) and an ongoing screen
/// recording or mirroring (covered for as long as the screen is captured).
///
/// The cover is opaque on purpose. A blur keeps large text such as the
/// recovery phrase partly legible, which is exactly what this is for hiding.
final class SecureScreen: NSObject {
  static let shared = SecureScreen()

  private var enabled = false
  private var inactive = false
  private var cover: UIView?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "freizone/secure_screen",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "enable":
        shared.enabled = true
        shared.update()
        result(nil)
      case "disable":
        shared.enabled = false
        shared.update()
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
      self, selector: #selector(sceneWillDeactivate),
      name: UIScene.willDeactivateNotification, object: nil)
    center.addObserver(
      self, selector: #selector(sceneDidActivate),
      name: UIScene.didActivateNotification, object: nil)
    center.addObserver(
      self, selector: #selector(captureChanged),
      name: UIScreen.capturedDidChangeNotification, object: nil)
  }

  @objc private func sceneWillDeactivate() {
    inactive = true
    update()
  }

  @objc private func sceneDidActivate() {
    inactive = false
    update()
  }

  @objc private func captureChanged() {
    update()
  }

  private var window: UIWindow? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
  }

  private func update() {
    let window = self.window
    let captured = window?.windowScene?.screen.isCaptured ?? false
    let shouldCover = enabled && (inactive || captured)

    if shouldCover, cover == nil, let window {
      let view = UIView(frame: window.bounds)
      view.backgroundColor = .systemBackground
      view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      window.addSubview(view)
      cover = view
    } else if !shouldCover {
      cover?.removeFromSuperview()
      cover = nil
    }
  }
}
