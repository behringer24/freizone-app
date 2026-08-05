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
import '../util/person_label.dart';
import 'chat_target.dart';
import 'contact_store.dart';
import 'receipt_signal.dart';

/// How far one member's copy of a group message has got, from the two things
/// that can be known about it: whether their server took it, and whether they
/// themselves confirmed it.
///
/// Declared **worst first**, and the order is used: the delivery sheet sorts by
/// it, so the members something can still be done about are at the top.
enum GroupDeliveryStage {
  /// Their server refused the copy, or could not be reached. The only stage a
  /// retry addresses.
  failed,

  /// Still in flight.
  sending,

  /// Their server took it, and they have not confirmed anything yet. Not the
  /// same as "received": a queued copy sits on their server until their device
  /// next connects.
  sent,

  received,
  read,
}

/// One group conversation: the locally persisted transcript, plus the receipt
/// bookkeeping that a group needs per member rather than per chat.
class GroupConversation extends ChatTarget {
  GroupConversation({
    required this.groupId,
    this.displayName,
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

  /// The name the **group gave itself**, refreshed from the folded fact set
  /// every time that changes (see AppSession's \_refreshGroupName).
  ///
  /// This is the one meaning of "display name" that stayed on a transcript when
  /// the rest moved to the contact store (APP-19). A group is not a contact:
  /// nobody assigned this name locally, every member sees the same one, and it
  /// arrives as a signed fact rather than as a label somebody chose privately.
  String? displayName;

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
      if (_reached(watermarks, delivery.accountId, anchor)) count++;
    }
    return count;
  }

  static bool _reached(
    Map<String, DateTime> watermarks,
    String accountId,
    DateTime anchor,
  ) {
    final mark = watermarks[accountId];
    return mark != null && !mark.isBefore(anchor);
  }

  /// How far one recipient's copy of [message] has actually got -- what the
  /// delivery sheet lists per member, and the reason the counts above are not
  /// the whole story.
  ///
  /// Two independent sources meet here: [GroupDelivery.state] is what that
  /// recipient's *server* did with our copy, and the watermarks are what the
  /// recipient themselves confirmed. A copy the server took can still be
  /// unconfirmed, and a copy that failed can never be confirmed -- so the
  /// server's answer is consulted first and only "sent" leaves anything for
  /// the receipts to add.
  GroupDeliveryStage stageFor(StoredMessage message, GroupDelivery delivery) {
    switch (delivery.state) {
      case MessageSendState.failed:
        return GroupDeliveryStage.failed;
      case MessageSendState.pending:
        return GroupDeliveryStage.sending;
      case MessageSendState.sent:
        break;
    }
    final anchor = message.receiptAnchor;
    // Read implies received, so it is tested first -- a member whose read
    // receipt arrived while their delivered one was lost is read, not pending.
    if (_reached(memberReadUpTo, delivery.accountId, anchor)) {
      return GroupDeliveryStage.read;
    }
    if (_reached(memberDeliveredUpTo, delivery.accountId, anchor)) {
      return GroupDeliveryStage.received;
    }
    return GroupDeliveryStage.sent;
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
  /// [localServer] and [contacts] are both unused: a group has no server, and
  /// its name is its own rather than a contact's. They stay in the signature
  /// because a chat list renders groups and one-to-one chats through the same
  /// [ChatTarget] call.
  @override
  String titleFor(String localServer, ContactStore contacts) =>
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
  ///
  /// The name this device has given them where there is one (APP-18), and the
  /// *compact* label: a row that already truncates cannot spend a third of its
  /// width on the short id in parentheses.
  @override
  String previewFor(ContactStore contacts) {
    final base = super.previewFor(contacts);
    if (messages.isEmpty || base.isEmpty) return base;
    final last = messages.last;
    if (last.mine || last.kind != StoredMessageKind.normal) return base;
    final author = last.senderAccountId;
    if (author == null) return base;
    return '${personLabelCompact(contacts, author)}: $base';
  }

  Map<String, dynamic> toJson() {
    final j = <String, dynamic>{'group_id': groupId};
    writeBaseJson(j);
    // Written here now that ChatTarget no longer does it for everybody: the key
    // is unchanged, so existing group transcripts read back exactly as before.
    if (displayName != null) j['display_name'] = displayName;
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
