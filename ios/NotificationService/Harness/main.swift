// Runs the Notification Service Extension's wake logic (../NotificationService.swift)
// as a plain Mac program -- see run.sh for why and how.
import Foundation

let args = CommandLine.arguments
let directory = URL(fileURLWithPath: args[1])
let mode = args.count > 2 ? args[2] : "sync"
let accountIds = WakeSync.profileIds(in: directory)
print("accounts: \(accountIds.joined(separator: ", "))")

if mode == "hold" {
  // Holds every account open the way the extension does mid-sync, so the
  // app's wait-and-retry on resume can be watched.
  let seconds = args.count > 3 ? Double(args[3]) ?? 5 : 5
  for id in accountIds {
    _ = try Core.call(CoreOpen, ["path": directory.appendingPathComponent("core-\(id)").path])
  }
  print("holding for \(seconds)s")
  Thread.sleep(forTimeInterval: seconds)
  exit(0)
}

for id in accountIds {
  let start = Date()
  let result = WakeSync.sync(accountId: id, in: directory)
  let ms = Int(Date().timeIntervalSince(start) * 1000)
  switch result {
  case .notice(let notice):
    let content = WakeSync.content(for: notice, sound: WakeSync.notificationSound(in: directory))
    print("\(id): would show \"\(content.body)\" (\(ms) ms)")
    print("  payload: \(content.userInfo["payload"] ?? "-"), id: \(content.userInfo["NotificationId"] ?? "-")")
  case .nothing: print("\(id): nothing to show (\(ms) ms)")
  case .heldByApp: print("\(id): held open by the app, left to it")
  case .failed: print("\(id): failed (\(ms) ms) -- the placeholder would stay")
  }
}
