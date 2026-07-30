// A small square preview of an image attachment, for the compact places
// that only *reference* a message instead of rendering it: the pinned
// message bar, the reply preview above the composer, and the picture
// staged for sending in the composer itself (APP-04).
//
// Deliberately fed from bytes that are already in memory -- either the tiny
// inline thumbnail a message carries (MessageAttachment.thumb) or a freshly
// picked file's own bytes -- so none of those bars needs the asynchronous
// file resolution ImageAttachment does. That also means a picture whose
// full blob was never downloaded (or is long gone) still shows something
// here, which is the whole point of these previews.
import 'dart:typed_data';

import 'package:flutter/material.dart';

class AttachmentThumbnail extends StatelessWidget {
  const AttachmentThumbnail({super.key, required this.bytes, this.size = 32});

  /// Null or empty renders the placeholder instead: an attachment whose
  /// sender included no inline thumbnail should still read as a picture
  /// rather than vanish from the bar.
  final Uint8List? bytes;

  /// Edge length of the (square) preview. Kept small by every caller so a
  /// bar never grows to picture height.
  final double size;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final data = bytes;

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: size,
        height: size,
        child: data == null || data.isEmpty
            ? ColoredBox(
                color: colorScheme.surfaceContainerHighest,
                child: Icon(
                  Icons.image_outlined,
                  size: size * 0.55,
                  color: colorScheme.onSurfaceVariant,
                ),
              )
            : Image.memory(
                data,
                fit: BoxFit.cover,
                // Decoded at roughly the size actually drawn rather than at
                // the source's full resolution -- the composer preview is
                // handed a whole 1600px JPEG (see maxSentImageEdge), which
                // has no business sitting in the image cache at full size
                // just to be painted 44px wide. Doubled for hi-dpi screens.
                cacheWidth: (size * 2).round(),
                // A staged picture is rebuilt on every keystroke in the
                // composer; without this the preview blinks each time.
                gaplessPlayback: true,
                // Same reasoning as the placeholder above: unreadable bytes
                // (a truncated or corrupt thumbnail) must not take out the
                // whole bar they sit in.
                errorBuilder: (context, _, _) => ColoredBox(
                  color: colorScheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.broken_image_outlined,
                    size: size * 0.55,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
      ),
    );
  }
}
