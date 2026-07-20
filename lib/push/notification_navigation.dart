// Bridges a tapped "new message" notification back to the live app.
// push_manager.dart's notification callbacks are plain top-level
// functions with no BuildContext or captured app state (they can run in
// a background isolate -- see that file's header comment), so they can't
// navigate directly. AppRoot instead registers a handler here once its
// AccountManager exists, and push_manager.dart calls [handleNotificationPayload]
// whenever a notification is tapped (live) or, via
// PushManager.consumeLaunchNotificationPayload, when a tap cold-launched
// the app.
typedef NotificationTapHandler =
    void Function(String accountId, String? peerAccountId);

NotificationTapHandler? _handler;

void setNotificationTapHandler(NotificationTapHandler handler) {
  _handler = handler;
}

/// Encodes which account -- and, if known, which peer conversation -- a
/// "new message" notification is for, into flutter_local_notifications'
/// single opaque payload string. Account/peer ids never contain '|' (see
/// util/address_format.dart's charset), so a plain delimiter is enough;
/// no need for JSON here. peerAccountId is null when the notification
/// couldn't be attributed to a specific conversation (a background push
/// wake, whose payload carries no content -- see push_manager.dart's
/// header comment) -- tapping then still switches to the right account,
/// just not a specific chat.
String encodeNotificationPayload({
  required String accountId,
  String? peerAccountId,
}) => peerAccountId == null ? accountId : '$accountId|$peerAccountId';

/// Decodes a payload built by [encodeNotificationPayload] and, if a
/// handler is registered, invokes it. Safe to call with null/empty (no
/// notification was tapped) or before a handler is registered (a tap
/// that raced app startup -- the cold-launch path re-delivers the same
/// payload once the handler exists, see AppRoot._load).
void handleNotificationPayload(String? payload) {
  if (payload == null || payload.isEmpty) return;
  final parts = payload.split('|');
  _handler?.call(parts[0], parts.length > 1 ? parts[1] : null);
}
