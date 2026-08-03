// A group's transcript (APP-16).
//
// Deliberately holds only what a transcript needs. The membership -- who is in
// the group, who may do what -- is not here at all: it lives in the signed
// fact set, in its own file per group (group_store.dart), and is folded by the
// native core. Keeping a second copy of it here would be a cache that can
// disagree with the facts, which is the one thing this design is built to
// avoid.
//
// The single exception is [displayName], refreshed from the folded view every
// time the fact set changes, so a chat-list row can be drawn without opening
// every group's file.
import '../ffi/models.dart';
import 'chat_target.dart';
import 'receipt_signal.dart';

/// One group conversation: the locally persisted transcript, plus the receipt
/// bookkeeping that a group needs per member rather than per chat.
class GroupConversation extends ChatTarget {
  GroupConversation({
    required this.groupId,
    super.displayName,
    super.messages,
    super.lastActivityAt,
    super.hasUnread,
    super.pinnedMessageIds,
    this.invitePending = false,
    Map<String, DateTime>? memberDeliveredUpTo,
    Map<String, DateTime>? memberReadUpTo,
    Map<String, DateTime>? sentReceiptUpTo,
  }) : memberDeliveredUpTo = memberDeliveredUpTo ?? {},
       memberReadUpTo = memberReadUpTo ?? {},
       sentReceiptUpTo = sentReceiptUpTo ?? {};

  factory GroupConversation.fromJson(Map<String, dynamic> j) =>
      GroupConversation(
        groupId: j['group_id'] as String,
        displayName: j['display_name'] as String?,
        messages: (j['messages'] as List<dynamic>?)
            ?.map((m) => StoredMessage.fromJson(m as Map<String, dynamic>))
            .toList(),
        lastActivityAt: decodeTime(j['last_activity_at'] as String),
        hasUnread: j['has_unread'] as bool? ?? false,
        pinnedMessageIds: (j['pinned_message_ids'] as List<dynamic>?)
            ?.cast<String>()
            .toList(),
        invitePending: j['invite_pending'] as bool? ?? false,
        memberDeliveredUpTo: _watermarksFromJson(j['member_delivered_up_to']),
        memberReadUpTo: _watermarksFromJson(j['member_read_up_to']),
        sentReceiptUpTo: _watermarksFromJson(j['sent_receipt_up_to']),
      );

  final String groupId;

  @override
  String get id => groupId;

  /// True while this account has been added but has not accepted yet.
  ///
  /// The counterpart to a one-to-one conversation's `pendingApproval`, and for
  /// the same reason: being added to a group discloses your address to every
  /// member, so that disclosure waits for a decision rather than arriving with
  /// one already made.
  bool invitePending;

  /// How far each member has confirmed receiving and reading MY messages.
  ///
  /// A map rather than the single watermark a one-to-one conversation keeps,
  /// because "read by 12" is a count over members. Needs nothing new on the
  /// wire: a `v: 2` receipt already names a message id, and the envelope
  /// already says who sent it, so the author resolves both locally.
  final Map<String, DateTime> memberDeliveredUpTo;
  final Map<String, DateTime> memberReadUpTo;

  /// How far I have already told each author I have read theirs -- purely
  /// local bookkeeping, so an identical receipt is not re-sent on every
  /// redraw. Keyed by author, since in a group a receipt goes to the person
  /// who wrote the message rather than to "the peer".
  final Map<String, DateTime> sentReceiptUpTo;

  /// How many of [message]'s recipients have confirmed receiving, and reading,
  /// it -- counted from the watermarks above against the message's own send
  /// stamp, so one marker per member answers for every message they have caught
  /// up with.
  ///
  /// Counted over the message's own delivery list rather than the current
  /// membership: what "3 of 5" means is "the five this copy was owed to", and
  /// somebody who joined afterwards was never owed one.
  int deliveredCountFor(StoredMessage message) =>
      _countAtLeast(message, memberDeliveredUpTo);

  int readCountFor(StoredMessage message) =>
      _countAtLeast(message, memberReadUpTo);

  int _countAtLeast(StoredMessage message, Map<String, DateTime> watermarks) {
    final anchor = message.receiptAnchor;
    var count = 0;
    for (final delivery in message.deliveries) {
      final mark = watermarks[delivery.accountId];
      if (mark != null && !mark.isBefore(anchor)) count++;
    }
    return count;
  }

  /// Records a member's confirmation, monotonically: an out-of-order or
  /// duplicate older receipt never regresses an already-newer status. Returns
  /// true if anything actually moved, so a caller can avoid a needless save.
  bool recordMemberReceipt({
    required String accountId,
    required ReceiptStatus status,
    required DateTime upTo,
  }) {
    final watermarks = status == ReceiptStatus.read
        ? memberReadUpTo
        : memberDeliveredUpTo;
    final current = watermarks[accountId];
    if (current != null && !upTo.isAfter(current)) return false;
    watermarks[accountId] = upTo;
    return true;
  }

  /// The group's name if it has one, otherwise a short form of its id.
  ///
  /// [localServer] is unused: a group has no server. It stays in the signature
  /// because a chat list renders groups and one-to-one chats through the same
  /// [ChatTarget] call.
  @override
  String titleFor(String localServer) =>
      displayName?.isNotEmpty == true ? displayName! : 'Group $shortGroupId';

  /// The first five characters of the id -- the version marker plus four
  /// characters of real entropy, the same grouping an account id is displayed
  /// in (see freizone-server's docs/PROTOCOL.md §1).
  String get shortGroupId =>
      groupId.length > 5 ? groupId.substring(0, 5) : groupId;

  /// A group's chat-list preview names the author, since "who said this" is
  /// not answered by the conversation itself the way it is in a one-to-one
  /// chat. Falls back to the plain preview for our own messages and for
  /// history written before authors were recorded.
  @override
  String get lastMessagePreview {
    final base = super.lastMessagePreview;
    if (messages.isEmpty || base.isEmpty) return base;
    final last = messages.last;
    if (last.mine || last.kind != StoredMessageKind.normal) return base;
    final author = last.senderAccountId;
    if (author == null) return base;
    return '${author.substring(0, author.length > 5 ? 5 : author.length)}: $base';
  }

  Map<String, dynamic> toJson() {
    final j = <String, dynamic>{'group_id': groupId};
    writeBaseJson(j);
    if (invitePending) j['invite_pending'] = true;
    _writeWatermarks(j, 'member_delivered_up_to', memberDeliveredUpTo);
    _writeWatermarks(j, 'member_read_up_to', memberReadUpTo);
    _writeWatermarks(j, 'sent_receipt_up_to', sentReceiptUpTo);
    return j;
  }
}

Map<String, DateTime> _watermarksFromJson(dynamic raw) {
  if (raw is! Map) return {};
  final out = <String, DateTime>{};
  raw.forEach((key, value) {
    if (key is String && value is String) out[key] = decodeTime(value);
  });
  return out;
}

void _writeWatermarks(
  Map<String, dynamic> j,
  String key,
  Map<String, DateTime> marks,
) {
  if (marks.isEmpty) return;
  j[key] = marks.map((k, v) => MapEntry(k, encodeTime(v)));
}
