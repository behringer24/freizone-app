// What the shared core hands the UI (SRV-23 stage 6).
//
// Deliberately thin: these carry what a widget draws and nothing it would have
// to interpret. Two absences are on purpose and worth naming, because both
// look like omissions.
//
// An attachment has no key and no bytes. The key is the one secret in a message
// the shell has no use for -- a picture is fetched by asking the core for its
// path, and the core does the opening. Carrying the key would put it in every
// widget's reach for no gain.
//
// A peer chat has no display name. That comes from the local address book,
// which is the shell's own and something the core has no part in: it knows
// account ids, and who somebody *is* to this user is not a protocol fact.
import 'dart:convert';

/// One row of the chat list. Peers and groups share a shape, because the list
/// shows them in one list ordered by one clock.
class ChatSummary {
  const ChatSummary({
    required this.chatId,
    required this.isGroup,
    this.title = '',
    this.topic = '',
    this.peerServer = '',
    this.lastActivityAt,
    this.hasUnread = false,
    this.preview = '',
    this.previewMine = false,
    this.previewSender = '',
    this.blocked = false,
    this.pendingApproval = false,
    this.members = 0,
    this.invited = false,
    this.dissolved = false,
    this.pinnedMessageIds = const [],
    this.peerDeliveredUpTo,
    this.peerReadUpTo,
  });

  factory ChatSummary.fromJson(Map<String, dynamic> j) => ChatSummary(
    chatId: j['chat_id'] as String,
    isGroup: j['group'] as bool? ?? false,
    title: j['title'] as String? ?? '',
    topic: j['topic'] as String? ?? '',
    peerServer: j['peer_server'] as String? ?? '',
    lastActivityAt: _time(j['last_activity_at']),
    hasUnread: j['has_unread'] as bool? ?? false,
    preview: j['preview'] as String? ?? '',
    previewMine: j['preview_mine'] as bool? ?? false,
    previewSender: j['preview_sender'] as String? ?? '',
    blocked: j['blocked'] as bool? ?? false,
    pendingApproval: j['pending_approval'] as bool? ?? false,
    members: j['members'] as int? ?? 0,
    invited: j['invited'] as bool? ?? false,
    dissolved: j['dissolved'] as bool? ?? false,
    pinnedMessageIds: ((j['pinned_message_ids'] as List<dynamic>?) ?? const [])
        .cast<String>(),
    peerDeliveredUpTo: _time(j['peer_delivered_up_to']),
    peerReadUpTo: _time(j['peer_read_up_to']),
  );

  final String chatId;
  final bool isGroup;

  /// The group's name. Empty for a peer -- see the note at the top of the file.
  final String title;
  final String topic;
  final String peerServer;

  final DateTime? lastActivityAt;
  final bool hasUnread;

  /// The last line, carried so a list does not read a transcript per row.
  final String preview;
  final bool previewMine;
  final String previewSender;

  final bool blocked;
  final bool pendingApproval;

  /// Members counts only those who accepted, which is what a header shows.
  final int members;

  /// An invitation to this account that has not been answered. Nothing arrives
  /// in the group until it is, so a list has to show it differently.
  final bool invited;

  final bool dissolved;

  /// Carried on the summary because the transcript has already been read for
  /// the preview, so answering costs nothing extra.
  final List<String> pinnedMessageIds;

  /// How far the peer has got with our messages, for the ticks. One-to-one
  /// only: a group keeps one per member, and those come with the membership.
  final DateTime? peerDeliveredUpTo;
  final DateTime? peerReadUpTo;
}

/// One transcript line.
class CoreMessage {
  const CoreMessage({
    required this.id,
    required this.text,
    required this.mine,
    required this.timestamp,
    required this.kind,
    required this.sendState,
    this.senderSentAt,
    this.senderAccountId = '',
    this.replyToId = '',
    this.replyPreviewText = '',
    this.replyPreviewMine,
    this.replyPreviewAuthorId = '',
    this.attachments = const [],
    this.deliveries = const [],
  });

  factory CoreMessage.fromJson(Map<String, dynamic> j) => CoreMessage(
    id: j['id'] as String,
    text: j['text'] as String? ?? '',
    mine: j['mine'] as bool? ?? false,
    timestamp: _time(j['timestamp']) ?? DateTime.now().toUtc(),
    senderSentAt: _time(j['sender_sent_at']),
    senderAccountId: j['sender_account_id'] as String? ?? '',
    replyToId: j['reply_to_id'] as String? ?? '',
    replyPreviewText: j['reply_preview_text'] as String? ?? '',
    replyPreviewMine: j['reply_preview_mine'] as bool?,
    replyPreviewAuthorId: j['reply_preview_author_id'] as String? ?? '',
    kind: j['kind'] as String? ?? 'normal',
    sendState: j['send_state'] as String? ?? 'sent',
    attachments: ((j['attachments'] as List<dynamic>?) ?? const [])
        .map((a) => CoreAttachment.fromJson(a as Map<String, dynamic>))
        .toList(growable: false),
    deliveries: ((j['deliveries'] as List<dynamic>?) ?? const [])
        .map((d) => CoreDelivery.fromJson(d as Map<String, dynamic>))
        .toList(growable: false),
  );

  final String id;
  final String text;
  final bool mine;

  /// When this device recorded the line. [senderSentAt] is the sender's own
  /// clock from inside the envelope, which is what a receipt is anchored to --
  /// absent for our own lines and for senders predating the field.
  final DateTime timestamp;
  final DateTime? senderSentAt;

  /// Empty in a one-to-one chat, where the chat answers who wrote this. A group
  /// transcript needs it on every line.
  final String senderAccountId;

  final String replyToId;
  final String replyPreviewText;
  final bool? replyPreviewMine;
  final String replyPreviewAuthorId;

  /// "normal" or "system_info" -- the latter is a local, never-transmitted line
  /// rendered centred, like "Secure session was reset".
  final String kind;

  /// "pending", "sent" or "failed".
  final String sendState;

  final List<CoreAttachment> attachments;

  /// One entry per recipient, for a group message. A partial failure shows as
  /// exactly that rather than as one state for the whole message.
  final List<CoreDelivery> deliveries;

  bool get isSystem => kind == 'system_info';
  bool get hasFailed => sendState == 'failed';
  bool get isPending => sendState == 'pending';
}

class CoreAttachment {
  const CoreAttachment({
    required this.kind,
    required this.blobId,
    this.mimeType = '',
    this.byteSize = 0,
    this.width = 0,
    this.height = 0,
    this.pending = false,
  });

  factory CoreAttachment.fromJson(Map<String, dynamic> j) => CoreAttachment(
    kind: j['kind'] as String? ?? 'image',
    blobId: j['blob_id'] as String? ?? '',
    mimeType: j['mime_type'] as String? ?? '',
    byteSize: j['byte_size'] as int? ?? 0,
    width: j['width'] as int? ?? 0,
    height: j['height'] as int? ?? 0,
    pending: j['pending'] as bool? ?? false,
  );

  final String kind;
  final String blobId;
  final String mimeType;
  final int byteSize;

  /// Reserved by a bubble before the download finishes, so the transcript does
  /// not jump as pictures land.
  final int width;
  final int height;

  /// The upload has not finished, so there is a local preview and nothing to
  /// fetch: a spinner, not a broken picture.
  final bool pending;
}

class CoreDelivery {
  const CoreDelivery({
    required this.accountId,
    required this.state,
    this.error = '',
    this.detail = '',
    this.attachmentSkipped = false,
  });

  factory CoreDelivery.fromJson(Map<String, dynamic> j) => CoreDelivery(
    accountId: j['account_id'] as String,
    state: j['state'] as String? ?? 'sent',
    error: j['error'] as String? ?? '',
    detail: j['detail'] as String? ?? '',
    attachmentSkipped: j['attachment_skipped'] as bool? ?? false,
  );

  final String accountId;
  final String state;

  /// Why this copy failed, in words for the person who sent it. Empty for one
  /// that did not fail -- "not delivered" on its own is not something a reader
  /// can do anything about.
  final String error;

  /// The same failure in the words of whatever refused it: endpoint, status,
  /// syscall. Goes to the log and never on screen.
  final String detail;

  /// They got the caption but not the picture: their server would not take it.
  /// Not a delivery failure, and no retry can mend it.
  final bool attachmentSkipped;
}

/// A group's membership and roles.
class GroupInfo {
  const GroupInfo({
    required this.groupId,
    this.name = '',
    this.topic = '',
    this.founder = '',
    this.dissolved = false,
    this.stateHash = '',
    this.myRole = 'none',
    this.members = const [],
  });

  factory GroupInfo.fromJson(Map<String, dynamic> j) => GroupInfo(
    groupId: j['group_id'] as String,
    name: j['name'] as String? ?? '',
    topic: j['topic'] as String? ?? '',
    founder: j['founder'] as String? ?? '',
    dissolved: j['dissolved'] as bool? ?? false,
    stateHash: j['state_hash'] as String? ?? '',
    myRole: j['my_role'] as String? ?? 'none',
    members: ((j['members'] as List<dynamic>?) ?? const [])
        .map((m) => GroupMemberInfo.fromJson(m as Map<String, dynamic>))
        .toList(growable: false),
  );

  final String groupId;
  final String name;
  final String topic;
  final String founder;
  final bool dissolved;

  /// The fold over the fact set, for diagnostics -- two members holding the
  /// same facts compute the same hash.
  final String stateHash;

  /// "none", "member", "moderator", "admin" or "founder".
  final String myRole;
  final List<GroupMemberInfo> members;
}

class GroupMemberInfo {
  const GroupMemberInfo({
    required this.accountId,
    required this.role,
    this.server = '',
    this.joined = false,
    this.deliveredUpTo,
    this.readUpTo,
  });

  factory GroupMemberInfo.fromJson(Map<String, dynamic> j) => GroupMemberInfo(
    accountId: j['account_id'] as String,
    role: j['role'] as String? ?? 'member',
    server: j['server'] as String? ?? '',
    joined: j['joined'] as bool? ?? false,
    deliveredUpTo: _time(j['delivered_up_to']),
    readUpTo: _time(j['read_up_to']),
  );

  final String accountId;
  final String role;
  final String server;

  /// False for somebody invited who has not accepted. They are shown, so a
  /// moderator can see the invitation is outstanding, but nothing is sent to
  /// them: being added must not disclose their address to the group before
  /// they agree to it.
  final bool joined;

  /// How far this member has confirmed receiving, and reading, *our* messages.
  /// Per member and never shared onward -- who has read what stays between
  /// reader and author.
  final DateTime? deliveredUpTo;
  final DateTime? readUpTo;
}

/// What one round of housekeeping managed.
class MaintenanceReport {
  const MaintenanceReport({
    this.prekeysToppedUp = false,
    this.debtsPaid = 0,
    this.recovered = const [],
    this.problems = const [],
  });

  factory MaintenanceReport.fromJson(
    Map<String, dynamic> j,
  ) => MaintenanceReport(
    prekeysToppedUp: j['prekeys_topped_up'] as bool? ?? false,
    debtsPaid: j['debts_paid'] as int? ?? 0,
    recovered: ((j['recovered'] as List<dynamic>?) ?? const []).cast<String>(),
    problems: ((j['problems'] as List<dynamic>?) ?? const []).cast<String>(),
  );

  final bool prekeysToppedUp;
  final int debtsPaid;

  /// Peers whose session was re-established.
  final List<String> recovered;

  /// What did not work, as text. Housekeeping is best-effort by nature -- one
  /// failing part must not stop the others -- so these are reported rather than
  /// thrown, and a caller logs them rather than showing them.
  final List<String> problems;

  bool get clean => problems.isEmpty;

  @override
  String toString() => jsonEncode({
    'prekeys_topped_up': prekeysToppedUp,
    'debts_paid': debtsPaid,
    'recovered': recovered.length,
    'problems': problems,
  });
}

DateTime? _time(dynamic raw) {
  if (raw is! String || raw.isEmpty) return null;
  return DateTime.tryParse(raw)?.toUtc();
}
