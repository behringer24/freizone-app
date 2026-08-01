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
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:unifiedpush/unifiedpush.dart';

import '../ffi/freizone_core.dart';
import '../ffi/freizone_core_exception.dart';
import '../net/api_client.dart';
import '../net/dto.dart';
import '../state/app_session.dart';
import '../state/app_settings.dart';
import '../state/local_state.dart';
import '../util/address_format.dart';
import 'notification_navigation.dart';

const _messagesChannelId = 'freizone_messages';

/// Logs a push-path diagnostic to BOTH the VM service and stdout.
///
/// Everything in this file can run in a background isolate (FCM's own
/// dispatch isolate, UnifiedPush's `--unifiedpush-bg` relaunch), where
/// nothing is attached to the VM service -- so [developer.log] alone goes
/// nowhere and a wake that fails silently is undiagnosable on a real
/// device. print() reaches logcat as `I/flutter`, which is the only
/// channel that survives a background wake, so failures on this path are
/// deliberately logged there too rather than only to the debugger.
void _log(String message) {
  developer.log(message, name: 'push');
  // ignore: avoid_print
  print('[freizone/push] $message');
}

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

/// Dart entrypoint for the background engine the platform side starts when
/// FCM hands us a refreshed token while the app is closed (APP-12).
///
/// Why this has to exist at all: `firebase_messaging`'s own
/// `FlutterFirebaseMessagingService.onNewToken` only does
/// `FlutterFirebaseTokenLiveData.postToken(token)` -- an **in-process
/// LiveData**. With no live Flutter engine observing it the new token goes
/// nowhere and is never persisted, and the plugin offers no background hook for
/// tokens the way it does for messages (`onBackgroundMessage`). So the server
/// keeps the stale token until the user happens to open the app: the gateway's
/// send comes back UNREGISTERED, freizone-server drops the push target, and no
/// wake arrives again -- which the user has no reason to fix, because nothing
/// is notifying them.
///
/// Deliberately does NOT call [initPush]: nothing here shows a notification or
/// needs UnifiedPush callbacks wired up, and doing so in a throwaway engine
/// would register handlers that are torn down moments later. It reads the new
/// token via getToken() rather than taking it as an argument, so it always
/// registers whatever is current even if several refreshes coalesced.
@pragma('vm:entry-point')
Future<void> pushTokenRefreshEntrypoint() async {
  WidgetsFlutterBinding.ensureInitialized();
  _log('background token-refresh engine started');
  try {
    await Firebase.initializeApp();
    await reregisterAllProfiles();
  } catch (e) {
    _log('background token refresh failed: $e');
  } finally {
    // Tells the platform side the engine may be torn down. Without this the
    // engine would be destroyed while this work was still in flight, or leak.
    try {
      await const MethodChannel(
        'freizone/push_token_refresh',
      ).invokeMethod('done');
    } catch (_) {
      // Nothing useful to do -- the platform side has its own timeout.
    }
  }
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

/// Outcome of a push registration attempt (see [registerForPush]). Lets the
/// UI tell apart "all good", "you need to pick a UnifiedPush distributor"
/// and "nothing worked at all" -- the last two warrant different one-time
/// hints (choose one in Settings vs. install a distributor / switch to FCM).
enum PushRegistration { registered, needsDistributorChoice, unavailable }

/// Which mechanism the app-wide preference and this device actually resolve
/// to, independent of any one account (APP-12).
///
/// This is deliberately a *device* fact, not a per-account one: the preference
/// lives in AppSettings, the chosen distributor is persisted by the UnifiedPush
/// plugin for the whole app, and the FCM token is one per install. Resolving it
/// once and passing it down is what keeps [registerForPush] from re-asking the
/// same device-wide question inside a per-account loop -- which it used to do,
/// harmlessly but confusingly.
enum PushMechanism {
  unifiedPush,
  fcm,

  /// UnifiedPush is wanted but several distributors are installed and none is
  /// chosen yet -- the user has to pick, so nothing can be registered.
  needsDistributorChoice,

  /// Nothing is available: no distributor and either no FCM or FCM ruled out.
  none,
}

/// Resolves the app-wide mechanism once. Call this before a loop over
/// accounts, not inside it.
Future<PushMechanism> resolvePushMechanism() async {
  final settings = await AppSettings.load();
  switch (settings.pushPreference) {
    case PushPreference.forceFcm:
      return PushMechanism.fcm;
    case PushPreference.forceUnifiedPush:
    case PushPreference.automatic:
      final distributor = await UnifiedPush.getDistributor();
      if (distributor != null && distributor.isNotEmpty) {
        return PushMechanism.unifiedPush;
      }
      final available = await UnifiedPush.getDistributors();
      // Exactly one installed and none chosen yet is the common case, and
      // picking it needs no interaction -- see _registerUnifiedPush.
      if (available.length == 1) return PushMechanism.unifiedPush;
      if (available.length > 1) {
        return settings.pushPreference == PushPreference.forceUnifiedPush
            ? PushMechanism.needsDistributorChoice
            // In automatic, an unanswered distributor choice is not a dead end:
            // FCM still gets a chance below.
            : PushMechanism.fcm;
      }
      return settings.pushPreference == PushPreference.forceUnifiedPush
          ? PushMechanism.none
          : PushMechanism.fcm;
  }
}

/// Registers one account's device for push, per the current
/// [PushPreference] (see lib/state/app_settings.dart):
///
/// - `automatic` (default): prefer UnifiedPush if a distributor is
///   available, else fall back to FCM. With exactly one distributor
///   installed and none chosen yet, that one is selected automatically so
///   the common case needs no interaction.
/// - `forceUnifiedPush`: UnifiedPush only, never FCM. With several
///   distributors installed and none chosen yet, returns
///   [PushRegistration.needsDistributorChoice] so the UI can prompt rather
///   than pick one silently.
/// - `forceFcm`: FCM only, ignoring any installed distributor.
///
/// Safe to call on every app start, on every SSE reconnect, and whenever the
/// preference or chosen distributor changes (see AppSession.reregisterPush).
/// [mechanism] lets a caller that already resolved it (a loop over several
/// accounts, see [resolvePushMechanism]) avoid re-asking the same device-wide
/// question per account. Omitted, it is resolved here.
Future<PushRegistration> registerForPush(
  ApiClient api,
  String instance,
  DeviceCredentials creds, {
  PushMechanism? mechanism,
}) async {
  final resolved = mechanism ?? await resolvePushMechanism();

  switch (resolved) {
    case PushMechanism.needsDistributorChoice:
      return PushRegistration.needsDistributorChoice;
    case PushMechanism.none:
      return PushRegistration.unavailable;
    case PushMechanism.fcm:
      return (await _registerFcm(api, creds))
          ? PushRegistration.registered
          : PushRegistration.unavailable;
    case PushMechanism.unifiedPush:
      final viaUnifiedPush = await _registerUnifiedPush(api, instance);
      if (viaUnifiedPush == PushRegistration.registered) return viaUnifiedPush;
      // Prefer UnifiedPush but don't get stuck on it: with the preference on
      // automatic, fall back to FCM and only surface UnifiedPush's own reason
      // if FCM fails too. Forced UnifiedPush never reaches this, since
      // resolvePushMechanism would not have returned unifiedPush.
      final settings = await AppSettings.load();
      if (settings.pushPreference != PushPreference.forceUnifiedPush &&
          await _registerFcm(api, creds)) {
        return PushRegistration.registered;
      }
      return viaUnifiedPush;
  }
}

/// A friendly name for the common UnifiedPush distributors, falling back to the
/// package id for anything else (resolving the real app label would need a
/// PackageManager round-trip we don't otherwise take).
///
/// Shared rather than private to the settings tile, so the distributor is named
/// identically wherever it appears (Settings, the push status screen).
String describeDistributor(String pkg) => switch (pkg) {
  'io.heckel.ntfy' => 'ntfy',
  'org.unifiedpush.distributor.nextpush' => 'NextPush',
  'org.unifiedpush.distributor.fcm' => 'Embedded (FCM-backed)',
  _ => pkg,
};

/// The label stored in [AppState.pushMechanism] -- what the diagnostics screen
/// shows, so it has to name the distributor too, not just the family.
Future<String> pushMechanismLabel(PushMechanism mechanism) async {
  switch (mechanism) {
    case PushMechanism.fcm:
      return 'fcm';
    case PushMechanism.unifiedPush:
      final distributor = await UnifiedPush.getDistributor();
      return 'unifiedpush:${distributor ?? ''}';
    case PushMechanism.needsDistributorChoice:
      return 'none:needs-distributor-choice';
    case PushMechanism.none:
      return 'none';
  }
}

/// Registers via UnifiedPush. Auto-selects the sole installed distributor
/// when none has been chosen yet; with several installed and none chosen,
/// returns [PushRegistration.needsDistributorChoice] rather than picking one
/// silently -- which distributor sees the (metadata-only) push wake is the
/// user's call. The chosen distributor is persisted by the plugin, so this
/// stays stable across launches.
Future<PushRegistration> _registerUnifiedPush(
  ApiClient api,
  String instance,
) async {
  var distributor = await UnifiedPush.getDistributor();
  if (distributor == null || distributor.isEmpty) {
    final available = await UnifiedPush.getDistributors();
    if (available.isEmpty) return PushRegistration.unavailable;
    if (available.length > 1) return PushRegistration.needsDistributorChoice;
    distributor = available.first;
    await UnifiedPush.saveDistributor(distributor);
  }

  String? vapidKey;
  try {
    vapidKey = await api.getVAPIDPublicKey();
  } catch (e) {
    _log('fetching vapid public key failed: $e');
  }
  await UnifiedPush.register(instance: instance, vapid: vapidKey);
  return PushRegistration.registered;
}

Future<bool> _registerFcm(ApiClient api, DeviceCredentials creds) async {
  try {
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null) return false;
    await api.setPushTarget(creds: creds, platform: 'fcm', token: token);
    return true;
  } catch (e) {
    _log('registering fcm push target failed: $e');
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
    _log('registering push endpoint failed: $e');
  } finally {
    api.close();
  }
}

Future<void> _onRegistrationFailed(FailedReason reason, String instance) async {
  _log('push registration failed: $reason');
}

Future<void> _onUnregistered(String instance) async {
  final state = await LocalStateStore.loadProfile(instance);
  if (state == null) return;

  final api = ApiClient(baseUrl: state.server, core: FreizoneCore());
  try {
    await api.clearPushEndpoint(state.credentials);
  } catch (e) {
    _log('clearing push endpoint failed: $e');
  } finally {
    api.close();
  }
}

Future<void> _onTempUnavailable(String instance) async {
  _log('push distributor temporarily unavailable');
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
/// account; null (FCM, whose one-token-per-install model can't attribute
/// the *wake* to a specific account -- see registerForPush's doc comment)
/// syncs every locally stored profile instead, same iteration pattern as
/// _onFcmTokenRefresh.
///
/// Either way the notification itself is per-account: FCM's missing
/// attribution applies only to the incoming wake, and by the time a
/// profile has been synced we know exactly which account received what.
/// So both paths notify identically, naming the account and carrying the
/// peer id for tap-navigation -- an FCM wake for several accounts at once
/// simply produces one notification each (distinct ids, see
/// _notificationIdFor), rather than a single unattributed "New message(s)".
Future<void> _syncAndMaybeNotify(String? instance) async {
  final accountIds = instance != null
      ? [instance]
      : await LocalStateStore.listProfileIds();

  _log('wake received (${instance ?? 'fcm/all'}): ${accountIds.length} profile(s)');
  for (final accountId in accountIds) {
    // Load, decrypt and save as one locked unit, per account. Loading up
    // front and saving much later is what let the foreground isolate slip in
    // between and revert the ratchet -- and with several accounts, each
    // profile's snapshot aged through every preceding account's network sync
    // before finally being written back over whatever had changed since.
    final peerAccountId = await LocalStateStore.withProfileLock(accountId, () async {
      final state = await LocalStateStore.loadProfile(accountId);
      if (state == null) return null;
      return _syncProfile(state);
    });
    if (peerAccountId != null) {
      await showMessageNotification(accountId, peerAccountId: peerAccountId);
      _log('wake notified $accountId (peer $peerAccountId)');
    }
  }
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
/// Counts one failed attempt at [msg] and reports whether it should now be
/// dropped from the server queue -- the wake-side twin of
/// AppSession._giveUpOnEnvelope, minus the recovery it can't perform.
///
/// A wake can *detect* a desynced session but not repair one: re-keying means
/// sending, and none of AppSession's send machinery exists without a live
/// session (see this function's caller). So the evidence is recorded into the
/// profile and left there; the next AppSession to come up acts on it
/// (AppSession._recoverDesyncedSessions, on stream connect). This is exactly why
/// PeerSessionHealth is persisted rather than held in memory.
bool _giveUpOnEnvelope(
  AppState state,
  MessageResponse msg, {
  required bool isDesyncEvidence,
}) {
  if (!state.recordDecryptFailure(msg.messageId)) return false;
  if (isDesyncEvidence) {
    state.recordDesyncEvidence(msg.senderAccountId, DateTime.now().toUtc());
  }
  return true;
}

Future<String?> _syncProfile(AppState state) async {
  final core = FreizoneCore();
  final api = ApiClient(baseUrl: state.server, core: core);
  String? notifyPeerAccountId;
  try {
    final messages = await api.listMessages(state.credentials);
    _log('wake sync ${state.accountId}: ${messages.length} queued');
    var changed = false;
    // Collected and awaited together below rather than fired off and
    // forgotten: a delete that silently failed left the message queued, to be
    // fetched and decrypted again on the next wake.
    final deletions = <Future<void>>[];
    for (final msg in messages) {
      try {
        final result = await processIncomingMessage(state, msg, core);
        if (result == null) {
          // Can't be processed: no session for this sender and no X3DH
          // initial to start one (see processIncomingMessage). Count it --
          // once it has failed enough times it is dropped, since it will
          // never become decryptable and would otherwise be re-fetched on
          // every wake for as long as the server keeps it.
          changed = true;
          if (_giveUpOnEnvelope(state, msg, isDesyncEvidence: true)) {
            _log('wake sync ${state.accountId}: giving up on a message');
            deletions.add(api.deleteMessage(msg.messageId, state.credentials));
          } else {
            _log('wake sync ${state.accountId}: unprocessable, will retry');
          }
          continue;
        }
        changed = true;
        if (result.shouldNotify) notifyPeerAccountId = result.peerAccountId;
        deletions.add(api.deleteMessage(msg.messageId, state.credentials));
      } catch (e) {
        _log('background message decrypt failed: $e');
        changed = true;
        if (_giveUpOnEnvelope(
          state,
          msg,
          isDesyncEvidence: e is FreizoneCoreException && e.suggestsDesync,
        )) {
          _log('wake sync ${state.accountId}: giving up after repeated failures');
          deletions.add(api.deleteMessage(msg.messageId, state.credentials));
        }
      }
    }
    // Before saving, so a delete that fails leaves the failure count on disk
    // and the message is retried rather than silently forgotten.
    for (final deletion in deletions) {
      try {
        await deletion;
      } catch (e) {
        _log('deleting a processed message failed: $e');
      }
    }
    if (changed) await LocalStateStore.saveProfile(state);

    try {
      await topUpOneTimePrekeysIfNeeded(state, core, api);
    } catch (e) {
      _log('background prekey top-up failed: $e');
    }
  } catch (e) {
    _log('background sync failed: $e');
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
  // Resolved once, outside the loop: which mechanism applies is a device-wide
  // fact (see resolvePushMechanism), so asking per account only obscured that.
  final mechanism = await resolvePushMechanism();
  if (mechanism != PushMechanism.fcm) {
    _log('fcm token refreshed but mechanism is $mechanism -- nothing to do');
    return;
  }
  final label = await pushMechanismLabel(mechanism);

  for (final state in await LocalStateStore.listProfiles()) {
    final api = ApiClient(baseUrl: state.server, core: FreizoneCore());
    try {
      await api.setPushTarget(
        creds: state.credentials,
        platform: 'fcm',
        token: newToken,
      );
      // Recorded per account under the profile lock, since this can run in the
      // background engine concurrently with a foreground save (APP-12/SRV-03).
      await LocalStateStore.withProfileLock(state.accountId, () async {
        final fresh = await LocalStateStore.loadProfile(state.accountId);
        if (fresh == null) return;
        fresh.pushRegisteredAt = DateTime.now().toUtc();
        fresh.pushMechanism = label;
        await LocalStateStore.saveProfile(fresh);
      });
      _log('fcm token refreshed for ${state.accountId}');
    } catch (e) {
      _log('updating fcm push target failed: $e');
    } finally {
      api.close();
    }
  }
}

/// Re-registers **every** locally stored account for push, resolving the
/// mechanism once. This is what the background engine runs after an FCM token
/// refresh arrives with the app closed (APP-12) -- see
/// [pushTokenRefreshEntrypoint].
Future<void> reregisterAllProfiles() async {
  final mechanism = await resolvePushMechanism();
  final label = await pushMechanismLabel(mechanism);
  _log('re-registering all profiles, mechanism=$mechanism');

  for (final state in await LocalStateStore.listProfiles()) {
    final api = ApiClient(baseUrl: state.server, core: FreizoneCore());
    try {
      final result = await registerForPush(
        api,
        state.accountId,
        state.credentials,
        mechanism: mechanism,
      );
      if (result != PushRegistration.registered) {
        _log('re-register ${state.accountId}: $result');
        continue;
      }
      await LocalStateStore.withProfileLock(state.accountId, () async {
        final fresh = await LocalStateStore.loadProfile(state.accountId);
        if (fresh == null) return;
        fresh.pushRegisteredAt = DateTime.now().toUtc();
        fresh.pushMechanism = label;
        await LocalStateStore.saveProfile(fresh);
      });
    } catch (e) {
      _log('re-register ${state.accountId} failed: $e');
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
