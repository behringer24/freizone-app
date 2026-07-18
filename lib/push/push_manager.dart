// Wires UnifiedPush (Android-only for this milestone -- see README) to a
// generic "you have mail" system notification. Deliberately minimal: the
// wake payload the server sends carries no content or metadata (see
// docs/PROTOCOL.md in freizone-server), so there's nothing to decrypt or
// preview here -- tapping the notification just opens the app, which
// syncs over the normal authenticated API exactly as if it had just
// reconnected.
//
// The UnifiedPush plugin may relaunch this app's Dart entrypoint in a
// background isolate (`--unifiedpush-bg`) purely to deliver a wake while
// the app isn't otherwise running, so every callback below is a
// top-level function with no captured app/UI state -- each one loads
// whatever it needs directly from LocalStateStore.
import 'dart:developer' as developer;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:unifiedpush/unifiedpush.dart';

import '../ffi/freizone_core.dart';
import '../net/api_client.dart';
import '../state/local_state.dart';
import '../util/address_format.dart';

const _messagesChannelId = 'freizone_messages';

final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();

/// One id per account, shared between showing and clearing its
/// notification so they always refer to the same one.
int _notificationIdFor(String instance) => instance.hashCode & 0x7fffffff;

/// Clears instance's "new message(s)" notification, if any is showing --
/// call once it has no more unread conversations, so the launcher icon's
/// badge (which Android derives from active notifications) goes away
/// again instead of lingering after the messages have been read.
Future<void> clearMessageNotification(String instance) =>
    _notifications.cancel(id: _notificationIdFor(instance));

/// Sets up UnifiedPush + local-notification plumbing. Call once, as early
/// as possible (before runApp), so it also runs correctly when the
/// background isolate variant starts up.
Future<void> initPush() async {
  await _notifications.initialize(
    settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
  );
  await UnifiedPush.initialize(
    onNewEndpoint: _onNewEndpoint,
    onRegistrationFailed: _onRegistrationFailed,
    onUnregistered: _onUnregistered,
    onMessage: _onMessage,
    onTempUnavailable: _onTempUnavailable,
  );
}

/// Requests the Android 13+ notification permission. Only ever called
/// from the foreground app (never the `--unifiedpush-bg` headless run,
/// which never builds the UI that calls this) -- call once per app
/// launch, not once per account, since the permission is app-wide.
Future<void> requestNotificationPermission() async {
  await _notifications
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();
}

/// Registers one account's device for push using the user's current or
/// default UnifiedPush distributor, under a UnifiedPush "instance" named
/// after its account id -- one app can hold several such instances at
/// once, one per connected account, each getting its own wake endpoint.
/// Safe to call on every app start. Returns false if no distributor is
/// installed -- the caller can use that to show a one-time hint; chat
/// keeps working via SSE either way.
Future<bool> registerForPush(ApiClient api, String instance) async {
  final hasDistributor = await UnifiedPush.tryUseCurrentOrDefaultDistributor();
  if (!hasDistributor) return false;

  String? vapidKey;
  try {
    vapidKey = await api.getVAPIDPublicKey();
  } catch (e) {
    developer.log('fetching vapid public key failed: $e', name: 'push');
  }
  await UnifiedPush.register(instance: instance, vapid: vapidKey);
  return true;
}

Future<void> _onNewEndpoint(PushEndpoint endpoint, String instance) async {
  final keySet = endpoint.pubKeySet;
  final state = await LocalStateStore.loadProfile(instance);
  if (state == null || keySet == null) return;

  final api = ApiClient(baseUrl: state.server, core: FreizoneCore());
  try {
    await api.setPushEndpoint(
      creds: state.credentials,
      endpoint: endpoint.url,
      p256dh: keySet.pubKey,
      auth: keySet.auth,
    );
  } catch (e) {
    developer.log('registering push endpoint failed: $e', name: 'push');
  } finally {
    api.close();
  }
}

Future<void> _onRegistrationFailed(FailedReason reason, String instance) async {
  developer.log('push registration failed: $reason', name: 'push');
}

Future<void> _onUnregistered(String instance) async {
  final state = await LocalStateStore.loadProfile(instance);
  if (state == null) return;

  final api = ApiClient(baseUrl: state.server, core: FreizoneCore());
  try {
    await api.clearPushEndpoint(state.credentials);
  } catch (e) {
    developer.log('clearing push endpoint failed: $e', name: 'push');
  } finally {
    api.close();
  }
}

Future<void> _onTempUnavailable(String instance) async {
  developer.log('push distributor temporarily unavailable', name: 'push');
}

Future<void> _onMessage(PushMessage message, String instance) async {
  await showMessageNotification(instance);
}

/// Shows (or updates, if one's already up) instance's "new message(s)"
/// notification -- which is also what makes Android show a badge on the
/// launcher icon, since that's derived from active notifications, not
/// from anything drawn inside the app. Called both from a background
/// push wake (_onMessage) and live, from AppSession._handleIncoming,
/// whenever a message actually becomes unread while the app is in the
/// foreground -- the badge needs to reflect unread state regardless of
/// whether the app happened to be open when the message arrived.
Future<void> showMessageNotification(String instance) async {
  // instance is the waking account's own id -- purely local information
  // (never sent anywhere), so it's safe to show in the notification body
  // to say which of the user's own accounts it's for; also used directly
  // rather than reloading the profile from disk, since that raced
  // AppSession's own concurrent (non-atomic) write to that same file on
  // the live-message path and threw a FormatException on a half-written
  // read. Also used as the notification id so two accounts overlap into
  // one update, not a stack of duplicates, and so clearMessageNotification
  // cancels the right one.
  final body = 'New message(s) for ${formatAccountIdForDisplay(instance)}';

  await _notifications.show(
    id: _notificationIdFor(instance),
    title: 'Freizone',
    body: body,
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails(
        _messagesChannelId,
        'Messages',
        channelDescription: 'Notifies about new messages while the app is closed',
        importance: Importance.high,
        priority: Priority.high,
      ),
    ),
  );
}
