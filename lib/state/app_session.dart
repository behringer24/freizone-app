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
import 'dart:developer' as developer;
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../ffi/freizone_core.dart';
import '../ffi/freizone_core_exception.dart';
import '../ffi/models.dart';
import '../net/api_client.dart';
import '../net/dto.dart';
import '../net/sse_client.dart';
import '../push/push_manager.dart';
import '../util/address_format.dart';
import '../util/errors.dart';
import '../util/freizone_address.dart';
import '../util/server_url.dart';
import 'app_settings.dart';
import 'conversation.dart';
import 'media_store.dart';
import 'message_content.dart';
import 'outgoing_attachment.dart';
import 'local_state.dart';
import 'receipt_signal.dart';
import 'rekey_signal.dart';
import 'session_recovery.dart';

/// How many one-time prekeys to generate and upload at once, mirroring
/// cmd/devclient's defaultOneTimePrekeyBatch.
const _oneTimePrekeyBatch = 10;

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
  // Already handled: acknowledge it (so the caller clears it from the server
  // queue) without touching the ratchet. Delivery is at-least-once and the
  // delete is best-effort, so the same envelope legitimately arrives twice --
  // via a reconnecting stream, or a push wake racing the live one. Processing
  // it again is actively destructive: it advances the ratchet a second time
  // for one message, and a redelivered X3DH initial rebuilds the responder
  // session and overwrites the advanced one, breaking the conversation for
  // good. See AppState.processedMessageIds.
  if (state.processedMessageIds.contains(msg.messageId)) {
    return IncomingMessageResult(
      peerAccountId: msg.senderAccountId,
      shouldNotify: false,
    );
  }

  final parsed = core.parseEnvelope(msg.payload);
  final initial = parsed.initial;

  // Any one-time prekey the initial references -- looked up but NOT consumed
  // yet, so a failed responder attempt (a duplicate/redelivered or stale
  // initial) never burns a prekey. Consumed only once a responder session
  // built from it actually decrypts this envelope (see below).
  int? consumeOtpkId;
  Uint8List? otpkPriv;
  if (initial != null) {
    final otpkId = initial.oneTimePrekeyId;
    if (otpkId != null && state.oneTimePrekeys.containsKey(otpkId)) {
      consumeOtpkId = otpkId;
      otpkPriv = state.oneTimePrekeys[otpkId]!.priv;
    }
  }

  var session = state.sessions[msg.senderAccountId];
  DecryptResult? dec;
  var usedResponder = false; // adopted a fresh responder session (X3DH)
  var didRekey = false; // ...replacing an existing one (the peer reset theirs)

  if (session == null) {
    // First contact: an initial is required to establish a responder session.
    if (initial == null) return null; // no way to start a session -- drop.
    session = core.respondToSession(
      localDhIdentityPriv: state.dhIdentityPriv!,
      signedPrekeyPriv: state.signedPrekeyPriv!,
      oneTimePrekeyPriv: otpkPriv,
      initial: initial,
    );
    dec = core.sessionDecrypt(
      session: session,
      header: parsed.header,
      ciphertext: parsed.ciphertext,
    ); // may throw -> propagates to _handleIncoming's catch
    usedResponder = true;
  } else if (initial != null) {
    // A session already exists yet the peer sent a fresh X3DH initial: they
    // reset their secure session (see resetSecureSession) and re-keyed.
    // Accept it -- build a fresh responder session and adopt it ONLY if it
    // actually decrypts this envelope. The core's session calls are pure, so
    // a failed attempt leaves the live session intact; fall back to it for a
    // merely-redelivered initial whose real session is still the current one.
    try {
      final fresh = core.respondToSession(
        localDhIdentityPriv: state.dhIdentityPriv!,
        signedPrekeyPriv: state.signedPrekeyPriv!,
        oneTimePrekeyPriv: otpkPriv,
        initial: initial,
      );
      dec = core.sessionDecrypt(
        session: fresh,
        header: parsed.header,
        ciphertext: parsed.ciphertext,
      );
      session = fresh;
      usedResponder = true;
      didRekey = true;
    } catch (_) {
      dec = null; // not a genuine re-key for us -- fall back below.
    }
  }

  // Ongoing message, or the re-key attempt didn't apply: decrypt with the
  // existing session.
  if (dec == null) {
    try {
      dec = core.sessionDecrypt(
        session: session!,
        header: parsed.header,
        ciphertext: parsed.ciphertext,
      );
    } on FreizoneCoreException catch (e) {
      // The ratchet has already moved past this exact envelope: it was
      // decrypted before and the acknowledgement was lost (delivery is
      // at-least-once). Distinct from every other decrypt failure -- nothing is
      // wrong, so it must neither be retried nor counted as evidence of a
      // desync. Only reachable when processedMessageIds has already evicted the
      // id, since that check above catches the common case first.
      if (e.code == CoreErrorCode.duplicateMessage) {
        state.markMessageProcessed(msg.messageId);
        return IncomingMessageResult(
          peerAccountId: msg.senderAccountId,
          shouldNotify: false,
        );
      }
      rethrow; // classified by the caller -> see recordDesyncEvidence
    }
  }

  state.sessions[msg.senderAccountId] = dec.session;
  // Recorded here, the moment the ratchet has actually advanced -- before any
  // of the return paths below (receipt, blocked, stored message) diverge, and
  // never for a failed decrypt, which leaves the session untouched and must
  // stay retryable.
  state.markMessageProcessed(msg.messageId);
  // A decrypt that worked is the only proof this session is healthy, so any
  // desync evidence collected about this peer is now void -- including evidence
  // that had already crossed the threshold, which is what stops an automatic
  // re-key from firing after the conversation has recovered on its own (or
  // because we just adopted the peer's re-key).
  state.clearDesyncEvidence(msg.senderAccountId);
  // A one-time prekey is consumed only now that a responder session built
  // from the initial has successfully decrypted -- never on a failed attempt.
  if (usedResponder && consumeOtpkId != null) {
    state.oneTimePrekeys.remove(consumeOtpkId);
  }

  final now = DateTime.now().toUtc();
  // Blocked/known status is looked up from AppState.blockedPeers/knownPeerIds
  // -- deliberately independent of whether a Conversation for this peer
  // currently exists, so a deleted-then-recreated Conversation (see
  // deleteConversation) picks the right state back up rather than treating a
  // blocked or already-known peer as a brand new "message request."
  final blocked = state.blockedPeers.containsKey(msg.senderAccountId);

  // The peer re-keyed and we accepted it above: mark it in the transcript
  // before whatever this envelope turns out to carry, so the recovery is
  // visible on this side too (the resetting side shows its own marker). Done
  // here rather than alongside the stored message below because a re-key can
  // arrive on an *invisible* envelope -- the automatic path sends a bare
  // RekeySignal, so this marker is the only thing that would ever show up for
  // it. Deliberately does not touch lastActivityAt: recovering a session is
  // maintenance, not activity, and must not jump the chat to the top of the
  // list. No conversation (deleted locally while the session lived on) means
  // there is nothing to mark; the message below recreates it.
  final rekeySignal = RekeySignal.tryDecode(dec.plaintext);
  if (didRekey && !blocked) {
    state.conversations[msg.senderAccountId]?.messages.add(
      StoredMessage.system(
        rekeySignal?.reason == RekeyReason.decryptFailures
            ? automaticRekeyMarker
            : sessionResetMarker,
        now,
      ),
    );
  }
  if (rekeySignal != null) {
    // Nothing else to do: its whole purpose was the fresh `prekey` block on the
    // envelope around it (see rekey_signal.dart), which the code above has
    // already acted on. Never stored, never notified -- but the caller still
    // acks it out of the server queue like any other processed envelope.
    return IncomingMessageResult(
      peerAccountId: msg.senderAccountId,
      shouldNotify: false,
    );
  }

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
        attachments: content.attachments,
      ),
    );
    // Only the tiny inline preview is written now -- a kilobyte, so it costs
    // nothing even on the background push isolate, and it means a picture
    // shows *something* the moment it arrives. The full blob is fetched
    // lazily by the UI, which must not be blocked on here: a wake has no
    // screen to draw on and must not delay its notification.
    if (content.attachments.isNotEmpty) {
      await _writeAttachmentThumbs(state, msg.senderAccountId, content);
    }
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

/// Persists the inline preview thumbnails an incoming message carried, so a
/// picture can be shown before its blob has been downloaded.
///
/// Failures are swallowed on purpose: a missing thumbnail costs a preview,
/// never the message itself, and this runs on the background push isolate
/// too, where there is no one to report an error to.
Future<void> _writeAttachmentThumbs(
  AppState state,
  String peerAccountId,
  MessageContent content,
) async {
  try {
    final media = await MediaStore.instance();
    for (final attachment in content.attachments) {
      final thumb = attachment.thumb;
      if (thumb == null || thumb.isEmpty) continue;
      await media.writeFile(
        media.thumbFor(
          accountId: state.accountId,
          peerAccountId: peerAccountId,
          messageId: content.id,
        ),
        thumb,
      );
    }
  } catch (_) {
    // See above: a preview is a nicety, not part of delivery.
  }
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
  // Only when this actually minted keys. Saving unconditionally meant every
  // reconnect and every push wake wrote the whole profile back -- including,
  // from a stale in-memory copy, ratchet state another isolate had advanced
  // in the meantime. Nothing to persist when no new prekey was generated: the
  // upload above merely re-asserts existing material.
  if (otpkDtos.isNotEmpty) await LocalStateStore.saveProfile(state);
}

/// Whether this session's own home server is currently reachable. Drives
/// the account switcher's offline marking and the chat composer's
/// send-disabled bar. Starts [connecting] (no attempt has resolved yet),
/// flips to [online] on a successful SSE connect and to [unreachable] when
/// a connect attempt fails -- see AppSession._startStream / init.
enum ServerReachability { connecting, online, unreachable }

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
  /// SseClient's quick retry) without flickering the whole account grey.
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

  /// Refreshes [registrationPolicy] and [federationEnabled] from the public
  /// server-status endpoint (one call covers both). Call once after [init]
  /// and again whenever the app returns to the foreground, the SSE stream
  /// (re)connects, or the chat list / admin area is shown, so a change made
  /// elsewhere is picked up in time.
  Future<void> refreshRegistrationPolicy() async {
    try {
      final status = await api.getServerStatus();
      registrationPolicy = status.registrationPolicy;
      federationEnabled = status.federationEnabled;
      _ownBlobs = BlobCapability.from(status);
    } catch (e) {
      lastError = 'checking registration policy failed: $e';
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

  /// Picture bytes for outgoing messages not yet confirmed sent, keyed by
  /// message id -- what [retrySend] re-uploads after a failure. Dropped as
  /// soon as the send succeeds, and in memory only: that is precisely why an
  /// unsent message is never persisted (see Conversation.toJson), since a
  /// failed bubble restored from disk could never actually be resent.
  final Map<String, OutgoingAttachment> _outgoingAttachments = {};

  /// What the server holding this conversation's attachments will accept.
  ///
  /// That is the RECIPIENT's server, not ours: a blob is uploaded to where
  /// the recipient can fetch it from (docs/PROTOCOL.md §10), so for a
  /// federated peer the remote operator's switch and size cap are the ones
  /// that count. Returns null while unknown -- callers treat that as "don't
  /// know yet" rather than "unsupported", so a slow status call doesn't
  /// flicker the attachment button off.
  Future<BlobCapability?> blobCapabilityFor(Conversation convo) async {
    final peerServer = convo.peerServer;
    if (peerServer == null) {
      if (_ownBlobs == null) await refreshRegistrationPolicy();
      return _ownBlobs;
    }
    final cached = _peerBlobs[peerServer];
    if (cached != null) return cached;
    try {
      final status = await _clientFor(peerServer).getServerStatus();
      final capability = BlobCapability.from(status);
      _peerBlobs[peerServer] = capability;
      return capability;
    } catch (e) {
      // Unreachable or erroring: unknown, not unsupported. Sending will
      // surface the real failure rather than us pre-emptively lying about
      // what the peer's server supports.
      lastError = 'checking attachment support failed: $e';
      return null;
    }
  }

  /// A conversation is federation-locked when it lives on another server
  /// and this account's home server currently has federation disabled: the
  /// peer's replies would be blocked inbound, so we must not let the user
  /// keep sending into a dead end. Only sending is affected -- already
  /// received messages stay readable.
  bool federationLocked(Conversation convo) =>
      convo.peerServer != null && !federationEnabled;

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
    if (!value) {
      // Cancel any pending reachability grace: Android freezes us while
      // backgrounded, so a timer armed now would fire the instant we resume
      // and flash the account grey. Reachability is re-evaluated on resume.
      _reachabilityGraceTimer?.cancel();
      _reachabilityGraceTimer = null;
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
    await _reloadVolatileStateFromDisk();
    // Reopen the live stream that backgrounding closed, so the foregrounded
    // app is back on the fast path (and the server stops pushing to it).
    _startStream();
    // Re-check server-status on resume so an admin's federation (or
    // registration-policy) change made while the app was backgrounded shows
    // up promptly -- the lock UI and outbound guard depend on this flag, and
    // there is no push for a settings change.
    unawaited(refreshRegistrationPolicy());
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
    // Taken under the profile lock so a push wake that is mid-sync finishes
    // first: reading while it still had its advance in memory gave us the
    // pre-wake ratchet, which our next save then wrote back over its result.
    final fresh = await LocalStateStore.withProfileLock(
      state.accountId,
      () => LocalStateStore.loadProfile(state.accountId),
    );
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
    // Adopted along with the ratchet state they belong to: keeping our own
    // stale copies would forget what the push isolate just processed (letting
    // those messages be decrypted a second time) and reset its failure counts.
    state.processedMessageIds = fresh.processedMessageIds;
    state.decryptFailures = fresh.decryptFailures;
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
    // The prekey upload/top-up is network I/O against this account's home
    // server and may fail if that server is down. It must NOT gate the
    // rest of init: the SSE reconnect loop below is what tracks
    // reachability and recovers when the server returns, so it has to
    // start even on a dead server -- otherwise the account would be stuck
    // "connecting" forever with nothing ever retrying. onConnected re-runs
    // the top-up, so a recovered server still gets its prekeys refreshed.
    try {
      if (state.signedPrekeyPub == null) {
        await _uploadPrekeys();
      } else {
        await topUpOneTimePrekeysIfNeeded(state, core, api);
      }
      prekeysReady = true;
    } catch (e) {
      reachability = ServerReachability.unreachable;
      lastError = 'prekey upload failed: $e';
    }
    notifyListeners();
    _startStream();
    unawaited(refreshMyRole());
    // Housekeeping, deliberately not awaited: it only touches files no
    // message points at any more, so nothing depends on it finishing.
    unawaited(sweepOrphanedMedia());
    unawaited(refreshRegistrationPolicy());
    unawaited(_registerPush());
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

  /// The stream dropped or a reconnect attempt failed. Don't flip straight to
  /// [ServerReachability.unreachable] (which greys the account in the UI) when
  /// we were online: a resume from background or a brief blip reconnects in
  /// well under a second (see SseClient's quick retry), and greying the whole
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
    // it. A background resume reconnects in well under a second (SseClient's
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
    if (reachability != ServerReachability.online) {
      reachability = ServerReachability.online;
      notifyListeners();
    }
  }

  void _startStream() {
    if (_sse != null) return; // already streaming (or restarted before stop)
    _sse = SseClient(apiClient: api, creds: state.credentials);
    unawaited(
      _sse!.connect(
        onMessage: _handleIncoming,
        onError: (e) {
          lastError = 'stream error: $e';
          _markStreamDropped();
        },
        onConnected: () {
          _markStreamConnected();
          unawaited(topUpOneTimePrekeysIfNeeded(state, core, api));
          // Re-register push on every (re)connect: a server that was down at
          // startup (or when the endpoint first arrived) never got this
          // account's push target otherwise, and would stay push-less until
          // the next app start. registerForPush is idempotent.
          unawaited(_registerPush());
          // Pick up a server-status change (e.g. federation toggled) on every
          // (re)connect -- covers long-lived sessions and network changes.
          unawaited(refreshRegistrationPolicy());
          _retryPendingReceipts();
          // Heal any conversation whose desync was noticed while this session
          // couldn't act on it -- a background push wake detects but cannot
          // send (see push_manager.dart's _syncProfile), and the higher-id side
          // of a desync deliberately waits before re-keying
          // (autoRekeyResponderGrace), which needs *something* to come back and
          // re-check. Mirrors _retryPendingReceipts' own "every (re)connect"
          // trigger, for the same reason: it is the one moment this app
          // reliably revisits every conversation.
          unawaited(_recoverDesyncedSessions());
        },
      ),
    );
  }

  /// Closes the live SSE stream and releases this device's subscriber slot on
  /// the server, so a message arriving while the app is backgrounded triggers
  /// a push wake instead of being delivered into a stream nobody is reading
  /// (see [setForeground]). Closing is a clean disconnect -- SseClient.close
  /// marks itself closed before tearing down, so its reconnect loop exits
  /// without reporting an error, and reachability is left untouched. Safe to
  /// call when no stream is open.
  void _stopStream() {
    _sse?.close();
    _sse = null;
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
      // Nothing to decrypt with: no session for this sender and no X3DH initial
      // to start one (see processIncomingMessage). This is the one desync shape
      // that produces no crypto error at all -- our own session is simply gone,
      // while the peer keeps sending into the one they still hold -- so it has
      // to be counted here or automatic recovery would never see the case it
      // exists for.
      if (result == null) {
        await _giveUpOnEnvelope(msg, isDesyncEvidence: true);
        return;
      }

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
      await _giveUpOnEnvelope(
        msg,
        // Only a failure whose code means diverged keys counts towards
        // recovering the session. A redelivery is already handled inside
        // processIncomingMessage; an undiagnosed error (bad JSON, a storage
        // failure -- this catch covers the whole of the processing above, not
        // just the decrypt) says nothing about the ratchet, and discarding a
        // working session over one would lose messages for no reason.
        isDesyncEvidence: e is FreizoneCoreException && e.suggestsDesync,
      );
      lastError = 'decrypt error: $e';
      notifyListeners();
    }
  }

  /// Counts one failed attempt at [msg] and, once it has failed enough times,
  /// drops it from the server queue.
  ///
  /// A decrypt failure is deterministic (the same session and ciphertext fail
  /// identically), so a poison envelope -- e.g. an old-chain message left over
  /// after a secure-session reset -- would re-fetch and re-fail on every
  /// reconnect forever. The count lives in the profile, shared with the
  /// background push isolate (see AppState.recordDecryptFailure): both consumers
  /// see the same envelope, so counting per-isolate let it survive far longer
  /// than the limit suggests.
  ///
  /// [isDesyncEvidence] marks a failure that means this peer's session has
  /// diverged rather than that this one envelope is bad; the evidence is only
  /// recorded when the envelope is finally given up on, so one envelope counts
  /// once however many times it was retried.
  Future<void> _giveUpOnEnvelope(
    MessageResponse msg, {
    required bool isDesyncEvidence,
  }) async {
    if (state.recordDecryptFailure(msg.messageId)) {
      if (isDesyncEvidence) {
        state.recordDesyncEvidence(
          msg.senderAccountId,
          DateTime.now().toUtc(),
        );
      }
      unawaited(api.deleteMessage(msg.messageId, state.credentials));
    }
    await LocalStateStore.saveProfile(state);
    // Fire-and-forget: recovery sends a message and resolves a device, which
    // must not hold up draining the rest of the queue.
    unawaited(_recoverDesyncedSessions());
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
    // Pictures go with the history they belonged to -- clearing a chat but
    // leaving its images on disk would be both surprising and a slow leak.
    await _deleteConversationMedia(peerAccountId);
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
    await _deleteConversationMedia(peerAccountId);
    await LocalStateStore.saveProfile(state);
    if (removed.hasUnread && !hasAnyUnread)
      unawaited(clearMessageNotification(state.accountId));
    notifyListeners();
  }

  /// Deletes one conversation's stored pictures. Best-effort: leftover files
  /// waste space but break nothing, and this always runs alongside a more
  /// important deletion that must not fail because of them.
  Future<void> _deleteConversationMedia(String peerAccountId) async {
    try {
      final media = await MediaStore.instance();
      await media.deleteConversationMedia(state.accountId, peerAccountId);
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
      final live = <String>{};
      for (final convo in state.conversations.values) {
        for (final m in convo.messages) {
          if (m.hasAttachments) live.add(m.id);
        }
      }
      await media.sweepOrphans(accountId: state.accountId, liveMessageIds: live);
    } catch (_) {
      // Housekeeping only -- never worth surfacing or retrying.
    }
  }

  /// Encrypts an outgoing attachment and uploads it to the RECIPIENT's
  /// server, returning the reference to embed in the message.
  ///
  /// A blob lives where the recipient can fetch it without contacting a
  /// stranger (docs/PROTOCOL.md §10), so for a federated peer this uploads
  /// to *their* server -- where we have no device row, hence the
  /// self-describing-key federated route.
  Future<MessageAttachment> _uploadAttachment(
    Conversation convo,
    OutgoingAttachment attachment,
  ) async {
    // Checked against the receiving server's own advertised limits, so an
    // attachment it would refuse fails here with something explainable
    // instead of as a bare 404/413 from the upload.
    final capability = await blobCapabilityFor(convo);
    if (capability != null) {
      // "Their" server for a federated peer, ours otherwise -- the blob is
      // stored wherever the recipient reads it from.
      final whose = convo.peerServer == null
          ? 'This server'
          : "This contact's server";
      if (!capability.enabled) {
        throw StateError("$whose doesn't accept pictures.");
      }
      if (!capability.fits(attachment.bytes.length)) {
        throw StateError(
          '$whose allows at most '
          '${formatByteSize(capability.maxBytes)} per picture.',
        );
      }
    }

    final encrypted = core.encryptBlob(attachment.bytes);
    final peerServer = convo.peerServer;
    final recipientDeviceId = convo.peerDeviceId!;

    final String blobId;
    if (peerServer == null) {
      blobId = await api.uploadBlob(
        ciphertext: encrypted.ciphertext,
        digest: encrypted.digest,
        recipientDeviceId: recipientDeviceId,
        creds: state.credentials,
      );
    } else {
      // Freshly signed rather than cached, exactly as the federated message
      // path does: the peer's server has no row for this device to check
      // against, so the certificate travels with the request.
      final cert = core.signDeviceCertificate(
        accountId: state.accountId,
        deviceId: state.deviceId,
        devicePub: state.devicePub,
        issuedAt: DateTime.now().toUtc(),
        rootPriv: state.rootPriv,
      );
      blobId = await _clientFor(peerServer).uploadFederatedBlob(
        ciphertext: encrypted.ciphertext,
        digest: encrypted.digest,
        recipientDeviceId: recipientDeviceId,
        devicePriv: state.devicePriv,
        rootPub: state.rootPub,
        senderAccountId: state.accountId,
        cert: cert,
      );
    }

    return MessageAttachment(
      kind: 'image',
      blobId: blobId,
      key: encrypted.key,
      mimeType: attachment.mimeType,
      byteSize: attachment.bytes.length,
      width: attachment.width,
      height: attachment.height,
      thumb: attachment.thumb,
    );
  }

  /// Saves the sender's own copy of a picture they just sent, so it renders
  /// straight away instead of being downloaded back from the server.
  Future<void> _storeOwnAttachment(
    String peerAccountId,
    String messageId,
    OutgoingAttachment attachment,
  ) async {
    try {
      final media = await MediaStore.instance();
      await media.writeFile(
        media.fileFor(
          accountId: state.accountId,
          peerAccountId: peerAccountId,
          messageId: messageId,
        ),
        attachment.bytes,
      );
      final thumb = attachment.thumb;
      if (thumb != null) {
        await media.writeFile(
          media.thumbFor(
            accountId: state.accountId,
            peerAccountId: peerAccountId,
            messageId: messageId,
          ),
          thumb,
        );
      }
    } catch (e) {
      // The message is already sent and stored; failing to keep our own
      // copy only means we'd re-download it, so it must not fail the send.
      lastError = 'storing sent attachment failed: $e';
    }
  }

  /// Fetches and decrypts one attachment, storing it as a local file, and
  /// returns that file. If it is already downloaded the existing file is
  /// returned untouched -- the filesystem is the record of what's local, so
  /// this is safe to call whenever a bubble comes into view.
  ///
  /// A blob always lives on OUR OWN server, even for a federated peer: the
  /// sender uploaded it here (see docs/PROTOCOL.md §10), precisely so a
  /// recipient never has to contact a stranger's server. Hence [api], not
  /// [_clientFor].
  ///
  /// Only ever downloads a RECEIVED attachment. A blob is owned by the
  /// recipient device, so the sender's own upload is not retrievable by them
  /// on any server -- their copy is the local one written at send time.
  Future<File?> ensureAttachmentDownloaded({
    required String peerAccountId,
    required StoredMessage message,
  }) async {
    if (message.attachments.isEmpty) return null;
    final attachment = message.attachments.first;

    final media = await MediaStore.instance();
    final target = media.fileFor(
      accountId: state.accountId,
      peerAccountId: peerAccountId,
      messageId: message.id,
    );
    if (await target.exists()) return target;
    if (message.mine) return null;

    if (media.stateFor(message.id) == MediaFetchState.downloading) return null;
    media.markFetching(message.id);
    try {
      final ciphertext = await api.downloadBlob(
        attachment.blobId,
        state.credentials,
      );
      final plaintext = core.decryptBlob(
        key: attachment.key,
        ciphertext: ciphertext,
      );
      await media.writeFile(target, plaintext);
      media.clearFetchState(message.id);
      // The file is safely on disk, so the server copy has served its
      // purpose: free the quota now rather than waiting for the retention
      // sweep. Best effort -- if it fails, the TTL cleanup gets it later.
      unawaited(
        api
            .deleteBlob(attachment.blobId, state.credentials)
            .catchError((_) {}),
      );
      return target;
    } catch (e) {
      // Left as failed rather than retried automatically: the picture gets a
      // tap-to-retry placeholder, so a dead server or a deleted blob doesn't
      // turn into a silent retry loop.
      lastError = 'downloading attachment failed: $e';
      media.markFailed(message.id);
      return null;
    }
  }

  /// Discards the ratchet session with [peerAccountId] so a fresh X3DH runs as
  /// initiator (see [_getOrCreateCryptoSession]), carrying an `initial` the
  /// peer's receive path accepts in place of their stale session (see
  /// processIncomingMessage). Recovers a conversation whose Double Ratchet has
  /// desynced (messages silently fail to decrypt). The conversation, its
  /// history and the known/blocked status are all kept, and a system marker
  /// goes into the transcript for transparency.
  ///
  /// Then sends an invisible re-key signal straight away, rather than leaving
  /// the fresh `initial` to ride on whatever the user types next: what a desync
  /// breaks is *receiving*, so the peer is still sending into a session this
  /// side can no longer read, and until they hear otherwise nothing they do will
  /// change that. Best-effort -- a failed send leaves the session discarded, so
  /// the next real message recovers it the old way.
  Future<void> resetSecureSession(String peerAccountId) async {
    final convo = state.conversations[peerAccountId];
    await _discardSessionAndMark(
      peerAccountId,
      marker: sessionResetMarker,
      bumpActivity: true,
    );
    if (convo != null) {
      await _sendRekeySignal(convo, RekeyReason.userRequested);
    }
  }

  /// Discards the local ratchet session with [peerAccountId] and records it in
  /// the transcript. Shared by the manual reset and the automatic recovery,
  /// which differ only in wording and in whether this counts as activity: a
  /// reset the user asked for belongs at the top of the chat list where they
  /// left off, while an automatic one is maintenance and must not reorder
  /// anything behind their back.
  Future<void> _discardSessionAndMark(
    String peerAccountId, {
    required String marker,
    required bool bumpActivity,
  }) async {
    await _withPeerSessionLock(peerAccountId, () async {
      state.sessions.remove(peerAccountId);
    });
    final convo = state.conversations[peerAccountId];
    if (convo != null) {
      final now = DateTime.now().toUtc();
      convo.messages.add(StoredMessage.system(marker, now));
      if (bumpActivity) convo.lastActivityAt = now;
    }
    await LocalStateStore.saveProfile(state);
    notifyListeners();
  }

  /// Sends the invisible re-key control envelope (see rekey_signal.dart). Its
  /// content is irrelevant -- what matters is that sending anything at all now
  /// that the local session is gone re-runs X3DH and puts a fresh `prekey`
  /// block on the wire for the peer to adopt.
  ///
  /// Best-effort and never rethrows: this is a repair attempt, and the caller
  /// has already discarded the session, so a failure here costs a delay (until
  /// the next message or the next reconnect sweep), not correctness.
  Future<void> _sendRekeySignal(Conversation convo, RekeyReason reason) async {
    try {
      await _ensurePeerDeviceResolved(convo);
      await _encryptAndSend(convo, RekeySignal(reason: reason).encode());
      await LocalStateStore.saveProfile(state);
    } catch (e) {
      developer.log(
        'sending re-key signal to ${convo.peerAccountId} failed: $e',
        name: 'session-recovery',
      );
    }
  }

  /// Re-establishes every session this device has collected enough evidence
  /// against (SRV-03's automatic path). Called after an envelope is given up on
  /// and on every stream (re)connect; [shouldAutoRekey] owns the thresholds,
  /// the ordering rule that keeps both sides from re-keying at once, and the
  /// spacing between attempts.
  ///
  /// Eligibility beyond the crypto state is decided here: a blocked peer gets
  /// nothing sent to them, and neither does an unaccepted message request --
  /// answering one, even invisibly, would tell a stranger the user is there
  /// before they have decided to reply. Both recover if and when the user
  /// engages with them.
  Future<void> _recoverDesyncedSessions() async {
    final now = DateTime.now().toUtc();
    // Snapshotted: the loop awaits, and recovery mutates peerSessionHealth.
    for (final peerAccountId in state.peerSessionHealth.keys.toList()) {
      final convo = state.conversations[peerAccountId];
      if (convo == null || convo.blocked || convo.pendingApproval) continue;
      if (federationLocked(convo)) continue;
      if (!shouldAutoRekey(
        health: state.peerSessionHealth[peerAccountId],
        myAccountId: state.accountId,
        peerAccountId: peerAccountId,
        now: now,
      )) {
        continue;
      }

      // Stamped before the attempt, not after: if the send fails, the spacing
      // must still hold, or every reconnect would retry immediately and burn a
      // one-time prekey each time.
      state.recordAutoRekey(peerAccountId, now);
      developer.log(
        're-establishing the secure session with $peerAccountId',
        name: 'session-recovery',
      );
      await _discardSessionAndMark(
        peerAccountId,
        marker: automaticRekeyMarker,
        bumpActivity: false,
      );
      await _sendRekeySignal(convo, RekeyReason.decryptFailures);
    }
  }

  /// Returns the existing session with a conversation's peer, or
  /// establishes a new one as X3DH initiator by claiming their prekey
  /// bundle.
  Future<(RatchetSessionJson, InitialMessage?)> _getOrCreateCryptoSession(
    Conversation convo,
  ) async {
    final existing = state.sessions[convo.peerAccountId];
    if (existing != null) return (existing, null);

    // Signed either way (SRV-04) -- an unauthenticated claim still returns a
    // usable bundle but without a one-time prekey, quietly costing this session
    // forward secrecy on its first message. Which form applies is decided the
    // same way the send path decides it (see _encryptAndSend): a peer on our own
    // server authenticates by device id, one on another server by presenting
    // its whole certificate chain, since that server has never seen us.
    final PrekeyBundleResponse bundle;
    if (convo.peerServer == null) {
      bundle = await api.claimPrekeyBundle(
        convo.peerDeviceId!,
        state.credentials,
      );
    } else {
      bundle = await _clientFor(convo.peerServer).claimFederatedPrekeyBundle(
        deviceId: convo.peerDeviceId!,
        devicePriv: state.devicePriv,
        rootPub: state.rootPub,
        senderAccountId: state.accountId,
        cert: core.signDeviceCertificate(
          accountId: state.accountId,
          deviceId: state.deviceId,
          devicePub: state.devicePub,
          issuedAt: DateTime.now().toUtc(),
          rootPriv: state.rootPriv,
        ),
      );
    }

    // Never expected: this app signs every claim, so hearing otherwise means
    // our own credentials were refused (a clock far out of skew, a revoked
    // device, a stale cert) and this session is silently starting weaker than
    // it should. Logged rather than thrown -- a working conversation is worth
    // more than the first message's forward secrecy -- but not swallowed.
    if (bundle.wasClaimedUnauthenticated) {
      developer.log(
        'server refused our prekey-bundle claim credentials for '
        '${convo.peerAccountId}; session starts without a one-time prekey',
        name: 'prekeys',
      );
    }

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
  /// The bubble appears immediately, as [MessageSendState.pending], and only
  /// then does the network work start (APP-08 step 1) -- so the composer can
  /// be cleared the instant the user hits send instead of sitting frozen
  /// through a slow prekey lookup, blob upload or cross-server POST.
  ///
  /// Throws on failure, after marking the message
  /// [MessageSendState.failed] -- the bubble itself is the durable feedback,
  /// the throw only lets the calling screen explain *why* (e.g. a SnackBar).
  /// A failed message stays retryable for this session, see [retrySend].
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

    // Stamped ONCE, before the send: this exact instant goes out inside
    // the encrypted content (sentAt) AND becomes the local StoredMessage
    // .timestamp below -- receipts echo it back verbatim, and the
    // checkmark comparison (chat_screen.dart) is then an equality within
    // this one clock reading. Stamping after the await (as this used to)
    // loses that race locally: the receiver can decrypt and stamp its
    // receipt before the sender's own post-send stamp is even taken.
    final now = DateTime.now().toUtc();

    final message = StoredMessage(
      id: generateMessageId(),
      text: text,
      mine: true,
      timestamp: now,
      replyToId: quoted?.id,
      replyPreviewText: quoted?.text,
      replyPreviewMine: quoted?.mine,
      // Stands in until the upload returns a blob id, so the pending bubble
      // can already render the picture from our own local copy below.
      attachments: attachment == null
          ? const []
          : [_placeholderAttachment(attachment)],
      sendState: MessageSendState.pending,
    );

    if (attachment != null) {
      // Held for a possible retry, and written to disk before the bubble is
      // shown: ImageAttachment renders our own picture from this local file,
      // so it has to exist by the time the transcript first paints it.
      _outgoingAttachments[message.id] = attachment;
      await _storeOwnAttachment(peerAccountId, message.id, attachment);
    }

    convo.messages.add(message);
    convo.lastActivityAt = now;
    // Not persisted yet -- an unsent message is deliberately session-only
    // (see Conversation.toJson); this is purely so the bubble paints now.
    notifyListeners();

    await _deliver(convo, message, attachment);
  }

  /// Re-sends a message whose optimistic send failed. Only meaningful within
  /// the session that composed it: a picture's bytes live in
  /// [_outgoingAttachments], in memory, which is also why a failed message is
  /// never written to disk (see Conversation.toJson). Durable retry across a
  /// restart is APP-08 step 2's outbox.
  Future<void> retrySend(String peerAccountId, String messageId) async {
    final convo = state.conversations[peerAccountId];
    if (convo == null) return;
    final message = convo.messageById(messageId);
    if (message == null || !message.hasFailed) return;

    final attachment = _outgoingAttachments[messageId];
    if (message.hasAttachments && attachment == null) {
      // Can only happen if the bytes were dropped while the message stayed
      // failed, which nothing does today -- but re-sending the caption alone
      // would quietly deliver a different message than the user composed.
      message.sendError = 'The picture is no longer available to resend.';
      notifyListeners();
      return;
    }

    message.sendState = MessageSendState.pending;
    message.sendError = null;
    notifyListeners();

    await _deliver(convo, message, attachment);
  }

  /// The network half of a send, shared by [sendMessage] and [retrySend]:
  /// resolve the peer, upload the picture if it hasn't been uploaded yet,
  /// then encrypt and post -- resolving [message]'s send state either way.
  Future<void> _deliver(
    Conversation convo,
    StoredMessage message,
    OutgoingAttachment? attachment,
  ) async {
    try {
      await _ensurePeerDeviceResolved(convo);

      // Uploaded BEFORE the message is sent: the message carries the blob
      // id, so publishing it first would briefly point at something that
      // doesn't exist yet. Skipped when a previous attempt already got a
      // blob id and only the POST failed, so a retry can't leak a second
      // copy of the same picture onto the recipient's server.
      final uploaded = message.attachments.isNotEmpty &&
          message.attachments.first.blobId.isNotEmpty;
      if (attachment != null && !uploaded) {
        message.attachments = [await _uploadAttachment(convo, attachment)];
      }

      // Flipped relative to our own `replyPreviewMine`: the recipient reads
      // this same field as "mine" from *their* perspective, where the roles
      // are swapped (see message_content.dart).
      final wirePreview = message.replyToId == null
          ? null
          : ReplyPreview(
              text: message.replyPreviewText ?? '',
              mine: !(message.replyPreviewMine ?? false),
            );

      final content = MessageContent(
        id: message.id,
        text: message.text,
        attachments: message.attachments,
        replyToId: message.replyToId,
        replyPreview: wirePreview,
        // Sent on every cross-server message (not just the first), so the
        // recipient's knowledge of where to reach us for a reply
        // self-heals even if their local state is ever lost -- see
        // message_content.dart.
        senderServer: convo.peerServer != null ? state.server : null,
        sentAt: message.timestamp,
      );

      await _encryptAndSend(convo, content.encode());
    } catch (e) {
      message.sendState = MessageSendState.failed;
      message.sendError = describeError(e);
      lastError = 'send failed: ${describeError(e)}';
      notifyListeners();
      rethrow;
    }

    message.sendState = MessageSendState.sent;
    message.sendError = null;
    _outgoingAttachments.remove(message.id);
    // First save of this message: Conversation.toJson skips anything not
    // yet sent, so until now it existed only in memory.
    await LocalStateStore.saveProfile(state);

    lastError = null;
    notifyListeners();
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
    // Outbound federation guard: a federated conversation whose home server
    // now has federation disabled is a dead end (replies blocked inbound), so
    // stop sending -- covers both real messages and receipts. Already received
    // messages remain readable; only sending is blocked.
    if (federationLocked(convo)) {
      throw StateError(
        'Federation is turned off on your server, so you can\'t message '
        'contacts on other servers.',
      );
    }
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
    api.close();
    for (final client in _peerApiClients.values) {
      client.close();
    }
    super.dispose();
  }
}
