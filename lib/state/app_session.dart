// Owns everything that used to live inside a single ChatScreen: the Go
// core, the API client, one long-lived SSE stream, prekey upload, X3DH
// session establishment, and encrypt/decrypt -- for the lifetime of the
// app, independent of which screen is on screen. This is what lets the
// chat list update (new conversation, last-message preview, ordering)
// while a different conversation -- or no conversation -- is open,
// which a per-screen SSE connection cannot do.
//
// Deliberately a plain ChangeNotifier, not a state-management package:
// screens rebuild via ListenableBuilder, the same primitive already
// used everywhere else in this codebase.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../ffi/core_models.dart' show GroupInfo;
import '../ffi/freizone_core.dart';
import '../ffi/models.dart';
import '../net/api_client.dart';
import '../net/dto.dart';
import '../net/core_stream.dart';
import '../push/push_manager.dart';
import '../util/address_format.dart';
import '../util/errors.dart';
import '../util/log.dart';
import '../util/freizone_address.dart';
import '../util/gallery.dart';
import '../util/server_url.dart';
import 'app_settings.dart';
import 'chat_target.dart';
import 'conversation.dart';
import 'core_account.dart';
import 'core_bridge.dart';
import 'group_conversation.dart';
import 'group_store.dart';
import 'group_system_lines.dart';
import 'media_store.dart';
import 'message_content.dart';
import 'outgoing_attachment.dart';
import 'local_state.dart';

/// The transcript marker for a secure session the user reset themselves --
/// shown on both sides (the resetting device writes it in
/// [AppSession.resetSecureSession], the peer when it accepts the re-key in
/// [processIncomingMessage]).
const String sessionResetMarker = 'Secure session was reset';

/// The same, for a session the app re-established on its own after repeated
/// undecryptable messages (SRV-03). Worded differently on purpose: the user
/// didn't do this, and shouldn't be left wondering what they pressed.
const String automaticRekeyMarker =
    'Secure session was re-established automatically';

/// Appends one batch of "what changed about this group" lines to a transcript,
/// one second apart.
///
/// A transcript renders in insertion order, so the offsets are not what keeps
/// these in sequence -- they keep the *timestamps* from being identical, since
/// several changes can land in one batch ("invited" before "joined" is not the
/// same story as the other way round) and identical stamps would make the day
/// dividers, and any future ordering by time, arbitrary.
void _appendGroupSystemLines(
  GroupConversation chat,
  List<String> lines, {
  required DateTime at,
}) {
  for (var i = 0; i < lines.length; i++) {
    chat.messages.add(
      StoredMessage.system(lines[i], at.add(Duration(seconds: i))),
    );
  }
  if (lines.isNotEmpty) chat.lastActivityAt = at;
}


/// Re-asserts [state]'s DH identity + signed-prekey certificates, using its
/// already-held key material, unchanged -- never rotates anything, and no
/// longer tops up the one-time-prekey pool itself (SRV-23: that raced
/// coreAccount.maintain()'s own top-up, see the call site). Called from
/// [AppSession.init] only now, so it must not assume anything beyond
/// [state]/[core]/[api] -- but no-ops before the very first prekey upload
/// (AppSession.init handles that separately, unconditionally, the one time
/// it's actually needed).
///
/// Re-sending the DH identity cert on every call, not just once at
/// registration, is deliberately defensive, not redundant: found in
/// production (see the qsvfg*chatcentral.de investigation) that a
/// device's server-stored DH identity signature can drift from what the
/// device actually holds -- likely stale data from an account/device
/// reset -- silently blocking every new contact's first session with it,
/// with no error ever surfaced to the device itself (a peer whose
/// session-start fails gets nothing back to report -- there is no
/// feedback channel for "your identity cert doesn't verify"). Re-signing
/// and re-uploading the SAME key material on every reconnect is cheap
/// (one GET plus one small POST) and self-heals that class of drift the
/// moment it happens, rather than needing a live incident to notice it.
Future<void> reassertPrekeyCertificates(
  AppState state,
  FreizoneCore core,
  ApiClient api,
) async {
  if (state.signedPrekeyPub == null) return;

  final now = DateTime.now().toUtc();
  final dhCert = core.signDHIdentityCertificate(
    accountId: state.accountId,
    deviceId: state.deviceId,
    dhPub: state.dhIdentityPub!,
    issuedAt: now,
    devicePriv: state.devicePriv,
  );
  // The upload endpoint always requires signed_prekey (it replaces
  // whatever's currently on file) -- re-sign the SAME existing key
  // material rather than generating a new one, so this stays purely a
  // re-assertion, not a rotation.
  final spkCert = core.signSignedPrekeyCertificate(
    accountId: state.accountId,
    deviceId: state.deviceId,
    keyId: state.signedPrekeyId,
    dhIdentityPub: state.dhIdentityPub!,
    prekeyPub: state.signedPrekeyPub!,
    issuedAt: now,
    devicePriv: state.devicePriv,
  );

  // One-time prekeys are no longer minted here (SRV-23, closing a gap the
  // cut left open): this ran on every reconnect right alongside
  // coreAccount.maintain(), which tops the pool up through
  // pkg/client.TopUpOneTimePrekeys -- two independent minters racing the
  // same server-side pool, each holding the private half of only the ones
  // it minted itself. Whichever key a new contact's claim happened to land
  // on, if it was one of *this* function's, the core had no private key for
  // it and every first message to this device failed outright
  // ("ratchet: initial message references one-time prekey N but no
  // matching private key was provided") -- deterministically, for as long
  // as this kept re-topping-up a pool the core already considered healthy.
  // Always pass an empty list: the upload endpoint accepts one (see the
  // no-op branch this replaces, which already sent one whenever the pool
  // wasn't low), and the DH-identity/signed-prekey re-assertion below is
  // this function's entire remaining job.
  await api.uploadPrekeys(
    creds: state.credentials,
    dhIdentityCert: DHIdentityCertDTO(
      dhPubKey: dhCert.dhPubKey,
      issuedAt: dhCert.issuedAt,
      signature: dhCert.signature,
    ),
    signedPrekey: SignedPrekeyDTO(
      keyId: spkCert.keyId,
      dhIdentityPubKey: spkCert.dhIdentityPubKey,
      pubKey: spkCert.prekeyPubKey,
      issuedAt: spkCert.issuedAt,
      signature: spkCert.signature,
    ),
    oneTimePrekeys: const <OneTimePrekeyDTO>[],
  );
}

/// Whether this session's own home server is currently reachable. Drives
/// the account switcher's offline marking and the chat composer's
/// send-disabled bar. Starts [connecting] (no attempt has resolved yet),
/// flips to [online] on a successful SSE connect and to [unreachable] when
/// a connect attempt fails -- see AppSession._startStream / init.
enum ServerReachability { connecting, online, unreachable }

class AppSession extends ChangeNotifier {
  /// [core] is only ever passed by a test. On a device the library is found by
  /// name, so the default is right; a host test has to hand over one opened
  /// from a path, because an isolate is told the same way (see
  /// FreizoneCore.libraryPath, and CoreAccount's construction in [init] --
  /// it passes this instance's path on) and by name it would find nothing.
  AppSession(this.state, {FreizoneCore? core})
    : core = core ?? FreizoneCore() {
    api = ApiClient(baseUrl: state.server, core: this.core);
  }

  final AppState state;
  final FreizoneCore core;
  late final ApiClient api;
  CoreStream? _sse;

  /// The shared client core's handle for this account (SRV-23, the cut) --
  /// opened once in [init], right after this account's identity is settled
  /// (a first run mints one during [_uploadPrekeys]), and closed in
  /// [dispose]. Everything the core owns -- state, persistence, the stream,
  /// every protocol decision -- lives behind this handle now: [_startStream]
  /// no longer opens one of its own, and every send, receive and group action
  /// below goes through it rather than through Dart's own crypto and
  /// [LocalStateStore]. Late because opening it needs this account's prekey
  /// material, which the very first run has not generated yet when this
  /// constructor runs.
  late final CoreAccount coreAccount;

  /// Additional ApiClients for federated peers, keyed by their (already
  /// normalized) server url -- lazily created and reused, since a
  /// conversation's peer server rarely changes. [api] itself stays the
  /// one used for anything on this session's own server.
  final Map<String, ApiClient> _peerApiClients = {};


  /// The ApiClient to use for a peer whose home server is [server] --
  /// this session's own [api] if null or the same server, otherwise a
  /// cached (or freshly created) client pointed at that server directly.
  /// See docs/PROTOCOL.md §9: federation is client-direct, not relayed
  /// through this session's own server.
  ApiClient _clientFor(String? server) {
    if (server == null || sameServer(server, state.server)) return api;
    return _peerApiClients.putIfAbsent(
      server,
      () => ApiClient(baseUrl: server, core: core),
    );
  }

  bool prekeysReady = false;

  /// The last thing that went wrong in this account, as one human-readable
  /// line, or null once something has gone right again.
  ///
  /// Shown by the chat list (see chat_list_screen's error banner). Until it was
  /// shown anywhere, this was written from a dozen places and read by none --
  /// so a swallowed delivery failure, a group fact that never went out, or a
  /// decrypt that gave up left no trace the user could see, and "it took a while
  /// until everyone saw each other" had no visible cause.
  ///
  /// Notifies on change, since a failure deep in an async path is exactly the
  /// kind that has no other reason to rebuild anything.
  String? get lastError => _lastError;
  set lastError(String? value) {
    if (_lastError == value) return;
    _lastError = value;
    notifyListeners();
  }

  String? _lastError;

  /// Records a failure: always to the log, and to [lastError] -- which the chat
  /// list shows until dismissed -- only when it is worth a human's attention.
  ///
  /// A server that cannot be reached right now is not. It is the single most
  /// common failure, it is retried automatically (the stream reconnects, the
  /// outbox and the snapshot debts flush), and it is *already* on screen: the
  /// account is dimmed with an offline badge. Turning each attempt into a red
  /// banner as well would train the user to dismiss the one thing that is
  /// supposed to mean "look at this" -- which is exactly what a stream connect
  /// timing out did.
  ///
  /// Anything else -- a refused request, a device revoked, a malformed answer,
  /// a decrypt given up on -- is surfaced: those do not fix themselves.
  void _noteFailure(String what, Object error) {
    final described = '$what: ${describeError(error)}';
    logDiagnostic(described, name: 'freizone');
    if (isServerUnreachable(error)) return;
    lastError = described;
  }

  /// Live reachability of this session's home server, kept current by the
  /// SSE reconnect loop (see [_startStream]). The UI treats [unreachable]
  /// as "read-only": the account stays selectable and its cached chats
  /// readable, but the composer is disabled (see chat_screen) and the
  /// switcher dims the avatar + shows an offline badge (see
  /// account_shell_screen). Recovers on its own -- when the server comes
  /// back, the next reconnect flips this to [online] and the UI follows.
  ServerReachability reachability = ServerReachability.connecting;

  /// How long a dropped-but-previously-online connection may spend
  /// reconnecting before the UI is told the server is [unreachable]. Covers
  /// the sub-second reconnect after a background resume or a brief blip (see
  /// the core's quick retry) without flickering the whole account grey.
  static const _reachabilityGrace = Duration(seconds: 2);
  Timer? _reachabilityGraceTimer;

  /// Result of the most recent push registration (see push_manager). The
  /// chat-list one-time hint uses this to tell "pick a distributor" apart
  /// from "nothing available".
  PushRegistration pushRegistration = PushRegistration.registered;

  /// Set when a fresh registration produced a non-registered result the UI
  /// hasn't surfaced yet; consumed by the chat list's one-time hint. Kept
  /// separate from [pushRegistration] so merely re-reading the status on a
  /// rebuild doesn't re-trigger the hint.
  bool pushHintPending = false;

  /// This device's own server role ("admin"/"moderator"), or null if it
  /// has neither -- in which case the admin area should be hidden
  /// entirely. Deliberately in-memory only (not persisted): re-derived
  /// from the server on every refresh so a promotion/demotion made
  /// elsewhere is picked up rather than trusting a stale local copy.
  String? myRole;

  /// The most recently fetched account list (admin/moderator only),
  /// cached so the admin screen has something to show immediately while
  /// a fresh fetch is in flight.
  List<AdminAccountSummary> adminAccounts = [];

  /// The server's current registration policy ("open"/"invite"/"closed"),
  /// fetched via the public GET /v1/server-status -- unlike [myRole]'s
  /// admin-only source, this works for every role, which is what lets a
  /// plain "user" account still see the Invite action on an open server.
  String? registrationPolicy;

  /// Whether this account's own home server currently accepts federation,
  /// from the public GET /v1/server-status. Defaults to true until first
  /// fetched. Because outbound federated messages go client-direct (never
  /// through this server), there is no send-time server signal for "my
  /// server turned federation off" -- this polled flag is the only source,
  /// so it drives both the outbound guard and the lock UI. See
  /// [federationLocked].
  bool federationEnabled = true;

  /// This account's own home server's attestation (SRV-19 / APP-22), decoded
  /// and verified inside [refreshRegistrationPolicy] alongside the
  /// registration policy and federation flag it already fetches from the
  /// same GET /v1/server-status call -- one more field read off a response
  /// already in hand, not a second request. Null means either no attestation
  /// is configured (the ordinary case for the overwhelming majority of
  /// servers) or one was configured but does not hold up -- both render
  /// identically: nothing. See docs/design/22-verified-badge.md.
  AttestationInfo? ownAttestation;

  /// This server's seat ceiling against its real active-account count
  /// (SRV-22, admin only) -- a separate signed request from
  /// [ownAttestation], never folded into the public server-status response
  /// it comes from: how many accounts a server has is attack-surface
  /// information, unlike anything the badge itself shows. Null until
  /// [refreshLicenseStatus] has run, or if it failed (e.g. this device is
  /// not an admin) -- the admin screen treats both as "nothing to warn
  /// about" rather than an error.
  LicenseStatus? licenseStatus;

  /// Refreshes [licenseStatus]. Admin only -- call after confirming
  /// [myRole] is "admin", the same gate the server itself enforces; a
  /// moderator calling this just gets a 403 and [licenseStatus] stays null,
  /// same as a failed fetch of anything else here.
  Future<void> refreshLicenseStatus() async {
    try {
      licenseStatus = await api.getLicenseStatus(state.credentials);
    } catch (e) {
      licenseStatus = null;
      _noteFailure('checking license status failed', e);
    }
  }

  /// This server's current size and load -- accounts, devices, stored
  /// attachments, disk usage, queued messages, federation status. Admin
  /// only, same gating and null-on-failure convention as [licenseStatus].
  ServerStats? serverStats;

  /// The same figures over time, for the admin statistics page's growth
  /// charts. Null until [refreshServerStatsHistory] has run (or if it
  /// failed); empty rather than null just means the server hasn't recorded
  /// a snapshot yet.
  List<ServerStatsPoint>? serverStatsHistory;

  /// Refreshes [serverStats]. Admin only -- call after confirming [myRole]
  /// is "admin", same as [refreshLicenseStatus].
  ///
  /// Deliberately quiet on failure, unlike most other refreshes here: an
  /// older server that predates this endpoint (404) is an expected, common
  /// case, not a "this server is having a problem" the banner should be
  /// spent on -- the admin stats screen already reads a null [serverStats]
  /// as "no statistics available" and says so right there.
  Future<void> refreshServerStats() async {
    try {
      serverStats = await api.getServerStats(state.credentials);
    } catch (e) {
      serverStats = null;
      logDiagnostic('checking server stats failed: ${describeError(e)}', name: 'freizone');
    }
  }

  /// Refreshes [serverStatsHistory] over the last [days] days. Admin only,
  /// same gating and quiet-failure reasoning as [refreshServerStats].
  Future<void> refreshServerStatsHistory({int days = 90}) async {
    try {
      serverStatsHistory = await api.getServerStatsHistory(
        state.credentials,
        days: days,
      );
    } catch (e) {
      serverStatsHistory = null;
      logDiagnostic(
        'checking server stats history failed: ${describeError(e)}',
        name: 'freizone',
      );
    }
  }

  /// Refreshes [registrationPolicy], [federationEnabled] and [ownAttestation]
  /// from the public server-status endpoint (one call covers all three).
  /// Call once after [init] and again whenever the app returns to the
  /// foreground, the SSE stream (re)connects, or the chat list / admin area
  /// is shown, so a change made elsewhere is picked up in time.
  Future<void> refreshRegistrationPolicy() async {
    try {
      final status = await api.getServerStatus();
      registrationPolicy = status.registrationPolicy;
      federationEnabled = status.federationEnabled;
      _ownBlobs = BlobCapability.from(status);
      // The attestation's domain is a bare hostname (FREIZONE_DOMAIN
      // server-side, no scheme/port); state.server carries the full
      // https://-prefixed URL used as the API base, so it must be parsed
      // down to just the host before comparing -- same reasoning as the web
      // landing page comparing against location.hostname, not the origin.
      ownAttestation = status.attestation == null
          ? null
          : core.verifyAttestation(
              status.attestation!,
              Uri.parse(state.server).host,
            );
    } catch (e) {
      _noteFailure('checking registration policy failed', e);
    }
    notifyListeners();
  }

  /// What our own home server will accept as an attachment. Null until the
  /// first [refreshRegistrationPolicy] answers.
  BlobCapability? _ownBlobs;

  /// Same, per federated peer server, keyed by its URL. A remote server's
  /// answer is cached for the session: it changes only when its operator
  /// reconfigures, and [blobCapabilityFor] re-asks whenever the cache is
  /// empty, so a restart or an account switch picks up a change.
  final Map<String, BlobCapability> _peerBlobs = {};

  /// Messages with a retry in flight right now.
  ///
  /// [flushOutbox] runs on reconnect *and* on resume, and the two can overlap;
  /// the delivery sheet's manual retry can land in the middle of either. The
  /// core refuses a second attempt at a message the first has just marked
  /// pending -- rightly, it cannot encrypt one message twice at once -- and
  /// that refusal used to reach the user as "send failed" for a send that was
  /// going perfectly well. An overlapping retry is the app talking to itself,
  /// so it is dropped here rather than reported.
  ///
  /// Per message, not a lock around the whole flush: two flushes working on
  /// different messages are doing useful work and must not be serialised.
  final Set<String> _retrying = {};

  /// How many times [flushOutbox] has retried each unsent message this run.
  ///
  /// A message can fail for a reason no amount of retrying fixes -- a peer
  /// whose server has federation switched off, a picture too large for it --
  /// and an automatic retry on every reconnect would then be an endless,
  /// invisible loop. After [_maxOutboxAttempts] the message stays failed and
  /// waits for the user, whose "tap to retry" is deliberately not counted
  /// here: asking for it again is a decision, not a loop.
  final Map<String, int> _outboxAttempts = {};
  static const int _maxOutboxAttempts = 3;

  /// What the server holding this conversation's attachments will accept.
  ///
  /// That is the RECIPIENT's server, not ours: a blob is uploaded to where
  /// the recipient can fetch it from (docs/PROTOCOL.md §10), so for a
  /// federated peer the remote operator's switch and size cap are the ones
  /// that count. Returns null while unknown -- callers treat that as "don't
  /// know yet" rather than "unsupported", so a slow status call doesn't
  /// flicker the attachment button off.
  Future<BlobCapability?> blobCapabilityFor(Conversation convo) =>
      blobCapabilityForServer(convo.peerServer);

  /// Same, for a server named directly rather than via a conversation -- what
  /// a group fan-out needs, since its recipients are spread over several
  /// servers and it has no conversation for most of them (APP-16).
  Future<BlobCapability?> blobCapabilityForServer(String? server) async {
    if (server == null) {
      if (_ownBlobs == null) await refreshRegistrationPolicy();
      return _ownBlobs;
    }
    final cached = _peerBlobs[server];
    if (cached != null) return cached;
    try {
      final status = await _clientFor(server).getServerStatus();
      final capability = BlobCapability.from(status);
      _peerBlobs[server] = capability;
      return capability;
    } catch (e) {
      // Unreachable or erroring: unknown, not unsupported. Sending will
      // surface the real failure rather than us pre-emptively lying about
      // what the peer's server supports.
      _noteFailure('checking attachment support failed', e);
      return null;
    }
  }

  /// Same, per federated peer server, keyed by its URL -- same session-only
  /// caching trade-off as [_peerBlobs]: a change is only picked up on
  /// restart, not mid-session, which is fine here since an attestation's
  /// validity window is measured in months, not minutes.
  final Map<String, AttestationInfo?> _peerAttestations = {};

  /// The attestation for [server], or for our own home server when null
  /// (equivalent to reading [ownAttestation] directly, once it has loaded).
  /// Null means either no attestation is configured or one was configured
  /// but does not hold up -- see [ownAttestation] on why both render
  /// identically: nothing, never a warning.
  Future<AttestationInfo?> attestationFor(String? server) async {
    if (server == null) {
      if (_ownBlobs == null) await refreshRegistrationPolicy();
      return ownAttestation;
    }
    final cached = _peerAttestations[server];
    if (cached != null || _peerAttestations.containsKey(server)) return cached;
    try {
      final status = await _clientFor(server).getServerStatus();
      // Same host-only comparison as ownAttestation's -- server here is
      // also the full https://-prefixed URL, not the bare domain the
      // attestation itself names.
      final info = status.attestation == null
          ? null
          : core.verifyAttestation(status.attestation!, Uri.parse(server).host);
      _peerAttestations[server] = info;
      return info;
    } catch (e) {
      // Unreachable or erroring: unknown, not "not attested" -- leave the
      // cache unset so the next call tries again, same as
      // [blobCapabilityForServer]'s identical failure handling.
      _noteFailure('checking server attestation failed', e);
      return null;
    }
  }

  /// A conversation is federation-locked when it lives on another server
  /// and this account's home server currently has federation disabled: the
  /// peer's replies would be blocked inbound, so we must not let the user
  /// keep sending into a dead end. Only sending is affected -- already
  /// received messages stay readable.
  bool federationLocked(Conversation convo) =>
      federationLockedFor(convo.peerServer);

  /// Whether we may send to a peer on [server] at all. A federated peer whose
  /// home server now has federation disabled is a dead end -- their replies
  /// would be blocked inbound -- so sending stops. Reading what already
  /// arrived is unaffected.
  ///
  /// Takes the server rather than a conversation, since a group member is
  /// subject to the same rule and may not have one.
  bool federationLockedFor(String? server) =>
      server != null && !federationEnabled;

  /// Refreshes [myRole] and [adminAccounts] from the server. A 403 means
  /// this device is neither admin nor moderator -- not an error, just
  /// the answer. Call once after [init] and again whenever the admin
  /// area is opened, so a role change elsewhere in the meantime is seen.
  Future<void> refreshMyRole() async {
    try {
      final accounts = await api.listAccounts(state.credentials);
      adminAccounts = accounts;
      AdminAccountSummary? mine;
      for (final acc in accounts) {
        if (acc.id == state.accountId) {
          mine = acc;
          break;
        }
      }
      myRole = mine?.role;
    } on ApiException catch (e) {
      if (e.statusCode == 403) {
        myRole = null;
        adminAccounts = [];
      } else {
        _noteFailure('checking admin role failed', e);
      }
    } catch (e) {
      // Through _noteFailure like every other failure, rather than raw: this
      // runs on every start and on every visit to the admin area, so against
      // a server that is away it was the banner, reciting a SocketException
      // with an errno and an ephemeral port number.
      _noteFailure('checking admin role failed', e);
    }
    notifyListeners();
  }

  /// Grants or revokes admin/moderator status. Admin only (enforced
  /// server-side regardless of what this device believes its own role
  /// is). Refreshes the account list afterwards.
  Future<void> setAccountRole(String accountId, String role) async {
    await api.setAccountRole(state.credentials, accountId, role);
    await refreshMyRole();
  }

  /// Temporarily disables an account server-wide. Admin, or moderator acting
  /// on a regular member (SRV-08).
  Future<void> blockAccount(String accountId) async {
    await api.blockAccount(state.credentials, accountId);
    await refreshMyRole();
  }

  /// Restores a previously blocked account. Same authorization as blocking.
  Future<void> unblockAccount(String accountId) async {
    await api.unblockAccount(state.credentials, accountId);
    await refreshMyRole();
  }

  /// Permanently deletes an account. Admin only, irreversible.
  Future<void> deleteAccount(String accountId) async {
    await api.deleteAccount(state.credentials, accountId);
    await refreshMyRole();
  }

  /// Permanently deletes THIS account -- server-side, not just locally.
  /// Only ever targets the caller's own accountId (see api_client.dart's
  /// matching self-only endpoint) -- unlike [deleteAccount] above, which
  /// is the admin-only path for removing a *different* account.
  Future<void> deleteOwnAccount() =>
      api.deleteOwnAccount(state.credentials, state.accountId);

  /// Returns the current registration policy ("open"/"invite"/"closed").
  Future<String> getRegistrationPolicy() =>
      api.getRegistrationPolicy(state.credentials);

  /// Changes the registration policy (persisted server-side). Admin only.
  Future<void> setRegistrationPolicy(String policy) =>
      api.setRegistrationPolicy(state.credentials, policy);

  /// Returns whether inbound federation is currently enabled. Admin or
  /// moderator only (read).
  Future<bool> getFederationEnabled() =>
      api.getFederationEnabled(state.credentials);

  /// Turns inbound federation on/off (persisted server-side). Admin only.
  /// Also updates the locally cached [federationEnabled] so the lock UI
  /// reflects it immediately without waiting for the next status refresh.
  Future<void> setFederationEnabled(bool enabled) async {
    await api.setFederationEnabled(state.credentials, enabled);
    federationEnabled = enabled;
    notifyListeners();
  }

  /// Mints a single-use invite code. Admin or moderator only.
  Future<CreateInviteResponse> createInvite() =>
      api.createInvite(state.credentials);

  /// Conversations sorted newest-activity-first, for the chat list.
  List<Conversation> get conversations {
    final list = state.conversations.values.toList();
    list.sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
    return list;
  }

  Conversation? conversation(String peerAccountId) =>
      state.conversations[peerAccountId];

  /// Every chat, one-to-one and group alike, newest-activity-first. What a
  /// chat list renders: groups sit in the one list rather than behind a tab,
  /// so there is exactly one place that answers "what is new".
  List<ChatTarget> get chats {
    final list = <ChatTarget>[
      ...state.conversations.values,
      ...state.groups.values,
    ];
    list.sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
    return list;
  }

  /// True if any chat in this account has an unread message -- drives the
  /// account switcher's notification dot.
  bool get hasAnyUnread =>
      state.conversations.values.any((c) => c.hasUnread) ||
      state.groups.values.any((g) => g.hasUnread);

  /// The peer whose ChatScreen is currently on screen, if any -- an
  /// incoming message from them is never marked unread, since the user
  /// is already looking at it (see _handleIncoming).
  String? _openConversationPeerId;

  /// Whether the app is actually in the foreground. Pressing Home does
  /// NOT dispose a ChatScreen (it stays on the navigation stack), so
  /// _openConversationPeerId alone can't tell "user is looking at this
  /// chat" apart from "chat is technically still open but the app is
  /// backgrounded." Set via [setForeground] from the app-lifecycle
  /// observer (see main.dart).
  bool _appInForeground = true;

  // "Which chat counts as being read" is the core's question now: this side
  // simply clears the open chat on going to the background (see
  // [setForeground]), so a backgrounded app has none.

  /// Called by the app-lifecycle observer (main.dart) when the app moves
  /// between foreground and background. On returning to the foreground it
  /// first adopts whatever the background push isolate did while this one was
  /// frozen ([applyCoreState]) -- both isolates drive the same core handle, so
  /// what the wake decrypted is already on disk and this side simply has to
  /// re-read it. Only then, with a chat still open, re-runs the read logic so
  /// anything that arrived while backgrounded (left unread + notified) is now
  /// marked read -- the user is looking at it again.
  Future<void> setForeground(bool value) async {
    if (_appInForeground == value) return;
    _appInForeground = value;
    if (!value) {
      // Cancel any pending reachability grace: Android freezes us while
      // backgrounded, so a timer armed now would fire the instant we resume
      // and flash the account grey. Reachability is re-evaluated on resume.
      _reachabilityGraceTimer?.cancel();
      _reachabilityGraceTimer = null;
      // The core has no notion of foreground/background (see
      // docs/design/23-shared-client-core.md), only "which chat is open" -- so
      // going to the background has to clear that itself, or a message into
      // the chat that was on screen would stay silently suppressed for as
      // long as the app is backgrounded, which is exactly the opposite of
      // what a background notification is for.
      coreAccount.setOpenChat(null);
      // Tear down the live SSE stream. Holding it open in the background keeps
      // this device registered as a live subscriber on the server, and the
      // server only sends a push wake when NO subscriber is connected (see
      // queueAndNotify in freizone-server). Leaving the stream up therefore
      // silently suppressed every FCM/UnifiedPush background notification --
      // the whole point of releasing it here is to let push take over once
      // the app is no longer on screen.
      _stopStream();
      return;
    }
    // Whatever the background push wake (push_manager.dart) received while
    // this session was frozen -- it opens the same core handle's on-disk
    // state, see doCoreSync -- rather than re-reading a Dart-side profile the
    // wake no longer writes.
    applyCoreState(state, coreAccount);
    // Reopen the live stream that backgrounding closed, so the foregrounded
    // app is back on the fast path (and the server stops pushing to it).
    _startStream();
    // Re-check server-status on resume so an admin's federation (or
    // registration-policy) change made while the app was backgrounded shows
    // up promptly -- the lock UI and outbound guard depend on this flag, and
    // there is no push for a settings change.
    unawaited(refreshRegistrationPolicy());
    // Resuming is a second chance at whatever failed while we were away, and
    // the only one that doesn't need our own connection to have dropped: a
    // member whose server was briefly down leaves a debt behind while ours was
    // reachable throughout, so no reconnect fires for it (see flushOutbox's
    // other two call sites).
    unawaited(flushOutbox());
    if (_openConversationPeerId != null) {
      unawaited(enterConversation(_openConversationPeerId!));
    }
  }

  // Adopting the push isolate's work on resume was a hand-written merge of a
  // dozen fields under a profile lock, because the two isolates shared state
  // through one last-writer-wins file. They now share a core handle instead, so
  // it is [applyCoreState] and nothing else -- see setForeground.

  /// Call when a ChatScreen for peerAccountId opens: clears its unread flag,
  /// confirms it read to the peer, and tells the core which chat is on
  /// screen -- the one thing that suppresses a notification for it (see
  /// [CoreAccount.setOpenChat]).
  Future<void> enterConversation(String peerAccountId) async {
    _openConversationPeerId = peerAccountId;
    coreAccount.setOpenChat(peerAccountId);
    final convo = state.conversations[peerAccountId];
    if (convo == null || !convo.hasUnread) return;

    await coreAccount.markRead(peerAccountId);
    applyCoreChat(state, coreAccount, peerAccountId);
    // If that was the last unread conversation, clear this account's
    // "new message(s)" notification too, so its launcher-icon badge
    // (which Android derives from active notifications) goes away
    // rather than lingering after everything's been read.
    if (!hasAnyUnread) unawaited(clearMessageNotification(state.accountId));
    notifyListeners();
  }

  /// Call when that ChatScreen closes.
  void leaveConversation(String peerAccountId) {
    if (_openConversationPeerId == peerAccountId) {
      _openConversationPeerId = null;
      coreAccount.setOpenChat(null);
    }
  }

  /// Uploads prekeys if this is the first run, re-asserts the DH
  /// identity/signed-prekey certs otherwise, opens this account's handle
  /// into the shared client core (SRV-23, the cut), then opens the live
  /// message stream. Call once, right after construction.
  Future<void> init() async {
    // The prekey upload/re-assertion is network I/O against this account's
    // home server and may fail if that server is down. It must NOT gate the
    // rest of init: the SSE reconnect loop below is what tracks
    // reachability and recovers when the server returns, so it has to
    // start even on a dead server -- otherwise the account would be stuck
    // "connecting" forever with nothing ever retrying. onConnected re-runs
    // it, so a recovered server still gets its certs refreshed.
    //
    // Still Dart-side, deliberately: minting the very first signed prekey
    // stays here rather than moving to RotatePrekeys for this pass -- see
    // docs/design/23-shared-client-core.md. The one-time-prekey pool is not
    // -- that's coreAccount.maintain's job exclusively (run on every
    // reconnect below, via pkg/client.TopUpOneTimePrekeys) now that this
    // function no longer races it for the same pool with a private half
    // only Dart held (SRV-23: found live, every first message from a new
    // contact whose claim landed on one of this side's own kept failing to
    // decrypt).
    try {
      if (state.signedPrekeyPub == null) {
        await _uploadPrekeys();
      } else {
        await reassertPrekeyCertificates(state, core, api);
      }
      prekeysReady = true;
    } catch (e) {
      reachability = ServerReachability.unreachable;
      // The offline marking above is the visible half; the banner is only for a
      // prekey upload that failed for a reason waiting will not fix.
      _noteFailure('prekey upload failed', e);
    }

    // Opened regardless of whether the prekey step above succeeded: a first
    // run that could not reach the server yet still has an account id and
    // (if _uploadPrekeys got far enough) a device identity worth handing
    // over, and the core needs nothing more to exist. dhIdentityPriv and
    // signedPrekeyPriv are what let it decrypt at all -- see
    // FreizoneCore.coreSetIdentity's own doc comment -- so this is not
    // optional the way it was while this handle only ever held a stream.
    final handle = core.coreOpen(await coreStatePath(state.accountId));
    core.coreSetIdentity(
      handle: handle,
      accountId: state.accountId,
      server: state.server,
      rootPub: state.rootPub,
      rootPriv: state.rootPriv,
      deviceId: state.deviceId,
      devicePub: state.devicePub,
      devicePriv: state.devicePriv,
      dhIdentityPub: state.dhIdentityPub,
      dhIdentityPriv: state.dhIdentityPriv,
      signedPrekeyId: state.signedPrekeyId,
      signedPrekeyPub: state.signedPrekeyPub,
      signedPrekeyPriv: state.signedPrekeyPriv,
      nextSignedPrekeyId: state.nextSignedPrekeyId,
      nextOtpkKeyId: state.nextOtpkKeyId,
      recoveryBackupDone: state.recoveryBackupDone,
      pushMechanism: state.pushMechanism,
    );
    coreAccount = CoreAccount(
      core: core,
      handle: handle,
      libraryPath: core.libraryPath,
    );
    // Whatever the core already holds from a previous run, before the first
    // paint -- the same rebuild-whole read _handleIncoming and every send
    // below trigger on their own, just run once up front here.
    applyCoreState(state, coreAccount);

    // Before anything can confirm or record anything: the switch is app-wide
    // and the core keeps its own per-account copy, so a session that never
    // passed it on would honour whatever the last one happened to leave there.
    unawaited(applyReceiptsSetting((await AppSettings.load()).readReceiptsEnabled));

    notifyListeners();
    _startStream();
    unawaited(refreshMyRole());
    // Housekeeping, deliberately not awaited: it only touches files no
    // message points at any more, so nothing depends on it finishing.
    unawaited(sweepOrphanedMedia());
    unawaited(refreshRegistrationPolicy());
    unawaited(_registerPush());
    // Anything composed but never sent -- in this run or a previous one --
    // gets its first automatic attempt here (APP-08 step 2). Not awaited:
    // a backlog against a slow peer must not hold up startup.
    unawaited(flushOutbox());
  }

  /// Hands this account's core the read-receipts setting.
  ///
  /// Best-effort and never surfaced: failing to pass it on leaves the core with
  /// whatever it had, which is the previous answer rather than a wrong one, and
  /// the next session start passes it again.
  Future<void> applyReceiptsSetting(bool enabled) async {
    try {
      await coreAccount.setReceiptsEnabled(enabled);
    } catch (e) {
      logDiagnostic(
        'passing the read-receipts setting to the core failed: ${describeError(e)}',
        name: 'receipts',
      );
    }
  }

  Future<void> _registerPush() async {
    try {
      final mechanism = await resolvePushMechanism();
      final result = await registerForPush(
        api,
        state.accountId,
        state.credentials,
        mechanism: mechanism,
      );
      pushRegistration = result;
      pushHintPending = result != PushRegistration.registered;
      // Recorded on the profile so the diagnostics screen (APP-12) can still
      // answer "when did this account last manage to register" after a
      // restart -- pushRegistration itself is in-memory only.
      if (result == PushRegistration.registered) {
        state.pushRegisteredAt = DateTime.now().toUtc();
        state.pushMechanism = await pushMechanismLabel(mechanism);
        await LocalStateStore.saveProfile(state);
      }
      notifyListeners();
    } catch (e) {
      // Re-tried on every reconnect (see the stream's onConnected), so an
      // unreachable server here is a "later" like any other.
      _noteFailure('push registration failed', e);
      notifyListeners();
    }
  }

  /// Re-runs push registration for this account, e.g. right after the
  /// user changes PushPreference in Settings, so the switch takes effect
  /// immediately instead of waiting for the next app start.
  Future<void> reregisterPush() => _registerPush();

  Future<void> _uploadPrekeys() async {
    final now = DateTime.now().toUtc();

    DHIdentityCertDTO? dhCertDto;
    if (state.dhIdentityPub == null) {
      final dh = core.generateX25519KeyPair();
      final cert = core.signDHIdentityCertificate(
        accountId: state.accountId,
        deviceId: state.deviceId,
        dhPub: dh.pub,
        issuedAt: now,
        devicePriv: state.devicePriv,
      );
      state.dhIdentityPub = dh.pub;
      state.dhIdentityPriv = dh.priv;
      dhCertDto = DHIdentityCertDTO(
        dhPubKey: cert.dhPubKey,
        issuedAt: cert.issuedAt,
        signature: cert.signature,
      );
    }

    final spk = core.generateX25519KeyPair();
    final spkId = state.nextSignedPrekeyId;
    state.nextSignedPrekeyId++;
    final spkCert = core.signSignedPrekeyCertificate(
      accountId: state.accountId,
      deviceId: state.deviceId,
      keyId: spkId,
      dhIdentityPub: state.dhIdentityPub!,
      prekeyPub: spk.pub,
      issuedAt: now,
      devicePriv: state.devicePriv,
    );
    state.signedPrekeyId = spkId;
    state.signedPrekeyPub = spk.pub;
    state.signedPrekeyPriv = spk.priv;

    // No one-time prekeys minted here (SRV-23, closing a gap the cut left
    // open): the very first thing that opens this account's core handle,
    // right below, is coreSetIdentity -- and the first reconnect after that
    // runs coreAccount.maintain(), which tops the pool up itself through
    // pkg/client.TopUpOneTimePrekeys. Minting a batch here too meant two
    // independent minters claiming ids from the same server-side pool,
    // each holding the private half of only the ones it minted -- so a
    // contact whose claim landed on one of *these* had no private key
    // waiting for it on the core's side, and their first message failed
    // outright. Identity plus the signed prekey above is enough for the
    // core to exist; it mints its own one-time prekeys from there.
    await api.uploadPrekeys(
      creds: state.credentials,
      dhIdentityCert: dhCertDto,
      signedPrekey: SignedPrekeyDTO(
        keyId: spkCert.keyId,
        dhIdentityPubKey: spkCert.dhIdentityPubKey,
        pubKey: spkCert.prekeyPubKey,
        issuedAt: spkCert.issuedAt,
        signature: spkCert.signature,
      ),
      oneTimePrekeys: const <OneTimePrekeyDTO>[],
    );
    await LocalStateStore.saveProfile(state);
  }

  /// The stream dropped or a reconnect attempt failed. Don't flip straight to
  /// [ServerReachability.unreachable] (which greys the account in the UI) when
  /// we were online: a resume from background or a brief blip reconnects in
  /// well under a second (see the core's quick retry), and greying the whole
  /// account for that is just noise. A drop from [online] sits in [connecting]
  /// (visually identical to online) and only escalates to [unreachable] after
  /// [_reachabilityGrace] with no reconnect. A failure while never-online
  /// (cold start) or already-offline surfaces immediately -- the connect /
  /// request timeout was the wait there.
  void _markStreamDropped() {
    if (!_appInForeground) {
      // Backgrounded: the UI is hidden and Android will freeze us, so a grace
      // timer armed now would fire the instant we resume and flash the
      // account grey. Just drop the "confirmed online" claim (still visually
      // like online); resume re-evaluates from scratch via the reconnect.
      if (reachability == ServerReachability.online) {
        reachability = ServerReachability.connecting;
      }
      return;
    }
    if (reachability == ServerReachability.unreachable) return; // already off
    if (_reachabilityGraceTimer != null) return; // grace already deciding
    // First drop while in the foreground: stay visually online for the grace
    // window and only escalate to `unreachable` if nothing reconnects within
    // it. A background resume reconnects in well under a second (the core's
    // quick retry), so the grey never shows.
    reachability = ServerReachability.connecting;
    _reachabilityGraceTimer = Timer(_reachabilityGrace, () {
      _reachabilityGraceTimer = null;
      reachability = ServerReachability.unreachable;
      notifyListeners();
    });
  }

  /// A (re)connect succeeded: cancel any pending grace escalation and go
  /// online. (online == connecting visually, so this only actually redraws
  /// when coming back from [unreachable].)
  void _markStreamConnected() {
    _reachabilityGraceTimer?.cancel();
    _reachabilityGraceTimer = null;
    final wasOffline = reachability != ServerReachability.online;
    if (wasOffline) {
      reachability = ServerReachability.online;
      notifyListeners();
    }
    // Coming back from unreachable is the moment a send that failed for want
    // of a network can finally succeed, so it is where the outbox drains
    // (APP-08 step 2). Only on the transition: a reconnect that was never a
    // disconnect has nothing new to offer.
    if (wasOffline) unawaited(flushOutbox());
  }

  void _startStream() {
    if (_sse != null) return; // already streaming (or restarted before stop)
    _sse = CoreStream(core: core, handle: coreAccount.handle);
    unawaited(
      _sse!.connect(
        onMessage: _handleIncoming,
        onError: (e) {
          // A connect that timed out or was refused is what _markStreamDropped
          // is for: the offline badge, the grace period, and the retry loop.
          // Only a stream failing for some *other* reason reaches the banner.
          _noteFailure('stream error', e);
          _markStreamDropped();
        },
        onConnected: () {
          _markStreamConnected();
          // Everything a fresh connection should settle, in one call: drain
          // whatever is queued for this device, then top up the prekey pool,
          // pay any group snapshot debts and re-establish sessions the
          // evidence says are broken (see CoreAccount.sync, which does
          // maintain's work after the drain).
          //
          // Replaces three separate Dart-side calls (topUpOneTimePrekeysIfNeeded,
          // an implicit snapshot-debt sweep, _recoverDesyncedSessions) that each
          // read and wrote state the core owns exclusively now.
          //
          // The drain is not belt-and-braces: the stream discards events rather
          // than let a slow consumer stall the connection, nothing re-pushes
          // what it discarded, and the server only wakes a device that has *no*
          // stream open -- so without a fetch here an envelope dropped that way
          // waited for an app restart. See CoreAccount.sync.
          unawaited(_drainQueue());
          // Re-register push on every (re)connect: a server that was down at
          // startup (or when the endpoint first arrived) never got this
          // account's push target otherwise, and would stay push-less until
          // the next app start. registerForPush is idempotent.
          unawaited(_registerPush());
          // Pick up a server-status change (e.g. federation toggled) on every
          // (re)connect -- covers long-lived sessions and network changes.
          unawaited(refreshRegistrationPolicy());
        },
      ),
    );
  }

  /// Closes the live SSE stream and releases this device's subscriber slot on
  /// the server, so a message arriving while the app is backgrounded triggers
  /// a push wake instead of being delivered into a stream nobody is reading
  /// (see [setForeground]). Closing is a clean disconnect -- CoreStream.close
  /// marks itself closed before tearing down, so its reconnect loop exits
  /// without reporting an error, and reachability is left untouched. Safe to
  /// call when no stream is open. Leaves this account's core handle open --
  /// [coreAccount] outlives the stream, see its own doc comment.
  void _stopStream() {
    _sse?.close();
    _sse = null;
  }

  /// Drains this device's queue and folds what turned up in exactly as a
  /// streamed envelope would be -- see [CoreAccount.sync] for why a
  /// (re)connect has to fetch at all.
  ///
  /// Failure is deliberately quiet: a fetch that could not reach the server is
  /// what the reconnect loop already exists for, and this must not be the
  /// thing that lights up the offline banner. Housekeeping problems are logged
  /// for the same reason [MaintenanceReport.problems] is -- best-effort by
  /// nature, and not something to put in front of the user.
  Future<void> _drainQueue() async {
    try {
      final report = await coreAccount.sync();
      for (final problem in report.problems) {
        logDiagnostic('connect housekeeping problem: $problem');
      }
      for (final outcome in report.outcomes) {
        _handleIncoming(outcome);
      }
    } catch (e) {
      logDiagnostic('draining the queue on connect failed: $e');
    }
  }

  /// One envelope, already decided by the core: decrypted (or folded, if it
  /// was a group fact), acknowledged, receipted. Nothing left to do here but
  /// refresh whatever chat changed and, sometimes, say something about it --
  /// see [PollOutcome].
  void _handleIncoming(PollOutcome outcome) {
    if (outcome.failed) {
      // Logged, never shown and never acted on: the core has already decided
      // whether to retry this envelope or acknowledge it away, and there is
      // nothing a user could do about it. But a message that silently fails
      // to decrypt is the hardest thing in this app to diagnose without it
      // -- see PollOutcome.failure.
      logDiagnostic(
        'envelope from ${outcome.senderAccountId} not handled: ${outcome.failure}',
      );
      return;
    }
    if (outcome.chatId.isEmpty) return; // a duplicate
    applyCoreChat(state, coreAccount, outcome.chatId);

    // A picture starts downloading as it arrives rather than when its bubble is
    // first looked at -- i.e. not at the moment the user is waiting for it.
    // Unawaited on purpose: this is an optimisation over ImageAttachment's own
    // lazy fetch, and a download must never delay a receipt, a notification or
    // the redraw above, nor make a message that did arrive look as though it
    // had not.
    if (outcome.attachmentMessageId.isNotEmpty) {
      unawaited(
        _prefetchAttachment(
          chatId: outcome.chatId,
          messageId: outcome.attachmentMessageId,
        ),
      );
    }

    if (outcome.notify) {
      // Without this call, the launcher icon's badge (which Android derives
      // from active notifications, not anything drawn in-app) would never
      // appear for a message that happened to arrive while the app was in
      // the foreground.
      unawaited(
        showMessageNotification(
          state.accountId,
          // A group envelope points at the group, not at a one-to-one chat
          // with whoever happened to send it (main.dart's _openChatFor opens
          // exactly that for a peer id).
          peerAccountId: outcome.isGroup ? null : outcome.chatId,
          groupId: outcome.isGroup ? outcome.chatId : null,
          invitation: outcome.invitation,
        ).catchError((Object e) {
          // Best-effort, like the receipt and the acknowledgement before it:
          // the message is already stored and on screen, and a notification
          // that could not be shown is not worth turning into an unhandled
          // async error -- which is all this was, since nothing awaits it.
          logDiagnostic('showing a message notification failed: $e');
        }),
      );
    }

    lastError = null;
    notifyListeners();
  }

  /// Resolves and creates, or returns the already-resolved, Conversation
  /// with peerAddress -- a full Freizone address (`id*server`, `id*local`,
  /// or just a bare id/prefix, see lib/util/freizone_address.dart), so a
  /// dash-grouped or phone-dictated id ("k5x9 p2qa n7f3...") resolves the
  /// same as the canonical form. An explicit `*server` that isn't this
  /// session's own (or `local`) is a federated address (docs/PROTOCOL.md §9):
  /// resolved and messaged directly against that server, not this session's
  /// own.
  ///
  /// Through the core now (SRV-23, the cut) -- CoreAccount.startConversation,
  /// not a Dart-side resolve-and-mint. This one was not optional the way the
  /// rest of this pass's "deferred" list is: pkg/client.touchConversation
  /// deliberately never creates a Conversation record for a peer nobody
  /// called StartConversation for first (see its own doc comment -- "the
  /// caller is the one that knows whether creating it is right"), so a first
  /// message sent without this ever having run leaves that chat with no
  /// record in the core at all, forever -- Conversations() never lists it,
  /// applyCoreChat reads that as "gone" and removes the local entry on the
  /// very next refresh, and the screen still holding a reference crashes on
  /// the null the moment it rebuilds. Found by actually sending one on a
  /// device, not by review.
  Future<Conversation> startConversation(String peerAddress) async {
    final parsed = parseFreizoneAddress(peerAddress);
    if (parsed == null) throw StateError('Not a valid Freizone address');

    // Outbound federation guard: if the address is on another server but this
    // account's home server has federation disabled, the peer could never
    // reply (its messages would be blocked inbound), so refuse to start the
    // conversation rather than let the user run into a silent dead end.
    if (parsed.server != null &&
        !sameServer(parsed.server!, state.server) &&
        !federationEnabled) {
      throw StateError(
        'Federation is turned off on your server, so you can\'t message '
        'contacts on other servers.',
      );
    }
    final normalized = parsed.idOrPrefix;

    // Self-chat guard: messaging your own id resolves to your own device and
    // breaks X3DH/the ratchet (you'd be establishing a session with yourself),
    // so refuse it up front. A full id is your key's global identity, so match
    // it regardless of server; a short prefix only identifies an account
    // within a server, so only count a prefix match as "self" when the address
    // targets your own server.
    final ownServer =
        parsed.server == null || sameServer(parsed.server!, state.server);
    final isSelf =
        normalized == state.accountId ||
        (ownServer &&
            normalized.length == accountIdPrefixLength &&
            state.accountId.startsWith(normalized));
    if (isSelf) {
      throw StateError(
        "That's your own address -- you can't start a chat with yourself.",
      );
    }

    // CoreAccount.startConversation resolves the address itself (server-side
    // prefix resolution, same as the old _resolvePeerDevice), marks the peer
    // known and lifts any pending-approval flag -- pkg/client.StartConversation
    // does all three, which is exactly what the old Dart-side _markKnown
    // existed for.
    final chat = await coreAccount.startConversation(
      normalized,
      server: ownServer ? '' : parsed.server!,
    );
    applyCoreChat(state, coreAccount, chat.chatId);
    notifyListeners();
    return state.conversations[chat.chatId]!;
  }

  // Naming a peer is no longer a session's business (APP-19): a name belongs to
  // the person, one contact store holds them all, and writing it here would mean
  // this account's copy could disagree with another's. Callers use
  // ContactStore.setName / .remove directly -- see rename_dialog.dart's callers.

  /// Every peer blocked locally -- backs the "Blocked contacts" screen,
  /// which needs to list and unblock peers even once their Conversation
  /// (and thus their profile screen) no longer exists.
  List<BlockedPeer> get blockedPeers => state.blockedPeers.values.toList();

  /// Whether [peerAccountId] is blocked, from the block's authoritative home
  /// (see [setBlocked]). UI that has a [Conversation] at hand may still read
  /// its `blocked` mirror for rebuild-cheapness, but anything that *decides*
  /// -- what to render as the block toggle, whether to store a message --
  /// must ask this, so a mirror gone stale can never answer differently than
  /// the receive path does.
  bool isBlocked(String peerAccountId) =>
      state.blockedPeers.containsKey(peerAccountId);

  /// Blocks or unblocks a peer -- purely local, since Freizone's open
  /// registration means an unwanted contact can't be reported or banned
  /// server-side yet (see peer_profile_screen.dart's "Protection"
  /// section). Further incoming messages are still decrypted (so the
  /// ratchet session and the server's per-recipient queue both stay
  /// clean) but dropped before being stored or notified -- see
  /// _handleIncoming. Sending is disabled in the UI while blocked. The
  /// peer is never told either way.
  ///
  /// The block itself is now enforced by the core (SRV-23, the cut) --
  /// coreAccount.blockPeer/unblockPeer is what the receive path's
  /// IsPeerBlocked actually reads, without which blocking would decrypt
  /// (correctly) and then stop nowhere, since the core had never been told.
  /// [AppState.blockedPeers] stays alongside it, display-only: the "Blocked
  /// contacts" screen has to list someone with no conversation left, and the
  /// native account API has no call yet to list blocked accounts back -- see
  /// the follow-up filed for it. Deliberately outliving [deleteConversation]
  /// (see its own doc comment), so deleting a blocked peer's chat can never
  /// silently un-block them.
  Future<void> setBlocked(String peerAccountId, bool blocked) async {
    final convo = state.conversations[peerAccountId];
    if (blocked) {
      coreAccount.blockPeer(peerAccountId, server: convo?.peerServer ?? '');
      state.blockedPeers[peerAccountId] = BlockedPeer(
        peerAccountId: peerAccountId,
        peerServer: convo?.peerServer,
      );
    } else {
      coreAccount.unblockPeer(peerAccountId);
      state.blockedPeers.remove(peerAccountId);
      // Unblocking is itself a decision to hear from them normally again
      // -- they shouldn't reappear as an unactioned "message request" the
      // next time they write.
      state.knownPeerIds.add(peerAccountId);
    }
    await LocalStateStore.saveProfile(state);
    applyCoreChat(state, coreAccount, peerAccountId);
    notifyListeners();
  }

  /// Accepts a pending "message request" (see Conversation.pendingApproval).
  /// Nothing is sent to the peer or the server; they have no way to know
  /// either way. Tells the core too (SRV-23, the cut): the receive path's own
  /// notify rule reads *its* PendingApproval, not this session's copy, so a
  /// contact accepted only here would keep being treated as unaccepted --
  /// their follow-up messages arriving unread but silently, never notified,
  /// since the app's own rule for an accepted contact is the opposite of the
  /// one for an unactioned request.
  Future<void> acceptConversation(String peerAccountId) async {
    final convo = state.conversations[peerAccountId];
    if (convo == null) return;
    coreAccount.acceptRequest(peerAccountId);
    convo.pendingApproval = false;
    state.knownPeerIds.add(peerAccountId);
    await LocalStateStore.saveProfile(state);
    applyCoreChat(state, coreAccount, peerAccountId);
    notifyListeners();
  }

  /// Empties peerAccountId's message history, keeping the conversation
  /// itself (resolved peer device, alias) -- purely local, since the
  /// server never stored the history in the first place.
  Future<void> clearConversation(String peerAccountId) async {
    final convo = state.conversations[peerAccountId];
    if (convo == null) return;
    convo.messages.clear();
    final hadUnread = convo.hasUnread;
    convo.hasUnread = false;
    // Pictures go with the history they belonged to -- clearing a chat but
    // leaving its images on disk would be both surprising and a slow leak.
    await _deleteChatMedia(peerAccountId);
    await LocalStateStore.saveProfile(state);
    if (hadUnread && !hasAnyUnread)
      unawaited(clearMessageNotification(state.accountId));
    notifyListeners();
  }

  /// Removes peerAccountId's conversation entirely -- history, media and the
  /// resolved peer device -- while **keeping the ratchet session**.
  ///
  /// The session stays because the peer does not know their chat was deleted on
  /// our end and may keep writing in what looks to them like an ongoing
  /// conversation, without including fresh X3DH material. With no surviving
  /// session such a message cannot be decrypted at all (see _handleIncoming),
  /// and is lost silently for both sides. That is the only arrangement in which
  /// a resumption can be *seen*, which is what makes it the routine action;
  /// [removeConversationPermanently] is the one that takes the session too.
  ///
  /// The peer is also dropped from [AppState.knownPeerIds], so a resumption
  /// arrives as a message **request** to accept or decline rather than silently
  /// reopening the chat. **This reverses an earlier choice** (see
  /// [acceptConversation], which added them there precisely so a delete would
  /// not "regress them to an unactioned request"): deleting a chat is now taken
  /// as a decision about the relationship, so somebody writing again is an event
  /// worth surfacing rather than a chat quietly reappearing. Decided 2026-08-04,
  /// recorded in docs/design/19-contacts.md.
  ///
  /// Purely local either way: the account itself is untouched on the server.
  Future<void> deleteConversation(String peerAccountId) async {
    final removed = state.conversations.remove(peerAccountId);
    if (removed == null) return;
    if (_openConversationPeerId == peerAccountId)
      _openConversationPeerId = null;
    state.knownPeerIds.remove(peerAccountId);
    await _deleteChatMedia(peerAccountId);
    await LocalStateStore.saveProfile(state);
    if (removed.hasUnread && !hasAnyUnread)
      unawaited(clearMessageNotification(state.accountId));
    notifyListeners();
  }

  /// Everything [deleteConversation] does, **plus the ratchet session** -- for a
  /// peer who is actually gone.
  ///
  /// The durable removal an orphaned chat needs: nothing about this peer is left
  /// on the device. Only ever safe where there can be no next message from them,
  /// which is why the UI gates it on evidence from the public account directory
  /// (see peer_absence.dart) rather than on the user's belief. Where that
  /// evidence is a definite absence this loses nothing by construction: there is
  /// no sender left to lose a message from.
  ///
  /// Offered even when the directory could not be asked -- somebody who knows a
  /// server is dead should not be held hostage by a check that cannot
  /// conclude -- but then with the consequence stated: if that peer does come
  /// back, their first messages are undecryptable until a re-key completes.
  ///
  /// Both ratchet sessions go too, and the cached device with them (see
  /// [CoreAccount.forgetPeer]): leaving half of a discarded pair behind would
  /// keep exactly the state this action exists to clear, and a session is
  /// keyed to the device that established it.
  Future<void> removeConversationPermanently(String peerAccountId) async {
    await deleteConversation(peerAccountId);
    await coreAccount.forgetPeer(peerAccountId);
    await LocalStateStore.saveProfile(state);
    notifyListeners();
  }

  /// Deletes one chat's stored pictures. Best-effort: leftover files
  /// waste space but break nothing, and this always runs alongside a more
  /// important deletion that must not fail because of them.
  Future<void> _deleteChatMedia(String chatId) async {
    try {
      final media = await MediaStore.instance();
      await media.deleteChatMedia(state.accountId, chatId);
    } catch (_) {
      // See above.
    }
  }

  /// Removes stored pictures that no message refers to any more -- history
  /// deleted while the app was closed, or a send that failed after its file
  /// was written. Called once at startup, after state is loaded.
  Future<void> sweepOrphanedMedia() async {
    try {
      final media = await MediaStore.instance();
      // Every chat, groups included -- a group message's picture is stored
      // exactly like a one-to-one one, and leaving groups out of this would
      // sweep away pictures that are still on screen.
      final live = <String>{};
      for (final chat in chats) {
        for (final m in chat.messages) {
          if (m.hasAttachments) live.add(m.id);
        }
      }
      await media.sweepOrphans(
        accountId: state.accountId,
        liveMessageIds: live,
      );
    } catch (_) {
      // Housekeeping only -- never worth surfacing or retrying.
    }
  }

  // --- Groups (APP-16) -----------------------------------------------------
  //
  // The fact set of each group is an opaque blob produced by the native core
  // and stored in its own file. Nothing here interprets it; this layer holds
  // it, hands it back, and keeps the transcript beside it. Sending and
  // receiving come next -- everything below is local.

  /// Folded views, keyed by group id -- dead since the cut moved group facts
  /// into the core (see [groupState]); kept only because [loadGroupStates],
  /// [createGroup] and friends below still reference it, unreachable from any
  /// live path now.
  final Map<String, GroupStateResult> _groupStates = {};

  /// The screens' one window into a group's membership: name, topic, roles,
  /// who has joined. They ask for `.resolved`, the shape the old Dart-side
  /// fold produced -- kept exactly, so this is the one place that shape is
  /// still assembled, now from [CoreAccount.groupInfo] instead of from
  /// [_groupStates]. Null for a group this device holds no facts about yet
  /// (an invitation whose snapshot has not arrived, or none at all), which is
  /// the same "nothing to show" the screens already handle.
  GroupStateResult? groupState(String groupId) {
    GroupInfo info;
    try {
      info = coreAccount.groupInfo(groupId);
    } catch (_) {
      return null;
    }
    return GroupStateResult(
      groupId: info.groupId,
      // Opaque and unread by any screen -- see the grep that justified this
      // adapter's shape in the commit that added it.
      state: const {},
      stateHash: info.stateHash,
      resolved: GroupResolved(
        groupId: info.groupId,
        founder: info.founder,
        name: info.name,
        topic: info.topic,
        dissolved: info.dissolved,
        members: info.members
            .map(
              (m) => GroupMember(
                accountId: m.accountId,
                server: m.server,
                role: m.role,
                joined: m.joined,
                // Not carried by the core's API, and no screen reads it (only
                // its own factory does) -- see GroupMember.addedAt.
                addedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
              ),
            )
            .toList(),
      ),
      applied: const [],
      known: const [],
      rejected: const [],
    );
  }

  GroupConversation? group(String groupId) => state.groups[groupId];

  /// This account's identity, in the shape every signing call over the FFI
  /// boundary expects.
  GroupIdentity get _groupIdentity => GroupIdentity(
    accountId: state.accountId,
    rootPub: state.rootPub,
    rootPriv: state.rootPriv,
    deviceId: state.deviceId,
    devicePub: state.devicePub,
    devicePriv: state.devicePriv,
  );

  /// Reads every group's fact set back at startup.
  ///
  /// A group whose file is missing or damaged is skipped rather than fatal:
  /// the fact set is grow-only and any member can hand back a full snapshot,
  /// so the cost is a re-sync, and refusing to start an account over one
  /// group's file would be far worse.
  Future<void> loadGroupStates() async {
    final blobs = await GroupStateStore.loadAll(state.accountId);
    for (final entry in blobs.entries) {
      try {
        _groupStates[entry.key] = core.groupResolveState(entry.value);
      } catch (e) {
        lastError = 'group ${entry.key} failed to load: ${describeError(e)}';
      }
    }
    _refreshGroupNames();
    notifyListeners();
  }

  /// Founds a group. Local only: nobody else knows about it until somebody is
  /// invited.
  Future<GroupConversation> createGroup({
    String name = '',
    String topic = '',
  }) async {
    final groupId = await coreAccount.createGroup(name);
    // The core's own call has no topic parameter (see CoreAccount.createGroup)
    // -- name and topic are one record either way (see setGroupMeta), so a
    // topic given here is simply the record's second write.
    if (topic.isNotEmpty) {
      await coreAccount.setGroupMeta(groupId, name, topic);
    }
    applyCoreState(state, coreAccount);
    notifyListeners();
    return state.groups[groupId]!;
  }

  /// Signs one group event with this account's identity, ready to be applied
  /// and sent on. Which key signs it is the core's decision, not ours.
  Map<String, dynamic> signGroupEvent({
    required String groupId,
    required String type,
    String subject = '',
    String server = '',
    String role = '',
    String name = '',
    String topic = '',
  }) {
    final current = _groupStates[groupId];
    if (current == null) throw StateError('no group state for $groupId');
    return core.groupSignEvent(
      identity: _groupIdentity,
      state: current.state,
      type: type,
      subject: subject,
      server: server,
      role: role,
      name: name,
      topic: topic,
    );
  }

  /// Merges events into a group's fact set, whether our own or a peer's, and
  /// persists the result.
  ///
  /// [groupId] may name a group this device has never heard of -- that is how
  /// an invitation arrives, as a snapshot carrying the genesis. Rejected
  /// events are reported back rather than thrown: a snapshot from a hostile
  /// peer must cost only its bad entries.
  Future<GroupStateResult> applyGroupEvents(
    String groupId,
    List<Map<String, dynamic>> events,
  ) async {
    // Free here, unlike on the receive path: the folded view is already cached.
    final before = _groupStates[groupId]?.resolved;
    final result = core.groupApplyEvents(
      state: _groupStates[groupId]?.state ?? const <String, dynamic>{},
      events: events,
    );
    // The blob decides its own id: a snapshot for an unknown group carries the
    // genesis, and the id follows from the key in it rather than from whatever
    // the sender claimed.
    final id = result.groupId.isEmpty ? groupId : result.groupId;

    final chat = state.groups.putIfAbsent(
      id,
      () => GroupConversation(groupId: id),
    );
    // Our own acts get the same lines a peer's do -- an inviter should see "q2xjx
    // was invited" in the transcript exactly as everyone else does, or the two
    // sides of the same group read as different histories.
    _appendGroupSystemLines(
      chat,
      groupStateChangeLines(
        before: before,
        after: result.resolved,
        myAccountId: state.accountId,
        events: events,
      ),
      at: DateTime.now().toUtc(),
    );
    await _storeGroupState(result, groupId: id);
    await LocalStateStore.saveProfile(state);
    notifyListeners();
    return result;
  }

  /// Forgets a group locally: its facts, its transcript and its pictures.
  ///
  /// Purely local, like deleting a one-to-one conversation. Leaving a group so
  /// the other members know is a signed event, and a different thing.
  Future<void> deleteGroup(String groupId) async {
    _groupStates.remove(groupId);
    state.groups.remove(groupId);
    await GroupStateStore.delete(state.accountId, groupId);
    await _deleteChatMedia(groupId);
    await LocalStateStore.saveProfile(state);
    notifyListeners();
  }

  // Asking a member for the whole fact set, and its cooldown, moved into the
  // core with the rest of the group protocol -- pkg/client.RequestGroupSync,
  // called from [enterGroup] for the same reason it was called here.

  /// Call when a group's screen closes -- the counterpart to [enterGroup],
  /// mirroring [leaveConversation]. A group id and a peer id share the one
  /// "currently open chat" slot, which is what lets an arriving group message
  /// know the user is looking at it.
  ///
  /// Named for the screen, not the membership: [leaveGroup] is the signed act of
  /// leaving the group itself, and the two must never be confused.
  void exitGroup(String groupId) {
    if (_openConversationPeerId == groupId) {
      _openConversationPeerId = null;
      coreAccount.setOpenChat(null);
    }
  }

  /// Call when a group's screen opens: tells the core which chat is on screen,
  /// clears its unread flag, and confirms read to every author who is owed it
  /// (see [CoreAccount.markRead]) -- and settles this account's own group
  /// housekeeping (snapshot debts owed, sessions the evidence says are broken)
  /// the same [coreAccount.maintain] a stream reconnect runs, since opening a
  /// group screen is exactly the kind of moment worth re-checking it.
  Future<void> enterGroup(String groupId) async {
    // Shares the one open-chat slot with conversations, so a group message
    // arriving while its screen is on top is not marked unread and confirms
    // itself read right away.
    _openConversationPeerId = groupId;
    coreAccount.setOpenChat(groupId);
    unawaited(coreAccount.maintain());
    // Ask somebody for the facts rather than waiting to be told: a hash says
    // "we differ" and never who is behind, so a device that missed a fact and
    // does not itself write would stay behind indefinitely -- and this is the
    // moment its stale member list is about to be shown and acted on. Rate
    // limited per group in the core, and best-effort: nothing here depends on
    // an answer arriving.
    unawaited(coreAccount.requestGroupSync(groupId));

    final chat = state.groups[groupId];
    if (chat == null || !chat.hasUnread) return;
    await coreAccount.markRead(groupId);
    applyCoreChat(state, coreAccount, groupId);
    // Exactly as enterConversation does it: if that was the last unread chat in
    // this account, the notification goes with it -- otherwise Android's
    // launcher badge (derived from active notifications, not from anything drawn
    // in-app) would linger after the group, or the invitation, has been read.
    if (!hasAnyUnread) unawaited(clearMessageNotification(state.accountId));
    notifyListeners();
  }

  /// Invites an account, and tells everyone else.
  ///
  /// [address] is a full Freizone address (`id*server`, `id*local`, or just a
  /// bare id/prefix -- see lib/util/freizone_address.dart), exactly what
  /// [startConversation] accepts. Parsed and guarded here for the friendly
  /// errors (bad address, federation off, inviting yourself) before anything
  /// reaches the network; [CoreAccount.invite] does the resolution, the
  /// signing, the invitee's snapshot and the broadcast to everyone else in one
  /// call -- see freizone-server's pkg/client.InviteToGroup.
  Future<void> inviteToGroup(String groupId, String address) async {
    final parsed = parseFreizoneAddress(address);
    if (parsed == null) throw StateError('Not a valid Freizone address');

    // `*local`, no `*...` part, or an explicit spelling of our own server all
    // mean the same thing -- and the member's recorded server is absolute, so
    // it's this session's own normalized one, never the user's spelling of it.
    final onOwnServer =
        parsed.server == null || sameServer(parsed.server!, state.server);
    final memberServer = onOwnServer ? state.server : parsed.server!;

    // Same outbound federation guard as startConversation: a member this
    // server can't federate with could never answer, and inviting them writes
    // a permanent fact into the group's history.
    if (!onOwnServer && !federationEnabled) {
      throw StateError(
        'Federation is turned off on your server, so you can\'t invite '
        'contacts on other servers.',
      );
    }

    final isSelf =
        parsed.idOrPrefix == state.accountId ||
        (onOwnServer &&
            parsed.idOrPrefix.length == accountIdPrefixLength &&
            state.accountId.startsWith(parsed.idOrPrefix));
    if (isSelf) {
      throw StateError("That's your own address -- you're already in here.");
    }

    await coreAccount.invite(
      groupId,
      parsed.idOrPrefix,
      server: onOwnServer ? '' : memberServer,
    );
    applyCoreChat(state, coreAccount, groupId);
    notifyListeners();
  }

  /// Accepts an invitation addressed to this account.
  Future<void> acceptGroupInvite(String groupId) async {
    await coreAccount.acceptInvitation(groupId);
    applyCoreChat(state, coreAccount, groupId);
    notifyListeners();
  }

  /// Declines an invitation addressed to this account.
  ///
  /// A decline is a `leave`, not a new kind of fact -- see
  /// freizone-server's pkg/client.LeaveGroup, which the fold treats
  /// identically for an invitee and a joined member.
  ///
  /// **Known limitation**: unlike the Dart-only implementation this replaces,
  /// there is not yet a way to make the core forget a group's facts entirely
  /// (see CoreAccount/native's doCoreDeleteChat, which clears a group's
  /// transcript and media but deliberately leaves its fact-set directory
  /// alone). The group may still show up in the chat list until that exists.
  Future<void> declineGroupInvite(String groupId) async {
    await coreAccount.leaveGroup(groupId);
    coreAccount.deleteChat(groupId);
    applyCoreState(state, coreAccount);
    notifyListeners();
  }

  /// Grants or revokes a role.
  Future<void> setGroupRole(
    String groupId,
    String accountId,
    String role, {
    required bool grant,
  }) async {
    await coreAccount.setRole(groupId, accountId, role, grant: grant);
    applyCoreChat(state, coreAccount, groupId);
    notifyListeners();
  }

  /// Removes a member.
  Future<void> removeFromGroup(String groupId, String accountId) async {
    await coreAccount.removeMember(groupId, accountId);
    applyCoreChat(state, coreAccount, groupId);
    notifyListeners();
  }

  /// Sets the name and topic. One last-writer-wins record, so an unchanged
  /// field is carried over rather than cleared.
  Future<void> setGroupMeta(
    String groupId, {
    String? name,
    String? topic,
  }) async {
    final resolved = groupState(groupId)?.resolved;
    if (resolved == null) return;
    await coreAccount.setGroupMeta(
      groupId,
      name ?? resolved.name,
      topic ?? resolved.topic,
    );
    applyCoreChat(state, coreAccount, groupId);
    notifyListeners();
  }

  Future<void> leaveGroup(String groupId) async {
    await coreAccount.leaveGroup(groupId);
    applyCoreChat(state, coreAccount, groupId);
    notifyListeners();
  }

  /// Leaves a group and forgets it locally, as one action.
  ///
  /// See [declineGroupInvite]'s known limitation -- the same gap applies here.
  Future<void> leaveAndDeleteGroup(String groupId) async {
    await coreAccount.leaveGroup(groupId);
    coreAccount.deleteChat(groupId);
    applyCoreState(state, coreAccount);
    notifyListeners();
  }

  /// Ends the group, for the founder. They cannot leave one -- that would
  /// leave an authority behind that is not in the member list.
  Future<void> dissolveGroup(String groupId) async {
    await coreAccount.dissolveGroup(groupId);
    applyCoreChat(state, coreAccount, groupId);
    notifyListeners();
  }

  /// Sends a message into a group: one separately encrypted copy per member,
  /// through the core (SRV-23, the cut) -- CoreAccount.send dispatches on the
  /// chat id, the one namespace a peer and a group id share, so this is the
  /// same call [sendMessage] makes.
  ///
  /// There is no group key. Every copy rides that member's own pairwise
  /// ratchet, which is what makes removing somebody take effect immediately
  /// and need no re-key anywhere (see the design document).
  ///
  /// **Known gap**: the reply preview's author is not carried on the wire for
  /// an outgoing group reply -- freizone-server's pkg/client.SendOptions has
  /// no field for it (only content decoded from an *incoming* envelope ever
  /// populates ReplyPreviewAuthorID). Quoting a message that is not your own
  /// in a group therefore reaches the recipient without saying whose it was.
  /// The placeholder below still shows it correctly for the sender's own
  /// screen, since that renders from local data before the real send has
  /// even started.
  Future<void> sendGroupMessage(
    String groupId,
    String text, {
    String? replyToId,
    OutgoingAttachment? attachment,
  }) async {
    final chat = state.groups[groupId];
    final resolved = groupState(groupId)?.resolved;
    if (chat == null) throw StateError('no group $groupId');
    if (resolved == null) {
      // A transcript with no facts behind it: a message overtook the snapshot
      // that introduces the group. The member list is what a fan-out sends to,
      // so there is nothing to send to -- said in those terms rather than as
      // "no group", which is untrue and unactionable (the group screen shows the
      // same thing, see its composer branch).
      throw StateError(
        "This group's details haven't reached this device yet, so there is "
        'nobody to send to. It should catch up on its own.',
      );
    }
    if (resolved.dissolved) {
      throw StateError('This group has been dissolved.');
    }
    final me = resolved.memberById(state.accountId);
    if (me == null || !me.joined) {
      throw StateError('You are not a member of this group.');
    }

    final quoted = replyToId == null ? null : chat.messageById(replyToId);
    final now = DateTime.now().toUtc();

    final placeholder = StoredMessage(
      id: generateMessageId(),
      text: text,
      mine: true,
      timestamp: now,
      replyToId: quoted?.id,
      replyPreviewText: quoted?.text,
      replyPreviewMine: quoted?.mine,
      replyPreviewAuthorId: quoted == null
          ? null
          : (quoted.mine ? state.accountId : quoted.senderAccountId),
      sendState: MessageSendState.pending,
      attachments: attachment == null
          ? const []
          : [_placeholderAttachment(attachment)],
      // Only members who have accepted, matching who the core will actually
      // address -- an invitation must not disclose the invitee's address to
      // the group before they agree to it.
      deliveries: [
        for (final member in resolved.members)
          if (member.joined && member.accountId != state.accountId)
            GroupDelivery(
              accountId: member.accountId,
              wireMessageId: _randomHex(16),
            ),
      ],
    );
    chat.messages.add(placeholder);
    chat.lastActivityAt = now;
    notifyListeners();

    Object? error;
    try {
      await _sendViaCore(
        groupId,
        text,
        replyToId: quoted?.id,
        replyPreviewText: quoted?.text,
        replyPreviewMine: quoted?.mine,
        attachment: attachment,
      );
    } catch (e) {
      error = e;
      lastError = 'send failed: ${describeError(e)}';
    } finally {
      chat.messages.remove(placeholder);
      applyCoreChat(state, coreAccount, groupId);
      _logGroupDelivery('sent', groupId, null);
    }
    if (error == null) lastError = null;
    notifyListeners();
    if (error != null) throw error;
  }

  /// Writes the per-member outcome of one group fan-out to the log.
  ///
  /// A group send is the one path whose result exists nowhere but the bubble.
  /// The sending server records the copies it accepted and knows nothing of
  /// the ones addressed elsewhere; the server that refused, being down, logs
  /// nothing at all. So a partial delivery could until now only be described
  /// from the screen -- which is precisely the state a retry has to be
  /// debugged from. [logDiagnostic] keeps it out of release builds.
  ///
  /// [messageId] is null after a first send, where the core mints the id and
  /// the placeholder's is discarded; the newest outgoing line is that message.
  void _logGroupDelivery(String label, String groupId, String? messageId) {
    final chat = state.groups[groupId];
    if (chat == null) return;
    StoredMessage? message;
    if (messageId != null) {
      message = chat.messageById(messageId);
    } else {
      for (var i = chat.messages.length - 1; i >= 0; i--) {
        if (chat.messages[i].mine) {
          message = chat.messages[i];
          break;
        }
      }
    }
    if (message == null || message.deliveries.isEmpty) return;
    final each = message.deliveries.map((d) {
      // The detail, not the sentence the sheet shows: what is useful here is
      // the endpoint and the syscall, which is exactly what the sheet leaves
      // out.
      final why = d.detail ?? d.error;
      return '${shortAccountId(d.accountId)}=${d.state.name}'
          '${why == null ? '' : ' ($why)'}';
    });
    logDiagnostic(
      '$label ${shortAccountId(groupId)}/${message.id.substring(0, 8)}: '
      '${each.join(', ')}',
    );
  }

  /// Re-sends only the copies of a group message that never arrived.
  /// Re-sends into the gap only -- the members whose copy of [messageId]
  /// never arrived -- via freizone-server's pkg/client.RetryGroupMessage,
  /// added for exactly this call. Nothing to recover from disk: the core
  /// keeps the attachment bytes (if any) itself.
  Future<void> retryGroupSend(String groupId, String messageId) async {
    final chat = state.groups[groupId];
    final message = chat?.messageById(messageId);
    if (chat == null || message == null || !message.isGroupSend) return;
    if (!_retrying.add(messageId)) return;

    message.sendState = MessageSendState.pending;
    message.sendError = null;
    notifyListeners();

    try {
      await coreAccount.retry(groupId, messageId);
      lastError = null;
    } catch (e) {
      lastError = 'send failed: ${describeError(e)}';
      rethrow;
    } finally {
      _retrying.remove(messageId);
      applyCoreChat(state, coreAccount, groupId);
      _logGroupDelivery('retried', groupId, messageId);
      notifyListeners();
    }
  }

  Future<void> _storeGroupState(
    GroupStateResult result, {
    String? groupId,
  }) async {
    final id = groupId ?? result.groupId;
    if (id.isEmpty) return;
    _groupStates[id] = result;
    _refreshGroupName(id);
    await GroupStateStore.save(state.accountId, id, result.state);
  }

  void _refreshGroupNames() {
    for (final id in state.groups.keys) {
      _refreshGroupName(id);
    }
  }

  /// Copies the folded name onto the transcript, so a chat-list row can be
  /// drawn without opening every group's file. The one derived value kept
  /// outside the fact set, and it has exactly one writer.
  void _refreshGroupName(String groupId) {
    final conversation = state.groups[groupId];
    final resolved = _groupStates[groupId]?.resolved;
    if (conversation == null || resolved == null) return;
    conversation.displayName = resolved.name.isEmpty ? null : resolved.name;

    // An invitation this account has not accepted yet: listed, but nothing is
    // sent to us and we send nothing into it.
    final me = resolved.memberById(state.accountId);
    conversation.invitePending = me != null && !me.joined;
  }

  // The sender's own copy of a picture is written by the core before the
  // network is touched (pkg/client.SendText), so there is nothing to keep here.

  /// Starts downloading a just-arrived picture, and tells the UI when it lands
  /// so a bubble already on screen swaps its placeholder for the real file.
  ///
  /// Through the core, exactly as [ImageAttachment] does when a bubble asks for
  /// itself -- the same call, just made earlier. It has to be: the key a blob is
  /// opened with never crosses the FFI (see native's attachmentDTO), so this
  /// side cannot download anything itself.
  ///
  /// Every failure is swallowed: this is an optimisation over the lazy fetch,
  /// and a picture that cannot be downloaded now still gets its tap-to-retry
  /// placeholder from [ImageAttachment] exactly as before.
  Future<void> _prefetchAttachment({
    required String chatId,
    required String messageId,
  }) async {
    try {
      final path = await coreAccount.attachmentPath(chatId, messageId);
      if (path.isEmpty) return;
      notifyListeners();

      // APP-20's automatic save, off unless the user turned it on. This is the
      // moment a received picture first exists as a file, and the only one at
      // which "as it arrives" means anything. Best-effort and never prompting:
      // a picture landing in the background must not raise a permission
      // dialog, and a save that fails leaves the copy inside the app.
      if ((await AppSettings.load()).autoSavePicturesToGallery) {
        unawaited(saveImageToGallery(File(path), mayPrompt: false));
      }
    } catch (_) {
      // Left to the lazy path, which reports it in the bubble.
    }
  }


  /// Discards the ratchet session with [peerAccountId] so a fresh X3DH runs as
  /// initiator, carrying an `initial` the peer's receive path accepts in
  /// place of their stale session. Recovers a conversation whose Double
  /// Ratchet has desynced (messages silently fail to decrypt). The
  /// conversation, its history and the known/blocked status are all kept, and
  /// a system marker goes into the transcript for transparency.
  ///
  /// Through the core now (SRV-23, the cut) -- CoreAccount.resetSession, not
  /// the Dart-side discard-and-rekey this replaces. That distinction actually
  /// matters here in a way it does not for send/receive: discarding only the
  /// Dart-side session while the core goes on sending from *its* untouched
  /// one would not be a no-op, it would be worse than doing nothing -- the
  /// peer legitimately adopts the fresh session this call's re-key signal
  /// carries, while this account's own sends kept coming from the old one,
  /// diverging on purpose where nothing had actually gone wrong yet.
  Future<void> resetSecureSession(String peerAccountId) async {
    await coreAccount.resetSession(peerAccountId);
    applyCoreChat(state, coreAccount, peerAccountId);
    notifyListeners();
  }


  /// Encrypts and sends text to peerAccountId's conversation, through the
  /// core (SRV-23, the cut). If [replyToId] names a message still in local
  /// history, a self-contained snapshot of it (text + whether it was ours)
  /// rides along inside the encrypted content -- so the quote still renders
  /// for the recipient even if that original message is later deleted
  /// (locally, on either side) or otherwise unavailable. [replyToId] is
  /// silently dropped if the message can't be found locally anymore (e.g. it
  /// was deleted in the time it took to compose this reply) -- the calling
  /// screen only offers "reply" from a message that's currently on screen, so
  /// that's expected to be rare, not an error worth surfacing.
  ///
  /// The bubble appears immediately, as [MessageSendState.pending] -- but only
  /// as a throwaway local placeholder: [CoreAccount.send] is one opaque call
  /// that returns (or throws) only once the whole send, network included, is
  /// done, so there is no intermediate "written, now uploading" moment to
  /// show on this side of the boundary any more. The placeholder is removed
  /// once that call settles, in favour of the core's own record -- which by
  /// then already has the message, sent or [MessageSendState.failed], so the
  /// bubble never actually disappears from the user's point of view.
  ///
  /// Throws on failure -- the calling screen can explain why (e.g. a
  /// SnackBar) -- but the message is durable and retryable (see [retrySend])
  /// regardless of whether anything catches it.
  Future<void> sendMessage(
    String peerAccountId,
    String text, {
    String? replyToId,
    OutgoingAttachment? attachment,
  }) async {
    final convo = state.conversations[peerAccountId];
    if (convo == null) {
      throw StateError('no conversation for $peerAccountId');
    }

    final quoted = replyToId == null ? null : convo.messageById(replyToId);
    final now = DateTime.now().toUtc();
    final placeholder = StoredMessage(
      id: generateMessageId(),
      text: text,
      mine: true,
      timestamp: now,
      replyToId: quoted?.id,
      replyPreviewText: quoted?.text,
      replyPreviewMine: quoted?.mine,
      attachments: attachment == null
          ? const []
          : [_placeholderAttachment(attachment)],
      sendState: MessageSendState.pending,
    );
    convo.messages.add(placeholder);
    convo.lastActivityAt = now;
    notifyListeners();

    Object? error;
    try {
      await _sendViaCore(
        peerAccountId,
        text,
        replyToId: quoted?.id,
        replyPreviewText: quoted?.text,
        replyPreviewMine: quoted?.mine,
        attachment: attachment,
      );
    } catch (e) {
      error = e;
      lastError = 'send failed: ${describeError(e)}';
    } finally {
      convo.messages.remove(placeholder);
      applyCoreChat(state, coreAccount, peerAccountId);
    }
    if (error == null) lastError = null;
    notifyListeners();
    if (error != null) throw error;
  }

  /// Re-sends a message whose send failed, including one composed in an
  /// earlier run of the app. Nothing to recover from disk any more -- the
  /// core kept the attachment bytes (if any) itself the whole time, see
  /// freizone-server's pkg/client.RetryMessage.
  Future<void> retrySend(String peerAccountId, String messageId) async {
    final convo = state.conversations[peerAccountId];
    if (convo == null) return;
    final message = convo.messageById(messageId);
    if (message == null || !message.hasFailed) return;
    if (!_retrying.add(messageId)) return;

    message.sendState = MessageSendState.pending;
    message.sendError = null;
    notifyListeners();

    try {
      await coreAccount.retry(peerAccountId, messageId);
      lastError = null;
    } catch (e) {
      lastError = 'send failed: ${describeError(e)}';
      rethrow;
    } finally {
      _retrying.remove(messageId);
      applyCoreChat(state, coreAccount, peerAccountId);
      notifyListeners();
    }
  }

  /// Retries everything still unsent, oldest first, one chat at a time --
  /// one-to-one messages and group messages. Called after state is loaded and
  /// whenever the stream reconnects, which are exactly the two moments
  /// something that failed for want of a network might now succeed --
  /// reconnecting is also what settles any group snapshot debt on its own,
  /// see [CoreAccount.maintain] in _startStream's onConnected.
  Future<void> flushOutbox() async {
    for (final convo in state.conversations.values.toList()) {
      final unsent = convo.messages
          .where((m) => m.hasFailed && m.kind == StoredMessageKind.normal)
          .toList();
      for (final message in unsent) {
        // Checked here as well as in the retry itself, so an overlapping flush
        // does not spend one of the three attempts on a call that returns
        // without doing anything.
        if (_retrying.contains(message.id)) continue;
        final attempts = _outboxAttempts[message.id] ?? 0;
        if (attempts >= _maxOutboxAttempts) continue;
        _outboxAttempts[message.id] = attempts + 1;
        try {
          await retrySend(convo.peerAccountId, message.id);
          _outboxAttempts.remove(message.id);
        } catch (_) {
          // retrySend has already recorded the failure on the message; a
          // flush must keep going so one dead peer cannot hold up the rest.
        }
      }
    }

    // Group sends, on the same terms. A fan-out is if anything more likely to
    // be interrupted part-way than a one-to-one send -- it has as many chances
    // to fail as the group has members -- and until this it was the one send
    // path with no automatic second attempt at all: only the k-of-N indicator
    // and a manual retry in the group screen.
    for (final chat in state.groups.values.toList()) {
      final unsent = chat.messages
          .where(
            (m) =>
                m.isGroupSend &&
                m.aggregateSendState == MessageSendState.failed &&
                m.kind == StoredMessageKind.normal,
          )
          .toList();
      for (final message in unsent) {
        if (_retrying.contains(message.id)) continue;
        final attempts = _outboxAttempts[message.id] ?? 0;
        if (attempts >= _maxOutboxAttempts) continue;
        _outboxAttempts[message.id] = attempts + 1;
        try {
          // Addresses only the copies that never arrived (see
          // pkg/client.RetryGroupMessage), so a retry cannot deliver a second
          // copy to a member who already has it.
          await retryGroupSend(chat.groupId, message.id);
          _outboxAttempts.remove(message.id);
        } catch (_) {
          // Same reasoning as above: one unreachable member must not hold up
          // the rest of the flush.
        }
      }
    }
  }

  /// Sends into [chatId] -- a peer account id or a group id, the one
  /// namespace both share -- through the core. [CoreAccount.send] takes a
  /// path for an attachment, not bytes, since the native boundary reads the
  /// file itself; [attachment]'s bytes go to a temporary file first, deleted
  /// again once this call returns either way. The core makes its own durable
  /// copy before touching the network (see pkg/client.SendText's own doc
  /// comment on why), so there is nothing left in the temporary file worth
  /// keeping once it has been read.
  Future<void> _sendViaCore(
    String chatId,
    String text, {
    String? replyToId,
    String? replyPreviewText,
    bool? replyPreviewMine,
    OutgoingAttachment? attachment,
  }) async {
    String? mediaPath;
    String? thumbPath;
    if (attachment != null) {
      final dir = await getTemporaryDirectory();
      final base =
          '${dir.path}${Platform.pathSeparator}${generateMessageId()}';
      mediaPath = '$base.img';
      await File(mediaPath).writeAsBytes(attachment.bytes);
      final thumb = attachment.thumb;
      if (thumb != null) {
        thumbPath = '$base.thumb';
        await File(thumbPath).writeAsBytes(thumb);
      }
    }
    try {
      await coreAccount.send(
        chatId,
        text,
        replyToId: replyToId,
        replyPreviewText: replyPreviewText,
        replyPreviewMine: replyPreviewMine,
        mediaPath: mediaPath,
        thumbPath: thumbPath,
        mimeType: attachment?.mimeType,
        width: attachment?.width ?? 0,
        height: attachment?.height ?? 0,
      );
    } finally {
      if (mediaPath != null) {
        try {
          await File(mediaPath).delete();
        } catch (_) {
          // A leftover temp file costs disk space, never correctness.
        }
      }
      if (thumbPath != null) {
        try {
          await File(thumbPath).delete();
        } catch (_) {
          // Same as above.
        }
      }
    }
  }

  /// The attachment entry a still-uploading picture carries: everything the
  /// bubble needs to render it from our own local copy (kind, mime, size,
  /// dimensions, thumbnail), but no blob reference yet -- the server assigns
  /// that on upload. Never persisted (a pending message is session-only) and
  /// never used to fetch anything, since a picture of our own is never
  /// downloaded back (see ImageAttachment).
  MessageAttachment _placeholderAttachment(OutgoingAttachment attachment) =>
      MessageAttachment(
        kind: 'image',
        blobId: '',
        key: Uint8List(0),
        mimeType: attachment.mimeType,
        byteSize: attachment.bytes.length,
        width: attachment.width,
        height: attachment.height,
        thumb: attachment.thumb,
      );


  // Sending a receipt, and re-firing one that silently failed, are the core's
  // now: pkg/client.SendReceipt advances its own "already told them" marker
  // only once the send has actually gone out, so a lost one is simply sent
  // again the next time there is something to confirm.

  /// The one-to-one conversation or the group with this id.
  ///
  /// The two live in separate maps, but everything below only needs what they
  /// share as [ChatTarget] -- a message list and a set of pinned ids -- so one
  /// lookup serves both. Ids cannot collide: one is an account id, the other a
  /// group id, and both are generated, never chosen.
  ChatTarget? chatTarget(String chatId) =>
      state.conversations[chatId] ?? state.groups[chatId];

  /// Removes a single message from this device's own history only -- every
  /// other member's copy and the (already-deleted-from-queue) server side are
  /// unaffected. A no-op if the id isn't found (already removed).
  Future<void> deleteMessageLocally(String chatId, String messageId) async {
    final chat = chatTarget(chatId);
    if (chat == null) return;
    chat.messages.removeWhere((m) => m.id == messageId);
    chat.pinnedMessageIds.remove(messageId);
    await LocalStateStore.saveProfile(state);
    notifyListeners();
  }

  /// Pins a message locally -- purely a local display preference, never
  /// sent to the peer, the group or the server. Appending (rather than
  /// inserting at the front) keeps "most recently pinned" as the natural last
  /// element, which is what the sticky bar shows by default.
  Future<void> pinMessage(String chatId, String messageId) async {
    final chat = chatTarget(chatId);
    if (chat == null || chat.pinnedMessageIds.contains(messageId)) return;
    chat.pinnedMessageIds.add(messageId);
    await LocalStateStore.saveProfile(state);
    notifyListeners();
  }

  Future<void> unpinMessage(String chatId, String messageId) async {
    final chat = chatTarget(chatId);
    if (chat == null) return;
    chat.pinnedMessageIds.remove(messageId);
    await LocalStateStore.saveProfile(state);
    notifyListeners();
  }

  /// Records that the user has dealt with the recovery-phrase backup prompt
  /// (either backed the phrase up or dismissed the nudge), so the one-time
  /// post-setup nudge on the chat list stops showing for this account.
  Future<void> markRecoveryBackupDone() async {
    if (state.recoveryBackupDone) return;
    state.recoveryBackupDone = true;
    await LocalStateStore.saveProfile(state);
    notifyListeners();
  }

  String _randomHex(int byteLen) {
    final rnd = Random.secure();
    final buf = StringBuffer();
    for (var i = 0; i < byteLen; i++) {
      buf.write(rnd.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }

  @override
  void dispose() {
    _reachabilityGraceTimer?.cancel();
    _sse?.close();
    core.coreClose(coreAccount.handle);
    api.close();
    for (final client in _peerApiClients.values) {
      client.close();
    }
    super.dispose();
  }
}

