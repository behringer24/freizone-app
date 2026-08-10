// Wires two independent, non-interfering push-wake mechanisms to a
// generic "you have mail" system notification: UnifiedPush (self-hosted,
// no Google dependency) and Firebase Cloud Messaging (via
// freizone-gateway, see ../../../freizone-gateway). Which one a given
// account registers is controlled by AppSettings.pushPreference, not by
// which one(s) happen to be installed/available on the device -- see
// registerForPush. The wake payload the server/gateway sends carries no
// content or metadata whatsoever (see docs/PROTOCOL.md in
// freizone-server) -- not even which of several reasons triggered it --
// so every wake reacts identically: a silent background sync through the
// shared client core (fetch, decrypt/fold and acknowledge whatever is
// queued, top up the one-time-prekey pool and settle other housekeeping if
// it's running low -- see _syncAccount, native/client.go's doCoreSync) that
// only shows a system notification if a genuine new message actually turned
// up. This is what lets the exact same wake also serve a purely-housekeeping
// reason (the prekey pool running low on a rarely-opened device) without
// ever showing a misleading "New message(s)" for nothing.
//
// _syncAccount deliberately shares its receive path with the live stream's
// poll loop (SRV-23, the cut) rather than running a second implementation --
// see doCoreSync's own doc comment for why that used to be a real desync
// risk, not just duplicated code.
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
import 'dart:isolate';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:unifiedpush/unifiedpush.dart';

import '../ffi/freizone_core.dart';
import '../net/api_client.dart';
import '../net/core_stream.dart';
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
///
/// Deliberately NOT util/log.dart's [logDiagnostic], which is otherwise the
/// same idea: that one prints only in a debug build, and this path's whole
/// problem is a wake failing on a release build on somebody's actual phone.
/// The lines here are kept free of message content for that reason -- what
/// they say is that a wake arrived and what went wrong with it, never what it
/// was about.
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
    final notice = await _syncAccount(accountId);
    if (notice != null) {
      await showMessageNotification(
        accountId,
        peerAccountId: notice.peerAccountId,
        groupId: notice.groupId,
        invitation: notice.invitation,
      );
      _log(
        'wake notified $accountId '
        '(${notice.groupId ?? notice.peerAccountId})',
      );
    }
  }
}

/// What a wake found worth telling the user about: null when nothing was, and
/// otherwise which chat to jump to on tap -- either a one-to-one
/// [peerAccountId] or a [groupId], never both, since the two open different
/// screens -- and whether what turned up was a group invitation rather than a
/// message. Not just a peer id, because a group envelope is notify-worthy
/// while having no one-to-one conversation to point at.
typedef _WakeNotice = ({
  String? peerAccountId,
  String? groupId,
  bool invitation,
});

/// Opens [accountId]'s handle into the shared client core and drains
/// whatever is queued for it the same way the live stream's poll loop does
/// (SRV-23, the cut) -- see native/client.go's doCoreSync, which shares its
/// HandleIncoming-then-ack-then-receipt path with the live poll loop
/// (handleAndAck) rather than running a second implementation. That sharing
/// is the point: a message decrypted by a *different* pipeline while the app
/// was backgrounded used to be able to advance a session the live path's own
/// core never saw, a real desync waiting to happen every time a push arrived
/// while the app was closed.
///
/// [LocalStateStore.loadProfile] is only an identity bootstrap now -- server,
/// device keys, the signed prekey this device has published -- the same
/// fields AppSession.init hands the core, and the only ones this file still
/// reads, since nothing writes conversation or session state to that file
/// any more. Returns the last genuinely notify-worthy outcome, or null --
/// the caller's cue for whether to notify at all.
Future<_WakeNotice?> _syncAccount(String accountId) async {
  final identity = await LocalStateStore.loadProfile(accountId);
  if (identity == null) return null;

  // Resolved out here, before the isolate: coreStatePath goes through
  // path_provider, and a plain Isolate.run isolate has no platform channels.
  final statePath = await coreStatePath(accountId);
  try {
    final raw = await Isolate.run(
      () => _wakeSyncInIsolate(
        statePath,
        _identityArgs(identity),
      ),
    );
    for (final problem in (raw['problems'] as List<dynamic>? ?? const [])) {
      // Best-effort housekeeping (prekey top-up, group snapshot debts,
      // session recovery -- see doCoreMaintain) that did not work; one part
      // failing must not stop the messages that were fetched from being
      // handled, and did not.
      _log('wake sync $accountId: housekeeping problem: $problem');
    }
    final outcomes = ((raw['outcomes'] as List<dynamic>?) ?? const [])
        .map((o) => PollOutcome.fromJson(o as Map<String, dynamic>))
        .where((o) => o.chatId.isNotEmpty)
        .toList();
    _log('wake sync $accountId: ${outcomes.length} outcome(s)');

    _WakeNotice? notice;
    for (final outcome in outcomes) {
      if (!outcome.notify) continue;
      // A group envelope points at the group, never at a one-to-one chat
      // with whoever happened to send it.
      notice = (
        peerAccountId: outcome.isGroup ? null : outcome.chatId,
        groupId: outcome.isGroup ? outcome.chatId : null,
        invitation: outcome.invitation,
      );
    }
    return notice;
  } catch (e) {
    _log('background sync failed for $accountId: $e');
    return null;
  }
}

/// The identity fields [_wakeSyncInIsolate] needs, as plain sendable values.
///
/// Spelled out rather than sending the AppState itself: only these are the
/// core's business (it keeps its own copy of everything else), and an explicit
/// map cannot start failing to cross the boundary because something
/// unsendable was added to AppState later.
Map<String, dynamic> _identityArgs(AppState identity) => {
  'account_id': identity.accountId,
  'server': identity.server,
  'root_pub': identity.rootPub,
  'root_priv': identity.rootPriv,
  'device_id': identity.deviceId,
  'device_pub': identity.devicePub,
  'device_priv': identity.devicePriv,
  'dh_identity_pub': identity.dhIdentityPub,
  'dh_identity_priv': identity.dhIdentityPriv,
  'signed_prekey_id': identity.signedPrekeyId,
  'signed_prekey_pub': identity.signedPrekeyPub,
  'signed_prekey_priv': identity.signedPrekeyPriv,
  'next_signed_prekey_id': identity.nextSignedPrekeyId,
  'next_otpk_key_id': identity.nextOtpkKeyId,
  'recovery_backup_done': identity.recoveryBackupDone,
  'push_mechanism': identity.pushMechanism,
};

/// One account's whole wake sync, start to finish, off whichever thread asked.
///
/// This has to run in an isolate, and for a while it did not: a wake that
/// arrives while the app is in the *foreground* is delivered by FCM on the
/// main isolate (see the onMessage listener in initPush), and every call in
/// here is a synchronous FFI call -- doCoreSync fetches the queue over the
/// network. So a foreground wake blocked the UI thread for as long as the
/// fetch took, once per account, sequentially: on a device holding an account
/// whose server is simply unreachable that is the full request deadline, and
/// Android kills an app that ignores input for five seconds. Measured at
/// 29.5s of one MotionEvent going unanswered before this moved here.
///
/// Top-level and taking only plain values, because an isolate entry point
/// cannot capture a [FreizoneCore] -- it holds native pointers. The handle is
/// opened and closed inside, so nothing native outlives the isolate either.
Map<String, dynamic> _wakeSyncInIsolate(
  String statePath,
  Map<String, dynamic> identity,
) {
  final core = FreizoneCore();
  final handle = core.coreOpen(statePath);
  try {
    core.coreSetIdentity(
      handle: handle,
      accountId: identity['account_id'] as String,
      server: identity['server'] as String,
      rootPub: identity['root_pub'] as Uint8List,
      rootPriv: identity['root_priv'] as Uint8List,
      deviceId: identity['device_id'] as String,
      devicePub: identity['device_pub'] as Uint8List,
      devicePriv: identity['device_priv'] as Uint8List,
      dhIdentityPub: identity['dh_identity_pub'] as Uint8List?,
      dhIdentityPriv: identity['dh_identity_priv'] as Uint8List?,
      signedPrekeyId: identity['signed_prekey_id'] as int,
      signedPrekeyPub: identity['signed_prekey_pub'] as Uint8List?,
      signedPrekeyPriv: identity['signed_prekey_priv'] as Uint8List?,
      nextSignedPrekeyId: identity['next_signed_prekey_id'] as int,
      nextOtpkKeyId: identity['next_otpk_key_id'] as int,
      recoveryBackupDone: identity['recovery_backup_done'] as bool,
      pushMechanism: identity['push_mechanism'] as String?,
    );
    return core.coreSyncRaw({'handle': handle});
  } finally {
    core.coreClose(handle);
  }
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
/// [peerAccountId] (a one-to-one conversation) or [groupId] (a group) lets
/// tapping the notification jump straight to that chat instead of just
/// switching to the right account -- see notification_navigation.dart. They
/// are separate parameters rather than one id plus a flag because a caller
/// always knows which of the two it has, and the two open different screens.
///
/// [invitation] only changes the wording: a group invitation is the one
/// non-message thing worth surfacing (see group_receive.dart's
/// applyGroupControl), and "new message(s)" would send the user looking for a
/// message that isn't there. It deliberately shares this account's single
/// notification id with messages, so an account never stacks up two
/// notifications and clearMessageNotification still clears everything.
Future<void> showMessageNotification(
  String instance, {
  String? peerAccountId,
  String? groupId,
  bool invitation = false,
}) async {
  // instance is the waking account's own id -- purely local information
  // (never sent anywhere), so it's safe to show in the notification body
  // to say which of the user's own accounts it's for. Also used as the
  // notification id so two accounts overlap into
  // one update, not a stack of duplicates, and so clearMessageNotification
  // cancels the right one.
  final what = invitation ? 'Group invitation' : 'New message(s)';
  final body = '$what for ${formatAccountIdForDisplay(instance)}';
  await _show(
    id: _notificationIdFor(instance),
    body: body,
    payload: encodeNotificationPayload(
      accountId: instance,
      peerAccountId: peerAccountId,
      groupId: groupId,
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
