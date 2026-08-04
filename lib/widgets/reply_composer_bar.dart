import 'package:flutter/material.dart';

import '../state/chat_target.dart';
import '../util/message_preview.dart';
import 'attachment_thumbnail.dart';

/// The "replying to ..." preview shown above the input while composing a
/// reply -- tapping the close icon cancels it without sending.
///
/// Shared by both transcripts (APP-17). The one thing that differs between
/// them is [label]: a one-to-one chat can always name the person, a group
/// sometimes only has five characters of their account id to name them by.
class ReplyComposerBar extends StatelessWidget {
  const ReplyComposerBar({
    super.key,
    required this.replyingTo,
    required this.label,
    required this.onCancel,
  });

  /// The message being answered -- for its thumbnail and its one-line
  /// reference label, not for its author (see [label]).
  final StoredMessage replyingTo;

  /// The whole heading, e.g. "Replying to yourself" or "Replying to qk43r",
  /// rather than just a name: the two chat kinds phrase it differently and
  /// neither should have to be reconstructed from parts here.
  final String label;

  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        border: Border(top: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 32,
            color: colorScheme.primary,
            margin: const EdgeInsets.only(right: 8),
          ),
          if (replyingTo.hasAttachments) ...[
            AttachmentThumbnail(
              bytes: replyingTo.attachments.first.thumb,
              size: 32,
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    color: colorScheme.primary,
                  ),
                ),
                Text(
                  messageReferenceLabel(replyingTo),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Cancel reply',
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}
