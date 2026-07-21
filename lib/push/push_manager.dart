// Wires two independent, non-interfering push-wake mechanisms to a
// generic "you have mail" system notification: UnifiedPush (self-hosted,
// no Google dependency) and Firebase Cloud Messaging (via
// freizone-gateway, see ../../../freizone-gateway). Which one a given
// account registers is controlled by AppSettings.pushPreference, not by
// which one(s) happen to be installed/available on the device -- see
// registerForPush. The wake payload the server/gateway sends carries no
// content or metadata whatsoever (see docs/PROTOCOL.md in
// freizone-server) -- not even which of several reasons triggered it --
// so every wake reacts identically: a silent background sync (fetch +
// decrypt any queued messages, top up the one-time-prekey pool if it's
// running low, see _syncAndMaybeNotify) that only shows a system
// notification if a genuine new message actually turned up. This is what
// lets the exact same wake also serve a purely-housekeeping reason (the
// prekey pool running low on a rarely-opened device, see
// app_session.dart's topUpOneTimePrekeysIfNeeded) without ever showing a
// misleading "New message(s)" for nothing.
//
// Both mechanisms can relaunch this app's Dart entrypoint in a
// background isolate to deliver a wake while the app isn't otherwise
// running (UnifiedPush via `--unifiedpush-bg`, FCM via its own
// plugin-internal background dispatch -- these are two distinct
// mechanisms, not the same one), so every callback below is a top-level
// function with no captured app/UI state -- each one loads whatever it
// needs directly from LocalStateStore/AppSettings.
import 'dart:async';
import 'dart:developer' as developer;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:unifiedpush/unifiedpush.dart';

import '../ffi/freizone_core.dart';
import '../net/api_client.dart';
import '../state/app_session.dart';
import '../state/app_settings.dart';
import '../state/local_state.dart';
import '../util/address_format.dart';
import 'notification_navigation.dart';

const _messagesChannelId = 'freizone_messages';

/// Fixed id for the generic FCM wake notification -- unlike UnifiedPush's
/// per-account notifications (see _notificationIdFor), FCM issues one
/// token per app install, not per account, so a wake can't be attributed
/// to a specific account (see registerForPush's doc comment). One shared
/// notification for "something needs syncing" is the honest UI for that.
const _fcmNotificationId = 0x46434d; // 'FCM' in hex, arbitrary but stable

final FlutterLocalNotificationsPlugin _notifications =
    FlutterLocalNotificationsPlugin();

/// One id per account, shared between showing and clearing its
/// notification so they always refer to the same one.
int _notificationIdFor(String instance) => instance.hashCode & 0x7fffffff;

/// Clears instance's "new message(s)" notification, if any is showing --
/// call once it has no more unread conversations, so the launcher icon's
/// badge (which Android derives from active notifications) goes away
/// again instead of lingering after the messages have been read.
Future<void> clearMessageNotification(String instance) =>
    _notifications.cancel(id: _notificationIdFor(instance));

/// Checks whether the app's current run was cold-started by tapping a
/// notification (rather than the launcher icon) -- call once, early,
/// from AppRoot after its AccountManager and notification-tap handler
/// (see notification_navigation.dart) are ready, since the normal
/// onDidReceiveNotificationResponse callback never fires for the launch
/// itself (there's no method channel yet at that point). Returns the
/// same payload showMessageNotification encoded, or null if the app
/// wasn't launched this way.
Future<String?> consumeLaunchNotificationPayload() async {
  final details = await _notifications.getNotificationAppLaunchDetails();
  if (details?.didNotificationLaunchApp ?? false) {
    return details!.notificationResponse?.payload;
  }
  return null;
}

/// Sets up UnifiedPush + Firebase + local-notification plumbing. Call
/// once, as early as possible (before runApp), so it also runs correctly
/// when either background-isolate variant starts up.
Future<void> initPush() async {
  await _notifications.initialize(
    // Bare drawable name, no "@mipmap/"/"@drawable/" prefix -- the
    // plugin's Android side resolves this via
    // getResources().getIdentifier(name, "drawable", package), which
    // takes the string literally and only ever looks under the
    // "drawable" resource type. ic_stat_notification (a monochrome
    // silhouette in android/app/src/main/res/drawable-*dpi/) is a
    // dedicated status-bar icon, not the full-color launcher mipmap --
    // Android extracts only the alpha channel of whatever icon a
    // notification uses for its small icon, so pointing this at
    // ic_launcher would (and did) render as a plain filled circle,
    // the launcher icon's silhouette.
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('ic_stat_notification'),
    ),
    // Fires when a notification this plugin showed is tapped while its
    // Dart isolate is still alive (foreground, or backgrounded but not
    // killed) -- see notification_navigation.dart for how this reaches
    // AppRoot. A tap that cold-launches the app instead goes through
    // consumeLaunchNotificationPayload(), since no method channel exists
    // yet at that point for this callback to fire over.
    onDidReceiveNotificationResponse: (response) =>
        handleNotificationPayload(response.payload),
  );
  await UnifiedPush.initialize(
    onNewEndpoint: _onNewEndpoint,
    onRegistrationFailed: _onRegistrationFailed,
    onUnregistered: _onUnregistered,
    onMessage: _onMessage,
    onTempUnavailable: _onTempUnavailable,
  );

  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);
  FirebaseMessaging.onMessage.listen(_onFcmMessage);
  FirebaseMessaging.instance.onTokenRefresh.listen(_onFcmTokenRefresh);
}

/// Requests the Android 13+ notification permission. Only ever called
/// from the foreground app (never a background isolate, which never
/// builds the UI that calls this) -- call once per app launch, not once
/// per account, since the permission is app-wide.
Future<void> requestNotificationPermission() async {
  await _notifications
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.requestNotificationsPermission();
}

/// Registers one account's device for push, per the current
/// [PushPreference] (see lib/state/app_settings.dart):
///
/// - `automatic` (default): prefer UnifiedPush if a distributor is
///   installed -- no Google dependency needed when the user already has
///   one. Falls back to FCM only if none is found, which is the whole
///   reason the FCM path exists at all.
/// - `forceFcm` / `forceUnifiedPush`: pin to one mechanism regardless of
///   what's installed, mainly so the other can be tested deliberately
///   (e.g. verifying the FCM path without uninstalling UnifiedPush/ntfy).
///   `forceUnifiedPush` does not silently fall back to FCM if no
///   distributor is found -- an explicit force shouldn't quietly do the
///   other thing.
///
/// Safe to call on every app start and again whenever the preference
/// changes (see AppSession.reregisterPush). Returns false only if no
/// mechanism could be registered at all -- the caller uses that to show
/// a one-time hint; chat keeps working via SSE either way.
Future<bool> registerForPush(
  ApiClient api,
  String instance,
  DeviceCredentials creds,
) async {
  final settings = await AppSettings.load();

  switch (settings.pushPreference) {
    case PushPreference.forceUnifiedPush:
      return _registerUnifiedPush(api, instance);
    case PushPreference.forceFcm:
      return _registerFcm(api, creds);
    case PushPreference.automatic:
      if (await _registerUnifiedPush(api, instance)) return true;
      return _registerFcm(api, creds);
  }
}

Future<bool> _registerUnifiedPush(ApiClient api, String instance) async {
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

Future<bool> _registerFcm(ApiClient api, DeviceCredentials creds) async {
  try {
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null) return false;
    await api.setPushTarget(creds: creds, platform: 'fcm', token: token);
    return true;
  } catch (e) {
    developer.log('registering fcm push target failed: $e', name: 'push');
    return false;
  }
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
  await _syncAndMaybeNotify(instance);
}

/// FCM's background-dispatch entrypoint: the plugin invokes this in its
/// own background isolate/Flutter engine, entirely separate from
/// UnifiedPush's `--unifiedpush-bg` relaunch of this app's own main() --
/// so Firebase needs its own initializeApp() call here too, since
/// nothing from a normal app start can be assumed to have run first.
@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await _syncAndMaybeNotify(null);
}

Future<void> _onFcmMessage(RemoteMessage message) async {
  await _syncAndMaybeNotify(null);
}

/// The single reaction to any wake, from either mechanism: fetch and
/// decrypt whatever's actually queued, top up prekeys if needed, and
/// only then decide whether to show anything. [instance], when known
/// (UnifiedPush always provides one), limits the sync to that one
/// account; null (FCM, which can't attribute a wake to a specific
/// account -- see registerForPush's doc comment) syncs every locally
/// stored profile instead, same iteration pattern as
/// _onFcmTokenRefresh.
Future<void> _syncAndMaybeNotify(String? instance) async {
  if (instance != null) {
    final state = await LocalStateStore.loadProfile(instance);
    if (state == null) return;
    final peerAccountId = await _syncProfile(state);
    if (peerAccountId != null) {
      await showMessageNotification(instance, peerAccountId: peerAccountId);
    }
    return;
  }

  // No per-account attribution possible here (see above) -- one shared
  // notification if ANY profile turned up a genuine message, same as
  // before this rework, just now actually confirmed rather than assumed.
  var anyGenuine = false;
  for (final state in await LocalStateStore.listProfiles()) {
    if (await _syncProfile(state) != null) anyGenuine = true;
  }
  if (anyGenuine) await showGenericWakeNotification();
}

/// Runs the same decrypt-and-store logic as AppSession._handleIncoming,
/// via the shared processIncomingMessage (app_session.dart), for a
/// profile that has no live AppSession -- fetches every message
/// currently queued for [state]'s device, processes each, and tops up
/// the one-time-prekey pool if it's running low (topUpOneTimePrekeysIfNeeded).
/// A single malformed/undecryptable message is logged and skipped rather
/// than aborting the rest of the sync. Returns the peer id of the last
/// genuinely new (non-request) message found, or null if none turned up
/// -- the caller's cue for whether to notify at all.
///
/// Deliberately does NOT send "delivered" receipts (see receipt_signal
/// .dart) for what it processes here -- that needs AppSession's sending
/// machinery (_encryptAndSend, _resolvePeerDevice, ...), none of which
/// exists as a standalone function callable without a live AppSession.
/// A message that arrives while the app is fully closed only starts
/// showing delivery/read checkmarks to its sender once the app is next
/// opened (AppSession._handleIncoming/enterConversation send both).
Future<String?> _syncProfile(AppState state) async {
  final core = FreizoneCore();
  final api = ApiClient(baseUrl: state.server, core: core);
  String? notifyPeerAccountId;
  try {
    final messages = await api.listMessages(state.credentials);
    var changed = false;
    for (final msg in messages) {
      try {
        final result = await processIncomingMessage(state, msg, core);
        if (result == null) continue;
        changed = true;
        if (result.shouldNotify) notifyPeerAccountId = result.peerAccountId;
        unawaited(api.deleteMessage(msg.messageId, state.credentials));
      } catch (e) {
        developer.log('background message decrypt failed: $e', name: 'push');
      }
    }
    if (changed) await LocalStateStore.saveProfile(state);

    try {
      await topUpOneTimePrekeysIfNeeded(state, core, api);
    } catch (e) {
      developer.log('background prekey top-up failed: $e', name: 'push');
    }
  } catch (e) {
    developer.log('background sync failed: $e', name: 'push');
  } finally {
    api.close();
  }
  return notifyPeerAccountId;
}

/// FCM tokens rotate occasionally; re-push the fresh one to every
/// account currently relying on FCM for its wake -- there's no
/// per-account FCM token to update individually (see registerForPush's
/// doc comment), so this re-derives "is this account using FCM right
/// now" the same way registerForPush decides it in the first place,
/// rather than tracking that separately.
Future<void> _onFcmTokenRefresh(String newToken) async {
  final settings = await AppSettings.load();
  if (settings.pushPreference == PushPreference.forceUnifiedPush) return;

  for (final state in await LocalStateStore.listProfiles()) {
    if (settings.pushPreference == PushPreference.automatic &&
        await UnifiedPush.tryUseCurrentOrDefaultDistributor()) {
      continue; // this account would register UnifiedPush, not FCM
    }
    final api = ApiClient(baseUrl: state.server, core: FreizoneCore());
    try {
      await api.setPushTarget(
        creds: state.credentials,
        platform: 'fcm',
        token: newToken,
      );
    } catch (e) {
      developer.log('updating fcm push target failed: $e', name: 'push');
    } finally {
      api.close();
    }
  }
}

/// Shows (or updates, if one's already up) instance's "new message(s)"
/// notification -- which is also what makes Android show a badge on the
/// launcher icon, since that's derived from active notifications, not
/// from anything drawn inside the app. Called both from a confirmed-
/// genuine background sync (_syncAndMaybeNotify) and live, from
/// AppSession._handleIncoming, whenever a message actually becomes
/// unread while the app is in the foreground -- the badge needs to
/// reflect unread state regardless of whether the app happened to be
/// open when the message arrived. Never called speculatively -- by the
/// time either path calls this, a message has actually been decrypted
/// and confirmed worth surfacing.
///
/// [peerAccountId] lets tapping the notification jump straight to that
/// conversation instead of just switching to the right account -- see
/// notification_navigation.dart.
Future<void> showMessageNotification(
  String instance, {
  String? peerAccountId,
}) async {
  // instance is the waking account's own id -- purely local information
  // (never sent anywhere), so it's safe to show in the notification body
  // to say which of the user's own accounts it's for. Also used as the
  // notification id so two accounts overlap into
  // one update, not a stack of duplicates, and so clearMessageNotification
  // cancels the right one.
  final body = 'New message(s) for ${formatAccountIdForDisplay(instance)}';
  await _show(
    id: _notificationIdFor(instance),
    body: body,
    payload: encodeNotificationPayload(
      accountId: instance,
      peerAccountId: peerAccountId,
    ),
  );
}

/// The FCM counterpart to [showMessageNotification]: shown when a wake
/// arrives with no way to know which account it was for (see
/// registerForPush's doc comment on FCM's one-token-per-install model),
/// so the text can't name a specific account the way UnifiedPush's can --
/// nor, therefore, is there anything to encode into a tap payload.
Future<void> showGenericWakeNotification() =>
    _show(id: _fcmNotificationId, body: 'New message(s)');

Future<void> _show({
  required int id,
  required String body,
  String? payload,
}) async {
  // Loaded fresh each time, same reasoning as above: this can run in a
  // background isolate, so nothing from a live AppSettings instance can
  // be captured/injected here.
  final settings = await AppSettings.load();

  await _notifications.show(
    id: id,
    title: 'Freizone',
    body: body,
    payload: payload,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        _messagesChannelId,
        'Messages',
        channelDescription:
            'Notifies about new messages while the app is closed',
        importance: Importance.high,
        priority: Priority.high,
        playSound: settings.notificationSound,
        enableVibration: settings.notificationVibration,
      ),
    ),
  );
}
