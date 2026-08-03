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
import 'group_info_screen.dart';

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
          'theirs. There are ${resolved.members.length} member(s).\n\n'
          // Said before accepting, not discovered after: the empty transcript
          // is by design and permanent. Nothing that was written before you
          // join is ever forwarded -- there is no group copy of it to forward
          // (see docs/design/16-groups.md).
          'You will see messages from now on. Anything written before you join '
          'stays with the people who were there.',
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

  /// Declining takes this account out of the group's member list for everyone
  /// (it is a signed `leave`, see AppSession.declineGroupInvite) and forgets the
  /// group here. Confirmed first because both halves are one-way: the invitation
  /// cannot be re-opened from this side, only re-issued from theirs.
  Future<void> _decline() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Decline this invitation?'),
        content: const Text(
          'The group will see that you declined, and you will be removed from '
          'its member list. This group then disappears from your chats — only '
          'someone in the group can invite you again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Decline'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.session.declineGroupInvite(widget.groupId);
      // The group is gone from this account, so this screen has nothing left to
      // render (its build would fall through to "Group not found").
      navigator.pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(e))));
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
            // Tapping the title opens the member list -- the standard gesture
            // in every messenger, and unbound in ChatScreen today. Group
            // moderation lives there rather than in a menu, because every
            // action is about one member.
            title: InkWell(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => GroupInfoScreen(
                    session: widget.session,
                    groupId: widget.groupId,
                  ),
                ),
              ),
              child: Column(
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
          ),
          body: Column(
            children: [
              Expanded(child: _buildTranscript(context, chat)),
              if (chat.invitePending && resolved != null)
                _buildInviteBar(context, resolved)
              else if (resolved?.dissolved ?? false)
                const _Notice('This group has been dissolved.')
              // Left, or removed by a moderator. The transcript stays readable
              // (it is ours), but a composer here would only produce "you are
              // not a member of this group" on send -- so say it up front, and
              // point at the one action left: getting it off this device, in
              // the info screen behind the title.
              else if (resolved != null &&
                  resolved.memberById(widget.session.state.accountId) == null)
                const _Notice('You are no longer a member of this group.')
              // No facts about this group at all: a message overtook the
              // snapshot that introduces it (delivery is unordered). Sending
              // needs the member list, so there is nothing to send to yet.
              else if (resolved == null)
                const _Notice(
                  'Waiting for this group\'s details from another member.',
                )
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
        child: Row(
          children: [
            // Declining is offered next to joining, not hidden in a menu: an
            // invitation is a question, and a question with only one answer on
            // screen is a nudge.
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _decline,
                icon: const Icon(Icons.close),
                label: const Text('Decline'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: () => _accept(resolved),
                icon: const Icon(Icons.group_add),
                label: const Text('Join group'),
              ),
            ),
          ],
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
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.send,
                textCapitalization: TextCapitalization.sentences,
                onSubmitted: (_) => _send(),
                // Matched to ChatScreen's composer rather than left at the
                // Material default: two chat screens that look different in
                // the one place the user's hands live would read as a bug.
                decoration: InputDecoration(
                  hintText: 'Message',
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
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
        // IntrinsicWidth so the bubble hugs its text instead of always filling
        // the 75% cap: an Align child expands to the space it is given, which
        // is what made every bubble the same width regardless of content.
        child: IntrinsicWidth(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showAuthor && author != null)
                Text(
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
              Text(message.text, style: TextStyle(color: onBubble)),
              if (mine)
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [_statusFor(context, message, onBubble)],
                ),
            ],
          ),
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
      // Two checks mean "delivered to everyone owed a copy" -- which is
      // vacuously true when nobody was owed one. A group whose only other
      // members are pending invitees is owed nothing (see
      // AppSession.sendGroupMessage: a copy goes only to members who have
      // accepted), and a bare checkmark there reads as "it arrived".
      MessageSendState.sent when message.deliveries.isEmpty => (
        Icons.done_all,
        'Nobody has accepted yet',
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
