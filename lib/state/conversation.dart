// A conversation's display/history model -- the UI-facing layer on top
// of the crypto layer (AppState.sessions, a ratchet.Session's own JSON
// form). Kept deliberately separate: this is what the chat list and
// chat screen render, the ratchet session is what the Go core consumes.
import 'dart:typed_data';

import '../ffi/models.dart';
import '../util/freizone_address.dart';
import 'message_content.dart';

/// What kind of transcript line a [StoredMessage] is. [normal] is an ordinary
/// chat message (rendered as a bubble); [systemInfo] is a local, non-encrypted
/// info line rendered centered (e.g. "Secure session was reset"), never
/// transmitted.
enum StoredMessageKind { normal, systemInfo }

StoredMessageKind _storedMessageKindFromJson(String? v) =>
    StoredMessageKind.values.firstWhere(
      (k) => k.name == v,
      orElse: () => StoredMessageKind.normal,
    );

/// How far one of our OWN outgoing messages has got (APP-08). A received
/// message, and anything loaded back from disk, is always [sent]: the
/// transcript is written only once a message is actually away (see
/// Conversation.toJson), so no other value can survive a restart.
///
/// [pending] means the bubble is already in the transcript while the upload
/// and/or the encrypted POST are still in flight -- that is the whole point,
/// so the composer can be cleared the instant the user hits send instead of
/// looking frozen on a slow connection.
enum MessageSendState { pending, sent, failed }

/// Tolerant of anything unexpected, like the enum parse above: history
/// written by an older build simply has no "attachments" key, and a
/// malformed entry costs its own attachment rather than the whole message.
List<MessageAttachment> _attachmentsFromJson(dynamic raw) {
  if (raw is! List || raw.isEmpty) return const [];
  final out = <MessageAttachment>[];
  for (final entry in raw) {
    if (entry is! Map<String, dynamic>) continue;
    final parsed = MessageAttachment.fromJson(entry);
    if (parsed != null) out.add(parsed);
  }
  return out;
}

/// One decrypted (or about-to-be-sent) chat line, persisted locally --
/// the server never stores plaintext or keeps history. [id] identifies
/// this message for replies/delete/pin; messages from before those
/// features existed get one synthesized on load (see fromJson) purely
/// for local use -- it was never transmitted for them, so nothing else
/// can reference it, which is fine since delete/pin are local-only and a
/// reply naturally can't point at a message sent before replies existed.
class StoredMessage {
  StoredMessage({
    String? id,
    required this.text,
    required this.mine,
    required this.timestamp,
    this.senderSentAt,
    this.replyToId,
    this.replyPreviewText,
    this.replyPreviewMine,
    this.kind = StoredMessageKind.normal,
    this.attachments = const [],
    this.sendState = MessageSendState.sent,
  }) : id = id ?? generateMessageId();

  /// A local, non-encrypted info line shown centered in the transcript
  /// (e.g. "Secure session was reset"). Never transmitted; see
  /// chat_screen.dart's _SystemMessage renderer.
  factory StoredMessage.system(String text, DateTime timestamp) =>
      StoredMessage(
        text: text,
        mine: false,
        timestamp: timestamp,
        kind: StoredMessageKind.systemInfo,
      );

  factory StoredMessage.fromJson(Map<String, dynamic> j) => StoredMessage(
    id: j['id'] as String? ?? generateMessageId(),
    text: j['text'] as String,
    mine: j['mine'] as bool,
    timestamp: decodeTime(j['timestamp'] as String),
    senderSentAt: j['sender_sent_at'] == null
        ? null
        : decodeTime(j['sender_sent_at'] as String),
    replyToId: j['reply_to_id'] as String?,
    replyPreviewText: j['reply_preview_text'] as String?,
    replyPreviewMine: j['reply_preview_mine'] as bool?,
    kind: _storedMessageKindFromJson(j['kind'] as String?),
    attachments: _attachmentsFromJson(j['attachments']),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'mine': mine,
    'timestamp': encodeTime(timestamp),
    if (senderSentAt != null) 'sender_sent_at': encodeTime(senderSentAt!),
    if (replyToId != null) 'reply_to_id': replyToId,
    if (replyPreviewText != null) 'reply_preview_text': replyPreviewText,
    if (replyPreviewMine != null) 'reply_preview_mine': replyPreviewMine,
    if (kind != StoredMessageKind.normal) 'kind': kind.name,
    if (attachments.isNotEmpty)
      'attachments': attachments.map((a) => a.toJson()).toList(),
  };

  final String id;
  final String text;
  final bool mine;
  final DateTime timestamp;

  /// Whether this is an ordinary chat message or a local system/info line
  /// (see [StoredMessageKind]).
  final StoredMessageKind kind;

  /// Files sent with this message (see [MessageAttachment]). Kept as the
  /// attachment *metadata* only -- the blob reference, key and a tiny
  /// preview thumbnail. The picture itself is a file on disk, never part of
  /// the profile JSON: that whole file is rewritten on every single message,
  /// so image bytes in here would make every chat write cost megabytes.
  ///
  /// Reassignable for one reason only: an optimistically-appended outgoing
  /// picture (see [sendState]) is in the transcript before its blob exists,
  /// so it starts out with a placeholder entry carrying just the local
  /// rendering metadata, and AppSession.sendMessage swaps in the real
  /// reference once the upload returns a blob id.
  List<MessageAttachment> attachments;

  bool get hasAttachments => attachments.isNotEmpty;

  /// Where this message is on its way out (APP-08) -- mutable because the
  /// bubble is rendered *before* the network work starts and has to be
  /// updated in place as that work resolves. Always
  /// [MessageSendState.sent] for received messages and for anything read
  /// back from disk.
  MessageSendState sendState;

  /// Why the send failed, for the SnackBar shown alongside the failed
  /// bubble -- the state alone can't say "this server doesn't accept
  /// pictures". Null unless [sendState] is [MessageSendState.failed].
  String? sendError;

  bool get isPending => sendState == MessageSendState.pending;
  bool get hasFailed => sendState == MessageSendState.failed;

  /// For a RECEIVED message: the sender's own clock reading at send time,
  /// carried inside the encrypted content (message_content.dart's sentAt)
  /// -- null for own messages and for messages from senders predating the
  /// field. Display and ordering keep using [timestamp] (local arrival
  /// time); this exists solely as the value receipts must echo back, see
  /// [receiptAnchor].
  final DateTime? senderSentAt;

  /// The timestamp a delivery/read receipt for this message must carry:
  /// the sender's own send-time stamp when known, so the sender's
  /// checkmark comparison (chat_screen.dart's _deliveryStatusFor, its own
  /// StoredMessage.timestamp vs. the receipt) happens within one clock --
  /// falling back to local arrival time for legacy senders.
  DateTime get receiptAnchor => senderSentAt ?? timestamp;

  /// The id of the message this one replies to, if any -- may point at a
  /// message no longer in local history (deleted, or never received);
  /// [replyPreviewText]/[replyPreviewMine] are the self-contained
  /// snapshot to render regardless, see message_content.dart.
  final String? replyToId;
  final String? replyPreviewText;
  final bool? replyPreviewMine;

  bool get isReply => replyToId != null;
}

/// One peer conversation: who they are (resolved once, cached), and the
/// locally persisted message history with them.
class Conversation {
  Conversation({
    required this.peerAccountId,
    this.displayName,
    this.peerServer,
    this.peerDeviceId,
    this.peerDevicePubKey,
    List<StoredMessage>? messages,
    DateTime? lastActivityAt,
    this.hasUnread = false,
    List<String>? pinnedMessageIds,
    this.blocked = false,
    this.pendingApproval = false,
    this.peerDeliveredUpTo,
    this.peerReadUpTo,
    this.sentDeliveredReceiptUpTo,
    this.sentReadReceiptUpTo,
  }) : messages = messages ?? [],
       pinnedMessageIds = pinnedMessageIds ?? [],
       lastActivityAt = lastActivityAt ?? DateTime.now().toUtc();

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
    peerAccountId: j['peer_account_id'] as String,
    displayName: j['display_name'] as String?,
    peerServer: j['peer_server'] as String?,
    peerDeviceId: j['peer_device_id'] as String?,
    peerDevicePubKey: j['peer_device_pub_key'] == null
        ? null
        : decodeB64(j['peer_device_pub_key'] as String),
    messages: (j['messages'] as List<dynamic>?)
        ?.map((m) => StoredMessage.fromJson(m as Map<String, dynamic>))
        .toList(),
    lastActivityAt: decodeTime(j['last_activity_at'] as String),
    hasUnread: j['has_unread'] as bool? ?? false,
    pinnedMessageIds: (j['pinned_message_ids'] as List<dynamic>?)
        ?.cast<String>()
        .toList(),
    blocked: j['blocked'] as bool? ?? false,
    pendingApproval: j['pending_approval'] as bool? ?? false,
    peerDeliveredUpTo: j['peer_delivered_up_to'] == null
        ? null
        : decodeTime(j['peer_delivered_up_to'] as String),
    peerReadUpTo: j['peer_read_up_to'] == null
        ? null
        : decodeTime(j['peer_read_up_to'] as String),
    sentDeliveredReceiptUpTo: j['sent_delivered_receipt_up_to'] == null
        ? null
        : decodeTime(j['sent_delivered_receipt_up_to'] as String),
    sentReadReceiptUpTo: j['sent_read_receipt_up_to'] == null
        ? null
        : decodeTime(j['sent_read_receipt_up_to'] as String),
  );

  final String peerAccountId;
  String? displayName;

  /// This peer's home server, normalized (see server_url.dart), if it's
  /// on a DIFFERENT server than this session's own -- null means "same
  /// server," the common case. Set explicitly when starting a federated
  /// conversation, and kept fresh on every incoming message that carries
  /// one (see AppSession._handleIncoming and message_content.dart's
  /// senderServer) so it self-heals if local state is ever lost.
  String? peerServer;
  String? peerDeviceId;
  Uint8List? peerDevicePubKey;
  List<StoredMessage> messages;
  DateTime lastActivityAt;

  /// True once an incoming message has arrived while this conversation's
  /// ChatScreen wasn't the one open -- cleared when it's opened. Drives
  /// the unread dot in the chat list and the account switcher.
  bool hasUnread;

  /// Locally pinned message ids, oldest-pinned first -- purely local,
  /// never sent to the peer or the server. The sticky bar in ChatScreen
  /// shows the most recently pinned one by default, with </> to browse
  /// the rest.
  List<String> pinnedMessageIds;

  /// True once this peer is blocked -- purely local (see
  /// AppSession.setBlocked): further incoming messages are decrypted
  /// (so the ratchet session and server-side queue both stay clean) but
  /// dropped before being stored or notified, and the chat screen
  /// disables sending. The peer is never told either way.
  bool blocked;

  /// True while this conversation is an unactioned "message request" --
  /// set only when [AppSession._handleIncoming] creates it for a peer
  /// that never existed before (an incoming first contact), never for one
  /// created by [AppSession.startConversation] (you reaching out doesn't
  /// need your own approval). Cleared by [AppSession.acceptConversation]
  /// or by blocking. Purely a display/composer-gating concern -- messages
  /// still arrive and get stored normally while pending, see
  /// _handleIncoming.
  bool pendingApproval;

  /// How far the PEER has confirmed receiving/reading MY messages -- one
  /// marker per conversation, not one per message (see receipt_signal
  /// .dart): a message of mine with `timestamp <= peerReadUpTo` is
  /// rendered as read, `<= peerDeliveredUpTo` as delivered. Monotonic --
  /// only ever moves forward, see AppSession.processIncomingMessage.
  /// Never set if [AppSettings.readReceiptsEnabled] is off, which is what
  /// makes disabling receipts reciprocal (nothing to render either way).
  DateTime? peerDeliveredUpTo;
  DateTime? peerReadUpTo;

  /// How far I've already told the peer I've received/read THEIR
  /// messages -- purely local bookkeeping so AppSession doesn't re-send
  /// an identical receipt every time it re-checks (e.g. on every incoming
  /// message in a burst, or every time the conversation is reopened).
  DateTime? sentDeliveredReceiptUpTo;
  DateTime? sentReadReceiptUpTo;

  /// The alias if one is set, otherwise the peer's compact
  /// "shortid*domain" address -- which server they're actually on is
  /// worth always keeping visible (especially once federation means
  /// that isn't always this session's own server), more so than the
  /// full checksummed id. [localServer] fills in for [peerServer] ==
  /// null (this peer is on the same server as us).
  String titleFor(String localServer) =>
      displayName ??
      shortFreizoneAddress(id: peerAccountId, server: peerServer ?? localServer);

  /// One-line summary for the chat list. An attachment gets a marker, since
  /// a picture with no caption would otherwise show as a blank row.
  String get lastMessagePreview {
    if (messages.isEmpty) return '';
    final last = messages.last;
    if (!last.hasAttachments) return last.text;
    final label = last.attachments.first.isImage ? '📷 Photo' : '📎 Attachment';
    return last.text.isEmpty ? label : '$label  ${last.text}';
  }

  /// Looks up a message by id, or null if it's not (or no longer) in
  /// local history -- e.g. it was deleted locally, or belongs to the
  /// other side's history only.
  StoredMessage? messageById(String id) {
    for (final m in messages) {
      if (m.id == id) return m;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'peer_account_id': peerAccountId,
    if (displayName != null) 'display_name': displayName,
    if (peerServer != null) 'peer_server': peerServer,
    if (peerDeviceId != null) 'peer_device_id': peerDeviceId,
    if (peerDevicePubKey != null)
      'peer_device_pub_key': encodeB64(peerDevicePubKey!),
    // Only messages that actually left the device (APP-08). A pending or
    // failed one is deliberately session-only: retrying it needs the
    // original picture bytes, which live in memory (AppSession's outgoing
    // attachment map), so a "failed" bubble restored after a restart could
    // never be resent -- it would just be a dead end the user can't clear.
    // Making them durable is exactly what step 2's real outbox is for.
    // Filtered here rather than at the call site so an unrelated save (an
    // incoming message, a receipt) can't persist one by accident either.
    'messages': messages
        .where((m) => m.sendState == MessageSendState.sent)
        .map((m) => m.toJson())
        .toList(),
    'last_activity_at': encodeTime(lastActivityAt),
    'has_unread': hasUnread,
    if (pinnedMessageIds.isNotEmpty) 'pinned_message_ids': pinnedMessageIds,
    if (blocked) 'blocked': blocked,
    if (pendingApproval) 'pending_approval': pendingApproval,
    if (peerDeliveredUpTo != null)
      'peer_delivered_up_to': encodeTime(peerDeliveredUpTo!),
    if (peerReadUpTo != null) 'peer_read_up_to': encodeTime(peerReadUpTo!),
    if (sentDeliveredReceiptUpTo != null)
      'sent_delivered_receipt_up_to': encodeTime(sentDeliveredReceiptUpTo!),
    if (sentReadReceiptUpTo != null)
      'sent_read_receipt_up_to': encodeTime(sentReadReceiptUpTo!),
  };
}
