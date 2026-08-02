// A group's transcript (APP-16).
//
// Deliberately its own screen for now rather than a ChatScreen taught to
// render both. ChatScreen is built end to end around a peer -- blocking,
// message requests, the secure-session reset, receipt watermarks, the peer
// profile -- and none of that exists in a group. Threading a ChatTarget
// through all of it, untested, would risk the one screen people actually use
// every day. The cost is two transcript renderers that can drift, which is
// real and recorded in the design document; merging them is worth doing once
// the group side has stopped moving.
import 'package:flutter/material.dart';

import '../ffi/models.dart';
import '../state/app_session.dart';
import '../state/app_settings.dart';
import '../state/chat_target.dart';
import '../state/group_conversation.dart';
import '../util/avatar_color.dart';
import '../util/errors.dart';

class GroupChatScreen extends StatefulWidget {
  const GroupChatScreen({
    super.key,
    required this.session,
    required this.groupId,
    required this.settings,
  });

  final AppSession session;
  final String groupId;
  final AppSettings settings;

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final _composer = TextEditingController();
  final _scroll = ScrollController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    // Looking at it is what makes it read.
    widget.session.enterGroup(widget.groupId);
  }

  @override
  void dispose() {
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _sending) return;
    _composer.clear();
    setState(() => _sending = true);
    try {
      await widget.session.sendGroupMessage(widget.groupId, text);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(describeError(e))));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Everyone in a group learns everyone else's address -- pairwise fan-out
  /// leaves no choice about that. Said plainly at the moment of accepting,
  /// rather than left to be discovered.
  Future<void> _accept(GroupResolved resolved) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Join this group?'),
        content: Text(
          'Everyone in this group will see your address, and you will see '
          'theirs. There are ${resolved.members.length} member(s).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Join'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.session.acceptGroupInvite(widget.groupId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(describeError(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        final chat = widget.session.group(widget.groupId);
        final resolved = widget.session.groupState(widget.groupId)?.resolved;
        if (chat == null) {
          return const Scaffold(body: Center(child: Text('Group not found')));
        }

        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(chat.titleFor(widget.session.state.server)),
                if (resolved != null)
                  Text(
                    _subtitleFor(resolved),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          body: Column(
            children: [
              Expanded(child: _buildTranscript(context, chat)),
              if (chat.invitePending && resolved != null)
                _buildInviteBar(context, resolved)
              else if (resolved?.dissolved ?? false)
                const _Notice('This group has been dissolved.')
              else
                _buildComposer(context),
            ],
          ),
        );
      },
    );
  }

  String _subtitleFor(GroupResolved resolved) {
    final joined = resolved.members.where((m) => m.joined).length;
    final invited = resolved.members.length - joined;
    final topic = resolved.topic;
    if (topic.isNotEmpty) return topic;
    return invited == 0
        ? '$joined member(s)'
        : '$joined member(s), $invited invited';
  }

  Widget _buildTranscript(BuildContext context, GroupConversation chat) {
    if (chat.messages.isEmpty) {
      return const Center(child: Text('No messages yet'));
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: chat.messages.length,
      itemBuilder: (context, i) {
        final message = chat.messages[i];
        final previous = i == 0 ? null : chat.messages[i - 1];
        // Only the first of a run from one author is labelled -- repeating it
        // on every bubble is noise.
        final showAuthor =
            !message.mine &&
            message.senderAccountId != null &&
            previous?.senderAccountId != message.senderAccountId;
        return _GroupBubble(message: message, showAuthor: showAuthor);
      },
    );
  }

  Widget _buildInviteBar(BuildContext context, GroupResolved resolved) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: FilledButton.icon(
          onPressed: () => _accept(resolved),
          icon: const Icon(Icons.group_add),
          label: const Text('Join group'),
        ),
      ),
    );
  }

  Widget _buildComposer(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _composer,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: const InputDecoration(
                  hintText: 'Message',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            IconButton(
              onPressed: _sending ? null : _send,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
  );
}

class _GroupBubble extends StatelessWidget {
  const _GroupBubble({required this.message, required this.showAuthor});

  final StoredMessage message;
  final bool showAuthor;

  @override
  Widget build(BuildContext context) {
    if (message.kind == StoredMessageKind.systemInfo) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 24),
        child: Text(
          message.text,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }

    final colorScheme = Theme.of(context).colorScheme;
    final mine = message.mine;
    final onBubble = mine ? colorScheme.onPrimary : colorScheme.onSurface;
    final author = message.senderAccountId;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: mine ? colorScheme.primary : colorScheme.surfaceContainerHighest,
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
            if (showAuthor && author != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _shortId(author),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    // The same function the avatar uses, so a name in the
                    // transcript and a face in the member list are visibly the
                    // same person rather than two unrelated colours.
                    color: avatarColorFor(author),
                  ),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(message.text, style: TextStyle(color: onBubble)),
            ),
            if (mine) _statusFor(context, message, onBubble),
          ],
        ),
      ),
    );
  }

  /// "Delivered to k of N" as one glyph. A running counter in every bubble
  /// would be a number nobody cares about five minutes later.
  Widget _statusFor(BuildContext context, StoredMessage message, Color color) {
    final (icon, label) = switch (message.aggregateSendState) {
      MessageSendState.pending => (Icons.schedule, 'Sending'),
      MessageSendState.failed => (
        Icons.error_outline,
        'Delivered to ${message.deliveredCount} of '
            '${message.deliveries.length}',
      ),
      MessageSendState.sent => (Icons.done_all, ''),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (label.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: color.withValues(alpha: 0.8),
                ),
              ),
            ),
          Icon(icon, size: 14, color: color.withValues(alpha: 0.8)),
        ],
      ),
    );
  }

  static String _shortId(String accountId) =>
      accountId.length > 5 ? accountId.substring(0, 5) : accountId;
}
