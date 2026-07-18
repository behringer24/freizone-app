// A conversation's display/history model -- the UI-facing layer on top
// of the crypto layer (AppState.sessions, a ratchet.Session's own JSON
// form). Kept deliberately separate: this is what the chat list and
// chat screen render, the ratchet session is what the Go core consumes.
import 'dart:typed_data';

import '../ffi/models.dart';
import '../util/address_format.dart';

/// One decrypted (or about-to-be-sent) chat line, persisted locally --
/// the server never stores plaintext or keeps history.
class StoredMessage {
  StoredMessage({required this.text, required this.mine, required this.timestamp});

  factory StoredMessage.fromJson(Map<String, dynamic> j) => StoredMessage(
        text: j['text'] as String,
        mine: j['mine'] as bool,
        timestamp: decodeTime(j['timestamp'] as String),
      );

  Map<String, dynamic> toJson() => {
        'text': text,
        'mine': mine,
        'timestamp': encodeTime(timestamp),
      };

  final String text;
  final bool mine;
  final DateTime timestamp;
}

/// One peer conversation: who they are (resolved once, cached), and the
/// locally persisted message history with them.
class Conversation {
  Conversation({
    required this.peerAccountId,
    this.displayName,
    this.peerDeviceId,
    this.peerDevicePubKey,
    List<StoredMessage>? messages,
    DateTime? lastActivityAt,
    this.hasUnread = false,
  })  : messages = messages ?? [],
        lastActivityAt = lastActivityAt ?? DateTime.now().toUtc();

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
        peerAccountId: j['peer_account_id'] as String,
        displayName: j['display_name'] as String?,
        peerDeviceId: j['peer_device_id'] as String?,
        peerDevicePubKey:
            j['peer_device_pub_key'] == null ? null : decodeB64(j['peer_device_pub_key'] as String),
        messages: (j['messages'] as List<dynamic>?)
            ?.map((m) => StoredMessage.fromJson(m as Map<String, dynamic>))
            .toList(),
        lastActivityAt: decodeTime(j['last_activity_at'] as String),
        hasUnread: j['has_unread'] as bool? ?? false,
      );

  final String peerAccountId;
  String? displayName;
  String? peerDeviceId;
  Uint8List? peerDevicePubKey;
  List<StoredMessage> messages;
  DateTime lastActivityAt;

  /// True once an incoming message has arrived while this conversation's
  /// ChatScreen wasn't the one open -- cleared when it's opened. Drives
  /// the unread dot in the chat list and the account switcher.
  bool hasUnread;

  /// The alias if one is set, otherwise the id in its readable,
  /// dash-grouped form (docs/PROTOCOL.md's cosmetic display format).
  String get title => displayName ?? formatAccountIdForDisplay(peerAccountId);

  String get lastMessagePreview => messages.isEmpty ? '' : messages.last.text;

  Map<String, dynamic> toJson() => {
        'peer_account_id': peerAccountId,
        if (displayName != null) 'display_name': displayName,
        if (peerDeviceId != null) 'peer_device_id': peerDeviceId,
        if (peerDevicePubKey != null) 'peer_device_pub_key': encodeB64(peerDevicePubKey!),
        'messages': messages.map((m) => m.toJson()).toList(),
        'last_activity_at': encodeTime(lastActivityAt),
        'has_unread': hasUnread,
      };
}
