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
      await widget.session.sendMessage(widget.peerAccountId, text);
      _messageController.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Send failed: ${describeError(e)}')));
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
      items.add(_MessageBubble(message: m, timeLabel: _timeLabel(m.timestamp)));
    }
    return items;
  }

  /// Sets, changes, or removes this conversation's local alias -- purely
  /// local, never sent to the peer or the server.
  Future<void> _showRenameDialog(BuildContext context, Conversation convo) async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => _RenameDialog(initialName: convo.displayName ?? ''),
    );
    if (result == null) return; // cancelled
    await widget.session.setDisplayName(widget.peerAccountId, result.isEmpty ? null : result);
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
      body: Column(
        children: [
          Expanded(
            child: ListenableBuilder(
              listenable: widget.session,
              builder: (context, _) {
                final convo = widget.session.conversation(
                  widget.peerAccountId,
                )!;
                final items = _buildItems(context, convo);
                _scrollToBottom();
                return ListView(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(8),
                  children: items,
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
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
                    backgroundColor: _messageController.text.trim().isEmpty
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
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.of(context).pop(''), child: const Text('Remove')),
        FilledButton(onPressed: () => Navigator.of(context).pop(_controller.text), child: const Text('Save')),
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
  const _MessageBubble({required this.message, required this.timeLabel});

  final StoredMessage message;
  final String timeLabel;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final mine = message.mine;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
            Text(
              message.text,
              style: TextStyle(
                color: mine ? colorScheme.onPrimary : colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              timeLabel,
              style: TextStyle(
                fontSize: 11,
                color: (mine ? colorScheme.onPrimary : colorScheme.onSurface)
                    .withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
