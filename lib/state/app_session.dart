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
import '../net/core_stream.dart';
import '../push/push_manager.dart';
import '../util/address_format.dart';
import '../util/errors.dart';
import '../util/freizone_address.dart';
import '../util/gallery.dart';
import '../util/server_url.dart';
import 'app_settings.dart';
import 'chat_target.dart';
import 'conversation.dart';
import 'group_control.dart';
import 'group_conversation.dart';
import 'group_receive.dart';
import 'group_store.dart';
import 'group_system_lines.dart';
import 'media_store.dart';
import 'message_content.dart';
import 'outgoing_attachment.dart';
import 'peer_endpoint.dart';
import 'local_state.dart';
import 'receipt_signal.dart';
import 'rekey_signal.dart';
import 'session_recovery.dart';
import 'stale_device.dart';

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
    this.groupDeliveredUpTo,
    this.groupId,
    this.peerGroupStateHash,
    this.peerServer,
    this.groupSnapshotRequested = false,
    this.groupInvite = false,
    this.attachmentMessageId,
  });

  final String peerAccountId;
  final bool shouldNotify;

  /// The id of the message just stored, when it carried an attachment -- so a
  /// caller that can reach the network starts fetching the picture on arrival
  /// instead of leaving it until a bubble is first drawn.
  ///
  /// Only a hint: the download is still driven by [ensureAttachmentDownloaded],
  /// which is idempotent, so the UI asking again costs nothing. This exists
  /// because the alternative is a spinner that begins its work the moment the
  /// user opens the chat -- exactly when they are waiting for it.
  final String? attachmentMessageId;

  /// This envelope was an invitation into a group new to this account (see
  /// group_receive.dart's GroupControlOutcome.invited) -- notify-worthy, but not
  /// a message, so the notification says so and doesn't deep-link anywhere.
  final bool groupInvite;

  /// The group this envelope belonged to, if any (APP-16) -- so a caller that
  /// caches folded group state knows which one to refresh.
  final String? groupId;

  /// The sender's own view of that group's fact set. A caller that can send
  /// compares it with ours and offers a snapshot on a mismatch; comparing is
  /// free here, which is why it rides along on every group envelope rather
  /// than being asked for.
  final String? peerGroupStateHash;

  /// They asked for our fact set outright.
  final bool groupSnapshotRequested;

  /// Where the sender said they live, from the envelope's own encrypted content
  /// (MessageContent.senderServer) -- null for a same-server sender or an
  /// envelope that carries no such field. The one way to reach a federated group
  /// member this device has never messaged one-to-one.
  final String? peerServer;

  /// The receipt anchor of a genuinely new, stored (not blocked, not a
  /// receipt) message in a *one-to-one* conversation -- the sender's own
  /// send-time stamp when the message carried one, local arrival time
  /// otherwise (see StoredMessage.receiptAnchor); null for a receipt, a
  /// dropped/blocked message, or anything else that isn't itself a
  /// delivered chat message.
  ///
  /// Always null for a group message: a receipt travels over a *conversation*,
  /// so an anchor taken from a group message would confirm that member's
  /// unrelated direct messages instead -- see [groupDeliveredUpTo].
  ///
  /// Lets a caller that CAN send (AppSession, which has sending
  /// capability; a bare background sync currently doesn't -- see
  /// push_manager.dart's _syncProfile) decide whether to send a
  /// "delivered" receipt back, without processIncomingMessage itself
  /// needing to know how to send anything.
  final DateTime? deliveredUpTo;

  /// The same anchor for a message that arrived in [groupId], kept in its own
  /// field because the receipt it drives is addressed differently: to the
  /// message's *author* ([peerAccountId]) and naming the group, so the author
  /// moves that one member's watermark in the right transcript. Nobody else in
  /// the group hears about it -- see ReceiptSignal.groupId.
  final DateTime? groupDeliveredUpTo;
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
  // ...or lost the tie-break for who sends on which, so the responder session
  // is kept for reading only (see below).
  var keepOwnSendingSession = false;

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
    // A session already exists yet the peer sent a fresh X3DH initial. That is
    // ambiguous: either they reset their secure session and re-keyed (SRV-03),
    // or they simply established one at the same moment we did -- rare between
    // two people chatting, routine in a group, where a joining member reaches
    // for everyone at once and everyone reaches back. The two need opposite
    // handling, so the sender now says which it is in the prekey block
    // (SRV-17); only a sender predating that field leaves it to be inferred
    // from the decrypted content (docs/PROTOCOL.md §5).
    //
    // Either way, adopt nothing that does not actually decrypt: the core's
    // session calls are pure, so a failed attempt leaves the live session
    // intact and a merely-redelivered initial falls through below.
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
      usedResponder = true;

      // What the peer said, if anything (SRV-17). `false` is an answer too and
      // is trusted as one: it means "not a re-key", so the tie-break below
      // decides and the content is never sniffed. Only a null -- a peer that
      // predates the field -- falls back to the old inference, where a v: 3
      // envelope stands for "I threw my session away".
      //
      // A peer that threw their session away can read nothing but their own, so
      // theirs is adopted whatever the ids say.
      final deliberateRekey =
          parsed.rekey ?? (RekeySignal.tryDecode(dec.plaintext) != null);
      // Otherwise it is a race, and the tie-break is the ordering rule
      // re-keying already uses: the lower account id's session wins.
      final peerWins =
          msg.senderAccountId.compareTo(state.accountId) < 0;

      if (deliberateRekey || peerWins) {
        session = fresh;
        didRekey = true;
      } else {
        // Ours wins, so we keep sending on it -- but they are still sending on
        // theirs until our next message reaches them. Keeping this one for
        // reading is what stops those in-flight messages being stranded.
        keepOwnSendingSession = true;
      }
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

      // One more session to try before calling this a failure: the losing half
      // of a simultaneous establishment, kept for reading. The peer goes on
      // sending from it until our next message reaches them, and those
      // follow-ups carry no initial -- so this is the only thing that can read
      // them, and without it they would look like a desync.
      final inbound = state.inboundSessions[msg.senderAccountId];
      if (inbound == null) rethrow; // -> see recordDesyncEvidence
      try {
        dec = core.sessionDecrypt(
          session: inbound,
          header: parsed.header,
          ciphertext: parsed.ciphertext,
        );
      } catch (_) {
        throw e; // the original failure, not this one
      }
      keepOwnSendingSession = true;
    }
  }

  if (keepOwnSendingSession) {
    // We read this on a session we do not send from: our own won the
    // tie-break, so the advance belongs to the read-only half.
    state.inboundSessions[msg.senderAccountId] = dec.session;
  } else {
    state.sessions[msg.senderAccountId] = dec.session;
  }
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

  // Group membership and roles (APP-16). Handled here rather than handed up,
  // because the ratchet has already advanced past this envelope and the id is
  // already marked processed -- whoever decrypts a group envelope has to act
  // on it, or the facts inside are gone for good. That includes the background
  // push isolate, which is why this lives in group_receive.dart as a plain
  // function rather than an AppSession method.
  //
  // Never stored: membership is not a message. The one exception to "never
  // notified" is an invitation addressed to us -- a decision waiting on the
  // user, and their only sign of it, since nothing is sent into a group until
  // they accept (see applyGroupControl). The caller still acks it out of the
  // queue like any other processed envelope.
  final control = GroupControl.tryDecode(dec.plaintext);
  if (control != null) {
    final outcome = await applyGroupControl(state, core, control);
    // Their view, remembered per member: it is what the send path checks before
    // deciding whether that member needs the whole fact set with their next copy.
    recordGroupPeerStateHash(
      state,
      outcome.groupId,
      msg.senderAccountId,
      outcome.peerStateHash,
    );
    return IncomingMessageResult(
      peerAccountId: msg.senderAccountId,
      shouldNotify: outcome.invited && openConversationPeerId != outcome.groupId,
      groupInvite: outcome.invited,
      groupId: outcome.groupId,
      peerGroupStateHash: outcome.peerStateHash,
      groupSnapshotRequested: outcome.wantsSnapshot,
    );
  }

  final receipt = ReceiptSignal.tryDecode(dec.plaintext);
  if (receipt != null && receipt.groupId != null) {
    // A group receipt: one member telling *us*, the author, how far they have
    // got with our messages in that group. Filed per member, never re-broadcast
    // -- who has read what stays between reader and author (see
    // ReceiptSignal.groupId).
    final chat = state.groups[receipt.groupId];
    if (chat != null && (await AppSettings.load()).readReceiptsEnabled) {
      chat.recordMemberReceipt(
        accountId: msg.senderAccountId,
        status: receipt.status,
        upTo: receipt.upToSentAt,
      );
    }
    return IncomingMessageResult(
      peerAccountId: msg.senderAccountId,
      shouldNotify: false,
      groupId: receipt.groupId,
    );
  }
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

  // A group message goes into its own transcript, not into a one-to-one
  // conversation with whoever happened to send it -- which is exactly what an
  // older build does with it, and the reason group content is `v: 4` rather
  // than `v: 1` plus a field.
  if (content.isGroupMessage) {
    if (blocked) {
      // Decrypted so the ratchet and the queue stay clean, then dropped --
      // but unlike a blocked peer's one-to-one message, not without a trace:
      // a shared transcript with invisible holes reads as delivery loss, so
      // the group shows a collapsed system line instead (see
      // recordBlockedGroupMessage).
      recordBlockedGroupMessage(
        state,
        content.groupId!,
        msg.senderAccountId,
        now,
      );
      return IncomingMessageResult(
        peerAccountId: msg.senderAccountId,
        shouldNotify: false,
        groupId: content.groupId,
      );
    }
    final stored = storeGroupMessage(
      state,
      content,
      msg.senderAccountId,
      now,
      openChatId: openConversationPeerId,
    );
    // Exactly as in a one-to-one chat below, and for the same reason -- the
    // group path simply did not do it, so a group picture had nothing at all
    // to show until its blob had downloaded. A received bubble and the
    // placeholder behind a missing picture are both surfaceContainerHighest,
    // so that read as an empty bubble rather than as a picture on its way.
    // The chat id is the group id, as everywhere else media is keyed (see
    // MediaStore.chatDir).
    if (content.attachments.isNotEmpty) {
      await _writeAttachmentThumbs(state, content.groupId!, content);
    }
    recordGroupPeerStateHash(
      state,
      content.groupId!,
      msg.senderAccountId,
      content.stateHash,
    );
    return IncomingMessageResult(
      peerAccountId: msg.senderAccountId,
      shouldNotify: openConversationPeerId != content.groupId,
      // Its own field, deliberately not deliveredUpTo: a receipt travels over a
      // *conversation*, so reporting a group anchor through the one-to-one field
      // confirmed that member's unrelated direct messages -- which it used to.
      groupDeliveredUpTo: stored.receiptAnchor,
      attachmentMessageId: content.attachments.isEmpty ? null : stored.id,
      groupId: content.groupId,
      peerGroupStateHash: content.stateHash,
      peerServer: content.senderServer,
    );
  }

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
  // The conversation's flag is only a mirror of AppState.blockedPeers (see
  // setBlocked); resynced here so a mirror that went stale -- e.g. a
  // conversation minted by an older build's startConversation after the
  // blocked one was deleted -- cannot make the 1:1 path disagree with the
  // group path about the same sender. The map is the authority in both
  // directions: a missing entry un-blocks a stray true just as an existing
  // one re-blocks a stray false.
  convo.blocked = blocked;
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
    attachmentMessageId: convo.blocked || content.attachments.isEmpty
        ? null
        : content.id,
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
/// [chatId] is where the picture belongs, which is a [MediaStore] chat id: the
/// sender's account id for a one-to-one message, the group id for a group one.
///
/// Failures are swallowed on purpose: a missing thumbnail costs a preview,
/// never the message itself, and this runs on the background push isolate
/// too, where there is no one to report an error to.
Future<void> _writeAttachmentThumbs(
  AppState state,
  String chatId,
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
          chatId: chatId,
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
  CoreStream? _sse;

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
    developer.log(described, name: 'freizone');
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

  /// Picture bytes for outgoing messages not yet confirmed sent, keyed by
  /// message id -- what [retrySend] re-uploads after a failure. Dropped as
  /// soon as the send succeeds. In memory only, but no longer the sole copy:
  /// [_recoverAttachment] reads the sender's own file back from disk for a
  /// message that outlived the run that composed it.
  final Map<String, OutgoingAttachment> _outgoingAttachments = {};

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

  /// How many envelopes each server takes in one request, by server address --
  /// 0 for a server that does not advertise batch delivery at all, so the
  /// fan-out posts to it one at a time.
  ///
  /// Discovered per server rather than once, because a group legitimately spans
  /// servers of different vintages: batching to one member's server and not to
  /// another's is the normal case, not an edge (docs/PROTOCOL.md §4). Cached for
  /// the session, like [_peerBlobs] -- a capability that changes needs a restart
  /// to be noticed, which is the same trade the blob cache already makes.
  final Map<String, int> _batchLimits = {};

  /// The batch limit for [server] (null meaning our own), or 0 if unknown.
  ///
  /// A server that cannot be asked counts as "no batching": the fan-out then
  /// posts individually, which works everywhere and fails per recipient rather
  /// than losing the whole batch to one unreachable status call.
  Future<int> _batchLimitFor(String? server) async {
    final key = server ?? state.server;
    final cached = _batchLimits[key];
    if (cached != null) return cached;
    try {
      final status = await _clientFor(server).getServerStatus();
      final limit = status.batchMessages
          ? (status.maxBatchMessages > 0 ? status.maxBatchMessages : 1)
          : 0;
      _batchLimits[key] = limit;
      return limit;
    } catch (e) {
      developer.log(
        'batch capability of $key unknown: ${describeError(e)}',
        name: 'groups',
      );
      return 0;
    }
  }

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
    state.inboundSessions = fresh.inboundSessions;
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
      // The offline marking above is the visible half; the banner is only for a
      // prekey upload that failed for a reason waiting will not fix.
      _noteFailure('prekey upload failed', e);
    }
    notifyListeners();
    _startStream();
    unawaited(refreshMyRole());
    // Housekeeping, deliberately not awaited: it only touches files no
    // message points at any more, so nothing depends on it finishing.
    unawaited(sweepOrphanedMedia());
    unawaited(refreshRegistrationPolicy());
    // Group fact sets live in their own files, so they are read separately
    // from the profile. Not awaited: a group that fails to load costs a
    // re-sync, never a startup.
    unawaited(loadGroupStates());
    unawaited(_registerPush());
    // Anything composed but never sent -- in this run or a previous one --
    // gets its first automatic attempt here (APP-08 step 2). Not awaited:
    // a backlog against a slow peer must not hold up startup.
    unawaited(flushOutbox());
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
    _sse = CoreStream(core: core, state: state);
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
  /// (see [setForeground]). Closing is a clean disconnect -- CoreStream.close
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

      // A group envelope changed the fact set on disk, so the folded view
      // this session caches is stale -- and it is what the chat list and the
      // group screen read.
      final groupId = result.groupId;
      if (groupId != null) {
        await _refreshGroupFromDisk(groupId);
        await _reconcileGroup(
          groupId,
          result.peerAccountId,
          result.peerGroupStateHash,
          snapshotRequested: result.groupSnapshotRequested,
          // Carried through so a group we hold no facts about can be asked
          // about even when the only member who has written is federated and
          // has never messaged us one-to-one.
          peerServer: result.peerServer,
        );
      }

      // A picture starts downloading the moment its message lands, not when a
      // bubble is first drawn. The lazy fetch in ImageAttachment stays -- it is
      // what covers history, a failed attempt and the background push isolate
      // (which deliberately writes only the inline thumbnail, see
      // processIncomingMessage) -- but relying on it alone meant the download
      // began exactly when the user opened the chat and was waiting for it.
      // Unawaited and best-effort: nothing here may delay a receipt or a
      // notification, and ensureAttachmentDownloaded is idempotent, so the UI
      // asking again a moment later simply finds the file or joins the attempt.
      final attachmentMessageId = result.attachmentMessageId;
      if (attachmentMessageId != null) {
        unawaited(
          _prefetchAttachment(
            chatId: groupId ?? result.peerAccountId,
            messageId: attachmentMessageId,
          ),
        );
      }

      if (result.shouldNotify) {
        // Without this call, the launcher icon's badge (which Android
        // derives from active notifications, not anything drawn in-app)
        // would never appear for a message that happened to arrive while
        // the app was in the foreground.
        unawaited(
          showMessageNotification(
            state.accountId,
            // A group envelope points at the group, not at a one-to-one chat
            // with whoever happened to send it (main.dart's _openChatFor opens
            // exactly that for a peer id).
            peerAccountId: groupId == null ? result.peerAccountId : null,
            groupId: groupId,
            invitation: result.groupInvite,
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
      // The group counterpart, addressed to the author of that one message
      // rather than to the group (see _sendGroupReceipt). Read is confirmed on
      // top when the user is actually looking at this group -- the same rule the
      // one-to-one path uses below, and the reason enterGroup claims the open-
      // chat slot.
      final groupUpTo = result.groupDeliveredUpTo;
      if (groupUpTo != null && groupId != null) {
        unawaited(
          _sendGroupDeliveredReceipt(groupId, result.peerAccountId, groupUpTo),
        );
        if (groupId == _readableConversation) {
          unawaited(sendGroupReadReceipts(groupId));
        }
      }

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
  /// against that server, not this session's own.
  ///
  /// Naming the peer is a separate act on the contact store (APP-19), not a
  /// parameter here: it returns the conversation, whose `peerAccountId` is the
  /// resolved id the contact has to be keyed by -- which is the only moment that
  /// id is known for an address typed as a prefix.
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
      // Seeded from AppState.blockedPeers, the block's authoritative home
      // (see setBlocked): a block deliberately outlives deleteConversation,
      // so re-starting a chat with a blocked peer must surface as a blocked
      // conversation rather than quietly minting an unblocked mirror. That
      // divergence is not cosmetic -- the group receive path reads the map
      // and drops, while the 1:1 path and the profile screen read the
      // mirror, so a stale mirror shows a working chat whose group messages
      // silently vanish.
      () => Conversation(
        peerAccountId: resolvedId,
        blocked: state.blockedPeers.containsKey(resolvedId),
      ),
    );
    convo.peerServer = sameServer(parsed.server ?? state.server, state.server)
        ? null
        : parsed.server;
    convo.peerDeviceId = verified.deviceId;
    convo.peerDevicePubKey = verified.devicePubKey;
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
  /// The read-only inbound session goes too (see AppState.inboundSessions):
  /// leaving half of a discarded pair behind would keep exactly the state this
  /// action exists to clear.
  Future<void> removeConversationPermanently(String peerAccountId) async {
    await deleteConversation(peerAccountId);
    await _withPeerSessionLock(peerAccountId, () async {
      state.sessions.remove(peerAccountId);
      state.inboundSessions.remove(peerAccountId);
    });
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
      await media.sweepOrphans(accountId: state.accountId, liveMessageIds: live);
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

  /// Folded views, keyed by group id, kept in step with the files on disk.
  ///
  /// Cached because folding is not free and the chat list asks constantly, and
  /// safe to cache because it is refreshed on the one path that can change a
  /// group: [_storeGroupState].
  final Map<String, GroupStateResult> _groupStates = {};

  GroupStateResult? groupState(String groupId) => _groupStates[groupId];

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
  Future<GroupConversation> createGroup({String name = '', String topic = ''}) async {
    final result = core.groupCreate(
      identity: _groupIdentity,
      server: state.server,
      name: name,
      topic: topic,
    );

    final conversation = GroupConversation(groupId: result.groupId);
    state.groups[result.groupId] = conversation;
    await _storeGroupState(result);
    await LocalStateStore.saveProfile(state);
    notifyListeners();
    return conversation;
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
    appendGroupSystemLines(
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

  /// Address records for members this account has no one-to-one conversation
  /// with. A member it *does* have one with reuses that conversation's
  /// endpoint, so device resolution is shared -- and the ratchet always is,
  /// since sessions are keyed by account id either way.
  final Map<String, PeerEndpoint> _groupPeers = {};

  PeerEndpoint _endpointFor(String accountId, String server) {
    // "Our own server" is the null the send path expects, not a string to
    // compare later.
    final foreign = sameServer(server, state.server) ? null : server;

    final existing = state.conversations[accountId]?.peer;
    if (existing != null) {
      existing.server ??= foreign;
      return existing;
    }
    final endpoint = _groupPeers.putIfAbsent(
      accountId,
      () => PeerEndpoint(accountId: accountId, server: foreign),
    );
    endpoint.server ??= foreign;
    return endpoint;
  }

  /// When each group was last asked to send its fact set, so opening a group
  /// repeatedly doesn't ask repeatedly. In memory only: a cold start is exactly
  /// when asking is most likely to be worth it.
  final Map<String, DateTime> _lastGroupSyncRequest = {};
  static const _groupSyncRequestCooldown = Duration(minutes: 5);

  /// Asks one member to send us their whole fact set.
  ///
  /// The other half of reconciliation, and until now the missing one: a state
  /// hash says "we differ", never who is behind, so a member who missed a fact
  /// finds out only when somebody next sends into the group -- and if that
  /// somebody is *us*, and we are the one behind, nothing at all happens. This
  /// asks outright.
  ///
  /// Sent to one member rather than all of them: any member holds the whole
  /// grow-only fact set, so one answer is as good as ten, and ten would put a
  /// snapshot-sized envelope in every member's queue every time somebody opens
  /// a group screen. Preferring a joined member because a pending invitee may
  /// hold nothing yet, and the founder first because they cannot have left.
  ///
  /// Best-effort by design: no debt is recorded and no error surfaces. Nothing
  /// is lost if it fails, since this asks for something we don't have rather
  /// than sending something somebody else needs.
  Future<void> _requestGroupSync(String groupId) async {
    final current = _groupStates[groupId];
    if (current == null || current.resolved.dissolved) return;

    final now = DateTime.now().toUtc();
    final last = _lastGroupSyncRequest[groupId];
    if (last != null && now.difference(last) < _groupSyncRequestCooldown) {
      return;
    }

    final candidates = current.resolved.members
        .where((m) => m.joined && m.accountId != state.accountId)
        .toList();
    if (candidates.isEmpty) return;
    final target = candidates.firstWhere(
      (m) => m.isFounder,
      orElse: () => candidates.first,
    );

    _lastGroupSyncRequest[groupId] = now;
    try {
      await _sendGroupControl(
        groupId,
        target.accountId,
        target.server,
        GroupControl(
          kind: GroupControlKind.syncRequest,
          groupId: groupId,
          stateHash: current.stateHash,
        ),
      );
    } catch (e) {
      developer.log(
        'group sync request to ${target.accountId} failed: ${describeError(e)}',
        name: 'groups',
      );
    }
  }

  /// Sends one receipt for [groupId], to [authorAccountId] alone.
  ///
  /// Addressed to the author rather than to the group, and that is the whole
  /// design: who has read what is between the reader and the person who wrote
  /// it. Fanning receipts out would hand every member a running attendance list
  /// of everyone else, at N times the traffic, and there is no reading of the
  /// protocol in which the other members are entitled to it.
  Future<void> _sendGroupReceipt(
    String groupId,
    String authorAccountId,
    String server,
    ReceiptStatus status,
    DateTime upTo,
  ) async {
    final peer = _endpointFor(authorAccountId, server);
    await _ensurePeerDeviceResolved(peer);
    await _encryptAndSend(
      peer,
      ReceiptSignal(
        status: status,
        upToSentAt: upTo,
        groupId: groupId,
      ).encode(),
    );
  }

  /// Confirms delivery of one member's group message, to that member only.
  ///
  /// Errors are logged, not surfaced: a receipt is a courtesy, and failing to
  /// send one must not look like a failure to receive the message it is about.
  Future<void> _sendGroupDeliveredReceipt(
    String groupId,
    String authorAccountId,
    DateTime upTo,
  ) async {
    try {
      if (!(await AppSettings.load()).readReceiptsEnabled) return;
      final member = _groupStates[groupId]?.resolved.memberById(authorAccountId);
      if (member == null) return;
      await _sendGroupReceipt(
        groupId,
        authorAccountId,
        member.server,
        ReceiptStatus.delivered,
        upTo,
      );
    } catch (e) {
      developer.log(
        'sending group delivered receipt to $authorAccountId failed: $e',
        name: 'receipts',
      );
    }
  }

  /// Tells every author in [groupId] how far their own messages have been read
  /// -- one receipt each, to them alone, and only where it would say something
  /// new (see GroupConversation.sentReceiptUpTo).
  ///
  /// A group transcript has many authors, so "read" is not one watermark but
  /// one per author, each measured over that author's own messages: confirming
  /// somebody else's newer message would tell an author their own was read when
  /// it was not.
  Future<void> sendGroupReadReceipts(String groupId) async {
    if (!(await AppSettings.load()).readReceiptsEnabled) return;
    final chat = state.groups[groupId];
    final resolved = _groupStates[groupId]?.resolved;
    if (chat == null || resolved == null) return;

    final newestPerAuthor = <String, DateTime>{};
    for (final message in chat.messages) {
      final author = message.senderAccountId;
      if (message.mine ||
          author == null ||
          message.kind != StoredMessageKind.normal) {
        continue;
      }
      final anchor = message.receiptAnchor;
      final current = newestPerAuthor[author];
      if (current == null || anchor.isAfter(current)) {
        newestPerAuthor[author] = anchor;
      }
    }

    var changed = false;
    for (final entry in newestPerAuthor.entries) {
      final alreadyTold = chat.sentReceiptUpTo[entry.key];
      if (alreadyTold != null && !entry.value.isAfter(alreadyTold)) continue;
      // Somebody who has since left is owed nothing, and sending to them would
      // be group traffic to an outsider.
      final member = resolved.memberById(entry.key);
      if (member == null) continue;
      try {
        await _sendGroupReceipt(
          groupId,
          entry.key,
          member.server,
          ReceiptStatus.read,
          entry.value,
        );
        chat.sentReceiptUpTo[entry.key] = entry.value;
        changed = true;
      } catch (e) {
        developer.log(
          'sending group read receipt to ${entry.key} failed: $e',
          name: 'receipts',
        );
      }
    }
    if (changed) await LocalStateStore.saveProfile(state);
  }

  /// Call when a group's screen closes -- the counterpart to [enterGroup],
  /// mirroring [leaveConversation]. A group id and a peer id share the one
  /// "currently open chat" slot, which is what lets an arriving group message
  /// know the user is looking at it.
  ///
  /// Named for the screen, not the membership: [leaveGroup] is the signed act of
  /// leaving the group itself, and the two must never be confused.
  void exitGroup(String groupId) {
    if (_openConversationPeerId == groupId) _openConversationPeerId = null;
  }

  /// Call when a group's screen opens: clears its unread flag, tells each author
  /// how far their messages have been read, and asks one member for their facts
  /// in case this device is the one that is behind.
  Future<void> enterGroup(String groupId) async {
    // Before the unread check, deliberately: whether the group has unread
    // messages says nothing about whether its member list is current, and the
    // membership divergence is exactly the thing nobody would otherwise notice.
    // Both directions at once -- ask for what we may be missing, and hand over
    // what somebody else never got.
    unawaited(_requestGroupSync(groupId));
    unawaited(_payGroupSnapshotDebts());
    // Shares the one open-chat slot with conversations, so a group message
    // arriving while its screen is on top is not marked unread (see
    // storeGroupMessage's openChatId) and confirms itself read right away.
    _openConversationPeerId = groupId;
    // Regardless of the unread flag: the flag says "something arrived since you
    // last looked", while a read receipt is owed for anything an author has not
    // been told about yet -- including messages read on a previous run that
    // could not be told at the time.
    unawaited(sendGroupReadReceipts(groupId));

    final chat = state.groups[groupId];
    if (chat == null || !chat.hasUnread) return;
    chat.hasUnread = false;
    await LocalStateStore.saveProfile(state);
    // Exactly as enterConversation does it: if that was the last unread chat in
    // this account, the notification goes with it -- otherwise Android's
    // launcher badge (derived from active notifications, not from anything drawn
    // in-app) would linger after the group, or the invitation, has been read.
    if (!hasAnyUnread) unawaited(clearMessageNotification(state.accountId));
    notifyListeners();
  }

  /// Invites an account, and tells everyone else.
  ///
  /// The invitee gets the whole fact set -- they have nothing to merge it
  /// into -- while everyone else gets just the new one, with the chain that
  /// authorizes it riding along inside the event itself.
  ///
  /// [address] is a full Freizone address (`id*server`, `id*local`, or just a
  /// bare id/prefix -- see lib/util/freizone_address.dart), exactly what
  /// [startConversation] accepts: a dash-grouped id pasted from "copy my
  /// address" and a short id-prefix both work.
  ///
  /// The address is resolved *before* anything is signed, and that ordering is
  /// the point. A member_add records the invitee's canonical full id because
  /// that string is what their whole key chain is signed over (see
  /// [_getOrCreateCryptoSession]'s certificate checks) and what their pairwise
  /// ratchet is keyed by -- so a member folded in under a cosmetic spelling of
  /// it, or under a prefix, is a phantom: shown in the member list, invited as
  /// far as the group is concerned, but impossible to establish a session with
  /// ("invalid dh identity certificate" on the very first send). Resolving
  /// first also means an address that resolves to nothing adds no member at
  /// all, instead of one nobody can ever deliver to.
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

    final (resolvedId, verified) = await _resolvePeerDevice(
      parsed.idOrPrefix,
      _clientFor(onOwnServer ? null : memberServer),
    );

    // The lookup above already produced (and verified) the device every send
    // below has to go to, so seed the endpoint cache rather than making
    // _sendGroupControl repeat the same GET.
    final peer = _endpointFor(resolvedId, memberServer);
    peer.deviceId ??= verified.deviceId;
    peer.devicePubKey ??= verified.devicePubKey;

    final existing = _groupStates[groupId]?.resolved.memberById(resolvedId);
    if (existing != null) {
      if (existing.joined) throw StateError('They are already in this group.');
      // Their invitation is still outstanding, so this is a re-send, not a
      // second member_add: the whole fact set again, to the same member row.
      // The repair path for an invitation whose delivery failed first time --
      // until the snapshot arrives the invitee has nothing at all, and nobody
      // else re-sends it for them (a snapshot is otherwise only offered in
      // answer to a state_hash mismatch, which needs them to send first).
      await _sendGroupSnapshotTo(groupId, resolvedId, memberServer);
      return;
    }

    final event = signGroupEvent(
      groupId: groupId,
      type: 'member_add',
      subject: resolvedId,
      server: memberServer,
    );
    await applyGroupEvents(groupId, [event]);

    // Signed and now part of this group's history: every other member has to
    // learn it even if the invitee themselves turns out to be unreachable
    // right now, or the group would disagree about its own membership. The
    // invitee's own failure is still reported -- it's the one the user asked
    // for -- just not at the cost of everyone else's copy.
    Object? snapshotError;
    try {
      await _sendGroupSnapshotTo(groupId, resolvedId, memberServer);
    } catch (e) {
      // Retried on the next working connection, so an invitation is not lost to
      // a moment without a network -- the invitee has nothing at all until the
      // snapshot arrives, and nobody re-sends it for them.
      _oweGroupSnapshot(groupId, resolvedId);
      snapshotError = e;
    }
    await _broadcastGroupEvents(groupId, [event], skip: {resolvedId});
    if (snapshotError != null) {
      // Persisted before the throw, or the debt recorded above would be lost
      // exactly when it matters: the invitation is signed and the group knows
      // about it, only the invitee doesn't.
      await LocalStateStore.saveProfile(state);
      throw snapshotError;
    }
  }

  /// Accepts an invitation addressed to this account.
  ///
  /// Announcing it is as much the invitee's job as the inviter's: they have
  /// the strongest interest in every member knowing to send to them.
  Future<void> acceptGroupInvite(String groupId) async {
    final event = signGroupEvent(
      groupId: groupId,
      type: 'join_accept',
      subject: state.accountId,
    );
    await applyGroupEvents(groupId, [event]);
    await _broadcastGroupEvents(groupId, [event]);
  }

  /// Declines an invitation addressed to this account, and forgets the group.
  ///
  /// A decline is a `leave`, not a new kind of fact: the fold deletes the member
  /// row for either one, so "I was invited and said no" and "I was in and left"
  /// are the same statement about the same person -- and the group needs exactly
  /// that. Saying nothing would leave the invitation outstanding in every
  /// member's list forever, which is the one outcome that serves nobody: the
  /// moderator can't tell a refusal from an unread invitation.
  ///
  /// Told to the group *before* the local copy goes, since signing and
  /// broadcasting both need the fact set. The local group is then forgotten
  /// completely (transcript and pictures included, see [deleteGroup]) -- having
  /// declined, there is nothing left to keep, and leaving it in the chat list
  /// would be a second invitation nobody sent.
  Future<void> declineGroupInvite(String groupId) async {
    final me = _groupStates[groupId]?.resolved.memberById(state.accountId);
    if (me == null) throw StateError('You are not in this group.');
    if (me.joined) {
      throw StateError('You have already joined this group -- leave it instead.');
    }
    await _groupAction(groupId, type: 'leave', subject: state.accountId);
    await deleteGroup(groupId);
  }

  /// Grants or revokes a role. Which key signs it is the core's decision --
  /// admin needs the group root key, moderator an ordinary device signature --
  /// and an act the fold will not authorize simply has no effect anywhere.
  Future<void> setGroupRole(
    String groupId,
    String accountId,
    String role, {
    required bool grant,
  }) => _groupAction(
    groupId,
    type: grant ? 'role_grant' : 'role_revoke',
    subject: accountId,
    role: role,
  );

  /// Removes a member. They are told too: as far as their own copy of the
  /// state is concerned they are still in the group until this reaches them.
  Future<void> removeFromGroup(String groupId, String accountId) =>
      _groupAction(groupId, type: 'member_remove', subject: accountId);

  /// Sets the name and topic. One last-writer-wins record, so an unchanged
  /// field is carried over rather than cleared.
  Future<void> setGroupMeta(String groupId, {String? name, String? topic}) async {
    final resolved = _groupStates[groupId]?.resolved;
    if (resolved == null) return;
    await _groupAction(
      groupId,
      type: 'meta',
      name: name ?? resolved.name,
      topic: topic ?? resolved.topic,
    );
  }

  Future<void> leaveGroup(String groupId) =>
      _groupAction(groupId, type: 'leave', subject: state.accountId);

  /// Leaves a group and forgets it locally, as one action.
  ///
  /// The pair belongs together, because forgetting a group this account is still
  /// a member of does not work on its own: the fact set goes, but the *others*
  /// keep sending -- and an arriving message re-creates the transcript for a
  /// group whose facts are gone, leaving a chat with no name, no member list, no
  /// way to open its info screen, and a composer whose send fails with "no
  /// group". Removing while still a member therefore means leaving first; this
  /// is that, in one step, so it cannot be half-done.
  ///
  /// Same order as [declineGroupInvite], and for the same reason: signing and
  /// broadcasting both need the fact set that the second half deletes.
  Future<void> leaveAndDeleteGroup(String groupId) async {
    await leaveGroup(groupId);
    await deleteGroup(groupId);
  }

  /// Ends the group, for the founder. They cannot leave one -- that would
  /// leave an authority behind that is not in the member list.
  Future<void> dissolveGroup(String groupId) =>
      _groupAction(groupId, type: 'dissolve');

  /// The shape every moderation action shares: sign it, apply it here, tell
  /// everyone.
  Future<void> _groupAction(
    String groupId, {
    required String type,
    String subject = '',
    String role = '',
    String name = '',
    String topic = '',
  }) async {
    final event = signGroupEvent(
      groupId: groupId,
      type: type,
      subject: subject,
      role: role,
      name: name,
      topic: topic,
    );
    // Captured before applying: a removal takes its subject out of the member
    // list, and they are the one person who most needs to hear about it.
    final removed = type == 'member_remove'
        ? _groupStates[groupId]?.resolved.memberById(subject)
        : null;

    await applyGroupEvents(groupId, [event]);
    await _broadcastGroupEvents(groupId, [event]);

    if (removed != null) {
      try {
        await _sendGroupControl(
          groupId,
          removed.accountId,
          removed.server,
          GroupControl(
            kind: GroupControlKind.events,
            groupId: groupId,
            stateHash: _groupStates[groupId]?.stateHash ?? '',
            events: [event],
          ),
        );
      } catch (e) {
        lastError =
            'telling ${removed.accountId} they were removed: '
            '${describeError(e)}';
      }
    }
  }

  /// Sends a few new facts to every member except this account and any in
  /// [skip] (an invitee who just received the whole snapshot).
  ///
  /// Recipients deliberately include members who have not accepted yet: a
  /// membership change is exactly the kind of fact a pending invitee needs.
  Future<void> _broadcastGroupEvents(
    String groupId,
    List<Map<String, dynamic>> events, {
    Set<String> skip = const {},
  }) async {
    final current = _groupStates[groupId];
    if (current == null) return;
    final control = GroupControl(
      kind: GroupControlKind.events,
      groupId: groupId,
      stateHash: current.stateHash,
      events: events,
    );

    var owedSomebody = false;
    for (final member in current.resolved.members) {
      if (member.accountId == state.accountId) continue;
      if (skip.contains(member.accountId)) continue;
      try {
        await _sendGroupControl(
          groupId,
          member.accountId,
          member.server,
          control,
        );
      } catch (e) {
        // One unreachable member must not stop the others hearing about it --
        // but the fact must not be lost either, so they are owed a snapshot.
        _oweGroupSnapshot(groupId, member.accountId);
        owedSomebody = true;
        // A debt has been recorded, so an unreachable member is a "later", not a
        // "look at this" -- see _noteFailure.
        _noteFailure('group update to ${member.accountId}', e);
      }
    }
    // Only when something actually failed: this runs on every membership change,
    // and the profile is rewritten in full each time it is saved.
    if (owedSomebody) await LocalStateStore.saveProfile(state);
  }

  /// Notes that [accountId] may be missing facts we hold about [groupId],
  /// because an envelope to them did not go out (see
  /// AppState.groupSnapshotDebts). Paid off by [flushOutbox].
  ///
  /// Not persisted here: every caller is mid-operation and saves the profile
  /// itself once it is done.
  void _oweGroupSnapshot(String groupId, String accountId) {
    (state.groupSnapshotDebts[groupId] ??= <String>{}).add(accountId);
  }

  void _clearGroupSnapshotDebt(String groupId, String accountId) {
    final owed = state.groupSnapshotDebts[groupId];
    if (owed == null) return;
    owed.remove(accountId);
    if (owed.isEmpty) state.groupSnapshotDebts.remove(groupId);
  }

  /// Re-sends the whole fact set to every member an envelope failed to reach.
  ///
  /// A snapshot rather than the individual events that were lost: the fact set
  /// is grow-only and the fold dedupes by event id, so "everything I know"
  /// is both the simplest thing to owe and always correct, and it needs no
  /// bookkeeping of which event went missing.
  ///
  /// A debt against a group this account no longer has, or against somebody who
  /// is no longer a member, is dropped rather than paid: sending group facts to
  /// an outsider would disclose the membership -- and with it every member's
  /// address -- to somebody now outside the group.
  Future<void> _payGroupSnapshotDebts() async {
    if (state.groupSnapshotDebts.isEmpty) return;
    var changed = false;

    for (final groupId in state.groupSnapshotDebts.keys.toList()) {
      final owed = state.groupSnapshotDebts[groupId]?.toList() ?? const [];
      final resolved = _groupStates[groupId]?.resolved;
      if (resolved == null) {
        state.groupSnapshotDebts.remove(groupId);
        changed = true;
        continue;
      }
      for (final accountId in owed) {
        final member = resolved.memberById(accountId);
        if (member == null) {
          _clearGroupSnapshotDebt(groupId, accountId);
          changed = true;
          continue;
        }
        try {
          await _sendGroupSnapshotTo(groupId, accountId, member.server);
          _clearGroupSnapshotDebt(groupId, accountId);
          changed = true;
        } catch (e) {
          // An account the server no longer knows is not "unreachable", it is
          // gone -- an admin deleted it, say. No number of retries will find it,
          // and the fold cannot be told: nothing in a group's facts can express
          // "this account ceased to exist". So the debt is dropped and the member
          // row stays until a moderator removes it, which is the only thing that
          // can actually resolve it. Without this, every resume would retry
          // forever and re-raise the same banner.
          //
          // But not every 404 is that: a dead *device* is not a dead *account*
          // (§4's stale-device rule). Those two codes name a member whose
          // device was replaced or is not yet provisioned -- and only reach
          // here when the claim path's re-resolve could not heal it this pass,
          // so the debt stays for the next one.
          if (e is ApiException && e.statusCode == 404) {
            if (e.code == 'unknown_device' || e.code == 'no_prekey_bundle') {
              _noteFailure('group sync to $accountId', e);
              continue;
            }
            _clearGroupSnapshotDebt(groupId, accountId);
            changed = true;
            lastError =
                'group member $accountId no longer exists on their server';
            continue;
          }
          // Still unreachable: the debt stays, to be tried again on the next
          // reconnect. Not counted or capped, unlike a failed message
          // (_outboxAttempts) -- a message the user can see and retry by hand,
          // while an unsent fact leaves the group quietly disagreeing about who
          // is in it.
          _noteFailure('group sync to $accountId', e);
        }
      }
    }
    if (changed) await LocalStateStore.saveProfile(state);
  }

  Future<void> _sendGroupSnapshotTo(
    String groupId,
    String accountId,
    String server,
  ) async {
    final current = _groupStates[groupId];
    if (current == null) return;
    await _sendGroupControl(
      groupId,
      accountId,
      server,
      GroupControl(
        kind: GroupControlKind.snapshot,
        groupId: groupId,
        stateHash: current.stateHash,
        events: (current.state['events'] as List<dynamic>? ?? const [])
            .cast<Map<String, dynamic>>(),
      ),
    );
  }

  /// Sends a message into a group: one separately encrypted copy per member.
  ///
  /// There is no group key. Every copy rides that member's own pairwise
  /// ratchet, which is what makes removing somebody take effect immediately
  /// and need no re-key anywhere (see the design document).
  Future<void> sendGroupMessage(
    String groupId,
    String text, {
    String? replyToId,
    OutgoingAttachment? attachment,
  }) async {
    final chat = state.groups[groupId];
    final resolved = _groupStates[groupId]?.resolved;
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

    final message = StoredMessage(
      id: generateMessageId(),
      text: text,
      mine: true,
      timestamp: now,
      replyToId: quoted?.id,
      replyPreviewText: quoted?.text,
      replyPreviewMine: quoted?.mine,
      // Resolved here, while the quoted message is still in hand, rather than
      // at render time: this is the only moment the author is known for
      // certain. senderAccountId is null on our own messages, which is not a
      // missing author but the one author no message needs to carry.
      replyPreviewAuthorId: quoted == null
          ? null
          : (quoted.mine ? state.accountId : quoted.senderAccountId),
      sendState: MessageSendState.pending,
      // Stands in until each recipient server's upload returns a blob id, so
      // the pending bubble already renders the picture from our own local copy.
      // A group cannot store one real reference here anyway: the blob id
      // differs per recipient server, so the reference is built per copy in
      // [_fanOut] and only the metadata is shared.
      attachments: attachment == null
          ? const []
          : [_placeholderAttachment(attachment)],
      // Only members who have accepted. An invitation must not disclose the
      // invitee's address to the group before they agree to it, and until they
      // accept there is nothing to send them anyway.
      deliveries: [
        for (final member in resolved.members)
          if (member.joined && member.accountId != state.accountId)
            GroupDelivery(
              accountId: member.accountId,
              wireMessageId: _randomHex(16),
            ),
      ],
    );

    if (attachment != null) {
      // Held for a possible retry, and written to disk before the bubble is
      // shown: ImageAttachment renders our own picture from this local file,
      // so it has to exist by the time the transcript first paints it.
      _outgoingAttachments[message.id] = attachment;
      await _storeOwnAttachment(groupId, message.id, attachment);
    }

    chat.messages.add(message);
    chat.lastActivityAt = now;
    notifyListeners();
    // Persisted before the network is touched, exactly as a one-to-one send
    // is (APP-08 step 2) -- and it matters more here, since a fan-out has
    // many more ways to be interrupted part-way.
    await LocalStateStore.saveProfile(state);

    await _fanOut(chat, message, attachment);
  }

  /// Delivers every outstanding copy of a group message.
  ///
  /// One recipient's failure never stops the others: in a group, one member
  /// being unreachable is not everybody else's problem. Each copy carries its
  /// own stable wire id, so a retry is idempotent per recipient.
  Future<void> _fanOut(
    GroupConversation chat,
    StoredMessage message,
    OutgoingAttachment? attachment,
  ) async {
    final resolved = _groupStates[chat.groupId]?.resolved;
    if (resolved == null) return;

    // A group with nobody else in it yet. There is no copy owed to anyone, so
    // the send is complete the moment it is made -- without this the message
    // sits pending forever, since an empty delivery list makes
    // aggregateSendState fall back to the message's own (pending) state.
    if (message.deliveries.isEmpty) {
      message.sendState = MessageSendState.sent;
      message.sendError = null;
      await LocalStateStore.saveProfile(state);
      notifyListeners();
      return;
    }

    // Who is still owed a copy, and where each of them reads it from. Resolved
    // up front rather than inside the send loop because an attachment is
    // uploaded once per recipient *server* (SRV-18), which cannot be worked out
    // one member at a time.
    final targets = <_GroupTarget>[];
    for (final delivery in message.deliveries) {
      if (delivery.isSent) continue;
      delivery.state = MessageSendState.pending;
      try {
        final member = resolved.memberById(delivery.accountId);
        if (member == null) {
          // Removed while this was queued: their copy is no longer owed, and
          // sending it would leak group traffic to somebody now outside it.
          delivery.state = MessageSendState.sent;
          continue;
        }
        final peer = _endpointFor(member.accountId, member.server);
        await _ensurePeerDeviceResolved(peer);
        targets.add(_GroupTarget(delivery: delivery, member: member, peer: peer));
      } catch (e) {
        delivery.state = MessageSendState.failed;
        delivery.error = describeError(e);
      }
    }

    // One upload per distinct recipient server, and the reference each member
    // is then sent -- plus, separately, the members whose upload merely failed
    // rather than being refused (see _uploadGroupAttachment).
    final upload = attachment == null
        ? _GroupAttachmentUpload()
        : await _uploadGroupAttachment(targets, attachment);

    // Encrypt first, post afterwards -- one request per distinct recipient
    // server instead of one per member (docs/PROTOCOL.md §7). Encryption cannot
    // be batched: there is no group key, so every copy rides its own recipient's
    // ratchet. Only the *transport* collapses.
    final copies = <_GroupCopy>[];
    for (final target in targets) {
      final (delivery, member, peer) = (
        target.delivery,
        target.member,
        target.peer,
      );
      if (delivery.state == MessageSendState.failed) continue;
      try {
        // This member's own reference: the same picture, under the blob id of
        // whichever server they fetch it from.
        final reference = attachment == null
            ? null
            : upload.references[member.accountId];
        if (attachment != null) {
          // Recomputed rather than only ever set, so a retry that does get the
          // picture through clears the note instead of leaving the previous
          // attempt's verdict standing.
          delivery.attachmentSkipped = reference == null;

          final uploadError = upload.failed[member.accountId];
          if (reference == null && uploadError != null) {
            // The upload did not get a *no* from their server, it just didn't
            // get through. Nothing is sent to them at all, so the whole copy is
            // retried later and arrives complete -- rather than delivering a
            // caption now and marking the picture permanently undeliverable,
            // which no retry could ever undo (a delivered copy is never
            // revisited).
            delivery.state = MessageSendState.failed;
            delivery.error = "Couldn't upload the picture: $uploadError";
            delivery.attachmentSkipped = false;
            continue;
          }
          if (reference == null && message.text.isEmpty) {
            // A picture with no caption, to a server that has said it cannot
            // hold it: there is nothing left to deliver, and sending the empty
            // remainder would put a blank bubble in their transcript. Failed
            // rather than skipped, so the k-of-N indicator says so and a
            // retry addresses them again.
            delivery.state = MessageSendState.failed;
            delivery.error =
                "Their server can't store the picture, and there is no "
                'caption to send instead.';
            continue;
          }
        }

        // Their state hash has never been seen to agree with ours, so they may
        // be missing facts -- and a fan-out is driven by state, so a member we
        // do not know about gets nothing. Handing over the whole set before the
        // message costs one envelope and is what the design asks for
        // (freizone-server's docs/design/01-groups.md, "Convergence").
        if (_needsProactiveSnapshot(chat.groupId, member.accountId)) {
          try {
            await _sendGroupSnapshotTo(
              chat.groupId,
              member.accountId,
              member.server,
            );
          } catch (e) {
            // The message itself still goes out; the facts are owed instead.
            _oweGroupSnapshot(chat.groupId, member.accountId);
            developer.log(
              'proactive snapshot to ${member.accountId} failed: '
              '${describeError(e)}',
              name: 'groups',
            );
          }
        }

        final content = MessageContent(
          id: message.id,
          text: message.text,
          groupId: chat.groupId,
          attachments: reference == null ? const [] : [reference],
          // Our own view, so a recipient notices a divergence without anyone
          // having to ask (see the receive path).
          stateHash: _groupStates[chat.groupId]?.stateHash,
          replyToId: message.replyToId,
          replyPreview: message.replyToId == null
              ? null
              : ReplyPreview(
                  text: message.replyPreviewText ?? '',
                  mine: !(message.replyPreviewMine ?? false),
                  // Absolute, so it is NOT flipped the way `mine` is -- and
                  // sent only here, in the group fan-out, because a
                  // one-to-one recipient learns nothing from it (APP-17).
                  author: message.replyPreviewAuthorId,
                ),
          senderServer: peer.isFederated ? state.server : null,
          sentAt: message.timestamp,
        );

        copies.add(await _encryptGroupCopy(peer, delivery, content.encode()));
      } catch (e) {
        delivery.state = MessageSendState.failed;
        delivery.error = describeError(e);
      }
    }

    // Grouped by the server that will hold the copy: our own for same-server
    // members (null), the member's own for federated ones.
    final byServer = <String?, List<_GroupCopy>>{};
    for (final copy in copies) {
      byServer.putIfAbsent(copy.peer.server, () => []).add(copy);
    }
    for (final entry in byServer.entries) {
      await _postGroupCopies(entry.key, entry.value);
    }

    message.sendState = message.aggregateSendState;
    message.sendError = message.hasFailed
        ? 'Not delivered to '
              '${message.deliveries.length - message.deliveredCount} of '
              '${message.deliveries.length} members.'
        : null;
    await LocalStateStore.saveProfile(state);
    notifyListeners();
  }

  /// Uploads an outgoing picture for a whole fan-out and returns the reference
  /// each member should be sent, keyed by their account id.
  ///
  /// One upload per distinct recipient *server* is what SRV-18 bought: ten
  /// members on one server share one upload and one stored copy instead of ten
  /// of each. The reference is still per member, because it need not be the
  /// same one — a server that advertises `max_blob_recipients: 1` (which is
  /// also what a server predating SRV-18 means by saying nothing) stores a blob
  /// per device, so its members get an upload and a blob id each.
  ///
  /// A member with no reference cannot be given the picture. Which of the two
  /// reasons it was matters, so [_GroupAttachmentUpload] keeps them apart: a
  /// server that *stated* it will not hold this picture is permanent, and a
  /// server that merely failed is not and must be retried rather than recorded
  /// as "they cannot receive pictures" forever.
  Future<_GroupAttachmentUpload> _uploadGroupAttachment(
    List<_GroupTarget> targets,
    OutgoingAttachment attachment,
  ) async {
    final byServer = <String?, List<_GroupTarget>>{};
    for (final target in targets) {
      if (target.delivery.state == MessageSendState.failed) continue;
      if (target.peer.deviceId == null) continue;
      byServer.putIfAbsent(target.peer.server, () => []).add(target);
    }

    final result = _GroupAttachmentUpload();
    for (final entry in byServer.entries) {
      try {
        await _uploadGroupAttachmentTo(
          entry.key,
          entry.value,
          attachment,
          result.references,
        );
      } catch (e) {
        // Not rethrown either way: one member's server must not cost the rest
        // of the group their copy.
        final permanent = isPermanentBlobRefusal(e);
        if (!permanent) {
          for (final target in entry.value) {
            result.failed[target.member.accountId] = describeError(e);
          }
        }
        developer.log(
          'group picture for ${entry.key ?? 'this server'} '
          '${permanent ? 'refused' : 'failed, will retry'}: '
          '${describeError(e)}',
          name: 'groups',
        );
        _noteFailure('sending a group picture failed', e);
      }
    }
    return result;
  }


  /// The per-server half of [_uploadGroupAttachment], filling [references] for
  /// the members it manages to upload for.
  Future<void> _uploadGroupAttachmentTo(
    String? server,
    List<_GroupTarget> targets,
    OutgoingAttachment attachment,
    Map<String, MessageAttachment> references,
  ) async {
    // Checked against the *recipient* server's own advertised limits, since
    // that is where the blob lives (docs/PROTOCOL.md §10). Unknown (null) is
    // not a refusal: the upload itself then reports the truth.
    final capability = await blobCapabilityForServer(server);
    if (capability != null) {
      if (!capability.enabled) return;
      // A server whose per-picture limit is below what we already downscaled
      // to. The design asks for a smaller rendition for that server alone,
      // which this build cannot produce (see docs/design/16-groups.md), so its
      // members go without rather than everyone getting a smaller picture --
      // which is the one option that decision ruled out.
      if (!capability.fits(attachment.bytes.length)) return;
    }

    // Encrypted once per server, not once overall: a distinct key per stored
    // object means the key that reached one server's members cannot decrypt
    // another server's copy.
    final encrypted = core.encryptBlob(attachment.bytes);
    final perUpload = capability?.maxRecipients ?? 1;

    for (var i = 0; i < targets.length; i += perUpload) {
      final chunk = targets.sublist(
        i,
        i + perUpload > targets.length ? targets.length : i + perUpload,
      );
      final blobId = await _uploadBlob(
        server: server,
        recipientDeviceIds: [for (final t in chunk) t.peer.deviceId!],
        encrypted: encrypted,
      );
      final reference = _referenceFor(
        attachment,
        blobId: blobId,
        key: encrypted.key,
      );
      for (final target in chunk) {
        references[target.member.accountId] = reference;
      }
    }
  }

  /// Re-sends only the copies of a group message that never arrived.
  Future<void> retryGroupSend(String groupId, String messageId) async {
    final chat = state.groups[groupId];
    final message = chat?.messageById(messageId);
    if (chat == null || message == null || !message.isGroupSend) return;

    final attachment = await _recoverAttachment(chat.groupId, message);
    if (message.hasAttachments && attachment == null) {
      // Re-sending the caption alone would quietly deliver a different message
      // than the one the user composed, so refuse -- the same rule retrySend
      // follows for a one-to-one picture.
      message.sendError = 'The picture is no longer available to resend.';
      notifyListeners();
      return;
    }
    await _fanOut(chat, message, attachment);
  }

  /// Re-reads one group's fact set after something else wrote it.
  ///
  /// The receive path applies events without an AppSession -- it has to, since
  /// the background push isolate decrypts too -- so the folded view cached
  /// here is the thing that goes stale, not the file.
  Future<void> _refreshGroupFromDisk(String groupId) async {
    final blob = await GroupStateStore.load(state.accountId, groupId);
    if (blob == null) return;
    try {
      _groupStates[groupId] = core.groupResolveState(blob);
      _refreshGroupName(groupId);
    } catch (e) {
      lastError = 'group $groupId failed to reload: ${describeError(e)}';
    }
  }

  /// Asks [peerAccountId] for a group's facts when this device has none.
  ///
  /// Separate from [_requestGroupSync], which needs a member list to choose a
  /// member from -- exactly what is missing here. The sender of the envelope that
  /// got us into this state is the only address we have.
  ///
  /// [peerServer] is where to reach them, and comes from the envelope's own
  /// encrypted content (MessageContent.senderServer, which a cross-server sender
  /// includes on every message precisely so a recipient's knowledge of it is
  /// self-healing -- docs/PROTOCOL.md §9). Without it this fell back to our own
  /// server, which is right for a member here and hopeless for a federated
  /// member we have never spoken to one-to-one: the one case where a group we
  /// hold no facts about could not recover on its own.
  ///
  /// Rate-limited with the same cooldown, so a burst of group messages that all
  /// find no facts produces one request, not one each.
  Future<void> _askForGroupFacts(
    String groupId,
    String peerAccountId, {
    String? peerServer,
  }) async {
    final now = DateTime.now().toUtc();
    final last = _lastGroupSyncRequest[groupId];
    if (last != null && now.difference(last) < _groupSyncRequestCooldown) return;
    _lastGroupSyncRequest[groupId] = now;

    try {
      await _sendGroupControl(
        groupId,
        peerAccountId,
        // What the envelope itself said, then what an existing conversation
        // knows, then our own server -- most specific first.
        peerServer ??
            state.conversations[peerAccountId]?.peerServer ??
            state.server,
        GroupControl(kind: GroupControlKind.syncRequest, groupId: groupId),
      );
    } catch (e) {
      developer.log(
        'asking $peerAccountId for group $groupId failed: ${describeError(e)}',
        name: 'groups',
      );
    }
  }

  /// Answers a peer whose view of a group differs from ours, or who asked
  /// outright.
  ///
  /// Sending our whole fact set is the entire repair mechanism: union of a
  /// grow-only set is idempotent and commutative, so it converges without a
  /// delta protocol or version vectors -- and a snapshot cannot invent
  /// anything, since every fact in it is individually signed.
  Future<void> _reconcileGroup(
    String groupId,
    String peerAccountId,
    String? peerStateHash, {
    bool snapshotRequested = false,
    String? peerServer,
  }) async {
    final current = _groupStates[groupId];
    if (current == null) {
      // We hold no facts about this group at all, so there is nothing to answer
      // with -- and, more to the point, nothing tells the sender that: our own
      // hash only travels on a message we cannot send without a member list.
      // Without asking outright, this state ends only if some member happens to
      // send a snapshot unprompted. So ask the one member we know exists,
      // because they just wrote to us.
      await _askForGroupFacts(
        groupId,
        peerAccountId,
        peerServer: peerServer,
      );
      return;
    }
    if (!snapshotRequested) {
      if (peerStateHash == null || peerStateHash.isEmpty) return;
      if (peerStateHash == current.stateHash) return;
      // Answer any given foreign hash at most once, so two peers that stay
      // divergent for a reason a snapshot cannot fix do not trade snapshots
      // forever.
      final seen = '$peerAccountId:$peerStateHash';
      if (!_answeredGroupHashes.add(seen)) return;
    }

    final member = current.resolved.memberById(peerAccountId);
    if (member == null) return;
    try {
      await _sendGroupControl(
        groupId,
        peerAccountId,
        member.server,
        GroupControl(
          kind: GroupControlKind.snapshot,
          groupId: groupId,
          stateHash: current.stateHash,
          events: (current.state['events'] as List<dynamic>? ?? const [])
              .cast<Map<String, dynamic>>(),
        ),
      );
    } catch (e) {
      // They asked, or their hash said they need it: owe it to them so the
      // answer is not lost with this one attempt.
      _oweGroupSnapshot(groupId, peerAccountId);
      _noteFailure('sending group snapshot to $peerAccountId', e);
    }
  }

  final Set<String> _answeredGroupHashes = {};

  /// Sends one control envelope to one member.
  Future<void> _sendGroupControl(
    String groupId,
    String accountId,
    String server,
    GroupControl control,
  ) async {
    final peer = _endpointFor(accountId, server);
    await _ensurePeerDeviceResolved(peer);
    await _encryptAndSend(peer, control.encode());
  }

  Future<void> _storeGroupState(GroupStateResult result, {String? groupId}) async {
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
    final blobId = await _uploadBlob(
      server: convo.peerServer,
      recipientDeviceIds: [convo.peerDeviceId!],
      encrypted: encrypted,
    );

    return _referenceFor(attachment, blobId: blobId, key: encrypted.key);
  }

  /// Uploads one already-encrypted blob for every device in
  /// [recipientDeviceIds], returning the blob id they all fetch it by.
  ///
  /// Several ids is the group case (SRV-18): the server stores the ciphertext
  /// once and each named device may fetch it, which is what makes a group
  /// picture cost one upload per recipient *server* instead of one per member.
  /// [server] null means our own; anything else goes over the federated route,
  /// where we have no device row and prove our identity inline.
  Future<String> _uploadBlob({
    required String? server,
    required List<String> recipientDeviceIds,
    required EncryptedBlob encrypted,
  }) async {
    if (server == null) {
      return api.uploadBlob(
        ciphertext: encrypted.ciphertext,
        digest: encrypted.digest,
        recipientDeviceIds: recipientDeviceIds,
        creds: state.credentials,
      );
    }
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
    return _clientFor(server).uploadFederatedBlob(
      ciphertext: encrypted.ciphertext,
      digest: encrypted.digest,
      recipientDeviceIds: recipientDeviceIds,
      devicePriv: state.devicePriv,
      rootPub: state.rootPub,
      senderAccountId: state.accountId,
      cert: cert,
    );
  }

  /// The reference that goes inside the encrypted message: which blob, and the
  /// key to decrypt it. Everything else is metadata the recipient needs to
  /// render the picture before it has downloaded.
  MessageAttachment _referenceFor(
    OutgoingAttachment attachment, {
    required String blobId,
    required Uint8List key,
  }) => MessageAttachment(
    kind: 'image',
    blobId: blobId,
    key: key,
    mimeType: attachment.mimeType,
    byteSize: attachment.bytes.length,
    width: attachment.width,
    height: attachment.height,
    thumb: attachment.thumb,
  );

  /// Saves the sender's own copy of a picture they just sent, so it renders
  /// straight away instead of being downloaded back from the server.
  Future<void> _storeOwnAttachment(
    String chatId,
    String messageId,
    OutgoingAttachment attachment,
  ) async {
    try {
      final media = await MediaStore.instance();
      await media.writeFile(
        media.fileFor(
          accountId: state.accountId,
          chatId: chatId,
          messageId: messageId,
        ),
        attachment.bytes,
      );
      final thumb = attachment.thumb;
      if (thumb != null) {
        await media.writeFile(
          media.thumbFor(
            accountId: state.accountId,
            chatId: chatId,
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

  /// Starts downloading a just-arrived picture, and tells the UI when it lands
  /// so a bubble already on screen swaps its placeholder for the real file.
  ///
  /// Every failure is swallowed: this is an optimization over the lazy fetch,
  /// and a picture that cannot be downloaded now still gets its tap-to-retry
  /// placeholder from [ImageAttachment] exactly as before.
  Future<void> _prefetchAttachment({
    required String chatId,
    required String messageId,
  }) async {
    final message =
        state.groups[chatId]?.messageById(messageId) ??
        state.conversations[chatId]?.messageById(messageId);
    if (message == null) return;
    try {
      final file = await ensureAttachmentDownloaded(
        chatId: chatId,
        message: message,
      );
      if (file != null) notifyListeners();
    } catch (_) {
      // Left to the lazy path, which reports it in the bubble.
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
    required String chatId,
    required StoredMessage message,
  }) async {
    if (message.attachments.isEmpty) return null;
    final attachment = message.attachments.first;

    final media = await MediaStore.instance();
    final target = media.fileFor(
      accountId: state.accountId,
      chatId: chatId,
      messageId: message.id,
    );
    if (await target.exists()) return target;
    if (message.mine) return null;

    // Keyed by the same three ids as the file itself, never by the message
    // alone: with more than one account on this device in the same group, the
    // message id is shared and the file is not (see MediaStore._fetching).
    final inFlight = media.stateFor(
      accountId: state.accountId,
      chatId: chatId,
      messageId: message.id,
    );
    if (inFlight == MediaFetchState.downloading) return null;
    media.markFetching(
      accountId: state.accountId,
      chatId: chatId,
      messageId: message.id,
    );
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
      media.clearFetchState(
        accountId: state.accountId,
        chatId: chatId,
        messageId: message.id,
      );
      // APP-20's automatic save, off unless the user turned it on: this is
      // the moment a received picture first exists as a file, and the only
      // one at which "as it arrives" can mean anything. Best-effort and
      // never prompting -- a picture landing in the background must not
      // raise a permission dialog, and a save that fails leaves the copy
      // inside the app exactly as before.
      if (attachment.isImage &&
          (await AppSettings.load()).autoSavePicturesToGallery) {
        unawaited(saveImageToGallery(target, mayPrompt: false));
      }
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
      media.markFailed(
        accountId: state.accountId,
        chatId: chatId,
        messageId: message.id,
      );
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
      await _ensurePeerDeviceResolved(convo.peer);
      await _encryptAndSend(
        convo.peer,
        RekeySignal(reason: reason).encode(),
        // The whole point of this envelope: our session is gone, so theirs has
        // to give way. Said in the prekey block (SRV-17) as well as by the `v: 3`
        // payload -- the payload is what a peer predating the field reads.
        afterOwnReset: true,
      );
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

  /// Returns the existing session with a peer, or establishes a new one as
  /// X3DH initiator by claiming their prekey bundle.
  ///
  /// Takes an endpoint rather than a conversation because a group member is
  /// reached the same way, and shares the very same session: pairwise fan-out
  /// means a group message to Ben rides Ben's own ratchet, the one a
  /// one-to-one chat with him would use.
  Future<(RatchetSessionJson, InitialMessage?)> _getOrCreateCryptoSession(
    PeerEndpoint peer,
  ) async {
    final existing = state.sessions[peer.accountId];
    if (existing != null) return (existing, null);

    PrekeyBundleResponse bundle;
    try {
      bundle = await _claimBundleFor(peer);
    } on ApiException catch (e) {
      // docs/PROTOCOL.md §4's stale-device rule: a 404 here is the first
      // moment a replaced peer device becomes visible to us -- nothing
      // propagates device revocations or account re-creations across servers
      // (§9's known gap), and this cache never expires on its own. So the
      // send that trips over the dead id is the one that heals it: forget
      // the id, re-resolve, retry once. Never more than once -- a second
      // 404 is a real answer, not a worse cache. If the re-resolve finds
      // the *account* gone, its own 404 propagates instead, which is then
      // the right error to surface.
      if (!isStaleDeviceError(e) || !await _refreshPeerDevice(peer)) {
        rethrow;
      }
      bundle = await _claimBundleFor(peer);
    }

    // Never expected: this app signs every claim, so hearing otherwise means
    // our own credentials were refused (a clock far out of skew, a revoked
    // device, a stale cert) and this session is silently starting weaker than
    // it should. Logged rather than thrown -- a working conversation is worth
    // more than the first message's forward secrecy -- but not swallowed.
    if (bundle.wasClaimedUnauthenticated) {
      developer.log(
        'server refused our prekey-bundle claim credentials for '
        '${peer.accountId}; session starts without a one-time prekey',
        name: 'prekeys',
      );
    }

    final dhCert = DHIdentityCertificate(
      accountId: peer.accountId,
      deviceId: peer.deviceId!,
      dhPubKey: bundle.dhIdentityPubKey,
      issuedAt: bundle.dhIdentityCert.issuedAt,
      signature: bundle.dhIdentityCert.signature,
    );
    if (!core.verifyDHIdentityCertificate(dhCert, peer.devicePubKey!)) {
      throw StateError('invalid dh identity certificate');
    }

    final spkCert = SignedPrekeyCertificate(
      accountId: peer.accountId,
      deviceId: peer.deviceId!,
      keyId: bundle.signedPrekey.keyId,
      dhIdentityPubKey: bundle.signedPrekey.dhIdentityPubKey,
      prekeyPubKey: bundle.signedPrekey.pubKey,
      issuedAt: bundle.signedPrekey.issuedAt,
      signature: bundle.signedPrekey.signature,
    );
    if (!core.verifySignedPrekeyCertificate(spkCert, peer.devicePubKey!)) {
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
    state.sessions[peer.accountId] = result.session;
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
    notifyListeners();

    // Persisted BEFORE the network is touched (APP-08 step 2). Anything held
    // only in memory is lost the moment the app is backgrounded, because
    // _reloadVolatileStateFromDisk replaces conversations wholesale with the
    // disk copy on resume -- so a message that exists only in memory while its
    // send is in flight simply vanishes, which is exactly what happened before
    // this line existed.
    await LocalStateStore.saveProfile(state);

    await _deliver(convo, message, attachment);
  }

  /// Re-sends a message whose send failed, including one composed in an
  /// earlier run of the app (APP-08 step 2).
  Future<void> retrySend(String peerAccountId, String messageId) async {
    final convo = state.conversations[peerAccountId];
    if (convo == null) return;
    final message = convo.messageById(messageId);
    if (message == null || !message.hasFailed) return;

    final attachment = await _recoverAttachment(convo.id, message);
    if (message.hasAttachments && attachment == null) {
      // Re-sending the caption alone would quietly deliver a different
      // message than the one the user composed, so refuse instead.
      message.sendError = 'The picture is no longer available to resend.';
      notifyListeners();
      return;
    }

    message.sendState = MessageSendState.pending;
    message.sendError = null;
    notifyListeners();
    // Same reason as in sendMessage: in flight is a state that has to survive
    // being backgrounded, since resuming re-reads conversations from disk.
    await LocalStateStore.saveProfile(state);

    await _deliver(convo, message, attachment);
  }

  /// The picture bytes a retry needs, from memory if this run composed the
  /// message and from disk otherwise.
  ///
  /// Reading it back is what makes an unsent message durable at all. The
  /// sender's own copy is written *before* the pending bubble first paints
  /// (see [sendMessage]), so by the time anything can fail it is already
  /// there -- and its metadata rode along in the message's own placeholder
  /// attachment entry, which is now persisted with it.
  /// [chatId] is the directory the sender's own copy lives in -- a peer account
  /// id for a one-to-one conversation, a group id for a group.
  Future<OutgoingAttachment?> _recoverAttachment(
    String chatId,
    StoredMessage message,
  ) async {
    if (!message.hasAttachments) return null;
    final held = _outgoingAttachments[message.id];
    if (held != null) return held;

    final reference = message.attachments.first;
    try {
      final media = await MediaStore.instance();
      final file = media.fileFor(
        accountId: state.accountId,
        chatId: chatId,
        messageId: message.id,
      );
      if (!await file.exists()) return null;

      final recovered = OutgoingAttachment(
        bytes: await file.readAsBytes(),
        mimeType: reference.mimeType,
        width: reference.width,
        height: reference.height,
        thumb: reference.thumb,
      );
      _outgoingAttachments[message.id] = recovered;
      return recovered;
    } catch (_) {
      // Unreadable for any reason is the same as absent: the caller refuses
      // to send the caption on its own rather than guessing.
      return null;
    }
  }

  /// Retries everything still unsent, oldest first, one chat at a time
  /// (APP-08 step 2) -- one-to-one messages, group messages, and the group
  /// facts somebody was never told (see [_payGroupSnapshotDebts]).
  ///
  /// Called after state is loaded and whenever the stream reconnects, which
  /// are exactly the two moments something that failed for want of a network
  /// might now succeed. Per chat the order is strictly oldest-first
  /// and sequential, so a flush cannot deliver a backlog out of order or
  /// enter the same ratchet twice -- [_encryptAndSend] serializes per peer,
  /// but only ordering the retries keeps them in the order they were typed.
  Future<void> flushOutbox() async {
    for (final convo in state.conversations.values.toList()) {
      final unsent = convo.messages
          .where((m) => m.hasFailed && m.kind == StoredMessageKind.normal)
          .toList();
      for (final message in unsent) {
        final attempts = _outboxAttempts[message.id] ?? 0;
        if (attempts >= _maxOutboxAttempts) continue;
        _outboxAttempts[message.id] = attempts + 1;
        try {
          await retrySend(convo.peerAccountId, message.id);
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
        final attempts = _outboxAttempts[message.id] ?? 0;
        if (attempts >= _maxOutboxAttempts) continue;
        _outboxAttempts[message.id] = attempts + 1;
        try {
          // Addresses only the copies that never arrived (see _fanOut), so a
          // retry cannot deliver a second copy to a member who already has it.
          await retryGroupSend(chat.groupId, message.id);
        } catch (_) {
          // Same reasoning as above: one unreachable member must not hold up
          // the rest of the flush.
        }
      }
    }

    await _payGroupSnapshotDebts();
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
      await _ensurePeerDeviceResolved(convo.peer);

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

      await _encryptAndSend(convo.peer, content.encode(), messageId: message.id);
    } catch (e) {
      message.sendState = MessageSendState.failed;
      message.sendError = describeError(e);
      lastError = 'send failed: ${describeError(e)}';
      notifyListeners();
      // The failure is persisted too, or the outbox has nothing to retry
      // from: without this the message is memory-only and the next resume
      // drops it (see _reloadVolatileStateFromDisk). Saving must not mask
      // the original error, so it is best-effort and the rethrow stands.
      try {
        await LocalStateStore.saveProfile(state);
      } catch (_) {
        // Nothing useful to do: the send already failed, and the caller is
        // about to hear about that.
      }
      rethrow;
    }

    message.sendState = MessageSendState.sent;
    message.sendError = null;
    _outgoingAttachments.remove(message.id);
    _outboxAttempts.remove(message.id);
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
  Future<void> _ensurePeerDeviceResolved(PeerEndpoint peer) async {
    if (peer.deviceId != null) return;
    final (_, verified) = await _resolvePeerDevice(
      peer.accountId,
      _clientFor(peer.server),
    );
    peer.deviceId = verified.deviceId;
    peer.devicePubKey = verified.devicePubKey;
    // A conversation's endpoint is part of the profile, so this is worth
    // keeping; a group member's standalone one is not persisted and simply
    // gets looked up again next run, which is one cheap GET.
    await LocalStateStore.saveProfile(state);
  }

  /// The reaction §4's stale-device rule prescribes: forget the cached device
  /// id and ask the peer's home server which device is current. Returns
  /// whether that produced a *different* device -- retrying with the same one
  /// would only repeat the same 404, so the caller rethrows instead.
  ///
  /// Cached ids go stale legitimately and invisibly: the peer revokes a
  /// device, or re-creates their account from its seed and the old device
  /// rows cascade away entirely. Exactly that happened on a live group where
  /// one member never received anything -- every sender kept claiming a
  /// prekey bundle for a device id the member's server had long forgotten.
  Future<bool> _refreshPeerDevice(PeerEndpoint peer) async {
    final stale = peer.deviceId;
    final (_, verified) = await _resolvePeerDevice(
      peer.accountId,
      _clientFor(peer.server),
    );
    if (verified.deviceId == stale) return false;
    peer.deviceId = verified.deviceId;
    peer.devicePubKey = verified.devicePubKey;
    developer.log(
      '${peer.accountId} replaced device $stale with ${verified.deviceId}; '
      'adopting it',
      name: 'session-recovery',
    );
    await LocalStateStore.saveProfile(state);
    return true;
  }

  /// The queueing-time form of the same discovery (§7's `unknown_recipient`):
  /// the message POST itself named a device the peer's server no longer
  /// knows. Unlike the claim-time form there is a ratchet session here, and
  /// it is bound to the dead device -- so it goes too, and the next send
  /// re-resolves and re-keys in one step via [_getOrCreateCryptoSession]'s
  /// claim-path healing.
  Future<void> _noteStaleRecipientDevice(PeerEndpoint peer) async {
    developer.log(
      'server no longer knows device ${peer.deviceId} of ${peer.accountId}; '
      'discarding it and its session',
      name: 'session-recovery',
    );
    peer.deviceId = null;
    peer.devicePubKey = null;
    // Deliberately NOT under _withPeerSessionLock: one caller
    // (_encryptAndSend's failure path) already holds that lock, and it is a
    // future chain, not reentrant. The bare synchronous remove cannot
    // interleave with anything -- the same reasoning _rollBackGroupCopy
    // relies on when it touches sessions outside the lock.
    state.sessions.remove(peer.accountId);
    await LocalStateStore.saveProfile(state);
  }

  /// Claims [peer]'s prekey bundle from whichever server holds it. Signed
  /// either way (SRV-04) -- an unauthenticated claim still returns a usable
  /// bundle but without a one-time prekey, quietly costing this session
  /// forward secrecy on its first message. Which form applies is decided the
  /// same way the send path decides it (see [_encryptAndSend]): a peer on our
  /// own server authenticates by device id, one on another server by
  /// presenting its whole certificate chain, since that server has never
  /// seen us.
  Future<PrekeyBundleResponse> _claimBundleFor(PeerEndpoint peer) {
    if (peer.server == null) {
      return api.claimPrekeyBundle(peer.deviceId!, state.credentials);
    }
    return _clientFor(peer.server).claimFederatedPrekeyBundle(
      deviceId: peer.deviceId!,
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

  /// Encrypts plaintext for convo's peer device and posts it via the
  /// correct path (same-server vs federated) -- the shared core of
  /// [sendMessage] and [_sendReceipt]. Requires convo.peerDeviceId to
  /// already be resolved (see [_ensurePeerDeviceResolved]). Deliberately
  /// does not touch convo.messages/lastActivityAt or save/notify -- callers
  /// decide what, if anything, becomes locally visible; a receipt should
  /// stay invisible and shouldn't bump the conversation to the top of the
  /// chat list, unlike a real sent message.
  ///
  /// [messageId] is the id the *server* de-duplicates by. A real message
  /// passes its own stable StoredMessage id, so re-sending after a failure
  /// cannot deliver a second copy: the server answers `409` and the client
  /// treats that as delivered (see ApiClient.sendMessage). A receipt has no
  /// stored identity and gets a fresh random one, which is fine -- a repeated
  /// receipt is a no-op for the peer.
  /// [afterOwnReset] marks a send that follows this device deliberately
  /// discarding its session with [peer] (SRV-03). It is what the prekey block's
  /// `rekey` flag states (SRV-17), and it decides how the peer handles finding an
  /// initial for a session they still hold: adopt ours unconditionally, rather
  /// than treat it as a race and possibly keep their own. Only the caller that
  /// reset the session knows this, which is why it is a parameter and not
  /// something inferred here.
  Future<void> _encryptAndSend(
    PeerEndpoint peer,
    Uint8List plaintext, {
    String? messageId,
    bool afterOwnReset = false,
  }) {
    // Outbound federation guard: a federated conversation whose home server
    // now has federation disabled is a dead end (replies blocked inbound), so
    // stop sending -- covers both real messages and receipts. Already received
    // messages remain readable; only sending is blocked.
    if (federationLockedFor(peer.server)) {
      throw StateError(
        'Federation is turned off on your server, so you can\'t message '
        'contacts on other servers.',
      );
    }
    // Serialized per peer (see _withPeerSessionLock) -- two sends to the
    // same peer close together (e.g. a "delivered" receipt immediately
    // followed by a "read" one) must never both read the ratchet session
    // before either has written its advanced state back.
    final wireMessageId = messageId ?? _randomHex(16);
    return _withPeerSessionLock(peer.accountId, () async {
      // Remembered so a failed POST can put the ratchet back where it was.
      // Encrypting advances the session, and committing that advance for a
      // message the peer never received burns a message number: they see a
      // gap, which their ratchet bridges only up to a bound before it counts
      // as a desync (SRV-03's too_many_skipped). Retrying used to widen that
      // gap on every attempt.
      final previousSession = state.sessions[peer.accountId];
      final (session, initial) = await _getOrCreateCryptoSession(peer);
      final enc = core.sessionEncrypt(session: session, plaintext: plaintext);
      state.sessions[peer.accountId] = enc.session;

      final payload = core.buildEnvelope(
        initial: initial,
        header: enc.header,
        ciphertext: enc.ciphertext,
        // Stated on every establishment, never left for the peer to guess: false
        // is as much an answer as true (SRV-17). Only meaningful when there is
        // an initial to qualify, which is exactly when the peer faces the
        // ambiguity.
        rekey: initial == null ? null : afterOwnReset,
      );
      try {
        await _postEnvelope(peer, wireMessageId, payload);
      } catch (e) {
        _rollBackSession(peer.accountId, previousSession);
        // §4's stale-device rule, queueing-time form: the POST named a device
        // the server no longer knows. Drop the id and the session bound to it
        // so the retry (manual or next flush) re-resolves and re-keys instead
        // of failing against the same dead id forever.
        if (isStaleDeviceError(e)) await _noteStaleRecipientDevice(peer);
        rethrow;
      }
    });
  }

  /// Puts one already-encrypted envelope on the wire, by whichever of the two
  /// routes the recipient needs. Split out of [_encryptAndSend] because a group
  /// fan-out encrypts every copy first and then posts them in batches, so the
  /// two halves no longer always happen together (see [_fanOut]).
  Future<void> _postEnvelope(
    PeerEndpoint peer,
    String wireMessageId,
    Map<String, dynamic> payload,
  ) async {
    if (peer.server == null) {
      await api.sendMessage(
        creds: state.credentials,
        messageId: wireMessageId,
        recipientDeviceId: peer.deviceId!,
        payload: payload,
      );
      return;
    }
    // The recipient's server has no local row for this device, so the request
    // carries a freshly-signed certificate instead of relying on one cached at
    // registration time -- see docs/PROTOCOL.md §9.
    await _clientFor(peer.server).sendFederatedMessage(
      devicePriv: state.devicePriv,
      rootPub: state.rootPub,
      senderAccountId: state.accountId,
      cert: _freshDeviceCertificate(),
      messageId: wireMessageId,
      recipientDeviceId: peer.deviceId!,
      payload: payload,
    );
  }

  DeviceCertificate _freshDeviceCertificate() => core.signDeviceCertificate(
    accountId: state.accountId,
    deviceId: state.deviceId,
    devicePub: state.devicePub,
    issuedAt: DateTime.now().toUtc(),
    rootPriv: state.rootPriv,
  );

  /// Encrypts one member's copy of a group message, leaving it ready to post.
  ///
  /// Holds that member's session lock for the encryption only, not for the POST
  /// that follows: the whole point of batching is that many copies share one
  /// request, and holding N locks across it invites deadlock. The advance is
  /// committed here, and [_rollBackGroupCopy] undoes it afterwards only if the
  /// session has not moved on since.
  Future<_GroupCopy> _encryptGroupCopy(
    PeerEndpoint peer,
    GroupDelivery delivery,
    Uint8List plaintext,
  ) => _withPeerSessionLock(peer.accountId, () async {
    final previousSession = state.sessions[peer.accountId];
    final (session, initial) = await _getOrCreateCryptoSession(peer);
    final enc = core.sessionEncrypt(session: session, plaintext: plaintext);
    state.sessions[peer.accountId] = enc.session;
    return _GroupCopy(
      peer: peer,
      delivery: delivery,
      payload: core.buildEnvelope(
        initial: initial,
        header: enc.header,
        ciphertext: enc.ciphertext,
        // A fan-out never re-keys: it sends into whatever session exists, or
        // establishes an ordinary one (SRV-17).
        rekey: initial == null ? null : false,
      ),
      previousSession: previousSession,
      committedSession: enc.session,
    );
  });

  /// Posts every copy destined for one server, in as few requests as that server
  /// allows, and resolves each delivery from its own result.
  ///
  /// A failure is per copy, never per batch -- one member at their queue cap is
  /// not the other members' problem (docs/PROTOCOL.md §7). A whole request that
  /// fails (network, or a server that turns out not to speak batch) falls back
  /// to posting the same copies individually, so a group send never depends on
  /// the newer route being there.
  Future<void> _postGroupCopies(String? server, List<_GroupCopy> copies) async {
    final limit = copies.length > 1 ? await _batchLimitFor(server) : 0;
    if (limit <= 1) {
      for (final copy in copies) {
        await _postGroupCopy(copy);
      }
      return;
    }

    for (var i = 0; i < copies.length; i += limit) {
      final chunk = copies.sublist(
        i,
        i + limit > copies.length ? copies.length : i + limit,
      );
      final items = [
        for (final copy in chunk)
          {
            'message_id': copy.delivery.wireMessageId,
            'recipient_device_id': copy.peer.deviceId!,
            'payload': copy.payload,
          },
      ];
      try {
        final results = server == null
            ? await api.sendMessagesBatch(
                creds: state.credentials,
                items: items,
              )
            : await _clientFor(server).sendFederatedMessagesBatch(
                devicePriv: state.devicePriv,
                rootPub: state.rootPub,
                senderAccountId: state.accountId,
                cert: _freshDeviceCertificate(),
                items: items,
              );
        // Matched by id rather than by position: the contract says "in the
        // submitted order", but a mis-ordered answer must not confirm the wrong
        // member's copy.
        final byId = {for (final r in results) r.messageId: r};
        for (final copy in chunk) {
          final result = byId[copy.delivery.wireMessageId];
          if (result != null && result.isDelivered) {
            copy.delivery.state = MessageSendState.sent;
            copy.delivery.error = null;
          } else {
            _rollBackGroupCopy(copy);
            copy.delivery.state = MessageSendState.failed;
            copy.delivery.error = result == null
                ? 'no answer for this copy'
                : 'server said ${result.status}';
            // The batch form of the same discovery: this member's copy named
            // a device their server no longer knows (§7's unknown_recipient
            // per-item status).
            if (isStaleRecipientStatus(result?.status)) {
              await _noteStaleRecipientDevice(copy.peer);
            }
          }
        }
      } catch (e) {
        developer.log(
          'batch send to ${server ?? 'our own server'} failed, posting '
          'individually: ${describeError(e)}',
          name: 'groups',
        );
        for (final copy in chunk) {
          await _postGroupCopy(copy);
        }
      }
    }
  }

  Future<void> _postGroupCopy(_GroupCopy copy) async {
    try {
      await _postEnvelope(
        copy.peer,
        copy.delivery.wireMessageId,
        copy.payload,
      );
      copy.delivery.state = MessageSendState.sent;
      copy.delivery.error = null;
    } catch (e) {
      _rollBackGroupCopy(copy);
      copy.delivery.state = MessageSendState.failed;
      copy.delivery.error = describeError(e);
      // Same stale-device reaction as _encryptAndSend's failure path, so a
      // group member whose device went away heals on the next fan-out.
      if (isStaleDeviceError(e)) await _noteStaleRecipientDevice(copy.peer);
    }
  }

  /// Undoes one copy's ratchet advance, but only if nothing else has used that
  /// session since it was encrypted.
  ///
  /// The check is what makes rolling back safe outside the lock: if another send
  /// (or an incoming message) has advanced the session in the meantime, restoring
  /// the old one would throw that work away and desync the pair -- far worse than
  /// the single-message gap the rollback exists to avoid.
  void _rollBackGroupCopy(_GroupCopy copy) {
    if (!identical(state.sessions[copy.peer.accountId], copy.committedSession)) {
      return;
    }
    _rollBackSession(copy.peer.accountId, copy.previousSession);
  }

  /// Whether [accountId] should be handed the whole fact set before the next
  /// message: we have never seen their state hash agree with ours.
  ///
  /// The hash they last sent is remembered per member (see
  /// AppState.groupPeerStateHashes). Equal means they were level as of their last
  /// envelope; anything else -- different, or never heard from -- means a
  /// snapshot is worth its one envelope, because state drives delivery and a
  /// member who is missing facts silently leaves people out of their own
  /// fan-out.
  bool _needsProactiveSnapshot(String groupId, String accountId) {
    final ours = _groupStates[groupId]?.stateHash;
    if (ours == null || ours.isEmpty) return false;
    return state.groupPeerStateHashes[groupId]?[accountId] != ours;
  }

  /// Undoes the ratchet advance of a send that did not go out.
  ///
  /// With a session that already existed, restoring it means the retry
  /// re-encrypts the same message *number* rather than the next one, so the
  /// peer sees no gap at all. Safe even if the POST secretly succeeded and
  /// only its response was lost: the retry carries the same wire message id,
  /// so the server answers `409` and the duplicate is never delivered.
  ///
  /// With a session that was created *for* this send, the rollback removes it
  /// entirely, and that is the important case. `_getOrCreateCryptoSession`
  /// returns no `initial` block once a session exists, so a first-contact send
  /// that failed would otherwise be retried without the X3DH prekey block --
  /// to a peer who has no session and therefore cannot decrypt it, ever.
  /// Starting over costs one of their one-time prekeys per attempt, which is a
  /// far better trade than a message that can never arrive.
  void _rollBackSession(String peerAccountId, RatchetSessionJson? previous) {
    if (previous == null) {
      state.sessions.remove(peerAccountId);
    } else {
      state.sessions[peerAccountId] = previous;
    }
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
      await _ensurePeerDeviceResolved(convo.peer);
      await _encryptAndSend(
        convo.peer,
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
    api.close();
    for (final client in _peerApiClients.values) {
      client.close();
    }
    super.dispose();
  }
}

/// One member's encrypted copy of a group message, between being encrypted and
/// being posted (see AppSession._fanOut).
///
/// Carries both sessions so the advance can be undone if the copy never goes
/// out: [previousSession] is what to restore, [committedSession] is how to tell
/// whether it is still ours to restore.
/// What one fan-out's attachment uploads produced.
///
/// Two outcomes rather than one, because "their server said no" and "the upload
/// didn't get through" need opposite handling: the first is permanent and the
/// member is told they missed the picture, the second is retried so they get the
/// message complete a moment later. Conflating them recorded a dropped
/// connection as "this member cannot receive pictures" — permanently, since a
/// copy that counts as delivered is never revisited.
class _GroupAttachmentUpload {
  /// The reference to send each member, by their account id.
  final Map<String, MessageAttachment> references = {};

  /// Members whose upload failed for a retryable reason, and why.
  final Map<String, String> failed = {};
}

/// One member still owed a copy of a group message, with everything the
/// fan-out resolved about them up front.
///
/// Separate from [_GroupCopy], which is a copy already encrypted and waiting to
/// be posted. The split exists because an attachment is uploaded once per
/// recipient *server* (SRV-18): that cannot be worked out one member at a time,
/// so who is being sent to has to be known before any copy is built.
class _GroupTarget {
  _GroupTarget({
    required this.delivery,
    required this.member,
    required this.peer,
  });

  final GroupDelivery delivery;
  final GroupMember member;
  final PeerEndpoint peer;
}

class _GroupCopy {
  _GroupCopy({
    required this.peer,
    required this.delivery,
    required this.payload,
    required this.previousSession,
    required this.committedSession,
  });

  final PeerEndpoint peer;
  final GroupDelivery delivery;
  final Map<String, dynamic> payload;
  final RatchetSessionJson? previousSession;
  final RatchetSessionJson committedSession;
}
