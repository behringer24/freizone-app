// A delivery/read receipt -- a tiny control envelope sent back over the
// exact same encrypted send/receive pipeline as a real chat message
// (AppSession.sendMessage / processIncomingMessage), but never shown as
// one and never stored as a StoredMessage. One marker per conversation
// ("everything up to this timestamp"), not one receipt per message.
//
// Deliberately its own "v": 2 envelope, not a field bolted onto
// MessageContent's "v": 1 shape: MessageContent.currentVersion stays 1
// forever (ordinary text messages never change format), so a receipt is
// the only thing that ever appears as "v": 2. An app that predates
// receipts sees an unrecognized-but-newer version and falls into
// MessageContent.decode's existing ">currentVersion" placeholder path
// (message_content.dart:119-124) automatically -- no compatibility code
// needed for that side.
import 'dart:convert';
import 'dart:typed_data';

enum ReceiptStatus { delivered, read }

class ReceiptSignal {
  const ReceiptSignal({
    required this.status,
    required this.upToSentAt,
    this.groupId,
  });

  final ReceiptStatus status;

  /// Everything the sender sent at or before this instant is confirmed
  /// delivered/read -- always compared in UTC.
  final DateTime upToSentAt;

  /// The group this receipt is about, or null for a one-to-one conversation.
  ///
  /// A group receipt goes **only to the member who wrote the message**, not to
  /// the group: reading is between the reader and the author, and fanning it out
  /// would tell everyone else who has read what -- a running attendance list
  /// nobody asked for, at N times the traffic. Which is also why this needs to
  /// be on the wire at all: the envelope says who sent the receipt, but only
  /// this says which of that member's transcripts the watermark belongs to.
  ///
  /// Added to the existing `v: 2` shape rather than given a version of its own.
  /// A build that predates it reads the receipt as a one-to-one one and moves
  /// that conversation's watermark a little early -- a tick appearing sooner
  /// than it should, which is the mildest of the options. A new `v` would land
  /// in MessageContent.decode's "newer app feature" path and leave a visible
  /// placeholder message in their transcript instead.
  final String? groupId;

  static const _version = 2;

  Uint8List encode() {
    final json = <String, dynamic>{
      'v': _version,
      'kind': 'receipt',
      'status': status.name,
      'up_to_sent_at': upToSentAt.toUtc().toIso8601String(),
      if (groupId != null) 'group_id': groupId,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  /// Returns null for anything that isn't a well-formed receipt envelope
  /// -- an ordinary chat message, garbage, or a future/unrecognized
  /// shape -- so the caller falls back to MessageContent.decode.
  static ReceiptSignal? tryDecode(Uint8List bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['v'] != _version || decoded['kind'] != 'receipt') {
        return null;
      }
      ReceiptStatus? status;
      for (final s in ReceiptStatus.values) {
        if (s.name == decoded['status']) status = s;
      }
      final upToSentAt = DateTime.tryParse(
        decoded['up_to_sent_at'] as String? ?? '',
      );
      if (status == null || upToSentAt == null) return null;
      final groupId = decoded['group_id'] as String?;
      return ReceiptSignal(
        status: status,
        upToSentAt: upToSentAt.toUtc(),
        groupId: groupId != null && groupId.isNotEmpty ? groupId : null,
      );
    } catch (_) {
      return null;
    }
  }
}
