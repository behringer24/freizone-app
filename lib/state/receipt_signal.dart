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
  const ReceiptSignal({required this.status, required this.upToSentAt});

  final ReceiptStatus status;

  /// Everything the sender sent at or before this instant is confirmed
  /// delivered/read -- always compared in UTC.
  final DateTime upToSentAt;

  static const _version = 2;

  Uint8List encode() {
    final json = <String, dynamic>{
      'v': _version,
      'kind': 'receipt',
      'status': status.name,
      'up_to_sent_at': upToSentAt.toUtc().toIso8601String(),
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
      return ReceiptSignal(status: status, upToSentAt: upToSentAt.toUtc());
    } catch (_) {
      return null;
    }
  }
}
