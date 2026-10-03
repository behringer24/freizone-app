import Foundation
import UserNotifications

/// Handles a push wake on iOS (APP-03).
///
/// The wake itself says nothing -- freizone-gateway sends the same placeholder
/// alert every time (see its internal/push/apns.go) -- so this does what the
/// Android app does in the background: open every account through the shared
/// Go core, fetch and decrypt what is queued, settle the housekeeping a fresh
/// connection does, and only then decide what, if anything, to show. It shares
/// the receive path with the app (doCoreSync), so a message decrypted here is
/// the same message the app shows when it is next opened.
///
/// What is shown matches the app's own notification (push_manager.dart's
/// showMessageNotification): one per account, naming the account, never the
/// content, carrying the same tap payload -- and marked the way
/// flutter_local_notifications marks its own, so the app treats a tap on it
/// exactly like a tap on one it showed itself.
final class NotificationService: UNNotificationServiceExtension {
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var placeholder: UNNotificationContent?
  private let deliveryLock = NSLock()
  private var delivered = false

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    placeholder = request.content
    DispatchQueue.global(qos: .userInitiated).async {
      let content = WakeSync.run(placeholder: request.content)
      self.deliver(content)
    }
  }

  /// The system's last call before it shows the placeholder as it came. The
  /// sync is still running in the core and cannot be interrupted; the
  /// placeholder ("New message") is the honest answer when we don't know yet.
  override func serviceExtensionTimeWillExpire() {
    if let placeholder { deliver(placeholder) }
  }

  private func deliver(_ content: UNNotificationContent) {
    deliveryLock.lock()
    defer { deliveryLock.unlock() }
    guard !delivered, let contentHandler else { return }
    delivered = true
    contentHandler(content)
  }
}

/// One push wake, start to finish.
enum WakeSync {
  /// What a sync found worth telling the user about, per account. Mirrors
  /// push_manager.dart's _WakeNotice.
  struct Notice {
    let accountId: String
    let peerAccountId: String?
    let groupId: String?
    let invitation: Bool
  }

  enum AccountResult {
    case notice(Notice)
    case nothing
    /// The app holds the account open, so it is on screen (or just leaving
    /// it) and its own live stream handles what arrives.
    case heldByApp
    case failed
  }

  static func run(placeholder: UNNotificationContent) -> UNNotificationContent {
    let directory = SharedStorage.directory
    let accountIds = profileIds(in: directory)
    var notices: [Notice] = []
    var failures = 0
    var held = 0
    for accountId in accountIds {
      switch sync(accountId: accountId, in: directory) {
      case .notice(let notice): notices.append(notice)
      case .nothing: break
      case .heldByApp: held += 1
      case .failed: failures += 1
      }
    }
    log("wake: \(accountIds.count) account(s), \(notices.count) to show, \(held) held by the app, \(failures) failed")

    let sound = notificationSound(in: directory)
    if let first = notices.first {
      // Further accounts get notifications of their own, as on Android; the
      // wake's own notification carries the first.
      for notice in notices.dropFirst() {
        let request = UNNotificationRequest(
          identifier: String(notificationId(for: notice.accountId)),
          content: content(for: notice, sound: sound),
          trigger: nil)
        UNUserNotificationCenter.current().add(request)
      }
      for notice in notices {
        removeEarlierNotifications(for: notice.accountId)
      }
      return content(for: first, sound: sound)
    }
    if failures > 0 && held == 0 {
      // Something may well be waiting that we could not fetch -- a server
      // that did not answer, say. The placeholder says as much without
      // claiming more.
      return placeholder
    }
    // Nothing new: a housekeeping wake (the prekey pool running low), or one
    // the app already handled on screen. An empty notification is not shown.
    return UNNotificationContent()
  }

  // MARK: - One account

  /// Opens one account, syncs it and closes it again -- push_manager.dart's
  /// _wakeSyncInIsolate, in Swift.
  static func sync(accountId: String, in directory: URL) -> AccountResult {
    let profileURL = directory.appendingPathComponent("freizone_profile_\(accountId).json")
    guard
      let data = try? Data(contentsOf: profileURL),
      let profile = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      log("wake: profile of \(accountId) unreadable")
      return .failed
    }

    let statePath = directory.appendingPathComponent("core-\(accountId)").path
    let handle: Int
    do {
      let opened = try Core.call(CoreOpen, ["path": statePath]) as? [String: Any]
      guard let h = opened?["handle"] as? Int else { return .failed }
      handle = h
    } catch let error as Core.Failure where error.code == "account_in_use" {
      return .heldByApp
    } catch {
      log("wake: opening \(accountId) failed: \(error)")
      return .failed
    }
    defer { _ = try? Core.call(CoreClose, ["handle": handle]) }

    var identity = profile.filter { identityKeys.contains($0.key) }
    identity["handle"] = handle
    do {
      _ = try Core.call(CoreSetIdentity, identity)
      let result = try Core.call(CoreSync, ["handle": handle]) as? [String: Any] ?? [:]
      for problem in result["problems"] as? [Any] ?? [] {
        log("wake: \(accountId) housekeeping problem: \(problem)")
      }
      var notice: Notice?
      for case let outcome as [String: Any] in result["outcomes"] as? [Any] ?? [] {
        let chatId = outcome["chat_id"] as? String ?? ""
        guard !chatId.isEmpty, outcome["notify"] as? Bool == true else { continue }
        let isGroup = outcome["is_group"] as? Bool == true
        notice = Notice(
          accountId: accountId,
          peerAccountId: isGroup ? nil : chatId,
          groupId: isGroup ? chatId : nil,
          invitation: outcome["invitation"] as? Bool == true)
      }
      return notice.map(AccountResult.notice) ?? .nothing
    } catch {
      log("wake: syncing \(accountId) failed: \(error)")
      return .failed
    }
  }

  /// The profile fields the core takes as the account's identity. The profile
  /// file uses the same names and encodings as the core's request (snake case,
  /// base64 keys), so they pass straight through; everything else in the file
  /// is the app's business. KEEP IN STEP with native/client.go's
  /// coreSetIdentityRequest.
  static let identityKeys: Set<String> = [
    "account_id", "server", "root_pub", "root_priv", "device_id", "device_pub",
    "device_priv", "dh_identity_pub", "dh_identity_priv", "signed_prekey_id",
    "signed_prekey_pub", "signed_prekey_priv", "next_signed_prekey_id",
    "next_otpk_key_id", "recovery_backup_done", "push_mechanism",
  ]

  static func profileIds(in directory: URL) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.compactMap { name in
      guard name.hasPrefix("freizone_profile_"), name.hasSuffix(".json") else { return nil }
      return String(name.dropFirst("freizone_profile_".count).dropLast(".json".count))
    }
  }

  // MARK: - What is shown

  /// KEEP IN STEP with push_manager.dart's showMessageNotification.
  static func content(for notice: Notice, sound: Bool) -> UNNotificationContent {
    let content = UNMutableNotificationContent()
    content.title = "Freizone"
    let what = notice.invitation ? "Group invitation" : "New message(s)"
    content.body = "\(what) for \(formatAccountId(notice.accountId))"
    content.threadIdentifier = notice.accountId
    if sound { content.sound = .default }
    content.userInfo = [
      // flutter_local_notifications' marks for a notification of its own (see
      // isAFlutterLocalNotification in its iOS plugin): with them a tap reaches
      // the app's onDidReceiveNotificationResponse and its launch details. The
      // present* flags only decide what happens while the app is on screen --
      // nothing, since its live stream has already shown what it needs to.
      "NotificationId": notificationId(for: notice.accountId),
      "payload": payload(for: notice),
      "presentAlert": false,
      "presentSound": false,
      "presentBadge": false,
      "presentBanner": false,
      "presentList": false,
    ]
    return content
  }

  /// KEEP IN STEP with notification_navigation.dart's encodeNotificationPayload.
  static func payload(for notice: Notice) -> String {
    if let groupId = notice.groupId { return "\(notice.accountId)|\(groupId)|group" }
    if let peer = notice.peerAccountId { return "\(notice.accountId)|\(peer)" }
    return notice.accountId
  }

  /// KEEP IN STEP with address_format.dart's formatAccountIdForDisplay.
  static func formatAccountId(_ id: String) -> String {
    var out = ""
    for (i, ch) in id.enumerated() {
      if i > 0 && i % 5 == 0 { out.append("-") }
      out.append(ch)
    }
    return out
  }

  /// One id per account, the same the app uses for the notification it shows
  /// itself: 31-bit FNV-1a over the account id's UTF-8 bytes. KEEP IN STEP with
  /// push_manager.dart's _notificationIdFor.
  static func notificationId(for accountId: String) -> Int {
    var hash: UInt32 = 0x811c_9dc5
    for byte in accountId.utf8 {
      hash ^= UInt32(byte)
      hash = hash &* 0x0100_0193
    }
    return Int(hash & 0x7fff_ffff)
  }

  /// One notification per account, as on Android: whatever this account
  /// showed before -- from an earlier wake, or by the app itself -- goes, and
  /// the new one takes its place.
  static func removeEarlierNotifications(for accountId: String) {
    let id = notificationId(for: accountId)
    let center = UNUserNotificationCenter.current()
    let done = DispatchSemaphore(value: 0)
    center.getDeliveredNotifications { notifications in
      let earlier = notifications
        .filter { ($0.request.content.userInfo["NotificationId"] as? Int) == id }
        .map { $0.request.identifier }
      center.removeDeliveredNotifications(withIdentifiers: earlier + [String(id)])
      done.signal()
    }
    _ = done.wait(timeout: .now() + 2)
  }

  /// The app's sound setting (freizone_settings.json, see app_settings.dart).
  static func notificationSound(in directory: URL) -> Bool {
    let url = directory.appendingPathComponent("freizone_settings.json")
    guard
      let data = try? Data(contentsOf: url),
      let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return true }
    return settings["notification_sound"] as? Bool ?? true
  }

  static func log(_ message: String) {
    NSLog("[freizone/push] %@", message)
  }
}

/// Calls into the Go core: JSON in, result envelope out.
enum Core {
  struct Failure: Error, CustomStringConvertible {
    let message: String
    let code: String?
    var description: String { code.map { "\(message) [\($0)]" } ?? message }
  }

  static func call(
    _ function: (UnsafeMutablePointer<CChar>?) -> UnsafeMutablePointer<CChar>?,
    _ request: [String: Any]
  ) throws -> Any? {
    let body = try JSONSerialization.data(withJSONObject: request)
    let json = String(decoding: body, as: UTF8.self)
    let raw = json.withCString { function(UnsafeMutablePointer(mutating: $0)) }
    guard let raw else { throw Failure(message: "no result from the core", code: nil) }
    defer { FreizoneFree(raw) }
    guard
      let envelope = try JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8))
        as? [String: Any]
    else { throw Failure(message: "unreadable result from the core", code: nil) }
    if envelope["ok"] as? Bool == true { return envelope["data"] }
    throw Failure(
      message: envelope["error"] as? String ?? "unknown core error",
      code: (envelope["code"] as? String).flatMap { $0.isEmpty ? nil : $0 })
  }
}
