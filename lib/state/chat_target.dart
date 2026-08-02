// What a transcript is, independent of who is on the other end.
//
// A one-to-one chat has a peer; a group (APP-16) has no peer at all, and
// Conversation is built around `peerAccountId` from top to bottom. Rather than
// make that field mean two things, the parts a transcript screen actually uses
// -- a stable id, a title, the messages, unread state, pins -- live here, and
// the peer-specific half stays in Conversation.
//
// StoredMessage moves here with it: a line of transcript is the same object
// whoever wrote it. conversation.dart re-exports this file, so existing
// imports keep working.
import '../ffi/models.dart';
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
/// message is always [sent].
///
/// [pending] means the bubble is already in the transcript while the upload
/// and/or the encrypted POST are still in flight -- that is the whole point,
/// so the composer can be cleared the instant the user hits send instead of
/// looking frozen on a slow connection.
///
/// All three are persisted (APP-08 step 2), but [pending] never survives a
/// restart: nothing is in flight in a process that no longer exists, so it
/// loads back as [failed] and gets retried. Before step 2 an unsent message
/// was dropped on close entirely.
enum MessageSendState { pending, sent, failed }

MessageSendState _sendStateFromJson(String? v) => switch (v) {
  // A message written while it was still in flight: the process it was in
  // flight from is gone, so it is a failure to retry, not a send in progress.
  'pending' || 'failed' => MessageSendState.failed,
  _ => MessageSendState.sent,
};

/// Tolerant of anything unexpected, like the enum parse above: history
/// written by an older build simply has no "attachments" key, and a
/// malformed entry costs its own attachment rather than the whole message.
///
/// Decoded as `local`, because this is our own stored history: an outgoing
/// picture still waiting to be sent has no blob id yet, and dropping it here
/// would turn a queued photo into a text-only message when the outbox
/// retries it.
List<MessageAttachment> _attachmentsFromJson(dynamic raw) {
  if (raw is! List || raw.isEmpty) return const [];
  final out = <MessageAttachment>[];
  for (final entry in raw) {
    if (entry is! Map<String, dynamic>) continue;
    final parsed = MessageAttachment.fromJson(entry, local: true);
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
    this.senderAccountId,
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
    senderAccountId: j['sender_account_id'] as String?,
    replyToId: j['reply_to_id'] as String?,
    replyPreviewText: j['reply_preview_text'] as String?,
    replyPreviewMine: j['reply_preview_mine'] as bool?,
    kind: _storedMessageKindFromJson(j['kind'] as String?),
    attachments: _attachmentsFromJson(j['attachments']),
    sendState: _sendStateFromJson(j['send_state'] as String?),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'mine': mine,
    'timestamp': encodeTime(timestamp),
    if (senderSentAt != null) 'sender_sent_at': encodeTime(senderSentAt!),
    if (senderAccountId != null) 'sender_account_id': senderAccountId,
    if (replyToId != null) 'reply_to_id': replyToId,
    if (replyPreviewText != null) 'reply_preview_text': replyPreviewText,
    if (replyPreviewMine != null) 'reply_preview_mine': replyPreviewMine,
    if (kind != StoredMessageKind.normal) 'kind': kind.name,
    if (attachments.isNotEmpty)
      'attachments': attachments.map((a) => a.toJson()).toList(),
    // Omitted for a sent message, which is almost all of them -- so existing
    // history stays byte-identical and only the exceptional case costs a key.
    // sendError is deliberately NOT persisted: a reason from a previous run
    // ("this server doesn't accept pictures") may no longer be true, and a
    // stale explanation is worse than the plain "not sent" the retry shows.
    if (sendState != MessageSendState.sent) 'send_state': sendState.name,
  };

  final String id;
  final String text;
  final bool mine;
  final DateTime timestamp;

  /// Whether this is an ordinary chat message or a local system/info line
  /// (see [StoredMessageKind]).
  final StoredMessageKind kind;

  /// Who wrote this, when that is not answered by [mine] alone. Null in a
  /// one-to-one chat, where the only two possibilities are "me" and "the one
  /// peer" -- it exists for a group transcript, where a bubble has to name its
  /// author. Absent from history written before groups, which is exactly
  /// right: those messages had only one possible author.
  final String? senderAccountId;

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

/// Anything that renders as a transcript: a one-to-one [Conversation] today,
/// a group as well once APP-16 lands.
///
/// Deliberately small. Everything a chat screen needs to draw a transcript and
/// a chat-list row belongs here; everything that is only true of *one peer* --
/// their server, their device, blocking them, a single receipt watermark --
/// stays in Conversation, because a group has none of it.
abstract class ChatTarget {
  ChatTarget({
    this.displayName,
    List<StoredMessage>? messages,
    DateTime? lastActivityAt,
    this.hasUnread = false,
    List<String>? pinnedMessageIds,
  }) : messages = messages ?? [],
       pinnedMessageIds = pinnedMessageIds ?? [],
       lastActivityAt = lastActivityAt ?? DateTime.now().toUtc();

  /// The stable local key for this chat: a peer's account id today, a group id
  /// once there are groups. Both are 21-character bech32m strings that differ
  /// only in their version marker, so anything keyed by this -- the chat map,
  /// the media directory -- needs no second form.
  String get id;

  String? displayName;
  List<StoredMessage> messages;
  DateTime lastActivityAt;

  /// True once an incoming message has arrived while this chat wasn't the one
  /// open -- cleared when it's opened. Drives the unread dot in the chat list
  /// and the account switcher.
  bool hasUnread;

  /// Locally pinned message ids, oldest-pinned first -- purely local, never
  /// sent to anyone. The sticky bar in ChatScreen shows the most recently
  /// pinned one by default, with </> to browse the rest.
  List<String> pinnedMessageIds;

  /// What to call this chat in a list or an app bar.
  String titleFor(String localServer);

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

  /// Writes the fields every transcript has. Subclasses add their own.
  ///
  /// Unsent messages are persisted too (APP-08 step 2). They used to be
  /// dropped here, because a retry needed the picture bytes from an in-memory
  /// map and a restored "failed" bubble could never actually be resent -- a
  /// dead end the user could not clear. That reasoning no longer holds: the
  /// sender's own copy of a picture is written to disk *before* the bubble
  /// first paints, so a retry can read it back (see
  /// AppSession.\_recoverAttachment).
  void writeBaseJson(Map<String, dynamic> j) {
    if (displayName != null) j['display_name'] = displayName;
    j['messages'] = messages.map((m) => m.toJson()).toList();
    j['last_activity_at'] = encodeTime(lastActivityAt);
    j['has_unread'] = hasUnread;
    if (pinnedMessageIds.isNotEmpty) {
      j['pinned_message_ids'] = pinnedMessageIds;
    }
  }
}
