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
    void Function(String accountId, String? chatId, {bool isGroup});

NotificationTapHandler? _handler;

void setNotificationTapHandler(NotificationTapHandler handler) {
  _handler = handler;
}

/// Marks the chat id in a payload as a group id rather than a peer account
/// id. Which one it is cannot be read off the id itself without trusting
/// its version marker, and the two open entirely different screens -- so
/// it is stated, not inferred.
const _groupMarker = 'group';

/// Encodes which account -- and, if known, which chat -- a notification is
/// for, into flutter_local_notifications' single opaque payload string.
/// Account, peer and group ids never contain '|' (see
/// util/address_format.dart's charset), so a plain delimiter is enough; no
/// need for JSON here.
///
/// Pass [peerAccountId] for a one-to-one conversation or [groupId] for a
/// group; both null when the notification couldn't be attributed to a
/// specific chat (a background push wake, whose payload carries no content
/// -- see push_manager.dart's header comment) -- tapping then still
/// switches to the right account, just not a specific chat. A group id is
/// tagged as such, so an old payload still sitting in the notification
/// tray from a previous version (`account|peer`) keeps decoding as the
/// one-to-one chat it was.
String encodeNotificationPayload({
  required String accountId,
  String? peerAccountId,
  String? groupId,
}) {
  assert(
    peerAccountId == null || groupId == null,
    'a notification is about one chat, not both',
  );
  if (groupId != null) return '$accountId|$groupId|$_groupMarker';
  if (peerAccountId != null) return '$accountId|$peerAccountId';
  return accountId;
}

/// Decodes a payload built by [encodeNotificationPayload] and, if a
/// handler is registered, invokes it. Safe to call with null/empty (no
/// notification was tapped) or before a handler is registered (a tap
/// that raced app startup -- the cold-launch path re-delivers the same
/// payload once the handler exists, see AppRoot._load).
void handleNotificationPayload(String? payload) {
  if (payload == null || payload.isEmpty) return;
  final parts = payload.split('|');
  _handler?.call(
    parts[0],
    parts.length > 1 ? parts[1] : null,
    isGroup: parts.length > 2 && parts[2] == _groupMarker,
  );
}
