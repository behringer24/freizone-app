import Flutter
import Photos

/// iOS half of lib/util/gallery.dart (APP-20) -- what MainActivity.kt does
/// with MediaStore, done with the Photos framework.
///
/// Asks for add-only access, never for the whole library: Freizone only ever
/// puts pictures in, so it has no business being able to read the user's
/// photos. The price is that there is no "Freizone" album as on Android --
/// creating one needs read access too.
///
/// Unlike Android, iOS asks only once: after a refusal the dialog never comes
/// back and the user has to change it in the Settings app. The Dart side
/// words its hint accordingly.
enum GalleryChannel {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "freizone/gallery",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "save":
        guard let args = call.arguments as? [String: Any],
          let path = args["path"] as? String
        else {
          result("failed")
          return
        }
        let mayPrompt = args["mayPrompt"] as? Bool ?? true
        withAddAccess(mayPrompt: mayPrompt) { granted in
          guard granted else {
            result("permission_denied")
            return
          }
          save(path: path, result: result)
        }
      case "requestPermission":
        withAddAccess(mayPrompt: true) { granted in
          result(granted ? "granted" : "permission_denied")
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Calls [completion] on the main thread with whether pictures may be
  /// added, asking first only if the user has never been asked and
  /// [mayPrompt] allows it (an automatic save must not raise a dialog).
  private static func withAddAccess(
    mayPrompt: Bool,
    completion: @escaping (Bool) -> Void
  ) {
    switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
    case .authorized, .limited:
      completion(true)
    case .notDetermined where mayPrompt:
      PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
        DispatchQueue.main.async {
          completion(status == .authorized || status == .limited)
        }
      }
    default:
      completion(false)
    }
  }

  /// Copies the bytes verbatim into the library: the file is already the
  /// decrypted picture, so there is nothing to decode or re-encode.
  ///
  /// Handed over as data, not as a file URL: the core stores media without a
  /// file extension, and Photos only types a file URL by its extension (it
  /// fails on an extensionless one), whereas it sniffs data by content.
  private static func save(path: String, result: @escaping FlutterResult) {
    guard let data = FileManager.default.contents(atPath: path) else {
      result("failed")
      return
    }
    PHPhotoLibrary.shared().performChanges({
      let options = PHAssetResourceCreationOptions()
      options.originalFilename = "freizone_\(Int(Date().timeIntervalSince1970)).jpg"
      PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: options)
    }) { ok, _ in
      DispatchQueue.main.async { result(ok ? "saved" : "failed") }
    }
  }
}
