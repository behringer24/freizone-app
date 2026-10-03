import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Before any plugin gets to: see NotificationRouter for why this has to
    // be in place by the time firebase_messaging looks for a delegate.
    NotificationRouter.shared.install()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // The APNs token's two possible outcomes, for ApnsChannel. super still runs,
  // so plugins that listen for them keep hearing them.
  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    ApnsChannel.shared.didRegister(deviceToken: deviceToken)
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    ApnsChannel.shared.didFail(error)
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Freizone's own channels -- the iOS halves of what MainActivity.kt
    // handles on Android. The Dart side treats a missing handler as
    // "unsupported", so anything not registered here just stays off.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FreizoneStorage") {
      StorageChannel.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FreizoneLifecycle") {
      BackgroundGrace.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FreizoneNotifications") {
      NotificationRouter.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FreizoneApns") {
      ApnsChannel.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FreizoneGallery") {
      GalleryChannel.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FreizoneSecureScreen") {
      SecureScreen.register(with: registrar)
    }
  }
}
