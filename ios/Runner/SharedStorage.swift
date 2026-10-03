import Foundation

/// Where Freizone keeps its files on iOS: the App Group container, so the
/// Notification Service Extension -- a separate process -- can open the same
/// accounts the app does. Without the App Group entitlement (a build signed by
/// a free Apple ID cannot have one) this falls back to the app's own Documents
/// directory, which is where everything lived before, and push wakes simply
/// cannot decrypt anything.
///
/// The iOS half of lib/util/app_storage.dart. Shared with the extension target,
/// so both resolve the same directory by the same rule.
enum SharedStorage {
  static let appGroup = "group.de.behringer24.freizone"

  /// What lives in the directory: profiles and settings (freizone_*.json) and
  /// one core state directory per account (core-<account id>). Only these are
  /// moved by the migration; anything else in Documents belongs to someone
  /// else.
  static func isOurs(_ name: String) -> Bool {
    name.hasPrefix("freizone_") || name.hasPrefix("core-")
  }

  /// The App Group directory, or nil when the build has no App Group.
  static var groupDirectory: URL? {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroup)
    else { return nil }
    return container.appendingPathComponent("Freizone", isDirectory: true)
  }

  /// Resolved once per process. In the app this also moves an existing
  /// install's files out of Documents, before Dart has read any of them.
  static let directory: URL = {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    guard let group = groupDirectory else { return documents }
    do {
      try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
    } catch {
      NSLog("[freizone/storage] cannot create the shared directory: \(error)")
      return documents
    }
    if !isExtension {
      migrate(from: documents, to: group)
    }
    return group
  }()

  private static var isExtension: Bool {
    Bundle.main.bundleURL.pathExtension == "appex"
  }

  /// Moves this install's files from Documents into the shared directory.
  ///
  /// A rename, not a copy: both directories are on the same volume, so each
  /// move is atomic and there is never a moment with two diverging copies of an
  /// account. Something already present at the target is left alone and the
  /// source kept -- that can only be a half-finished earlier run, and the copy
  /// the app has been using since is the one that counts.
  static func migrate(from documents: URL, to group: URL) {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: documents.path) else { return }
    for name in names where isOurs(name) {
      let target = group.appendingPathComponent(name)
      if fm.fileExists(atPath: target.path) { continue }
      do {
        try fm.moveItem(at: documents.appendingPathComponent(name), to: target)
      } catch {
        NSLog("[freizone/storage] could not move \(name) into the shared directory: \(error)")
      }
    }
  }
}
