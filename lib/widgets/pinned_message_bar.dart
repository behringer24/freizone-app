// The sticky "pinned message(s)" bar above a transcript, for both a
// one-to-one chat and a group (APP-21).
//
// Typed on ChatTarget rather than on Conversation, because a pinned id and a
// message list is all it ever touches -- which is exactly what the two chat
// kinds already share. Extracted from ChatScreen when groups grew the same
// bar: two copies of a browsable bar with its own index is precisely the drift
// the group screen's header warns about.
import 'package:flutter/material.dart';

import '../state/chat_target.dart';
import '../util/message_preview.dart';
import 'attachment_thumbnail.dart';

class PinnedMessageBar extends StatefulWidget {
  const PinnedMessageBar({
    super.key,
    required this.chat,
    required this.onJumpToMessage,
  });

  final ChatTarget chat;

  /// Scrolls the transcript to the pinned message. The screen owns the scroll
  /// controller and the per-message keys, so the jump stays there.
  final void Function(String messageId) onJumpToMessage;

  @override
  State<PinnedMessageBar> createState() => _PinnedMessageBarState();
}

class _PinnedMessageBarState extends State<PinnedMessageBar> {
  /// Which of several pinned messages is on show, as an index into the
  /// *reversed* id list -- so 0 is the most recently pinned one.
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    // Rendered as nothing rather than omitted by the caller, so unpinning the
    // last message does not take this State (and with it the browse position)
    // down with it.
    final ids = widget.chat.pinnedMessageIds.reversed.toList();
    if (ids.isEmpty) return const SizedBox.shrink();

    final colorScheme = Theme.of(context).colorScheme;
    final idx = _index.clamp(0, ids.length - 1);
    final pinned = widget.chat.messageById(ids[idx]);

    return Material(
      color: colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: pinned == null
            ? null
            : () => widget.onJumpToMessage(pinned.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.push_pin, size: 16, color: colorScheme.primary),
              const SizedBox(width: 8),
              if (pinned != null && pinned.hasAttachments) ...[
                AttachmentThumbnail(
                  bytes: pinned.attachments.first.thumb,
                  size: 26,
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  pinned == null
                      ? 'Pinned message no longer available'
                      : messageReferenceLabel(pinned),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (ids.length > 1) ...[
                IconButton(
                  icon: const Icon(Icons.chevron_left, size: 20),
                  visualDensity: VisualDensity.compact,
                  onPressed: () =>
                      setState(() => _index = (idx - 1) % ids.length),
                ),
                Text(
                  '${idx + 1}/${ids.length}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right, size: 20),
                  visualDensity: VisualDensity.compact,
                  onPressed: () =>
                      setState(() => _index = (idx + 1) % ids.length),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
