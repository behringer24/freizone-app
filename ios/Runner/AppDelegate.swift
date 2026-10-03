import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FreizoneGallery") {
      GalleryChannel.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FreizoneSecureScreen") {
      SecureScreen.register(with: registrar)
    }
  }
}
