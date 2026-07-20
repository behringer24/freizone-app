// Single-conversation chat screen: WhatsApp/Telegram/Signal-style
// bubbles over a conversation's persisted history (AppSession owns the
// data and the live SSE connection; this screen only renders it and
// forwards sends). Peer resolution now happens once, up front, in
// ChatListScreen's "new chat" flow -- by the time this screen opens,
// the conversation's peer device is already resolved and cached.
import 'package:flutter/material.dart';

import '../state/app_session.dart';
import '../state/conversation.dart';
import '../util/address_format.dart';
import '../util/errors.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.session,
    required this.peerAccountId,
  });

  final AppSession session;
  final String peerAccountId;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  bool _sending = false;

  /// Set while composing a reply -- shown as a preview bar above the
  /// input, cleared once the reply is sent or dismissed.
  StoredMessage? _replyingTo;

  /// Index into a conversation's pinned ids *reversed* (so 0 is always
  /// the most recently pinned) -- clamped against the current list on
  /// every build, so it never needs resetting when pins are added or
  /// removed elsewhere.
  int _pinnedIndex = 0;

  /// Stable per-message keys, reused across rebuilds, so a quote tap or
  /// the pinned bar can scroll to a message that isn't necessarily near
  /// the bottom of the list.
  final _messageKeys = <String, GlobalKey>{};

  GlobalKey _keyFor(String messageId) =>
      _messageKeys.putIfAbsent(messageId, () => GlobalKey());

  Color _avatarColor(String seed) =>
      Colors.primaries[seed.hashCode.abs() % Colors.primaries.length];

  @override
  void initState() {
    super.initState();
    widget.session.enterConversation(widget.peerAccountId);
  }

  Future<void> _send() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _sending) return;

    setState(() => _sending = true);
    try {
      await widget.session.sendMessage(
        widget.peerAccountId,
        text,
        replyToId: _replyingTo?.id,
      );
      _messageController.clear();
      setState(() => _replyingTo = null);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Send failed: ${describeError(e)}')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  void _scrollToMessage(String messageId) {
    final ctx = _messageKeys[messageId]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      alignment: 0.5,
    );
  }

  /// Long-press menu for a single message bubble: reply, pin/unpin (both
  /// purely local except reply, whose reference rides along inside the
  /// next message sent), or delete from this device only.
  Future<void> _showMessageActions(
    BuildContext context,
    Conversation convo,
    StoredMessage message,
  ) async {
    final isPinned = convo.pinnedMessageIds.contains(message.id);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Reply'),
              onTap: () => Navigator.of(context).pop('reply'),
            ),
            ListTile(
              leading: Icon(
                isPinned ? Icons.push_pin_outlined : Icons.push_pin,
              ),
              title: Text(isPinned ? 'Unpin' : 'Pin'),
              onTap: () => Navigator.of(context).pop(isPinned ? 'unpin' : 'pin'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete for me'),
              onTap: () => Navigator.of(context).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;

    switch (action) {
      case 'reply':
        setState(() => _replyingTo = message);
        break;
      case 'pin':
        await widget.session.pinMessage(widget.peerAccountId, message.id);
        break;
      case 'unpin':
        await widget.session.unpinMessage(widget.peerAccountId, message.id);
        break;
      case 'delete':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete message?'),
            content: const Text(
              'This removes the message from this device only -- it stays '
              'for the other person, and this cannot be undone.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                ),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          await widget.session.deleteMessageLocally(
            widget.peerAccountId,
            message.id,
          );
        }
        break;
    }
  }

  String _dayLabel(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (day == today) return 'Today';
    if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(day.day)}.${two(day.month)}.${day.year}';
  }

  String _timeLabel(DateTime utc) {
    final local = utc.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}';
  }

  List<Widget> _buildItems(BuildContext context, Conversation convo) {
    final items = <Widget>[];
    DateTime? lastDay;
    for (final m in convo.messages) {
      final local = m.timestamp.toLocal();
      final day = DateTime(local.year, local.month, local.day);
      if (lastDay == null || day != lastDay) {
        items.add(_DateDivider(label: _dayLabel(day)));
        lastDay = day;
      }
      items.add(
        _MessageBubble(
          key: _keyFor(m.id),
          message: m,
          timeLabel: _timeLabel(m.timestamp),
          peerTitle: convo.title,
          isPinned: convo.pinnedMessageIds.contains(m.id),
          onLongPress: () => _showMessageActions(context, convo, m),
          onTapQuote: m.replyToId == null
              ? null
              : () => _scrollToMessage(m.replyToId!),
        ),
      );
    }
    return items;
  }

  /// Sets, changes, or removes this conversation's local alias -- purely
  /// local, never sent to the peer or the server.
  Future<void> _showRenameDialog(
    BuildContext context,
    Conversation convo,
  ) async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => _RenameDialog(initialName: convo.displayName ?? ''),
    );
    if (result == null) return; // cancelled
    await widget.session.setDisplayName(
      widget.peerAccountId,
      result.isEmpty ? null : result,
    );
  }

  @override
  void dispose() {
    widget.session.leaveConversation(widget.peerAccountId);
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Widget _buildTitle(BuildContext context, Conversation convo) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: _avatarColor(convo.peerAccountId),
          child: Text(
            convo.title
                .substring(0, convo.title.length >= 2 ? 2 : 1)
                .toUpperCase(),
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: convo.displayName != null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(convo.displayName!, overflow: TextOverflow.ellipsis),
                    // Always shown alongside the alias, smaller and muted,
                    // so the verifiable id is never hidden behind a name
                    // someone else could equally claim.
                    Text(
                      formatAccountIdForDisplay(convo.peerAccountId),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                )
              : Text(convo.title, overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: ListenableBuilder(
          listenable: widget.session,
          builder: (context, _) => _buildTitle(
            context,
            widget.session.conversation(widget.peerAccountId)!,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Edit name',
            onPressed: () => _showRenameDialog(
              context,
              widget.session.conversation(widget.peerAccountId)!,
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.session,
        builder: (context, _) {
          final convo = widget.session.conversation(widget.peerAccountId)!;
          final items = _buildItems(context, convo);
          _scrollToBottom();
          return Column(
            children: [
              if (convo.pinnedMessageIds.isNotEmpty)
                _buildPinnedBar(context, convo),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    image: DecorationImage(
                      image: AssetImage(
                        Theme.of(context).brightness == Brightness.dark
                            ? 'gfx/chat_background_dark.png'
                            : 'gfx/chat_background_light.png',
                      ),
                      repeat: ImageRepeat.repeat,
                    ),
                  ),
                  child: ListView(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(8),
                    children: items,
                  ),
                ),
              ),
              if (_replyingTo != null)
                _buildReplyComposerBar(context, convo, _replyingTo!),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _messageController,
                          decoration: InputDecoration(
                            hintText: 'Message',
                            filled: true,
                            fillColor: colorScheme.surfaceContainerHighest,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                              borderSide: BorderSide.none,
                            ),
                          ),
                          minLines: 1,
                          maxLines: 5,
                          textCapitalization: TextCapitalization.sentences,
                          onChanged: (_) => setState(() {}),
                          onSubmitted: (_) => _send(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      CircleAvatar(
                        radius: 24,
                        backgroundColor:
                            _messageController.text.trim().isEmpty
                            ? colorScheme.surfaceContainerHighest
                            : colorScheme.primary,
                        child: IconButton(
                          icon: Icon(
                            Icons.send,
                            color: _messageController.text.trim().isEmpty
                                ? colorScheme.onSurfaceVariant
                                : colorScheme.onPrimary,
                          ),
                          onPressed: _sending ? null : _send,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// The sticky "pinned message(s)" bar -- not part of the scrollable
  /// message list, so it stays put while the list scrolls beneath it.
  /// Shows the most recently pinned message by default (index 0 of the
  /// reversed list), with </> to browse the rest when there's more than
  /// one.
  Widget _buildPinnedBar(BuildContext context, Conversation convo) {
    final colorScheme = Theme.of(context).colorScheme;
    final ids = convo.pinnedMessageIds.reversed.toList();
    final idx = _pinnedIndex.clamp(0, ids.length - 1);
    final pinned = convo.messageById(ids[idx]);

    return Material(
      color: colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: pinned == null ? null : () => _scrollToMessage(pinned.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.push_pin, size: 16, color: colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  pinned?.text ?? 'Pinned message no longer available',
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
                      setState(() => _pinnedIndex = (idx - 1) % ids.length),
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
                      setState(() => _pinnedIndex = (idx + 1) % ids.length),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The "replying to ..." preview shown above the input while composing
  /// a reply -- tapping the close icon cancels it without sending.
  Widget _buildReplyComposerBar(
    BuildContext context,
    Conversation convo,
    StoredMessage replyingTo,
  ) {
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
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  replyingTo.mine ? 'Replying to yourself' : 'Replying to ${convo.title}',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    color: colorScheme.primary,
                  ),
                ),
                Text(
                  replyingTo.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() => _replyingTo = null),
          ),
        ],
      ),
    );
  }
}

/// Dialog content for setting/changing/removing a conversation's local
/// alias. A dedicated StatefulWidget (rather than a controller created
/// and manually disposed inline) so the TextEditingController's
/// lifecycle is tied to this Element's own dispose(), not a
/// hand-timed call racing the dialog route's exit transition.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initialName});

  final String initialName;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _controller = TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit name'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Name'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(''),
          child: const Text('Remove'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _DateDivider extends StatelessWidget {
  const _DateDivider({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    super.key,
    required this.message,
    required this.timeLabel,
    required this.peerTitle,
    required this.isPinned,
    required this.onLongPress,
    this.onTapQuote,
  });

  final StoredMessage message;
  final String timeLabel;

  /// The peer's display title, used to label a quoted message that was
  /// theirs ("Replying to X" reads the same way the composer bar does).
  final String peerTitle;
  final bool isPinned;
  final VoidCallback onLongPress;

  /// Scrolls to the quoted original, if this message is a reply and its
  /// target is still in local history -- null (and the quote becomes
  /// untappable) otherwise.
  final VoidCallback? onTapQuote;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final mine = message.mine;
    final onBubble = mine ? colorScheme.onPrimary : colorScheme.onSurface;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.75,
              ),
              margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              decoration: BoxDecoration(
                color: mine
                    ? colorScheme.primary
                    : colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(mine ? 16 : 4),
                  bottomRight: Radius.circular(mine ? 4 : 16),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message.isReply)
                    GestureDetector(
                      onTap: onTapQuote,
                      child: Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(bottom: 4),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: onBubble.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                          border: Border(
                            left: BorderSide(color: onBubble, width: 3),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              message.replyPreviewMine == true
                                  ? 'You'
                                  : peerTitle,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                                color: onBubble,
                              ),
                            ),
                            Text(
                              message.replyPreviewText ?? '',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: onBubble.withValues(alpha: 0.8),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  Text(message.text, style: TextStyle(color: onBubble)),
                  const SizedBox(height: 2),
                  Text(
                    timeLabel,
                    style: TextStyle(
                      fontSize: 11,
                      color: onBubble.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
            if (isPinned)
              Positioned(
                top: -4,
                right: mine ? null : -4,
                left: mine ? -4 : null,
                child: Icon(
                  Icons.push_pin,
                  size: 21,
                  color: colorScheme.primary,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
