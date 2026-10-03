import UIKit
import UniformTypeIdentifiers

/// "Share to Freizone" from another app (APP-15 on iOS).
///
/// Android hands a share to the app itself, which then asks which chat it is
/// for. This does the same in two steps, because iOS runs a share in a separate
/// extension process: it parks what was shared in the App Group container --
/// the text, and a copy of the picture -- and brings the app forward, which
/// collects it exactly as it collects an Android share (share_intake.dart,
/// ios/Runner/ShareIntakeChannel.swift) and shows the same target picker.
///
/// Nothing is sent from here, and no account is opened: everything that needs
/// keys or the network stays in the app.
final class ShareViewController: UIViewController {
  /// KEEP IN STEP with ShareIntakeChannel.swift.
  static let inboxName = "share-inbox"
  static let pendingName = "pending.json"

  private var started = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !started else { return }
    started = true
    Task { await handOver() }
  }

  private func handOver() async {
    let inbox = SharedStorage.directory.appendingPathComponent(Self.inboxName, isDirectory: true)
    // One share at a time, as on Android: an earlier one the app never
    // collected is superseded, not queued.
    try? FileManager.default.removeItem(at: inbox)
    try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)

    var texts: [String] = []
    var imagePath: String?
    for item in extensionContext?.inputItems as? [NSExtensionItem] ?? [] {
      if let caption = item.attributedContentText?.string, !caption.isEmpty {
        texts.append(caption)
      }
      for provider in item.attachments ?? [] {
        if imagePath == nil, provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
          imagePath = await copyImage(from: provider, into: inbox)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
          let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL
        {
          texts.append(url.absoluteString)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
          let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier)
            as? String
        {
          texts.append(text)
        }
      }
    }

    // A page shared from Safari often arrives as its URL and again as text
    // containing it; say it once.
    var unique: [String] = []
    for text in texts where !unique.contains(where: { $0.contains(text) }) {
      unique.removeAll { text.contains($0) }
      unique.append(text)
    }
    var pending: [String: String] = [:]
    if !unique.isEmpty { pending["text"] = unique.joined(separator: "\n") }
    if let imagePath { pending["imagePath"] = imagePath }

    if !pending.isEmpty, let data = try? JSONSerialization.data(withJSONObject: pending) {
      try? data.write(to: inbox.appendingPathComponent(Self.pendingName), options: .atomic)
      if !openApp() {
        await showOpenAppHint()
      }
    }
    extensionContext?.completeRequest(returningItems: nil)
  }

  /// Copies the shared picture as it is: the app downscales and re-encodes it
  /// the same way it does any shared picture (normalizeSharedImage).
  private func copyImage(from provider: NSItemProvider, into inbox: URL) async -> String? {
    await withCheckedContinuation { continuation in
      provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
        // The file only exists for the duration of this callback.
        if let url {
          let target = inbox.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension.isEmpty ? "img" : url.pathExtension)
          if (try? FileManager.default.copyItem(at: url, to: target)) != nil {
            continuation.resume(returning: target.path)
            return
          }
        }
        // Some sources only offer an image object, not a file (a screenshot's
        // markup editor, for one).
        provider.loadItem(forTypeIdentifier: UTType.image.identifier) { item, _ in
          let target = inbox.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
          let data: Data? = switch item {
          case let image as UIImage: image.jpegData(compressionQuality: 0.95)
          case let data as Data: data
          default: nil
          }
          if let data, (try? data.write(to: target)) != nil {
            continuation.resume(returning: target.path)
          } else {
            continuation.resume(returning: nil)
          }
        }
      }
    }
  }

  /// Brings Freizone forward. A share extension has no supported way to open
  /// its app -- extensionContext.open is for widgets -- so this asks the
  /// UIApplication found up the responder chain, which is what share extensions
  /// commonly do. Should a future iOS refuse, the share is still parked and the
  /// app picks it up the next time it comes to the foreground; the hint below
  /// tells the user to open it.
  private func openApp() -> Bool {
    guard let url = URL(string: "freizone-share://incoming") else { return false }
    var responder: UIResponder? = self
    while let current = responder {
      if let application = current as? UIApplication {
        application.open(url, options: [:], completionHandler: nil)
        return true
      }
      responder = current.next
    }
    return false
  }

  private func showOpenAppHint() async {
    await withCheckedContinuation { continuation in
      let alert = UIAlertController(
        title: "Ready in Freizone",
        message: "Open Freizone to choose the chat to send this to.",
        preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in continuation.resume() })
      present(alert, animated: true)
    }
  }
}
