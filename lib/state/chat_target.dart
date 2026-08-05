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
import 'contact_store.dart';
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

/// One recipient's copy of a group message (APP-16).
///
/// A group send is N separately encrypted copies, so "sent" is not one state
/// but N of them, and a retry has to be able to address just the ones that
/// failed.
class GroupDelivery {
  GroupDelivery({
    required this.accountId,
    required this.wireMessageId,
    this.state = MessageSendState.pending,
    this.error,
    this.attachmentSkipped = false,
  });

  factory GroupDelivery.fromJson(Map<String, dynamic> j) => GroupDelivery(
    accountId: j['account_id'] as String,
    wireMessageId: j['wire_message_id'] as String,
    // Nothing is in flight in a process that no longer exists, so a copy
    // written while pending comes back as a failure to retry -- the same rule
    // the message as a whole follows.
    state: _sendStateFromJson(j['state'] as String?),
    attachmentSkipped: j['attachment_skipped'] as bool? ?? false,
  );

  final String accountId;

  /// The id the recipient's server de-duplicates by, so a retry cannot deliver
  /// a second copy: the server answers `409` and that counts as delivered.
  ///
  /// Random and per recipient, deliberately. Sharing the message's own id
  /// across recipients would make two members on the same server collide --
  /// the second copy answered `409` and recorded as delivered to somebody who
  /// never got it. Deriving it from the message id would fix that and let a
  /// server, or two servers comparing notes, recognise N copies as one group
  /// message.
  final String wireMessageId;

  MessageSendState state;
  String? error;

  /// This member got the caption but not the picture: their server does not
  /// store attachments, or would not take this one (APP-16/SRV-18). Not a
  /// delivery failure -- the message itself arrived -- so it needs its own
  /// flag rather than riding on [state].
  ///
  /// Persisted, unlike [error]: "they never got the picture" does not become
  /// untrue with time, and a retry cannot fix it either. A delivery that
  /// already counts as sent is never revisited, so re-delivering the picture
  /// would mean sending the whole message again, caption and all. The bubble
  /// says so instead, and sending it again is the user's call.
  bool attachmentSkipped;

  bool get isSent => state == MessageSendState.sent;

  Map<String, dynamic> toJson() => {
    'account_id': accountId,
    'wire_message_id': wireMessageId,
    if (state != MessageSendState.sent) 'state': state.name,
    if (attachmentSkipped) 'attachment_skipped': true,
  };
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
    this.replyPreviewAuthorId,
    this.kind = StoredMessageKind.normal,
    this.attachments = const [],
    this.sendState = MessageSendState.sent,
    List<GroupDelivery>? deliveries,
  }) : id = id ?? generateMessageId(),
       deliveries = deliveries ?? [];

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
    replyPreviewAuthorId: j['reply_preview_author_id'] as String?,
    kind: _storedMessageKindFromJson(j['kind'] as String?),
    attachments: _attachmentsFromJson(j['attachments']),
    sendState: _sendStateFromJson(j['send_state'] as String?),
    deliveries: ((j['deliveries'] as List<dynamic>?) ?? const [])
        .map((d) => GroupDelivery.fromJson(d as Map<String, dynamic>))
        .toList(),
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
    if (replyPreviewAuthorId != null)
      'reply_preview_author_id': replyPreviewAuthorId,
    if (kind != StoredMessageKind.normal) 'kind': kind.name,
    if (attachments.isNotEmpty)
      'attachments': attachments.map((a) => a.toJson()).toList(),
    // Omitted for a sent message, which is almost all of them -- so existing
    // history stays byte-identical and only the exceptional case costs a key.
    // sendError is deliberately NOT persisted: a reason from a previous run
    // ("this server doesn't accept pictures") may no longer be true, and a
    // stale explanation is worse than the plain "not sent" the retry shows.
    if (sendState != MessageSendState.sent) 'send_state': sendState.name,
    if (deliveries.isNotEmpty)
      'deliveries': deliveries.map((d) => d.toJson()).toList(),
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

  /// One entry per recipient of a group message, empty for a one-to-one one.
  ///
  /// [sendState] stays the single value the bubble renders -- it is the
  /// aggregate over these, written by the fan-out -- while these are what a
  /// retry addresses and what "delivered to 7 of 20" is counted from.
  final List<GroupDelivery> deliveries;

  bool get isGroupSend => deliveries.isNotEmpty;
  int get deliveredCount => deliveries.where((d) => d.isSent).length;

  /// The aggregate of [deliveries]: still going while any copy is in flight,
  /// failed once none is but some never arrived, sent when all of them did.
  MessageSendState get aggregateSendState {
    if (deliveries.isEmpty) return sendState;
    if (deliveries.any((d) => d.state == MessageSendState.pending)) {
      return MessageSendState.pending;
    }
    if (deliveries.any((d) => d.state == MessageSendState.failed)) {
      return MessageSendState.failed;
    }
    return MessageSendState.sent;
  }

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

  /// Who wrote the quoted message (APP-17), for a group quote that has to
  /// name an author among N rather than two. Null for a one-to-one reply,
  /// where [replyPreviewMine] already answers it, and null for a group reply
  /// from a build predating the field -- the renderer falls back to local
  /// history and then to no author line, never to a guess.
  final String? replyPreviewAuthorId;

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
  ///
  /// [contacts] is where a *person's* name comes from (APP-19) -- there is no
  /// alias on a conversation any more, because a name belongs to the person
  /// rather than to one of my chats with them. A group ignores it: a group named
  /// itself, and that name is its own (see [GroupConversation.displayName]).
  ///
  /// Taking the store rather than a name resolved by the caller is deliberate:
  /// the signature has to stay uniform, since a chat list draws both kinds
  /// through this one call -- and a required parameter is what makes the
  /// compiler point at every place a name is shown, instead of a forgotten
  /// lookup silently falling back to the address.
  String titleFor(String localServer, ContactStore contacts);

  /// One-line summary for the chat list. An attachment gets a marker, since
  /// a picture with no caption would otherwise show as a blank row.
  ///
  /// [contacts] is unused here and used by [GroupConversation], which names the
  /// author of the last message (APP-18). It sits in the signature for
  /// [titleFor]'s reason: one uniform call for both kinds of chat, and a
  /// required parameter the compiler can point at.
  String previewFor(ContactStore contacts) {
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
    // No `display_name` here any more (APP-19): a person's name lives in the
    // contact store, and a group writes its own in GroupConversation.toJson.
    // Nothing has to strip the old key from existing profiles -- a profile is
    // rewritten in full on every message, so it disappears on the next save
    // simply because nothing emits it.
    j['messages'] = messages.map((m) => m.toJson()).toList();
    j['last_activity_at'] = encodeTime(lastActivityAt);
    j['has_unread'] = hasUnread;
    if (pinnedMessageIds.isNotEmpty) {
      j['pinned_message_ids'] = pinnedMessageIds;
    }
  }
}
