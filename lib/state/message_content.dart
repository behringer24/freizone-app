// The structure of a message's plaintext -- the bytes that actually go
// through Session.encrypt/decrypt (see AppSession.sendMessage /
// _handleIncoming). Until now that was just the raw chat text; this
// versioned JSON envelope adds a stable per-message id (needed so a
// later message can reference this one, e.g. a reply) and a reply
// reference, while staying forward-compatible with both older
// (pre-this-feature, bare-string) and newer (future "v" values this
// build doesn't understand yet) plaintexts from other devices.
//
// "attachments" was carried as a reserved, always-empty field from the day
// this envelope was introduced, and APP-04 filled it without needing a
// format change -- builds predating pictures ignore the entries and still
// render the caption. Modeled as a list from day one (rather than a single
// content "type") so a message can carry text plus one or more images and,
// later, videos/audio clips without a second breaking change. Only one
// attachment is actually rendered today; see docs/PROTOCOL.md §10 in
// freizone-server for the wire contract.
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

/// The largest inline preview thumbnail an attachment may carry, in bytes.
///
/// The thumbnail rides inside the message itself so a picture shows
/// *something* the instant it arrives, before the real file has been
/// downloaded. That only works if it stays tiny -- a message is a small,
/// queued object, and the whole reason attachments went out of band is that
/// payloads must not grow. Enforced when encoding AND when decoding, so a
/// peer (buggy or hostile) cannot inflate our message store either.
const int maxAttachmentThumbBytes = 2 * 1024;

/// One attachment referenced by a message: where to fetch its ciphertext and
/// how to decrypt it, plus just enough metadata to render it well.
///
/// The bytes themselves live on the recipient's server as a blob (SRV-07,
/// see docs/PROTOCOL.md §10) -- this travels inside the message's *encrypted*
/// plaintext, so the key never reaches the server that stores the blob.
///
/// There is deliberately no `server` field: a blob always lives on the
/// recipient's own server, so the fetching client already knows where to
/// look. And no filename -- it would leak device paths and camera details
/// for no benefit.
class MessageAttachment {
  const MessageAttachment({
    required this.kind,
    required this.blobId,
    required this.key,
    required this.mimeType,
    required this.byteSize,
    required this.width,
    required this.height,
    this.algorithm = defaultAlgorithm,
    this.thumb,
  });

  static const defaultAlgorithm = 'aes-256-gcm';

  /// What this attachment is -- "image" today. An unknown kind must render
  /// as an unsupported placeholder rather than break the message, which is
  /// what lets video/audio be added later without a format change.
  final String kind;

  /// How the blob is encrypted. A string, so switching ciphers stays
  /// additive rather than a breaking change.
  final String algorithm;

  final String blobId;

  /// The symmetric key for this one blob -- freshly generated per
  /// attachment, NOT derived from the ratchet, so re-downloading still works
  /// after a secure-session reset (which discards ratchet state).
  final Uint8List key;

  final String mimeType;
  final int byteSize;

  /// Pixel dimensions, so the bubble can reserve the right aspect ratio
  /// before the image has downloaded -- without them the transcript reflows
  /// and jumps as pictures arrive.
  final int width;
  final int height;

  /// A tiny JPEG (at most [maxAttachmentThumbBytes]) shown blurred while the
  /// real file downloads. Null if the sender didn't include one.
  final Uint8List? thumb;

  bool get isImage => kind == 'image';

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'alg': algorithm,
    'blob_id': blobId,
    'key': base64Encode(key),
    'mime': mimeType,
    'size': byteSize,
    'w': width,
    'h': height,
    if (thumb != null && thumb!.length <= maxAttachmentThumbBytes)
      'thumb': base64Encode(thumb!),
  };

  /// Parses one attachment entry, returning null if it is unusable (missing
  /// the blob reference or key). A malformed entry is dropped rather than
  /// failing the whole message -- the text still deserves to arrive.
  static MessageAttachment? fromJson(Map<String, dynamic> j) {
    final blobId = j['blob_id'] as String?;
    final keyB64 = j['key'] as String?;
    if (blobId == null || blobId.isEmpty || keyB64 == null) return null;

    Uint8List? decode(String? b64) {
      if (b64 == null) return null;
      try {
        return base64Decode(b64);
      } catch (_) {
        return null;
      }
    }

    final key = decode(keyB64);
    if (key == null) return null;

    // Oversized thumbnails are dropped, not trusted: the cap has to hold on
    // the receiving side too, or a peer could bloat our stored history.
    var thumb = decode(j['thumb'] as String?);
    if (thumb != null && thumb.length > maxAttachmentThumbBytes) thumb = null;

    return MessageAttachment(
      kind: j['kind'] as String? ?? 'image',
      algorithm: j['alg'] as String? ?? defaultAlgorithm,
      blobId: blobId,
      key: key,
      mimeType: j['mime'] as String? ?? 'application/octet-stream',
      byteSize: (j['size'] as num?)?.toInt() ?? 0,
      width: (j['w'] as num?)?.toInt() ?? 0,
      height: (j['h'] as num?)?.toInt() ?? 0,
      thumb: thumb,
    );
  }
}

/// A decoded (or about-to-be-encoded) message plaintext.
class MessageContent {
  const MessageContent({
    required this.id,
    required this.text,
    this.replyToId,
    this.replyPreview,
    this.senderServer,
    this.sentAt,
    this.attachments = const [],
  });

  final String id;
  final String text;
  final String? replyToId;
  final ReplyPreview? replyPreview;

  /// Files that accompany this message (see [MessageAttachment]). A list
  /// from the start, so several pictures in one message need no further
  /// format change. [text] doubles as the caption when both are present.
  final List<MessageAttachment> attachments;

  /// The sender's OWN clock reading at send time, taken before the
  /// message left the device. Receipts echo this exact value back (see
  /// receipt_signal.dart / AppSession._sendReceipt), so the sender's
  /// checkmark comparison happens entirely within its own clock -- the
  /// receiver's arrival timestamp is useless for that: on a fast local
  /// network the receiver can decrypt before the sender's post-send code
  /// even stamps its local copy, and across two real devices the clocks
  /// can disagree outright; either way a receipt built from the
  /// receiver's clock can land "before" the message it confirms and be
  /// discarded by the monotonic guards forever. Null from senders
  /// predating this field -- receivers then fall back to their arrival
  /// stamp (the old, racy-but-usually-fine behavior).
  final DateTime? sentAt;

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
      'attachments': attachments.map((a) => a.toJson()).toList(),
      if (replyToId != null) 'reply_to': replyToId,
      if (replyPreview != null) 'reply_preview': replyPreview!.toJson(),
      if (senderServer != null) 'sender_server': senderServer,
      if (sentAt != null) 'sent_at': sentAt!.toUtc().toIso8601String(),
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
            sentAt: DateTime.tryParse(
              decoded['sent_at'] as String? ?? '',
            )?.toUtc(),
            attachments: _decodeAttachments(decoded['attachments']),
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

  /// Parses the "attachments" array, skipping entries that are malformed or
  /// unusable -- a bad attachment costs its own picture, never the message.
  static List<MessageAttachment> _decodeAttachments(dynamic raw) {
    if (raw is! List || raw.isEmpty) return const [];
    final out = <MessageAttachment>[];
    for (final entry in raw) {
      if (entry is! Map<String, dynamic>) continue;
      final parsed = MessageAttachment.fromJson(entry);
      if (parsed != null) out.add(parsed);
    }
    return out;
  }
}
