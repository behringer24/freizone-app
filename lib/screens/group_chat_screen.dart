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
import 'package:image_picker/image_picker.dart';

import '../ffi/models.dart';
import '../state/app_session.dart';
import '../state/app_settings.dart';
import '../state/chat_target.dart';
import '../state/group_conversation.dart';
import '../state/outgoing_attachment.dart';
import '../util/avatar_color.dart';
import '../util/errors.dart';
import '../util/message_actions.dart';
import '../widgets/attachment_thumbnail.dart';
import '../widgets/image_attachment.dart';
import '../widgets/pattern_background.dart';
import '../widgets/pinned_message_bar.dart';
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

  /// The picture staged in the composer, sent by [_send] with whatever caption
  /// is typed alongside it. One at a time, exactly as in a one-to-one chat.
  OutgoingAttachment? _pendingAttachment;
  bool _preparing = false;

  /// Stable per-message keys, reused across rebuilds, so the pinned bar can
  /// scroll to a message that isn't near the bottom of the list. The same
  /// mechanism ChatScreen uses.
  final _messageKeys = <String, GlobalKey>{};

  GlobalKey _keyFor(String messageId) =>
      _messageKeys.putIfAbsent(messageId, () => GlobalKey());

  /// Whether a picture could reach *anybody* in this group. False only when
  /// every server holding a member has said it stores no attachments -- then
  /// the button is dropped, since it could only ever fail. Null while unknown,
  /// so a slow status call doesn't hide a working feature.
  bool? _attachmentsSupported;

  @override
  void initState() {
    super.initState();
    // Looking at it is what makes it read.
    widget.session.enterGroup(widget.groupId);
    _checkAttachmentSupport();
  }

  /// Asks every server holding a member of this group whether it takes
  /// pictures.
  ///
  /// "Any of them" rather than "all of them" on purpose: a blob lives on the
  /// *recipient's* server (SRV-07), so in a federated group the answer
  /// genuinely differs per member, and one member on a server with attachments
  /// switched off must not disable the feature for everyone else. The send path
  /// reports who actually missed out. Answers are cached per session by
  /// AppSession, so this is one call per distinct server at most.
  Future<void> _checkAttachmentSupport() async {
    final resolved = widget.session.groupState(widget.groupId)?.resolved;
    if (resolved == null) return;
    final servers = <String?>{
      for (final member in resolved.members)
        if (member.joined && member.accountId != widget.session.state.accountId)
          member.server,
    };
    if (servers.isEmpty) return;

    var anySupported = false;
    for (final server in servers) {
      final capability = await widget.session.blobCapabilityForServer(server);
      // Unknown counts as supported: the send path re-checks and explains.
      if (capability == null || capability.enabled) {
        anySupported = true;
        break;
      }
    }
    if (!mounted) return;
    setState(() => _attachmentsSupported = anySupported);
  }

  /// Picks a picture from the gallery and stages it in the composer.
  ///
  /// image_picker does the downscale and JPEG re-encode natively as part of
  /// picking, so there is no separate "compressing" step -- the same path a
  /// one-to-one picture takes.
  Future<void> _pickImage() async {
    if (_preparing || _pendingAttachment != null) return;
    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: maxSentImageEdge.toDouble(),
        maxHeight: maxSentImageEdge.toDouble(),
        imageQuality: sentImageQuality,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Picker failed: ${describeError(e)}')),
        );
      }
      return;
    }
    if (picked == null || !mounted) return;

    setState(() => _preparing = true);
    try {
      final bytes = await picked.readAsBytes();
      final attachment = await OutgoingAttachment.prepare(bytes);
      if (attachment == null) {
        throw StateError("That file doesn't look like an image.");
      }
      if (!mounted) return;
      setState(() => _pendingAttachment = attachment);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Couldn't attach: ${describeError(e)}")),
        );
      }
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  @override
  void dispose() {
    // Releases the "currently open chat" slot this screen claimed, so a group
    // message arriving after it closes is marked unread again (and not silently
    // confirmed read) -- the same pairing ChatScreen has with enterConversation.
    widget.session.exitGroup(widget.groupId);
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Sends the typed text, the staged picture, or both -- the text doubles as
  /// the picture's caption, so a picture on its own is a valid message and an
  /// empty composer only blocks the send when nothing is staged either.
  Future<void> _send() async {
    final text = _composer.text.trim();
    final attachment = _pendingAttachment;
    if (_preparing || _sending) return;
    if (text.isEmpty && attachment == null) return;
    _composer.clear();
    setState(() {
      _sending = true;
      _pendingAttachment = null;
    });
    try {
      await widget.session.sendGroupMessage(
        widget.groupId,
        text,
        attachment: attachment,
      );
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
              // Above the transcript rather than inside it, so it stays put
              // while the list scrolls beneath -- ChatScreen's own bar, shared.
              PinnedMessageBar(
                chat: chat,
                onJumpToMessage: _scrollToMessage,
              ),
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
              else ...[
                // Directly above the input, matching where a one-to-one chat
                // puts it: the picture is part of the message being composed.
                if (_pendingAttachment != null)
                  _buildAttachmentComposerBar(context, _pendingAttachment!),
                _buildComposer(context),
              ],
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

  /// Pins the transcript to its newest message, the way ChatScreen does.
  ///
  /// After the frame, because the extent isn't known until the list has laid
  /// out -- and on every build rather than only on open, so a message arriving
  /// while the group is on screen scrolls into view instead of sitting below
  /// the fold.
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  /// Scrolls the transcript to one message, for the pinned bar's tap.
  ///
  /// A no-op when the id has no bubble on screen -- the message was deleted
  /// from this device while pinned, which is exactly how ChatScreen behaves.
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

  /// Long-press menu for one group message: pin/unpin, or delete it from this
  /// device (APP-21). Both are purely local -- no other member sees either.
  /// Replying is APP-17 and needs a wire field, so it is not offered yet.
  Future<void> _showMessageActions(
    BuildContext context,
    GroupConversation chat,
    StoredMessage message,
  ) async {
    final isPinned = chat.pinnedMessageIds.contains(message.id);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: Icon(
                isPinned ? Icons.push_pin_outlined : Icons.push_pin,
              ),
              title: Text(isPinned ? 'Unpin' : 'Pin'),
              onTap: () =>
                  Navigator.of(context).pop(isPinned ? 'unpin' : 'pin'),
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
      case 'pin':
        await widget.session.pinMessage(widget.groupId, message.id);
        break;
      case 'unpin':
        await widget.session.unpinMessage(widget.groupId, message.id);
        break;
      case 'delete':
        await confirmAndDeleteMessage(
          context,
          widget.session,
          chatId: widget.groupId,
          messageId: message.id,
        );
        break;
    }
  }

  Widget _buildTranscript(BuildContext context, GroupConversation chat) {
    // The patterned backdrop the one-to-one chat has. Applied even when the
    // transcript is empty, or a new group would show a bare surface and then
    // change appearance as soon as the first message landed.
    if (chat.messages.isEmpty) {
      return const PatternBackground(
        child: Center(child: Text('No messages yet')),
      );
    }
    _scrollToBottom();
    return PatternBackground(
      // Every bubble is built up front, like ChatScreen's list, rather than
      // lazily: the pinned bar has to be able to scroll to a message far above
      // the fold, and Scrollable.ensureVisible can only reach a widget that
      // exists. The transcript is fully in memory either way.
      child: ListView(
        controller: _scroll,
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: _buildBubbles(context, chat),
      ),
    );
  }

  List<Widget> _buildBubbles(BuildContext context, GroupConversation chat) {
    final bubbles = <Widget>[];
    for (var i = 0; i < chat.messages.length; i++) {
      final message = chat.messages[i];
      final previous = i == 0 ? null : chat.messages[i - 1];
      // Only the first of a run from one author is labelled -- repeating it
      // on every bubble is noise.
      final showAuthor =
          !message.mine &&
          message.senderAccountId != null &&
          previous?.senderAccountId != message.senderAccountId;
      bubbles.add(
        _GroupBubble(
          key: _keyFor(message.id),
          message: message,
          showAuthor: showAuthor,
          chat: chat,
          session: widget.session,
          isPinned: chat.pinnedMessageIds.contains(message.id),
          onLongPress: () => _showMessageActions(context, chat, message),
        ),
      );
    }
    return bubbles;
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
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Dropped entirely when every member's server has told us it
            // stores no attachments -- a button that can only fail is worse
            // than no button. Greyed out while a picture is already staged:
            // one attachment per message is all that renders today, so it goes
            // dead until that one is sent or dismissed, rather than silently
            // replacing it. Both rules match ChatScreen's composer.
            if (_attachmentsSupported != false)
              IconButton(
                icon: const Icon(Icons.image_outlined),
                tooltip: _pendingAttachment != null
                    ? 'One picture per message'
                    : 'Attach a picture',
                onPressed: _preparing || _pendingAttachment != null
                    ? null
                    : _pickImage,
              ),
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

  /// The staged picture above the composer, with its size and a way to drop it
  /// again. Styled from ChatScreen's own bar rather than from Material
  /// defaults, so the two composers stay indistinguishable.
  Widget _buildAttachmentComposerBar(
    BuildContext context,
    OutgoingAttachment attachment,
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
          AttachmentThumbnail(bytes: attachment.bytes, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Picture',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    color: colorScheme.primary,
                  ),
                ),
                // Already downscaled and re-encoded by the picker, so this is
                // what will actually be uploaded -- and in a group it is
                // uploaded once per recipient server, which is exactly why the
                // size is worth showing before the send.
                Text(
                  '${attachment.width}×${attachment.height} · '
                  '${formatByteSize(attachment.bytes.length)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Remove picture',
            onPressed: () => setState(() => _pendingAttachment = null),
          ),
        ],
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
  const _GroupBubble({
    super.key,
    required this.message,
    required this.showAuthor,
    required this.chat,
    required this.session,
    required this.isPinned,
    required this.onLongPress,
  });

  final StoredMessage message;
  final bool showAuthor;

  /// Draws the pin marker over the bubble's outer corner, as in a one-to-one
  /// chat -- so a pinned message is recognizable in the transcript itself and
  /// not only in the bar at the top.
  final bool isPinned;

  /// Opens the message's action menu. Never reached from a system line: those
  /// return before the bubble is built, matching ChatScreen, where a local
  /// info line is not pin- or delete-eligible either.
  final VoidCallback onLongPress;

  /// The transcript this bubble belongs to -- needed for the per-member receipt
  /// watermarks a group's send indicator counts over (see _statusFor).
  final GroupConversation chat;

  /// Needed to fetch and decrypt an attachment on demand, exactly as a
  /// one-to-one bubble does -- see AppSession.ensureAttachmentDownloaded.
  final AppSession session;

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
      child: GestureDetector(
        onLongPress: onLongPress,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.75,
              ),
              margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
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
              // IntrinsicWidth so the bubble hugs its text instead of always
              // filling the 75% cap: an Align child expands to the space it is
              // given, which is what made every bubble the same width
              // regardless of content.
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
                          // transcript and a face in the member list are visibly
                          // the same person rather than two unrelated colours.
                          color: avatarColorFor(author),
                        ),
                      ),
                    if (message.hasAttachments) ...[
                      // The same widget the one-to-one bubble uses, keyed on the
                      // group id: it only ever names the directory the file
                      // lives in, so the download and cache paths need no
                      // group-specific branch at all.
                      ImageAttachment(
                        session: session,
                        chatId: chat.groupId,
                        message: message,
                      ),
                      if (message.text.isNotEmpty) const SizedBox(height: 6),
                    ],
                    // Doubles as the caption when there is a picture, so a
                    // picture with no text renders nothing extra -- rather than
                    // the empty Text this used to draw unconditionally.
                    if (message.text.isNotEmpty)
                      Text(message.text, style: TextStyle(color: onBubble)),
                    if (mine && _skippedAttachmentCount > 0)
                      _buildAttachmentSkipped(context, onBubble),
                    if (mine)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [_statusFor(context, message, onBubble)],
                      ),
                  ],
                ),
              ),
            ),
            // On the bubble's inner corner, never the screen edge, so it cannot
            // be clipped away -- the placement ChatScreen uses.
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

  /// How many members got the caption but not the picture, because their
  /// server does not store attachments or would not take this one.
  int get _skippedAttachmentCount =>
      message.deliveries.where((d) => d.attachmentSkipped).length;

  /// Said in the bubble rather than in a SnackBar at send time: it stays true,
  /// and a message that reached everybody's transcript without its picture
  /// would otherwise look completely delivered.
  ///
  /// A retry cannot mend it -- those copies count as delivered, so re-sending
  /// the picture would mean re-sending the whole message -- which is why this
  /// is a statement of fact and not an action.
  Widget _buildAttachmentSkipped(BuildContext context, Color onBubble) {
    final count = _skippedAttachmentCount;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.image_not_supported_outlined,
            size: 13,
            color: onBubble.withValues(alpha: 0.8),
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              count == 1
                  ? '1 member could not receive the picture'
                  : '$count members could not receive the picture',
              style: TextStyle(
                fontSize: 11,
                color: onBubble.withValues(alpha: 0.8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// "Delivered to k of N" as one glyph. A running counter in every bubble
  /// would be a number nobody cares about five minutes later.
  Widget _statusFor(BuildContext context, StoredMessage message, Color color) {
    // Confirmed by the recipients themselves, not merely handed to their
    // servers: each member's own receipt, filed per member (see
    // GroupConversation.readCountFor). Only the counts are shown, never who --
    // a per-member list belongs in the delivery sheet, on demand.
    final owed = message.deliveries.length;
    final read = chat.readCountFor(message);
    final arrived = chat.deliveredCountFor(message);

    final (icon, label) = switch (message.aggregateSendState) {
      MessageSendState.pending => (Icons.schedule, 'Sending'),
      MessageSendState.failed => (
        Icons.error_outline,
        'Delivered to ${message.deliveredCount} of '
            '${message.deliveries.length}',
      ),
      // Sent to everyone owed a copy, and then the recipients' own word for it.
      // Read wins over received: it implies it.
      MessageSendState.sent when owed > 0 && read >= owed => (
        Icons.done_all,
        'Read by all',
      ),
      MessageSendState.sent when read > 0 => (
        Icons.done_all,
        'Read by $read of $owed',
      ),
      MessageSendState.sent when arrived > 0 => (
        Icons.done_all,
        'Received by $arrived of $owed',
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
