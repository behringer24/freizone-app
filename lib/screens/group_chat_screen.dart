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
import '../state/contact_store.dart';
import '../state/app_settings.dart';
import '../state/chat_target.dart';
import '../state/group_conversation.dart';
import '../state/outgoing_attachment.dart';
import '../util/avatar_color.dart';
import '../util/chat_time.dart';
import '../util/errors.dart';
import '../util/freizone_address.dart';
import '../util/message_actions.dart';
import '../util/person_label.dart';
import '../util/quoted_author.dart';
import '../widgets/attachment_thumbnail.dart';
import '../widgets/date_divider.dart';
import '../widgets/group_delivery_sheet.dart';
import '../widgets/image_attachment.dart';
import '../widgets/pattern_background.dart';
import '../widgets/pinned_message_bar.dart';
import '../widgets/rename_dialog.dart';
import '../widgets/reply_composer_bar.dart';
import '../widgets/reply_quote.dart';
import 'chat_screen.dart';
import 'group_info_screen.dart';

class GroupChatScreen extends StatefulWidget {
  const GroupChatScreen({
    super.key,
    required this.session,
    required this.groupId,
    required this.settings,
    required this.contacts,
  });

  final AppSession session;
  final String groupId;
  final AppSettings settings;

  /// The one place a peer's name lives (APP-19).
  final ContactStore contacts;

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

  /// The message being answered, while a reply is being composed (APP-17).
  /// Transient like [_pendingAttachment]: cleared on send, and never persisted
  /// -- an unsent reply is not a message.
  StoredMessage? _replyingTo;

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
    final replyToId = _replyingTo?.id;
    if (_preparing || _sending) return;
    if (text.isEmpty && attachment == null) return;
    _composer.clear();
    setState(() {
      _sending = true;
      _pendingAttachment = null;
      _replyingTo = null;
    });
    try {
      await widget.session.sendGroupMessage(
        widget.groupId,
        text,
        replyToId: replyToId,
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
          'its member list. This group then disappears from your chats â€” only '
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
      // The contact store alongside the session: naming somebody from this
      // transcript has to relabel every bubble they wrote, the quotes answering
      // them and the member list behind the title -- immediately, not on the
      // next visit (APP-18).
      listenable: Listenable.merge([widget.session, widget.contacts]),
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
                    contacts: widget.contacts,
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(chat.titleFor(widget.session.state.server, widget.contacts)),
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
                if (_replyingTo != null)
                  ReplyComposerBar(
                    replyingTo: _replyingTo!,
                    label: 'Replying to ${_composerAuthorLabel(_replyingTo!)}',
                    onCancel: () => setState(() => _replyingTo = null),
                  ),
                // Directly above the input, below any reply bar, matching where
                // a one-to-one chat puts them: the reply is context for the
                // message, the picture is part of it.
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

  /// Names the author of the message being answered, for the composer bar.
  ///
  /// Always answerable, unlike the quote inside a bubble: the message is in
  /// this transcript right now, which is how it came to be long-pressed.
  String _composerAuthorLabel(StoredMessage message) {
    if (message.mine) return 'yourself';
    final author = message.senderAccountId;
    return author == null
        ? 'this message'
        : personLabel(widget.contacts, author);
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

  /// Long-press menu for one group message: reply (APP-17), save/share a
  /// picture it carries (APP-20), pin/unpin, or delete it from this device
  /// (APP-21). Only the reply leaves this device; the rest are local, and no
  /// other member sees them.
  Future<void> _showMessageActions(
    BuildContext context,
    GroupConversation chat,
    StoredMessage message,
  ) async {
    final isPinned = chat.pinnedMessageIds.contains(message.id);
    // Who wrote it, when that is somebody other than me and is knowable at all:
    // my own messages store no author, and a message from a build predating
    // APP-16's sender field has none to find. Both mean the two entries about
    // the author are simply absent rather than inert (APP-18).
    final author = message.mine ? null : message.senderAccountId;
    final named = author != null && widget.contacts.nameFor(author) != null;
    // Resolved before the sheet is built rather than inside it: a picture
    // still downloading has no file yet, and the entries then have to be
    // absent rather than present and failing.
    final picture = await attachedPictureFile(
      widget.session,
      chatId: widget.groupId,
      message: message,
    );
    if (!context.mounted) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            // First, in ChatScreen's order -- the one action here that
            // produces a message rather than rearranging this device's view.
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Reply'),
              onTap: () => Navigator.of(context).pop('reply'),
            ),
            // The two entries about the *author*, kept together and above the
            // ones about this device's view of the message (APP-18).
            if (author != null) ...[
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(named ? 'Change their name' : 'Name this person'),
                // Said here because the effect is wider than this group, and
                // wider than this account -- the surprise is worth pre-empting.
                subtitle: const Text('Shows in every chat on this device'),
                onTap: () => Navigator.of(context).pop('name'),
              ),
              ListTile(
                leading: const Icon(Icons.chat_bubble_outline),
                title: const Text('Message them directly'),
                onTap: () => Navigator.of(context).pop('message'),
              ),
            ],
            // Then the two about the picture, still above the ones about this
            // device's view of the message. Same wording as ChatScreen's.
            if (picture != null) ...[
              if (maySavePicture(message))
                ListTile(
                  leading: const Icon(Icons.download_outlined),
                  title: const Text('Save to gallery'),
                  subtitle: const Text('Other apps can read it from there'),
                  onTap: () => Navigator.of(context).pop('save'),
                ),
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: const Text('Share picture'),
                onTap: () => Navigator.of(context).pop('share'),
              ),
            ],
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
      case 'reply':
        setState(() => _replyingTo = message);
        break;
      case 'name':
        await _nameAuthor(context, author!);
        break;
      case 'message':
        await _messageDirectly(context, author!);
        break;
      case 'save':
        await savePictureToGallery(context, picture!);
        break;
      case 'share':
        await sharePicture(picture!);
        break;
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

  /// Names the author of a group message, or renames them (APP-18).
  ///
  /// Writes the contact store, never this group: a name is about the person, so
  /// it takes effect in every chat on this device (APP-19). Empty means remove,
  /// exactly as the dialog does everywhere else -- and removing the name leaves
  /// the group, its transcript and its membership untouched.
  ///
  /// The member's home server is recorded alongside the name where the group
  /// knows one. Without it a contact made from a transcript would be an address
  /// nobody can start a chat from later -- the failure the contacts screen calls
  /// "unreachable" and cannot explain.
  Future<void> _nameAuthor(BuildContext context, String accountId) async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) =>
          RenameDialog(initialName: widget.contacts.nameFor(accountId) ?? ''),
    );
    if (result == null) return;
    if (result.isEmpty) {
      await widget.contacts.remove(accountId);
      return;
    }
    await widget.contacts.setName(
      accountId,
      name: result,
      server: _memberServer(accountId),
    );
  }

  /// Opens the one-to-one chat with a group member, starting it if this account
  /// has none yet (APP-18).
  ///
  /// Always from *this* account -- the one whose group this is -- so the
  /// multi-account question the contacts screen exists to ask is already
  /// answered here: they have seen this account's address in this group, and it
  /// is the one identity of mine they can place. Writing from another would
  /// disclose a second address of mine, which cannot be taken back.
  Future<void> _messageDirectly(BuildContext context, String accountId) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    // Already talking to them: the same conversation, not a second one.
    if (!widget.session.state.conversations.containsKey(accountId)) {
      final server = _memberServer(accountId);
      try {
        // The full address where the group knows their server, so a federated
        // member resolves against their own server rather than this one. A bare
        // id is the same fallback a same-server chat has always used.
        await widget.session.startConversation(
          server == null
              ? accountId
              : buildFreizoneAddress(id: accountId, server: server),
        );
      } catch (e) {
        // Federation off, or their server unreachable. Said rather than
        // swallowed: the group stays readable, so silence would look like the
        // action had worked.
        messenger.showSnackBar(
          SnackBar(
            content: Text("Couldn't start the chat: ${describeError(e)}"),
          ),
        );
        return;
      }
      if (!mounted) return;
    }

    navigator.push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          session: widget.session,
          peerAccountId: accountId,
          settings: widget.settings,
          contacts: widget.contacts,
        ),
      ),
    );
  }

  /// A member's home server as this group knows it, or null once they have left
  /// -- the member list is the only place a group records one. `GroupMember`
  /// defaults it to the empty string, which is an absence and not a server.
  String? _memberServer(String accountId) {
    final resolved = widget.session.groupState(widget.groupId)?.resolved;
    final server = resolved?.memberById(accountId)?.server;
    return server == null || server.isEmpty ? null : server;
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
    DateTime? lastDay;
    for (var i = 0; i < chat.messages.length; i++) {
      final message = chat.messages[i];
      final previous = i == 0 ? null : chat.messages[i - 1];
      // The same divider a one-to-one transcript draws, from the same helpers
      // (util/chat_time.dart) -- the two screens show the same thing and a
      // reader moving between them should not have to notice which they are in.
      final day = localDayOf(message.timestamp);
      if (lastDay == null || day != lastDay) {
        bubbles.add(DateDivider(label: dayLabel(day)));
        lastDay = day;
      }
      // Only the first of a run from one author is labelled -- repeating it
      // on every bubble is noise.
      final showAuthor =
          !message.mine &&
          message.senderAccountId != null &&
          previous?.senderAccountId != message.senderAccountId;
      // Only the original knows whether it was a picture -- the reply carries
      // a text snapshot only -- so this is best-effort from local history and
      // simply stays false once the original is gone, exactly as in a
      // one-to-one chat.
      final quoted = message.replyToId == null
          ? null
          : chat.messageById(message.replyToId!);
      bubbles.add(
        _GroupBubble(
          key: _keyFor(message.id),
          message: message,
          showAuthor: showAuthor,
          chat: chat,
          session: widget.session,
          contacts: widget.contacts,
          isPinned: chat.pinnedMessageIds.contains(message.id),
          quotedHasImage:
              quoted != null &&
              quoted.hasAttachments &&
              quoted.attachments.first.isImage,
          onLongPress: () => _showMessageActions(context, chat, message),
          onTapQuote: message.replyToId == null
              ? null
              : () => _scrollToMessage(message.replyToId!),
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
                  '${attachment.width}Ã—${attachment.height} Â· '
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
    required this.contacts,
    required this.isPinned,
    required this.onLongPress,
    this.quotedHasImage = false,
    this.onTapQuote,
  });

  final StoredMessage message;
  final bool showAuthor;

  /// Where the author's name comes from (APP-18/APP-19). Read here rather than
  /// pre-resolved by the caller, because the quote inside the bubble needs the
  /// same lookup for a *different* person than the author line does.
  final ContactStore contacts;

  /// Whether the message this one quotes was a picture (APP-13's stand-in
  /// icon). Best-effort, from local history -- see the caller.
  final bool quotedHasImage;

  /// Scrolls to the quoted original, when this message is a reply.
  final VoidCallback? onTapQuote;

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
                        personLabel(contacts, author),
                        // A long name would otherwise widen every bubble in the
                        // run to the 75% cap and push the text below it around.
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                          // The same function the avatar uses, so a name in the
                          // transcript and a face in the member list are visibly
                          // the same person rather than two unrelated colours.
                          color: avatarColorFor(author),
                        ),
                      ),
                    if (message.isReply) _buildQuote(context, mine, onBubble),
                    if (message.hasAttachments) ...[
                      // The same widget the one-to-one bubble uses, keyed on the
                      // group id: it only ever names the directory the file
                      // lives in, so the download and cache paths need no
                      // group-specific branch at all.
                      //
                      // Given a width here, unlike in a one-to-one bubble, and
                      // that is not cosmetic: [IntrinsicWidth] below asks this
                      // column how wide it wants to be, a tight width is the one
                      // answer a box can give without asking its own child, and
                      // asking further down is what blanked this transcript
                      // outright (see ImageAttachment's spinner). The picture
                      // caps at this width anyway.
                      SizedBox(
                        width: 260,
                        child: ImageAttachment(
                          session: session,
                          chatId: chat.groupId,
                          message: message,
                        ),
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
                    const SizedBox(height: 2),
                    // The same footer a one-to-one bubble carries: the clock
                    // for everybody, the send state only for one's own -- a
                    // group transcript had neither, which left no way to tell
                    // when anything was said.
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          timeLabel(message.timestamp),
                          style: TextStyle(
                            fontSize: 11,
                            color: onBubble.withValues(alpha: 0.7),
                          ),
                        ),
                        // The counts are the summary; who is who is behind a
                        // tap, on purpose (APP-16). A message nobody was owed
                        // a copy of has nothing to list, so it stays inert
                        // rather than opening an empty sheet.
                        if (mine) ...[
                          const SizedBox(width: 6),
                          GestureDetector(
                            onTap: message.deliveries.isEmpty
                                ? null
                                : () => showGroupDeliverySheet(
                                    context,
                                    session: session,
                                    groupId: chat.groupId,
                                    messageId: message.id,
                                    contacts: contacts,
                                  ),
                            child: _statusFor(context, message, onBubble),
                          ),
                        ],
                      ],
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

  /// The quote block above a reply's own text (APP-17) -- ChatScreen's widget,
  /// differing only in that the author has to be worked out rather than being
  /// one of two people.
  Widget _buildQuote(BuildContext context, bool mine, Color onBubble) {
    final author = resolveQuotedAuthor(
      reply: message,
      chat: chat,
      myAccountId: session.state.accountId,
      contacts: contacts,
    );
    return ReplyQuote(
      previewText: message.replyPreviewText ?? '',
      authorLabel: author.label,
      onBubble: onBubble,
      // The author's own colour, so the same person reads the same in a quote,
      // in an author line and in the member list. Not inside my own bubble:
      // that background is the theme's primary, against which a palette colour
      // has no contrast guarantee.
      authorColor: mine || author.accountId == null
          ? null
          : avatarColorFor(author.accountId!),
      quotedHasImage: quotedHasImage,
      onTap: onTapQuote,
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
    // No padding of its own: this sits in the bubble's footer row beside the
    // clock, and anything here would knock the two off the same line.
    return Row(
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
    );
  }

}
