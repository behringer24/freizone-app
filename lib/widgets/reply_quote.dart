import 'package:flutter/material.dart';

/// The quote block drawn at the top of a bubble that is a reply -- a snapshot
/// of the message being answered, not a live view of it.
///
/// Shared by the one-to-one and the group transcript (APP-17), which is the
/// point: a quote is the same object in both, and the two differ only in what
/// can be said about its author. A one-to-one chat has two people, so
/// "You" or the peer's title is a complete answer; a group has to name one
/// member among N, and may not be able to (see [authorLabel]).
class ReplyQuote extends StatelessWidget {
  const ReplyQuote({
    super.key,
    required this.previewText,
    required this.authorLabel,
    required this.onBubble,
    this.authorColor,
    this.quotedHasImage = false,
    this.onTap,
  });

  /// The quoted message's text, as snapshotted into the reply. Empty for a
  /// picture sent without a caption, which is why the row below shrinks to
  /// just the icon rather than stretching.
  final String previewText;

  /// Who is being quoted. **Null draws no author line at all** -- the honest
  /// rendering for a group reply whose author cannot be established: it came
  /// from a build that sent no author id, and the quoted message is no longer
  /// (or was never) in this device's history. A guess would be worse than a
  /// quote that simply does not say.
  final String? authorLabel;

  /// The bubble's foreground colour, which the quote's tint, border and text
  /// are all derived from so it reads as part of the bubble.
  final Color onBubble;

  /// The author line's colour, for a group quote that colours a name the way
  /// the transcript and member list do (avatarColorFor). Defaults to
  /// [onBubble] -- which is also what a caller should pass on a bubble whose
  /// background is the theme's primary, where an arbitrary palette colour has
  /// no contrast guarantee.
  final Color? authorColor;

  /// Whether the quoted message was a picture, shown as a small stand-in icon
  /// (APP-13 replaces it with a real thumbnail).
  final bool quotedHasImage;

  /// Scrolls to the quoted original. Null -- and the quote is untappable --
  /// when that message is not in local history.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: onBubble.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border(left: BorderSide(color: onBubble, width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (authorLabel != null)
              Text(
                authorLabel!,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  color: authorColor ?? onBubble,
                ),
              ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (quotedHasImage) ...[
                  Icon(
                    Icons.photo_outlined,
                    size: 13,
                    color: onBubble.withValues(alpha: 0.8),
                  ),
                  const SizedBox(width: 4),
                ],
                // Flexible, not Expanded: with an empty caption (a picture
                // sent without one) the row should shrink to just the icon
                // rather than stretch the quote to full width.
                Flexible(
                  child: Text(
                    previewText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: onBubble.withValues(alpha: 0.8),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
