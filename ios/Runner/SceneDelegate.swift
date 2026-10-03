import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  /// The Share Extension's freizone-share:// link, while the app is already
  /// running: the share is waiting in the App Group, and Dart is told to
  /// collect it. A share that launches the app needs nothing here -- Dart asks
  /// once its accounts are loaded. Other links go on to Flutter as usual.
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    let shares = URLContexts.filter { $0.url.scheme == ShareIntakeChannel.scheme }
    if !shares.isEmpty {
      ShareIntakeChannel.shared.shareArrived()
    }
    let others = URLContexts.subtracting(shares)
    if !others.isEmpty {
      super.scene(scene, openURLContexts: others)
    }
  }
}
