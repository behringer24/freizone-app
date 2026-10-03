import Flutter

/// freizone/storage: tells Dart where the files are.
enum StorageChannel {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "freizone/storage",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "directory":
        result(SharedStorage.directory.path)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
