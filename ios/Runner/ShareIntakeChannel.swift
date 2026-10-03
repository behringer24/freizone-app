import Flutter
import UIKit

/// iOS half of lib/util/share_intake.dart (APP-15) -- what MainActivity.kt does
/// for an ACTION_SEND, for a share the Share Extension (ios/ShareExtension)
/// parked in the App Group container.
///
/// Pull-based like Android's: Dart asks once its accounts exist
/// (takePendingShare), because a share can be what launched the app. When the
/// app was already running, the extension's freizone-share:// link arrives at
/// the SceneDelegate, and this only nudges Dart (shareReceived) to come and ask.
final class ShareIntakeChannel {
  static let shared = ShareIntakeChannel()

  /// KEEP IN STEP with ShareViewController.swift.
  static let scheme = "freizone-share"
  private static let inboxName = "share-inbox"
  private static let pendingName = "pending.json"

  private var channel: FlutterMethodChannel?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "freizone/share_intake",
      binaryMessenger: registrar.messenger()
    )
    shared.channel = channel
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "takePendingShare":
        result(shared.takePendingShare())
      case "normalizeImage":
        let args = call.arguments as? [String: Any] ?? [:]
        guard let path = args["path"] as? String else {
          result(nil)
          return
        }
        let maxEdge = args["maxEdge"] as? Int ?? 1600
        let quality = args["quality"] as? Int ?? 80
        DispatchQueue.global(qos: .userInitiated).async {
          let normalized = normalizeImage(path: path, maxEdge: maxEdge, quality: quality)
          DispatchQueue.main.async { result(normalized) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// The extension's link: a share is waiting.
  func shareArrived() {
    channel?.invokeMethod("shareReceived", arguments: nil)
  }

  /// Collects the parked share and clears it, so neither a second ask nor a
  /// later launch delivers it twice. The picture stays where it is; Dart hands
  /// it to normalizeImage, which replaces it.
  private func takePendingShare() -> [String: String]? {
    let pending = SharedStorage.directory
      .appendingPathComponent(Self.inboxName, isDirectory: true)
      .appendingPathComponent(Self.pendingName)
    guard
      let data = try? Data(contentsOf: pending),
      let share = try? JSONSerialization.jsonObject(with: data) as? [String: String]
    else { return nil }
    try? FileManager.default.removeItem(at: pending)
    return share
  }

  /// Downscales a shared picture to the edge a gallery pick gets and
  /// re-encodes it as JPEG, as MainActivity.normalizeImage does: a shared
  /// picture must not go out at full camera resolution where a picked one
  /// would not. Drawing through UIImage applies its EXIF orientation, so the
  /// result is upright. Returns the new file, or nil if it was not an image.
  static func normalizeImage(path: String, maxEdge: Int, quality: Int) -> String? {
    guard let image = UIImage(contentsOfFile: path) else { return nil }
    let pixelWidth = image.size.width * image.scale
    let pixelHeight = image.size.height * image.scale
    let longest = max(pixelWidth, pixelHeight)
    let ratio = longest > CGFloat(maxEdge) ? CGFloat(maxEdge) / longest : 1
    let size = CGSize(width: (pixelWidth * ratio).rounded(), height: (pixelHeight * ratio).rounded())

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }
    guard let jpeg = rendered.jpegData(compressionQuality: CGFloat(quality) / 100) else { return nil }

    let target = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("shared-\(UUID().uuidString).jpg")
    do {
      try jpeg.write(to: target)
    } catch {
      return nil
    }
    try? FileManager.default.removeItem(atPath: path)
    return target.path
  }
}
