// Turning a picked image into something sendable (APP-04).
//
// image_picker already does the expensive part natively -- downscaling and
// re-encoding to JPEG as it hands the file over -- so this only has to read
// the result, measure it, and shrink a tiny preview thumbnail out of it.
// Both of those use dart:ui's own codec, so no extra image package is
// needed.
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../net/api_client.dart';
import '../net/dto.dart';
import 'message_content.dart';

/// What a given server will take as an attachment, read from its public
/// status endpoint (SRV-07). Discovered rather than assumed, so a peer on
/// an older or differently-configured server produces a clear explanation
/// instead of a raw upload failure.
class BlobCapability {
  const BlobCapability({
    required this.enabled,
    required this.maxBytes,
    this.maxRecipients = 1,
  });

  factory BlobCapability.from(ServerStatus status) => BlobCapability(
    enabled: status.blobsEnabled,
    maxBytes: status.maxBlobBytes,
    maxRecipients: status.maxBlobRecipients,
  );

  final bool enabled;

  /// 0 when the server didn't state one -- then only [enabled] is enforced
  /// and an oversized upload still fails server-side, as before.
  final int maxBytes;

  /// How many recipient devices one upload may name (SRV-18). 1 means this
  /// server stores a blob per device, so a group send has to upload once per
  /// member there instead of once for all of them -- which is also what an
  /// older server that never heard of the field gets, by its absence rule.
  final int maxRecipients;

  bool fits(int byteSize) => maxBytes <= 0 || byteSize <= maxBytes;
}

/// Whether a failed blob upload was a *stated* refusal rather than something a
/// retry might get past.
///
/// The distinction decides how a group send records a member who did not get
/// the picture (APP-16). A refusal is permanent, so they are told the picture
/// could not reach them and the caption goes out on its own. Anything else is
/// retried, with nothing sent to them in the meantime — because a copy that
/// counts as delivered is never revisited, so recording a dropped connection as
/// a refusal would strand that member's picture for good.
///
/// Only the server's own no counts: blobs switched off, an unknown or inactive
/// recipient device (`404`), and a picture over its size cap (`413`). A timeout,
/// a socket error, a `5xx`, or a `429` quota that will free itself when the
/// recipient next empties their downloads are all worth another attempt.
bool isPermanentBlobRefusal(Object error) =>
    error is ApiException &&
    (error.statusCode == 404 || error.statusCode == 413);

/// Renders a byte count the way a size limit reads to a person ("8 MB").
/// Powers of 1024, since that is what the server's limits are expressed in,
/// but without the pedantic MiB spelling.
String formatByteSize(int bytes) {
  if (bytes >= 1024 * 1024) {
    final mb = bytes / (1024 * 1024);
    return '${mb == mb.roundToDouble() ? mb.toStringAsFixed(0) : mb.toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024).round()} KB';
}

/// The longest edge a sent picture keeps. Comfortably sharp on a phone
/// screen while keeping a photo well under a megabyte -- the same
/// "compress silently, don't ask" behaviour other chat apps have trained
/// people to expect.
const int maxSentImageEdge = 1600;

/// JPEG quality for that re-encode. 80 is the usual sweet spot: visually
/// hard to tell from the original, a fraction of the bytes.
const int sentImageQuality = 80;

/// The edge length of the inline preview thumbnail. Deliberately tiny -- it
/// rides inside the message itself (see [maxAttachmentThumbBytes]), so it
/// exists only to show *something* before the real file downloads.
const int thumbnailEdge = 24;

/// An image that has been prepared for sending: the bytes to encrypt and
/// upload, plus the metadata the recipient needs to render it well.
class OutgoingAttachment {
  const OutgoingAttachment({
    required this.bytes,
    required this.mimeType,
    required this.width,
    required this.height,
    this.thumb,
  });

  final Uint8List bytes;
  final String mimeType;
  final int width;
  final int height;

  /// Tiny blurred-preview JPEG, or null if one couldn't be produced (in
  /// which case the recipient simply sees a plain placeholder while the
  /// picture downloads).
  final Uint8List? thumb;

  /// Measures [bytes] and derives a preview thumbnail.
  ///
  /// Returns null if the bytes aren't a decodable image -- better to refuse
  /// than to upload something the recipient can't render.
  static Future<OutgoingAttachment?> prepare(
    Uint8List bytes, {
    String mimeType = 'image/jpeg',
  }) async {
    ui.Image? full;
    try {
      full = await _decode(bytes);
    } catch (_) {
      return null;
    }
    final width = full.width;
    final height = full.height;
    full.dispose();

    return OutgoingAttachment(
      bytes: bytes,
      mimeType: mimeType,
      width: width,
      height: height,
      thumb: await _makeThumb(bytes),
    );
  }

  static Future<ui.Image> _decode(Uint8List bytes, {int? targetWidth}) async {
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: targetWidth);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  /// Re-encodes the picture at [thumbnailEdge] px wide. Returns null rather
  /// than throwing: a missing thumbnail costs a preview, never the send.
  static Future<Uint8List?> _makeThumb(Uint8List bytes) async {
    try {
      final small = await _decode(bytes, targetWidth: thumbnailEdge);
      // PNG is the only format dart:ui can encode to. At 24px wide that is
      // still well inside the 2 KB budget, and avoids pulling in an encoder
      // package purely for a thumbnail.
      final data = await small.toByteData(format: ui.ImageByteFormat.png);
      small.dispose();
      if (data == null) return null;
      final out = data.buffer.asUint8List();
      return out.length <= maxAttachmentThumbBytes ? out : null;
    } catch (_) {
      return null;
    }
  }
}
