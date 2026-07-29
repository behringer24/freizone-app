// Turning a picked image into something sendable (APP-04).
//
// image_picker already does the expensive part natively -- downscaling and
// re-encoding to JPEG as it hands the file over -- so this only has to read
// the result, measure it, and shrink a tiny preview thumbnail out of it.
// Both of those use dart:ui's own codec, so no extra image package is
// needed.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'message_content.dart';

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
