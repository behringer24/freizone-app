// The structure of a message's plaintext -- the bytes that actually go
// through Session.encrypt/decrypt (see AppSession.sendMessage /
// _handleIncoming). Until now that was just the raw chat text; this
// versioned JSON envelope adds a stable per-message id (needed so a
// later message can reference this one, e.g. a reply) and a reply
// reference, while staying forward-compatible with both older
// (pre-this-feature, bare-string) and newer (future "v" values this
// build doesn't understand yet) plaintexts from other devices.
//
// "attachments" is reserved, always empty for now -- deliberately
// modeled as a list from day one (rather than a single content "type")
// so a future message can carry text plus one or more images/videos/
// audio clips without a second breaking format change.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// A fresh random message id -- used both for newly composed messages and
/// to backfill one, purely locally, for a message that predates this id
/// (legacy local history, or an incoming legacy/unknown-version
/// plaintext) so it can still be deleted or pinned like any other.
String generateMessageId() {
  final rnd = Random.secure();
  final buf = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buf.write(rnd.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}

/// A snapshot of the quoted message's content, carried inside the reply
/// itself (not just its id) -- so the quote still renders even if the
/// original was deleted locally (on either side) or never seen by this
/// device, the same approach Signal/WhatsApp use.
///
/// [mine] is always relative to whoever is currently storing/rendering
/// this preview locally -- i.e. already corrected for perspective. The
/// sender flips the "did I write the quoted message" bit before it goes
/// on the wire (see AppSession.sendMessage), so decoding it here never
/// needs a second inversion.
class ReplyPreview {
  const ReplyPreview({required this.text, required this.mine});

  final String text;
  final bool mine;

  factory ReplyPreview.fromJson(Map<String, dynamic> j) =>
      ReplyPreview(text: j['text'] as String? ?? '', mine: j['mine'] as bool? ?? false);

  Map<String, dynamic> toJson() => {'text': text, 'mine': mine};
}

/// A decoded (or about-to-be-encoded) message plaintext.
class MessageContent {
  const MessageContent({
    required this.id,
    required this.text,
    this.replyToId,
    this.replyPreview,
    this.senderServer,
  });

  final String id;
  final String text;
  final String? replyToId;
  final ReplyPreview? replyPreview;

  /// The sender's own home server, if they're sending cross-server --
  /// null for an ordinary same-server message. This is how a recipient
  /// learns where to reach the sender for a reply, since nothing else
  /// ties an account to a particular hostname (see docs/PROTOCOL.md §9)
  /// -- deliberately carried here, inside the encrypted content, rather
  /// than as delivery-layer metadata the server would ever see. Sent on
  /// *every* cross-server message, not just the first, so a recipient's
  /// knowledge of it self-heals if local state is ever lost.
  final String? senderServer;

  static const currentVersion = 1;

  Uint8List encode() {
    final json = <String, dynamic>{
      'v': currentVersion,
      'id': id,
      'text': text,
      'attachments': const [],
      if (replyToId != null) 'reply_to': replyToId,
      if (replyPreview != null) 'reply_preview': replyPreview!.toJson(),
      if (senderServer != null) 'sender_server': senderServer,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  /// Decodes decrypted plaintext bytes. Falls back to treating the whole
  /// decoded text as a legacy ("version 0", pre-this-feature) message body
  /// -- with no reply info, and [fallbackId] as its id -- whenever the
  /// bytes aren't a recognized envelope: not JSON at all, JSON but not an
  /// object (or one without a "v" this build understands), or an object
  /// whose "v" is newer than [currentVersion]. This is deliberately
  /// conservative: a message can only be parsed as the new envelope if it
  /// unambiguously declares the version this code knows how to read.
  factory MessageContent.decode(Uint8List bytes, {required String fallbackId}) {
    final raw = utf8.decode(bytes);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final v = decoded['v'];
        if (v == currentVersion) {
          final replyPreviewJson = decoded['reply_preview'];
          return MessageContent(
            id: decoded['id'] as String? ?? fallbackId,
            text: decoded['text'] as String? ?? '',
            replyToId: decoded['reply_to'] as String?,
            replyPreview: replyPreviewJson == null
                ? null
                : ReplyPreview.fromJson(replyPreviewJson as Map<String, dynamic>),
            senderServer: decoded['sender_server'] as String?,
          );
        }
        if (v is int && v > currentVersion) {
          return MessageContent(
            id: decoded['id'] as String? ?? fallbackId,
            text: 'This message uses a newer app feature and can\'t be shown here yet.',
          );
        }
      }
    } catch (_) {
      // Not JSON (or not shaped as expected) -- legacy plaintext below.
    }
    return MessageContent(id: fallbackId, text: raw);
  }
}
