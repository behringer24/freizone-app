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
import 'dart:developer' as developer;
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../ffi/freizone_core.dart';
import '../ffi/models.dart';
import '../net/api_client.dart';
import '../net/dto.dart';
import '../net/sse_client.dart';
import '../push/push_manager.dart';
import '../util/address_format.dart';
import '../util/freizone_address.dart';
import '../util/server_url.dart';
import 'app_settings.dart';
import 'conversation.dart';
import 'message_content.dart';
import 'local_state.dart';
import 'receipt_signal.dart';

/// How many one-time prekeys to generate and upload at once, mirroring
/// cmd/devclient's defaultOneTimePrekeyBatch.
const _oneTimePrekeyBatch = 10;

/// How low this device lets its own one-time-prekey pool get before
/// [topUpOneTimePrekeysIfNeeded] tops it back up -- comfortably above the
/// server's own lowOneTimePrekeyThreshold (internal/api/prekeys.go),
/// which only exists as a fallback wake for a device that isn't checking
/// on its own; a device that's actually in regular use should top up
/// here, well before the server ever needs to nudge it.
const _oneTimePrekeyLowWaterMark = 3;

/// Which peer a decrypted message came from, and whether it clears the
/// bar for a user-visible notification -- distinct from whether it was
/// stored at all (a blocked peer's message is decrypted and dropped,
/// never stored, so it can never be notify-worthy either).
class IncomingMessageResult {
  const IncomingMessageResult({
    required this.peerAccountId,
    required this.shouldNotify,
    this.deliveredUpTo,
  });

  final String peerAccountId;
  final bool shouldNotify;

  /// The receipt anchor of a genuinely new, stored (not blocked, not a
  /// receipt) message -- the sender's own send-time stamp when the
  /// message carried one, local arrival time otherwise (see
  /// StoredMessage.receiptAnchor); null for a receipt, a dropped/blocked
  /// message, or anything else that isn't itself a delivered chat message.
  /// Lets a caller that CAN send (AppSession, which has sending
  /// capability; a bare background sync currently doesn't -- see
  /// push_manager.dart's _syncProfile) decide whether to send a
  /// "delivered" receipt back, without processIncomingMessage itself
  /// needing to know how to send anything.
  final DateTime? deliveredUpTo;
}

/// Decrypts and stores one incoming envelope into [state] -- the shared
/// core of [AppSession._handleIncoming], factored out so a background
/// push wake (push_manager.dart's _syncAndMaybeNotify, which has no live
/// AppSession) can run the identical decrypt logic. Mutates [state]
/// in-place (sessions/conversations/one-time-prekey pool) but does not
/// save it to disk or delete [msg] server-side -- callers do both once,
/// after processing a whole batch, so several messages in one sync don't
/// each trigger their own disk write. [openConversationPeerId] only
/// matters to the live path (a background sync has no open conversation,
/// so its default of null is always correct there). Returns null if the
/// envelope couldn't be decrypted (no session and no X3DH material to
/// start one) -- caller should just skip it; other decrypt failures
/// propagate as an exception, so a caller processing several messages in
/// one batch can catch per-message and keep going.
Future<IncomingMessageResult?> processIncomingMessage(
  AppState state,
  MessageResponse msg,
  FreizoneCore core, {
  String? openConversationPeerId,
}) async {
  final parsed = core.parseEnvelope(msg.payload);

  var session = state.sessions[msg.senderAccountId];
  if (session == null) {
    final initial = parsed.initial;
    if (initial == null) return null; // no way to start a session -- drop.

    Uint8List? otpkPriv;
    final otpkId = initial.oneTimePrekeyId;
    if (otpkId != null && state.oneTimePrekeys.containsKey(otpkId)) {
      otpkPriv = state.oneTimePrekeys[otpkId]!.priv;
      state.oneTimePrekeys.remove(otpkId);
    }
    session = core.respondToSession(
      localDhIdentityPriv: state.dhIdentityPriv!,
      signedPrekeyPriv: state.signedPrekeyPriv!,
      oneTimePrekeyPriv: otpkPriv,
      initial: initial,
    );
  }

  final dec = core.sessionDecrypt(
    session: session,
    header: parsed.header,
    ciphertext: parsed.ciphertext,
  );
  state.sessions[msg.senderAccountId] = dec.session;

  final receipt = ReceiptSignal.tryDecode(dec.plaintext);
  if (receipt != null) {
    // A receipt never creates a conversation (no putIfAbsent here, unlike
    // below) -- if there's no local record of this peer at all, there's
    // nothing to update. Either way this envelope is fully processed (the
    // ratchet session already advanced above), so the caller still
    // acks/deletes it from the server queue like any other message.
    final convo = state.conversations[msg.senderAccountId];
    if (convo != null && (await AppSettings.load()).readReceiptsEnabled) {
      // Monotonic: an out-of-order or duplicate older receipt never
      // regresses an already-newer status.
      switch (receipt.status) {
        case ReceiptStatus.delivered:
          if (convo.peerDeliveredUpTo == null ||
              receipt.upToSentAt.isAfter(convo.peerDeliveredUpTo!)) {
            convo.peerDeliveredUpTo = receipt.upToSentAt;
          }
        case ReceiptStatus.read:
          if (convo.peerReadUpTo == null ||
              receipt.upToSentAt.isAfter(convo.peerReadUpTo!)) {
            convo.peerReadUpTo = receipt.upToSentAt;
          }
      }
    }
    return IncomingMessageResult(
      peerAccountId: msg.senderAccountId,
      shouldNotify: false,
    );
  }

  final content = MessageContent.decode(
    dec.plaintext,
    fallbackId: generateMessageId(),
  );
  final now = DateTime.now().toUtc();

  // Blocked/known status is looked up from AppState.blockedPeers/
  // knownPeerIds -- deliberately independent of whether a Conversation
  // for this peer currently exists, so a deleted-then-recreated
  // Conversation (see deleteConversation) picks the right state back up
  // rather than treating a blocked or already-known peer as a brand new
  // "message request."
  final blocked = state.blockedPeers.containsKey(msg.senderAccountId);
  final isFirstContact = !state.knownPeerIds.contains(msg.senderAccountId);
  // Captured before putIfAbsent creates the entry -- distinguishes the
  // message that actually starts a new "message request" from a
  // follow-up while it's still sitting there unactioned (see shouldNotify
  // below).
  final isNewConversation = !state.conversations.containsKey(
    msg.senderAccountId,
  );
  final convo = state.conversations.putIfAbsent(
    msg.senderAccountId,
    () => Conversation(
      peerAccountId: msg.senderAccountId,
      blocked: blocked,
      pendingApproval: isFirstContact && !blocked,
    ),
  );
  // Refreshed on every message that carries one (not just the first), so
  // this self-heals if local state is ever lost -- see message_content
  // .dart's senderServer.
  if (content.senderServer != null) {
    convo.peerServer = content.senderServer;
  }

  var shouldNotify = false;
  // A blocked peer's messages are still decrypted above (so the ratchet
  // session stays in sync and the server-side queue still gets drained by
  // the caller) but dropped here rather than stored or notified -- see
  // setBlocked.
  if (!convo.blocked) {
    convo.messages.add(
      StoredMessage(
        id: content.id,
        text: content.text,
        mine: false,
        timestamp: now,
        senderSentAt: content.sentAt,
        replyToId: content.replyToId,
        replyPreviewText: content.replyPreview?.text,
        replyPreviewMine: content.replyPreview?.mine,
      ),
    );
    convo.lastActivityAt = now;
    if (msg.senderAccountId != openConversationPeerId) {
      convo.hasUnread = true;
      // The message that actually creates a new "message request" still
      // notifies once -- you should learn someone wants to chat with you
      // -- but a follow-up from that same still-unaccepted sender doesn't:
      // once you've been told a request exists, it shouldn't be able to
      // keep interrupting you before you've accepted or blocked it, only
      // show up passively in the Message requests section.
      shouldNotify = isNewConversation || !convo.pendingApproval;
    }
  }

  return IncomingMessageResult(
    peerAccountId: msg.senderAccountId,
    shouldNotify: shouldNotify,
    // The sender's own send-time stamp when it carried one (see
    // StoredMessage.receiptAnchor for why receipts must be in the
    // sender's clock domain), local arrival time only as the legacy
    // fallback.
    deliveredUpTo: convo.blocked ? null : (content.sentAt ?? now),
  );
}

/// Re-asserts [state]'s DH identity + signed-prekey certificates (using
/// its already-held key material, unchanged -- never rotates anything)
/// and tops up the one-time-prekey pool if the server reports it's
/// running low. Called from [AppSession.init], on every SSE reconnect,
/// and from a background push-wake sync (push_manager.dart, no live
/// AppSession there), so it must not assume anything beyond [state]/
/// [core]/[api]. No-ops before the very first prekey upload (AppSession
/// .init handles that separately, unconditionally, the one time it's
/// actually needed).
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
Future<void> topUpOneTimePrekeysIfNeeded(
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

  final remaining = await api.getPrekeyStatus(state.credentials);
  final otpkDtos = <OneTimePrekeyDTO>[];
  if (remaining < _oneTimePrekeyLowWaterMark) {
    for (var i = remaining; i < _oneTimePrekeyBatch; i++) {
      final kp = core.generateX25519KeyPair();
      final keyId = state.nextOtpkKeyId;
      state.nextOtpkKeyId++;
      state.oneTimePrekeys[keyId] = OneTimePrekeyState(
        pub: kp.pub,
        priv: kp.priv,
      );
      otpkDtos.add(OneTimePrekeyDTO(keyId: keyId, pubKey: kp.pub));
    }
  }

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
    oneTimePrekeys: otpkDtos,
  );
  await LocalStateStore.saveProfile(state);
}

class AppSession extends ChangeNotifier {
  AppSession(this.state) {
    api = ApiClient(baseUrl: state.server, core: core);
  }

  final AppState state;
  final FreizoneCore core = FreizoneCore();
  late final ApiClient api;
  SseClient? _sse;

  /// Additional ApiClients for federated peers, keyed by their (already
  /// normalized) server url -- lazily created and reused, since a
  /// conversation's peer server rarely changes. [api] itself stays the
  /// one used for anything on this session's own server.
  final Map<String, ApiClient> _peerApiClients = {};

  /// One chained Future per peer, keyed by their account id -- every
  /// operation that reads-modifies-writes state.sessions[peerAccountId]
  /// (decrypting an incoming envelope, or encrypting an outgoing one, see
  /// _withPeerSessionLock) runs through here so two such operations for
  /// the SAME peer never overlap. Without this, e.g. a "delivered"
  /// receipt fired from _handleIncoming and a "read" receipt fired
  /// moments later from enterConversation (tapping a notification jumps
  /// straight into that chat, fast enough to still race the first send)
  /// could both encrypt from the same pre-advance ratchet snapshot and
  /// clobber each other's advancement when writing it back -- the
  /// clobbered send is still delivered over the wire, just encrypted
  /// with a state the local session no longer agrees with, so the peer's
  /// next decrypt of it can silently fail (caught, logged to lastError,
  /// nothing else) rather than crash.
  final Map<String, Future<void>> _peerSessionLocks = {};

  Future<T> _withPeerSessionLock<T>(
    String peerAccountId,
    Future<T> Function() action,
  ) async {
    final previous = _peerSessionLocks[peerAccountId] ?? Future.value();
    final done = Completer<void>();
    _peerSessionLocks[peerAccountId] = done.future;
    try {
      await previous;
      return await action();
    } finally {
      done.complete();
    }
  }

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
  String? lastError;

  /// True once a push-registration attempt found no way to deliver a
  /// background wake at all under the current PushPreference (no
  /// UnifiedPush distributor for automatic/forceUnifiedPush, or no FCM
  /// token obtainable for forceFcm/automatic's fallback). Consumed (reset
  /// to false) by whichever screen shows the one-time hint about it --
  /// chat keeps working via SSE regardless.
  bool pushUnavailable = false;

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

  /// Refreshes [registrationPolicy] from the server. Call once after
  /// [init] and again whenever the chat list is shown, so a policy
  /// change made elsewhere is picked up.
  Future<void> refreshRegistrationPolicy() async {
    try {
      final status = await api.getServerStatus();
      registrationPolicy = status.registrationPolicy;
    } catch (e) {
      lastError = 'checking registration policy failed: $e';
    }
    notifyListeners();
  }

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
        lastError = 'checking admin role failed: $e';
      }
    } catch (e) {
      lastError = 'checking admin role failed: $e';
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

  /// Temporarily disables an account. Admin only.
  Future<void> blockAccount(String accountId) async {
    await api.blockAccount(state.credentials, accountId);
    await refreshMyRole();
  }

  /// Restores a previously blocked account. Admin only.
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

  /// True if any conversation in this account has an unread message --
  /// drives the account switcher's notification dot.
  bool get hasAnyUnread => state.conversations.values.any((c) => c.hasUnread);

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

  /// The conversation the user is actually reading right now: the open
  /// one, but only while the app is in the foreground. Backgrounded, no
  /// chat counts as being read -- so an incoming message still notifies
  /// and still marks unread, and no read receipt is sent for a chat the
  /// user isn't actually looking at.
  String? get _readableConversation =>
      _appInForeground ? _openConversationPeerId : null;

  /// Called by the app-lifecycle observer (main.dart) when the app moves
  /// between foreground and background. On returning to the foreground it
  /// first adopts whatever the background push isolate wrote while the app
  /// was frozen (see _reloadVolatileStateFromDisk) -- otherwise this
  /// isolate's stale in-memory state would clobber the push isolate's
  /// ratchet advancement on the next save, desyncing the Double Ratchet
  /// and silently dropping every subsequent message. Only then, with a
  /// chat still open, re-runs the read logic so anything that arrived
  /// while backgrounded (left unread + notified) is now marked read --
  /// the user is looking at it again.
  Future<void> setForeground(bool value) async {
    if (_appInForeground == value) return;
    _appInForeground = value;
    if (!value) return;
    await _reloadVolatileStateFromDisk();
    if (_openConversationPeerId != null) {
      unawaited(enterConversation(_openConversationPeerId!));
    }
  }

  /// Re-reads this account's profile from disk and adopts the fields the
  /// background push isolate (push_manager.dart's _syncProfile) can have
  /// advanced while this isolate was frozen -- the Double Ratchet
  /// sessions above all, plus the conversation history it stored and the
  /// prekey material it may have topped up. The two isolates share state
  /// only through the profile file with last-writer-wins (see
  /// LocalStateStore.saveProfile); without adopting the disk copy on
  /// resume, this isolate keeps a stale ratchet in memory and overwrites
  /// the push isolate's progress on its next save. Identity fields
  /// (server/accountId/root*/device*) are never touched by the push
  /// isolate, so they're deliberately left as-is. The field swaps run
  /// synchronously after the single await, so no _handleIncoming can
  /// interleave mid-swap within this single-threaded isolate. Correct as
  /// a plain "disk wins": a frozen isolate produces no in-memory changes,
  /// so its memory can never be newer than disk.
  Future<void> _reloadVolatileStateFromDisk() async {
    final fresh = await LocalStateStore.loadProfile(state.accountId);
    if (fresh == null) return;
    state.sessions = fresh.sessions;
    state.conversations = fresh.conversations;
    state.oneTimePrekeys = fresh.oneTimePrekeys;
    state.nextOtpkKeyId = fresh.nextOtpkKeyId;
    state.signedPrekeyId = fresh.signedPrekeyId;
    state.signedPrekeyPub = fresh.signedPrekeyPub;
    state.signedPrekeyPriv = fresh.signedPrekeyPriv;
    state.nextSignedPrekeyId = fresh.nextSignedPrekeyId;
    state.dhIdentityPub = fresh.dhIdentityPub;
    state.dhIdentityPriv = fresh.dhIdentityPriv;
    state.knownPeerIds = fresh.knownPeerIds;
    state.blockedPeers = fresh.blockedPeers;
    notifyListeners();
  }

  /// Call when a ChatScreen for peerAccountId opens: clears its unread
  /// flag and remembers it as "currently open" for _handleIncoming.
  Future<void> enterConversation(String peerAccountId) async {
    _openConversationPeerId = peerAccountId;
    final convo = state.conversations[peerAccountId];
    if (convo == null || !convo.hasUnread) return;
    convo.hasUnread = false;

    // "Read up to" the peer's own last message, not simply the
    // conversation's last message overall -- a trailing message of mine
    // shouldn't be part of what I'm confirming I've read.
    DateTime? theirLastTimestamp;
    for (final m in convo.messages.reversed) {
      if (!m.mine) {
        theirLastTimestamp = m.receiptAnchor;
        break;
      }
    }
    if (theirLastTimestamp != null &&
        (convo.sentReadReceiptUpTo == null ||
            theirLastTimestamp.isAfter(convo.sentReadReceiptUpTo!))) {
      unawaited(_sendReceipt(convo, ReceiptStatus.read, theirLastTimestamp));
    }

    await LocalStateStore.saveProfile(state);
    // If that was the last unread conversation, clear this account's
    // "new message(s)" notification too, so its launcher-icon badge
    // (which Android derives from active notifications) goes away
    // rather than lingering after everything's been read.
    if (!hasAnyUnread) unawaited(clearMessageNotification(state.accountId));
    notifyListeners();
  }

  /// Call when that ChatScreen closes.
  void leaveConversation(String peerAccountId) {
    if (_openConversationPeerId == peerAccountId)
      _openConversationPeerId = null;
  }

  /// Uploads prekeys if this is the first run, tops up the one-time
  /// prekey pool if it's already running low, then opens the live
  /// message stream. Call once, right after construction.
  Future<void> init() async {
    try {
      if (state.signedPrekeyPub == null) {
        await _uploadPrekeys();
      } else {
        await topUpOneTimePrekeysIfNeeded(state, core, api);
      }
      prekeysReady = true;
      notifyListeners();
      _startStream();
      unawaited(refreshMyRole());
      unawaited(refreshRegistrationPolicy());
      unawaited(_registerPush());
    } catch (e) {
      lastError = 'prekey upload failed: $e';
      notifyListeners();
    }
  }

  Future<void> _registerPush() async {
    try {
      final delivered = await registerForPush(
        api,
        state.accountId,
        state.credentials,
      );
      pushUnavailable = !delivered;
      notifyListeners();
    } catch (e) {
      lastError = 'push registration failed: $e';
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

    final otpkDtos = <OneTimePrekeyDTO>[];
    for (var i = 0; i < _oneTimePrekeyBatch; i++) {
      final kp = core.generateX25519KeyPair();
      final keyId = state.nextOtpkKeyId;
      state.nextOtpkKeyId++;
      state.oneTimePrekeys[keyId] = OneTimePrekeyState(
        pub: kp.pub,
        priv: kp.priv,
      );
      otpkDtos.add(OneTimePrekeyDTO(keyId: keyId, pubKey: kp.pub));
    }

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
      oneTimePrekeys: otpkDtos,
    );
    await LocalStateStore.saveProfile(state);
  }

  void _startStream() {
    _sse = SseClient(apiClient: api, creds: state.credentials);
    unawaited(
      _sse!.connect(
        onMessage: _handleIncoming,
        onError: (e) {
          lastError = 'stream error: $e';
          notifyListeners();
        },
        onConnected: () {
          unawaited(topUpOneTimePrekeysIfNeeded(state, core, api));
          _retryPendingReceipts();
        },
      ),
    );
  }

  Future<void> _handleIncoming(MessageResponse msg) async {
    try {
      // Serialized against any in-flight send to this same peer (see
      // _withPeerSessionLock) -- decrypting also reads-modifies-writes
      // state.sessions[msg.senderAccountId], the same resource
      // _encryptAndSend touches.
      final result = await _withPeerSessionLock(
        msg.senderAccountId,
        () => processIncomingMessage(
          state,
          msg,
          core,
          openConversationPeerId: _readableConversation,
        ),
      );
      if (result == null) return;

      if (result.shouldNotify) {
        // Without this call, the launcher icon's badge (which Android
        // derives from active notifications, not anything drawn in-app)
        // would never appear for a message that happened to arrive while
        // the app was in the foreground.
        unawaited(
          showMessageNotification(
            state.accountId,
            peerAccountId: result.peerAccountId,
          ),
        );
      }

      // Only the live path sends a "delivered" receipt right away -- a
      // message processed by the background push-wake sync
      // (push_manager.dart's _syncProfile, no live AppSession there)
      // doesn't currently trigger one, so a fully-closed app only starts
      // showing delivered/read checkmarks to the sender once it's next
      // opened (which sends both anyway, see enterConversation) --
      // deliberate scope-narrowing to avoid needing every one of
      // AppSession's send-path helpers (_resolvePeerDevice,
      // _getOrCreateCryptoSession, _clientFor) to become standalone,
      // isolate-safe functions just for this.
      final upTo = result.deliveredUpTo;
      if (upTo != null) {
        final convo = state.conversations[result.peerAccountId];
        if (convo != null &&
            (convo.sentDeliveredReceiptUpTo == null ||
                upTo.isAfter(convo.sentDeliveredReceiptUpTo!))) {
          unawaited(_sendReceipt(convo, ReceiptStatus.delivered, upTo));
        }
        // A message that lands in the conversation the user is actually
        // reading right now (chat open AND app in the foreground, see
        // _readableConversation) is read the moment it arrives. Without
        // this, no read receipt would ever fire for it: enterConversation
        // only sends one when it finds the conversation unread on open,
        // and a message arriving into the open chat never marks it unread
        // (same behavior as WhatsApp/Signal: blue ticks appear immediately
        // while the chat is open). Gated on _readableConversation, not the
        // raw open-chat id, so a chat left open but sent to the background
        // (Home button doesn't dispose the ChatScreen) does NOT falsely
        // confirm "read" -- that message stays unread + notified until the
        // user actually returns (setForeground re-runs the read logic then).
        if (convo != null &&
            result.peerAccountId == _readableConversation &&
            (convo.sentReadReceiptUpTo == null ||
                upTo.isAfter(convo.sentReadReceiptUpTo!))) {
          unawaited(_sendReceipt(convo, ReceiptStatus.read, upTo));
        }
      }

      await LocalStateStore.saveProfile(state);
      unawaited(api.deleteMessage(msg.messageId, state.credentials));

      lastError = null;
      notifyListeners();
    } catch (e) {
      lastError = 'decrypt error: $e';
      notifyListeners();
    }
  }

  /// Resolves peerIdOrPrefix's true account id and verified active device
  /// -- independently verifying the full self-certifying chain, per
  /// docs/PROTOCOL.md, no trust in the server required. peerIdOrPrefix may
  /// be either the full canonical id or just its first
  /// [accountIdPrefixLength] characters (docs/PROTOCOL.md's id-prefix
  /// uniqueness note) -- either way, the returned id is always the true
  /// full one, verified against the returned device's key chain, never
  /// just echoed back from whatever shorthand was looked up with.
  /// [apiClient] is [api] for a same-server peer, or one from
  /// [_clientFor] pointed directly at a federated peer's own server.
  Future<(String accountId, DeviceResponse device)> _resolvePeerDevice(
    String peerIdOrPrefix,
    ApiClient apiClient,
  ) async {
    final acc = await apiClient.getAccount(peerIdOrPrefix);
    if (!core.verifyAddressId(acc.id, acc.rootPubKey)) {
      throw StateError('peer account id does not match its root key');
    }

    for (final d in acc.devices) {
      if (d.status != 'active') continue;
      final cert = DeviceCertificate(
        accountId: acc.id,
        deviceId: d.deviceId,
        devicePubKey: d.devicePubKey,
        issuedAt: d.issuedAt,
        signature: d.signature,
      );
      if (core.verifyDeviceCertificate(cert, acc.rootPubKey)) {
        return (acc.id, d);
      }
    }
    throw StateError('no verifiable active device found for $peerIdOrPrefix');
  }

  /// Whether a and b name the same peer server for the purpose of
  /// dedup'ing an already-resolved conversation -- both null (or both
  /// same-server) counts as a match; a prefix is only unique per server
  /// (docs/PROTOCOL.md), so a lookup must agree on the server too, not
  /// just the id/prefix, once more than one server is in play.
  bool _samePeerServer(String? a, String? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    return sameServer(a, b);
  }

  /// Resolves and creates, or returns the already-resolved, Conversation
  /// with peerAddress -- a full Freizone address (`id*server`, `id*local`,
  /// or just a bare id/prefix, see lib/util/freizone_address.dart), so a
  /// dash-grouped or phone-dictated id ("k5x9 p2qa n7f3...") resolves the
  /// same as the canonical form, and may be just the first
  /// [accountIdPrefixLength] characters (unique per server, see
  /// docs/PROTOCOL.md), in which case an already-known conversation
  /// resolves purely locally, with no network round trip. An explicit
  /// `*server` that isn't this session's own (or `local`) is a federated
  /// address (docs/PROTOCOL.md §9): resolved and messaged directly
  /// against that server, not this session's own. If displayName is
  /// given and this is a new conversation, it's set as the initial local
  /// alias.
  Future<Conversation> startConversation(
    String peerAddress, {
    String? displayName,
  }) async {
    final parsed = parseFreizoneAddress(peerAddress);
    if (parsed == null) throw StateError('Not a valid Freizone address');
    final normalized = parsed.idOrPrefix;

    final existing = state.conversations[normalized];
    if (existing != null &&
        existing.peerDeviceId != null &&
        _samePeerServer(existing.peerServer, parsed.server)) {
      await _markKnown(existing);
      return existing;
    }

    if (normalized.length == accountIdPrefixLength) {
      for (final convo in state.conversations.values) {
        if (convo.peerDeviceId != null &&
            convo.peerAccountId.startsWith(normalized) &&
            _samePeerServer(convo.peerServer, parsed.server)) {
          await _markKnown(convo);
          return convo;
        }
      }
    }

    final peerApi = _clientFor(parsed.server);
    final (resolvedId, verified) = await _resolvePeerDevice(
      normalized,
      peerApi,
    );

    final convo = state.conversations.putIfAbsent(
      resolvedId,
      () => Conversation(peerAccountId: resolvedId),
    );
    convo.peerServer = sameServer(parsed.server ?? state.server, state.server)
        ? null
        : parsed.server;
    convo.peerDeviceId = verified.deviceId;
    convo.peerDevicePubKey = verified.devicePubKey;
    if (convo.displayName == null &&
        displayName != null &&
        displayName.trim().isNotEmpty) {
      convo.displayName = displayName.trim();
    }
    convo.pendingApproval = false;
    state.knownPeerIds.add(resolvedId);
    await LocalStateStore.saveProfile(state);
    notifyListeners();
    return convo;
  }

  /// Reaching out to (or back to) a peer yourself is an implicit accept
  /// -- there's no "pending" decision left to make about someone you just
  /// deliberately chose to (re-)contact, e.g. via the new-chat sheet's
  /// address field even while their message request sat unactioned. Only
  /// writes/notifies if anything actually changed.
  Future<void> _markKnown(Conversation convo) async {
    final wasPending = convo.pendingApproval;
    convo.pendingApproval = false;
    final added = state.knownPeerIds.add(convo.peerAccountId);
    if (wasPending || added) {
      await LocalStateStore.saveProfile(state);
      notifyListeners();
    }
  }

  /// Sets, changes, or (name == null / blank) removes a conversation's
  /// local alias. Purely local -- never sent to the peer or the server.
  Future<void> setDisplayName(String peerAccountId, String? name) async {
    final convo = state.conversations[peerAccountId];
    if (convo == null) return;
    convo.displayName = (name == null || name.trim().isEmpty)
        ? null
        : name.trim();
    await LocalStateStore.saveProfile(state);
    notifyListeners();
  }

  /// Every peer blocked locally -- backs the "Blocked contacts" screen,
  /// which needs to list and unblock peers even once their Conversation
  /// (and thus their profile screen) no longer exists.
  List<BlockedPeer> get blockedPeers => state.blockedPeers.values.toList();

  /// Blocks or unblocks a peer -- purely local, since Freizone's open
  /// registration means an unwanted contact can't be reported or banned
  /// server-side yet (see peer_profile_screen.dart's "Protection"
  /// section). Further incoming messages are still decrypted (so the
  /// ratchet session and the server's per-recipient queue both stay
  /// clean) but dropped before being stored or notified -- see
  /// _handleIncoming. Sending is disabled in the UI while blocked. The
  /// peer is never told either way.
  ///
  /// The block itself lives in [AppState.blockedPeers], not on the
  /// [Conversation] -- deliberately outliving [deleteConversation] (see
  /// its own doc comment), so deleting a blocked peer's chat can never
  /// silently un-block them, and there's always a way to unblock them
  /// again (the "Blocked contacts" screen) even with no conversation left.
  /// [convo], if one currently exists, is kept as an in-sync mirror so
  /// existing chat/profile UI can keep reading `convo.blocked` directly.
  Future<void> setBlocked(String peerAccountId, bool blocked) async {
    final convo = state.conversations[peerAccountId];
    if (blocked) {
      state.blockedPeers[peerAccountId] = BlockedPeer(
        peerAccountId: peerAccountId,
        peerServer: convo?.peerServer,
        displayName: convo?.displayName,
      );
      if (convo != null) {
        convo.blocked = true;
        // Blocking is itself a decision about a pending request --
        // nothing left to approve.
        convo.pendingApproval = false;
      }
    } else {
      state.blockedPeers.remove(peerAccountId);
      // Unblocking is itself a decision to hear from them normally again
      // -- they shouldn't reappear as an unactioned "message request" the
      // next time they write.
      state.knownPeerIds.add(peerAccountId);
      if (convo != null) convo.blocked = false;
    }
    await LocalStateStore.saveProfile(state);
    notifyListeners();
  }

  /// Accepts a pending "message request" (see Conversation.pendingApproval)
  /// -- purely local, just lifts the UI gate so the chat screen shows the
  /// normal composer instead of the Accept/Block bar. Nothing is sent to
  /// the peer or the server; they have no way to know either way. Records
  /// them in [AppState.knownPeerIds] so a later [deleteConversation]
  /// doesn't regress them back to "unactioned request" if they write again.
  Future<void> acceptConversation(String peerAccountId) async {
    final convo = state.conversations[peerAccountId];
    if (convo == null) return;
    convo.pendingApproval = false;
    state.knownPeerIds.add(peerAccountId);
    await LocalStateStore.saveProfile(state);
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
    await LocalStateStore.saveProfile(state);
    if (hadUnread && !hasAnyUnread)
      unawaited(clearMessageNotification(state.accountId));
    notifyListeners();
  }

  /// Removes peerAccountId's conversation entirely -- history and the
  /// resolved peer device. The ratchet session is deliberately kept: the
  /// peer doesn't know their chat was deleted on our end and may just keep
  /// writing in what looks to them like an ongoing conversation, without
  /// including fresh X3DH material. Without a surviving session, such a
  /// message can't be decrypted at all (no session and no X3DH material to
  /// start one -- see _handleIncoming) and is lost silently, for both
  /// sides, with no error or notification anywhere. Purely local: the
  /// account itself is untouched on the server.
  Future<void> deleteConversation(String peerAccountId) async {
    final removed = state.conversations.remove(peerAccountId);
    if (removed == null) return;
    if (_openConversationPeerId == peerAccountId)
      _openConversationPeerId = null;
    await LocalStateStore.saveProfile(state);
    if (removed.hasUnread && !hasAnyUnread)
      unawaited(clearMessageNotification(state.accountId));
    notifyListeners();
  }

  /// Returns the existing session with a conversation's peer, or
  /// establishes a new one as X3DH initiator by claiming their prekey
  /// bundle.
  Future<(RatchetSessionJson, InitialMessage?)> _getOrCreateCryptoSession(
    Conversation convo,
  ) async {
    final existing = state.sessions[convo.peerAccountId];
    if (existing != null) return (existing, null);

    final bundle = await _clientFor(
      convo.peerServer,
    ).claimPrekeyBundle(convo.peerDeviceId!);

    final dhCert = DHIdentityCertificate(
      accountId: convo.peerAccountId,
      deviceId: convo.peerDeviceId!,
      dhPubKey: bundle.dhIdentityPubKey,
      issuedAt: bundle.dhIdentityCert.issuedAt,
      signature: bundle.dhIdentityCert.signature,
    );
    if (!core.verifyDHIdentityCertificate(dhCert, convo.peerDevicePubKey!)) {
      throw StateError('invalid dh identity certificate');
    }

    final spkCert = SignedPrekeyCertificate(
      accountId: convo.peerAccountId,
      deviceId: convo.peerDeviceId!,
      keyId: bundle.signedPrekey.keyId,
      dhIdentityPubKey: bundle.signedPrekey.dhIdentityPubKey,
      prekeyPubKey: bundle.signedPrekey.pubKey,
      issuedAt: bundle.signedPrekey.issuedAt,
      signature: bundle.signedPrekey.signature,
    );
    if (!core.verifySignedPrekeyCertificate(spkCert, convo.peerDevicePubKey!)) {
      throw StateError('invalid signed prekey certificate');
    }
    if (!listEquals(
      bundle.signedPrekey.dhIdentityPubKey,
      bundle.dhIdentityPubKey,
    )) {
      throw StateError(
        'signed prekey is not bound to the claimed dh identity key',
      );
    }

    final remote = RemoteBundle(
      dhIdentityPub: bundle.dhIdentityPubKey,
      signedPrekeyId: bundle.signedPrekey.keyId,
      signedPrekeyPub: bundle.signedPrekey.pubKey,
      oneTimePrekeyId: bundle.oneTimePrekey?.keyId,
      oneTimePrekeyPub: bundle.oneTimePrekey?.pubKey,
    );
    final result = core.initiateSession(
      localDhIdentityPriv: state.dhIdentityPriv!,
      remote: remote,
    );
    state.sessions[convo.peerAccountId] = result.session;
    return (result.session, result.initial);
  }

  /// Encrypts and sends text to peerAccountId's conversation, appending
  /// it to the persisted history. If [replyToId] names a message still in
  /// local history, a self-contained snapshot of it (text + whether it
  /// was ours) rides along inside the encrypted content -- so the quote
  /// still renders for the recipient even if that original message is
  /// later deleted (locally, on either side) or otherwise unavailable.
  /// [replyToId] is silently dropped if the message can't be found
  /// locally anymore (e.g. it was deleted in the time it took to compose
  /// this reply) -- the calling screen only offers "reply" from a message
  /// that's currently on screen, so that's expected to be rare, not an
  /// error worth surfacing.
  ///
  /// Throws on failure -- the calling screen decides how to surface that
  /// (e.g. a SnackBar).
  Future<void> sendMessage(
    String peerAccountId,
    String text, {
    String? replyToId,
  }) async {
    final convo = state.conversations[peerAccountId];
    if (convo == null) {
      throw StateError('no conversation for $peerAccountId');
    }
    await _ensurePeerDeviceResolved(convo);

    final quoted = replyToId == null ? null : convo.messageById(replyToId);
    // Flipped relative to our own `quoted.mine`: the recipient reads this
    // same field as "mine" from *their* perspective, where the roles are
    // swapped (see message_content.dart).
    final wirePreview = quoted == null
        ? null
        : ReplyPreview(text: quoted.text, mine: !quoted.mine);

    // Stamped ONCE, before the send: this exact instant goes out inside
    // the encrypted content (sentAt) AND becomes the local StoredMessage
    // .timestamp below -- receipts echo it back verbatim, and the
    // checkmark comparison (chat_screen.dart) is then an equality within
    // this one clock reading. Stamping after the await (as this used to)
    // loses that race locally: the receiver can decrypt and stamp its
    // receipt before the sender's own post-send stamp is even taken.
    final now = DateTime.now().toUtc();
    final content = MessageContent(
      id: generateMessageId(),
      text: text,
      replyToId: quoted?.id,
      replyPreview: wirePreview,
      // Sent on every cross-server message (not just the first), so the
      // recipient's knowledge of where to reach us for a reply
      // self-heals even if their local state is ever lost -- see
      // message_content.dart.
      senderServer: convo.peerServer != null ? state.server : null,
      sentAt: now,
    );

    await _encryptAndSend(convo, content.encode());

    convo.messages.add(
      StoredMessage(
        id: content.id,
        text: text,
        mine: true,
        timestamp: now,
        replyToId: quoted?.id,
        replyPreviewText: quoted?.text,
        replyPreviewMine: quoted?.mine,
      ),
    );
    convo.lastActivityAt = now;
    await LocalStateStore.saveProfile(state);

    lastError = null;
    notifyListeners();
  }

  /// Resolves and caches convo's peer device, if it hasn't been already --
  /// a conversation that only ever received messages (never started via
  /// startConversation, and never sent to before) has no resolved peer
  /// device yet. Shared by [sendMessage] and [_sendReceipt], since a
  /// receipt needs somewhere to send to just as much as a real message
  /// does, even if the user has never sent this peer anything themselves.
  Future<void> _ensurePeerDeviceResolved(Conversation convo) async {
    if (convo.peerDeviceId != null) return;
    final (_, verified) = await _resolvePeerDevice(
      convo.peerAccountId,
      _clientFor(convo.peerServer),
    );
    convo.peerDeviceId = verified.deviceId;
    convo.peerDevicePubKey = verified.devicePubKey;
    await LocalStateStore.saveProfile(state);
  }

  /// Encrypts plaintext for convo's peer device and posts it via the
  /// correct path (same-server vs federated) -- the shared core of
  /// [sendMessage] and [_sendReceipt]. Requires convo.peerDeviceId to
  /// already be resolved (see [_ensurePeerDeviceResolved]). Deliberately
  /// does not touch convo.messages/lastActivityAt or save/notify -- callers
  /// decide what, if anything, becomes locally visible; a receipt should
  /// stay invisible and shouldn't bump the conversation to the top of the
  /// chat list, unlike a real sent message.
  Future<void> _encryptAndSend(Conversation convo, Uint8List plaintext) {
    // Serialized per peer (see _withPeerSessionLock) -- two sends to the
    // same peer close together (e.g. a "delivered" receipt immediately
    // followed by a "read" one) must never both read the ratchet session
    // before either has written its advanced state back.
    return _withPeerSessionLock(convo.peerAccountId, () async {
      final (session, initial) = await _getOrCreateCryptoSession(convo);
      final enc = core.sessionEncrypt(session: session, plaintext: plaintext);
      state.sessions[convo.peerAccountId] = enc.session;

      final payload = core.buildEnvelope(
        initial: initial,
        header: enc.header,
        ciphertext: enc.ciphertext,
      );
      if (convo.peerServer == null) {
        await api.sendMessage(
          creds: state.credentials,
          messageId: _randomHex(16),
          recipientDeviceId: convo.peerDeviceId!,
          payload: payload,
        );
      } else {
        // The recipient's server has no local row for this device, so
        // the request carries a freshly-signed certificate instead of
        // relying on one cached at registration time -- see
        // docs/PROTOCOL.md §9.
        final cert = core.signDeviceCertificate(
          accountId: state.accountId,
          deviceId: state.deviceId,
          devicePub: state.devicePub,
          issuedAt: DateTime.now().toUtc(),
          rootPriv: state.rootPriv,
        );
        await _clientFor(convo.peerServer).sendFederatedMessage(
          devicePriv: state.devicePriv,
          rootPub: state.rootPub,
          senderAccountId: state.accountId,
          cert: cert,
          messageId: _randomHex(16),
          recipientDeviceId: convo.peerDeviceId!,
          payload: payload,
        );
      }
    });
  }

  /// Sends a delivery/read receipt to convo's peer, gated by
  /// AppSettings.readReceiptsEnabled -- best-effort: failures are logged,
  /// not surfaced, since a missed receipt just leaves the peer's
  /// checkmark one step behind until the next one goes out, not a lost
  /// message. The "sent up to" marker (Conversation.sentDeliveredReceiptUpTo
  /// / sentReadReceiptUpTo) is only advanced once the send actually
  /// succeeds -- callers must NOT set it themselves beforehand, or a
  /// failed send would be marked done anyway and never get retried. See
  /// _retryPendingReceipts for how a failed send gets a second chance.
  Future<void> _sendReceipt(
    Conversation convo,
    ReceiptStatus status,
    DateTime upToSentAt,
  ) async {
    try {
      if (!(await AppSettings.load()).readReceiptsEnabled) return;
      await _ensurePeerDeviceResolved(convo);
      await _encryptAndSend(
        convo,
        ReceiptSignal(status: status, upToSentAt: upToSentAt).encode(),
      );
      if (status == ReceiptStatus.read) {
        convo.sentReadReceiptUpTo = upToSentAt;
      } else {
        convo.sentDeliveredReceiptUpTo = upToSentAt;
      }
      await LocalStateStore.saveProfile(state);
    } catch (e) {
      developer.log('sending $status receipt failed: $e', name: 'receipts');
    }
  }

  /// Re-checks every conversation's delivered/read markers against its
  /// locally known message history and re-fires any receipt that never
  /// got through -- the self-heal for _sendReceipt's silent failures.
  /// Called on every SSE (re)connect (see _startStream), mirroring
  /// topUpOneTimePrekeysIfNeeded's own "init + reconnect" trigger. A read
  /// receipt is only retried once the conversation is confirmed actually
  /// read locally (!convo.hasUnread, set unconditionally by
  /// enterConversation regardless of whether its own send succeeded) --
  /// otherwise this could wrongly tell a peer their message was read when
  /// the user never actually opened that conversation.
  void _retryPendingReceipts() {
    for (final convo in state.conversations.values) {
      DateTime? theirLastTimestamp;
      for (final m in convo.messages.reversed) {
        if (!m.mine) {
          theirLastTimestamp = m.receiptAnchor;
          break;
        }
      }
      if (theirLastTimestamp == null) continue;

      if (convo.sentDeliveredReceiptUpTo == null ||
          theirLastTimestamp.isAfter(convo.sentDeliveredReceiptUpTo!)) {
        unawaited(
          _sendReceipt(convo, ReceiptStatus.delivered, theirLastTimestamp),
        );
      }
      if (!convo.hasUnread &&
          (convo.sentReadReceiptUpTo == null ||
              theirLastTimestamp.isAfter(convo.sentReadReceiptUpTo!))) {
        unawaited(_sendReceipt(convo, ReceiptStatus.read, theirLastTimestamp));
      }
    }
  }

  /// Removes a single message from this device's own history only -- the
  /// peer's copy and the (already-deleted-from-queue) server side are
  /// unaffected. A no-op if the id isn't found (already removed).
  Future<void> deleteMessageLocally(String peerAccountId, String messageId) async {
    final convo = state.conversations[peerAccountId];
    if (convo == null) return;
    convo.messages.removeWhere((m) => m.id == messageId);
    convo.pinnedMessageIds.remove(messageId);
    await LocalStateStore.saveProfile(state);
    notifyListeners();
  }

  /// Pins a message locally -- purely a local display preference, never
  /// sent to the peer or the server. Appending (rather than inserting at
  /// the front) keeps "most recently pinned" as the natural last element,
  /// which is what the sticky bar shows by default.
  Future<void> pinMessage(String peerAccountId, String messageId) async {
    final convo = state.conversations[peerAccountId];
    if (convo == null || convo.pinnedMessageIds.contains(messageId)) return;
    convo.pinnedMessageIds.add(messageId);
    await LocalStateStore.saveProfile(state);
    notifyListeners();
  }

  Future<void> unpinMessage(String peerAccountId, String messageId) async {
    final convo = state.conversations[peerAccountId];
    if (convo == null) return;
    convo.pinnedMessageIds.remove(messageId);
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
    _sse?.close();
    api.close();
    for (final client in _peerApiClients.values) {
      client.close();
    }
    super.dispose();
  }
}
