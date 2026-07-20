// A conversation's display/history model -- the UI-facing layer on top
// of the crypto layer (AppState.sessions, a ratchet.Session's own JSON
// form). Kept deliberately separate: this is what the chat list and
// chat screen render, the ratchet session is what the Go core consumes.
import 'dart:typed_data';

import '../ffi/models.dart';
import '../util/freizone_address.dart';
import 'message_content.dart';

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
    this.replyToId,
    this.replyPreviewText,
    this.replyPreviewMine,
  }) : id = id ?? generateMessageId();

  factory StoredMessage.fromJson(Map<String, dynamic> j) => StoredMessage(
    id: j['id'] as String? ?? generateMessageId(),
    text: j['text'] as String,
    mine: j['mine'] as bool,
    timestamp: decodeTime(j['timestamp'] as String),
    replyToId: j['reply_to_id'] as String?,
    replyPreviewText: j['reply_preview_text'] as String?,
    replyPreviewMine: j['reply_preview_mine'] as bool?,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'mine': mine,
    'timestamp': encodeTime(timestamp),
    if (replyToId != null) 'reply_to_id': replyToId,
    if (replyPreviewText != null) 'reply_preview_text': replyPreviewText,
    if (replyPreviewMine != null) 'reply_preview_mine': replyPreviewMine,
  };

  final String id;
  final String text;
  final bool mine;
  final DateTime timestamp;

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

  /// The alias if one is set, otherwise the peer's compact
  /// "shortid*domain" address -- which server they're actually on is
  /// worth always keeping visible (especially once federation means
  /// that isn't always this session's own server), more so than the
  /// full checksummed id. [localServer] fills in for [peerServer] ==
  /// null (this peer is on the same server as us).
  String titleFor(String localServer) =>
      displayName ??
      shortFreizoneAddress(id: peerAccountId, server: peerServer ?? localServer);

  String get lastMessagePreview => messages.isEmpty ? '' : messages.last.text;

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
    'messages': messages.map((m) => m.toJson()).toList(),
    'last_activity_at': encodeTime(lastActivityAt),
    'has_unread': hasUnread,
    if (pinnedMessageIds.isNotEmpty) 'pinned_message_ids': pinnedMessageIds,
    if (blocked) 'blocked': blocked,
  };
}
