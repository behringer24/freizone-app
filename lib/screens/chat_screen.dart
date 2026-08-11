// Single-conversation chat screen: WhatsApp/Telegram/Signal-style
// bubbles over a conversation's persisted history (AppSession owns the
// data and the live SSE connection; this screen only renders it and
// forwards sends). Peer resolution now happens once, up front, in
// ChatListScreen's "new chat" flow -- by the time this screen opens,
// the conversation's peer device is already resolved and cached.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../state/app_session.dart';
import '../state/contact_store.dart';
import '../state/app_settings.dart';
import '../state/conversation.dart';
import '../state/outgoing_attachment.dart';
import '../state/receipt_signal.dart';
import '../widgets/attachment_thumbnail.dart';
import '../widgets/date_divider.dart';
import '../widgets/image_attachment.dart';
import '../widgets/link_confirm_sheet.dart';
import '../widgets/message_text.dart';
import '../widgets/new_chat_sheet.dart';
import '../util/block_actions.dart';
import '../util/chat_time.dart';
import '../util/errors.dart';
import '../util/freizone_address.dart';
import '../util/link_detection.dart';
import '../util/message_actions.dart';
import '../util/share_intake.dart';
import '../widgets/pattern_background.dart';
import '../widgets/peer_avatar.dart';
import '../widgets/pinned_message_bar.dart';
import '../widgets/rename_dialog.dart';
import '../widgets/reply_composer_bar.dart';
import '../widgets/reply_quote.dart';
import 'peer_profile_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.session,
    required this.peerAccountId,
    required this.settings,
    required this.contacts,
    this.sharedText,
    this.sharedImagePath,
  });

  final AppSession session;
  final String peerAccountId;
  final AppSettings settings;

  /// The one place a peer's name lives (APP-19).
  final ContactStore contacts;

  /// Text handed over from another app's share (APP-15). Pre-fills the
  /// composer; deliberately not sent, so the user can still edit or abandon it.
  final String? sharedText;

  /// A shared image, already copied into our cache by the platform side. Staged
  /// in the composer like a gallery pick -- and refused if it turns out not to
  /// be a decodable image, since the sending app's mime type isn't trusted.
  final String? sharedImagePath;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();

  /// Set while composing a reply -- shown as a preview bar above the
  /// input, cleared once the reply is sent or dismissed.
  StoredMessage? _replyingTo;

  /// A picture staged for sending, shown as a preview bar above the input
  /// (like [_replyingTo]) until the message is actually sent or the picture
  /// is discarded. Picking one deliberately does NOT send: the caption is
  /// typed afterwards, so firing the message off immediately would make a
  /// caption impossible whenever the picture is chosen first.
  ///
  /// Single-valued rather than a list on purpose -- the wire format already
  /// carries a list of attachments (see MessageContent), but nothing renders
  /// several pictures per message yet, so the picker is locked while one is
  /// staged instead of quietly dropping the extras.
  OutgoingAttachment? _pendingAttachment;

  /// True while a just-picked file is being read and measured. The only
  /// thing that still blocks the send button: an in-flight send doesn't
  /// (see [_send]), but a picture that isn't measured yet genuinely cannot
  /// be handed over.
  bool _preparing = false;

  /// Stable per-message keys, reused across rebuilds, so a quote tap or
  /// the pinned bar can scroll to a message that isn't necessarily near
  /// the bottom of the list.
  final _messageKeys = <String, GlobalKey>{};

  GlobalKey _keyFor(String messageId) =>
      _messageKeys.putIfAbsent(messageId, () => GlobalKey());

  /// Whether the server that would hold this conversation's pictures takes
  /// them at all. Null while unknown -- the button stays available then, so
  /// a slow or unreachable status call doesn't hide a working feature; the
  /// send path re-checks and explains properly if it turns out not to work.
  bool? _attachmentsSupported;

  @override
  void initState() {
    super.initState();
    widget.session.enterConversation(widget.peerAccountId);
    _checkAttachmentSupport();
    if (widget.sharedText != null) {
      _messageController.text = widget.sharedText!;
    }
    if (widget.sharedImagePath != null) {
      unawaited(_stageSharedImage(widget.sharedImagePath!));
    }
  }

  /// Stages an image handed over by another app's share, using exactly the
  /// path a gallery pick takes -- including refusing it when it doesn't decode,
  /// because the sending app's claimed mime type is not evidence.
  ///
  /// It is **normalized first** (see normalizeSharedImage): a gallery pick is
  /// downscaled and re-encoded by image_picker before it reaches here, so a
  /// shared picture has to be brought to the same size and format or it would
  /// go out at full camera resolution.
  ///
  /// Note it is staged, not sent: the size limit that applies belongs to the
  /// *recipient's* server (SRV-07), so it can only be checked once this
  /// conversation is the target -- which the send path already does, complete
  /// with naming the actual limit.
  Future<void> _stageSharedImage(String path) async {
    setState(() => _preparing = true);
    try {
      final normalized = await normalizeSharedImage(path) ?? path;
      final bytes = await File(normalized).readAsBytes();
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

  Future<void> _checkAttachmentSupport() async {
    final convo = widget.session.state.conversations[widget.peerAccountId];
    if (convo == null) return;
    final capability = await widget.session.blobCapabilityFor(convo);
    if (!mounted || capability == null) return;
    setState(() => _attachmentsSupported = capability.enabled);
  }

  /// Sends whatever is currently composed: the typed text, the staged
  /// picture (see [_pendingAttachment]), or both -- the text doubles as the
  /// picture's caption. A picture alone is a valid message, so an empty
  /// composer only blocks the send when nothing is staged either.
  ///
  /// The composer is emptied straight away and is NOT disabled while the
  /// send is in flight (APP-08): the message is already in the transcript as
  /// pending by then, and a failed one stays there with a retry, so there is
  /// nothing that would need restoring into the composer afterwards --
  /// which is what used to make blocking it necessary. Several sends can
  /// therefore overlap; AppSession serializes them per peer, so the ratchet
  /// is never entered twice at once.
  Future<void> _send() async {
    final text = _messageController.text.trim();
    final attachment = _pendingAttachment;
    final replyToId = _replyingTo?.id;
    if (_preparing) return;
    if (text.isEmpty && attachment == null) return;

    _messageController.clear();
    setState(() {
      _replyingTo = null;
      _pendingAttachment = null;
    });

    try {
      await widget.session.sendMessage(
        widget.peerAccountId,
        text,
        replyToId: replyToId,
        attachment: attachment,
      );
    } catch (e) {
      // The bubble already shows it failed and offers a retry; the SnackBar
      // only adds the reason, which a status icon can't convey ("this
      // server doesn't accept pictures", federation turned off, ...).
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Send failed: ${describeError(e)}')),
        );
      }
    }
  }

  /// Handles a Freizone `id*server` address tapped inside a message.
  ///
  /// Nothing here touches the network: resolving a peer contacts *that
  /// peer's server* directly (federation is client-direct, PROTOCOL §9), so a
  /// tap that resolved by itself would hand the user's IP to a server chosen
  /// by whoever wrote the message. Instead this either jumps to a chat that
  /// already exists, or opens the new-chat sheet pre-filled -- where pressing
  /// Start is the user's own decision.
  Future<void> _openTappedAddress(LinkSpan span) async {
    final parsed = parseFreizoneAddress(span.target);
    if (parsed == null) return;

    if (addressIsSelf(span, widget.session.state.accountId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That address is your own account')),
      );
      return;
    }

    // Already a known contact: go straight there. No network, nothing to
    // confirm -- the user has talked to them before.
    for (final convo in widget.session.conversations) {
      if (convo.peerAccountId == parsed.idOrPrefix ||
          convo.peerAccountId.startsWith(parsed.idOrPrefix)) {
        if (convo.peerAccountId == widget.peerAccountId) return; // already open
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChatScreen(
              session: widget.session,
              peerAccountId: convo.peerAccountId,
              contacts: widget.contacts,
              settings: widget.settings,
            ),
          ),
        );
        return;
      }
    }

    final peerAccountId = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          NewChatSheet(
            session: widget.session,
            contacts: widget.contacts,
            initialId: span.target,
          ),
    );
    if (peerAccountId == null || !mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          session: widget.session,
          peerAccountId: peerAccountId,
          contacts: widget.contacts,
          settings: widget.settings,
        ),
      ),
    );
  }

  /// Re-sends a message whose send failed, from the retry chip on its own
  /// bubble. Same error handling as [_send]: the bubble carries the state,
  /// the SnackBar carries the reason.
  Future<void> _retrySend(String messageId) async {
    try {
      await widget.session.retrySend(widget.peerAccountId, messageId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Send failed: ${describeError(e)}')),
        );
      }
    }
  }

  /// Picks a picture from the gallery and stages it in the composer -- it is
  /// sent by [_send], together with whatever caption is typed afterwards.
  ///
  /// image_picker does the downscale and JPEG re-encode natively as part of
  /// picking, so there is no separate "compressing" step to show -- and no
  /// quality prompt, matching what other chat apps do.
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

  /// Hardware-keyboard handling for the composer: when "send with Enter"
  /// is on, a bare Enter/Return sends and is swallowed so no newline is
  /// inserted; Shift+Enter (and the whole feature when off) falls through
  /// to the normal newline behavior. Soft keyboards are handled instead
  /// via the field's textInputAction, so this only matters for physical
  /// keyboards.
  KeyEventResult _handleComposerKey(KeyEvent event, bool enterSends) {
    if (!enterSends || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final isEnter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (isEnter && !HardwareKeyboard.instance.isShiftPressed) {
      _send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
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

  /// Long-press menu for a single message bubble: reply, save/share a picture
  /// it carries (APP-20), pin/unpin (all purely local except reply, whose
  /// reference rides along inside the next message sent), or delete from this
  /// device only.
  Future<void> _showMessageActions(
    BuildContext context,
    Conversation convo,
    StoredMessage message,
  ) async {
    final isPinned = convo.pinnedMessageIds.contains(message.id);
    // Resolved before the sheet is built rather than inside it: a picture
    // still downloading has no file yet, and the entries then have to be
    // absent rather than present and failing.
    final picture = await attachedPictureFile(
      widget.session,
      chatId: widget.peerAccountId,
      message: message,
    );
    if (!context.mounted) return;
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
            // The two about the picture, kept together and above the ones
            // about this device's view of the message.
            if (picture != null) ...[
              if (maySavePicture(message))
                ListTile(
                  leading: const Icon(Icons.download_outlined),
                  title: const Text('Save to gallery'),
                  // Worth saying: this is the one copy that leaves the app's
                  // own storage and becomes readable by other apps.
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
      case 'save':
        await savePictureToGallery(context, picture!);
        break;
      case 'share':
        await sharePicture(picture!);
        break;
      case 'pin':
        await widget.session.pinMessage(widget.peerAccountId, message.id);
        break;
      case 'unpin':
        await widget.session.unpinMessage(widget.peerAccountId, message.id);
        break;
      case 'delete':
        await confirmAndDeleteMessage(
          context,
          widget.session,
          chatId: widget.peerAccountId,
          messageId: message.id,
        );
        break;
    }
  }

  /// Derived from convo's per-conversation markers (see conversation
  /// .dart), not stored per message -- null for a peer's own message, or
  /// one of mine the peer hasn't yet confirmed at all.
  ReceiptStatus? _deliveryStatusFor(Conversation convo, StoredMessage m) {
    if (!m.mine) return null;
    final readUpTo = convo.peerReadUpTo;
    if (readUpTo != null && !m.timestamp.isAfter(readUpTo)) {
      return ReceiptStatus.read;
    }
    final deliveredUpTo = convo.peerDeliveredUpTo;
    if (deliveredUpTo != null && !m.timestamp.isAfter(deliveredUpTo)) {
      return ReceiptStatus.delivered;
    }
    return null;
  }

  List<Widget> _buildItems(BuildContext context, Conversation convo) {
    final items = <Widget>[];
    DateTime? lastDay;
    for (final m in convo.messages) {
      final day = localDayOf(m.displayTime);
      if (lastDay == null || day != lastDay) {
        items.add(DateDivider(label: dayLabel(day)));
        lastDay = day;
      }
      if (m.kind == StoredMessageKind.systemInfo) {
        // Local, non-encrypted info line (e.g. "Secure session was reset") --
        // centered, no bubble, no delivery status, not pin/long-press eligible.
        items.add(_SystemMessage(label: m.text));
        continue;
      }
      // Best-effort: whether the message this one quotes was a picture, which
      // only the *original* knows -- the self-contained reply snapshot on the
      // wire carries text only (see ReplyPreview). So this is resolved from
      // local history and simply stays false once the original is gone,
      // leaving the text-only quote that was rendered before.
      final quoted = m.replyToId == null ? null : convo.messageById(m.replyToId!);
      items.add(
        _MessageBubble(
          key: _keyFor(m.id),
          message: m,
          timeLabel: timeLabel(m.displayTime),
          peerTitle: convo.titleFor(widget.session.state.server, widget.contacts),
          isPinned: convo.pinnedMessageIds.contains(m.id),
          deliveryStatus: _deliveryStatusFor(convo, m),
          session: widget.session,
          peerAccountId: widget.peerAccountId,
          quotedHasImage:
              quoted != null &&
              quoted.hasAttachments &&
              quoted.attachments.first.isImage,
          onLongPress: () => _showMessageActions(context, convo, m),
          onTapQuote: m.replyToId == null
              ? null
              : () => _scrollToMessage(m.replyToId!),
          onRetry: m.hasFailed ? () => _retrySend(m.id) : null,
          onOpenAddress: _openTappedAddress,
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
      builder: (context) => RenameDialog(
        initialName: widget.contacts.nameFor(widget.peerAccountId) ?? '',
      ),
    );
    if (result == null) return; // cancelled
    // Writes the contact, not this conversation (APP-19) -- the same act as
    // renaming from the profile screen, and clearing the field removes the
    // contact rather than blanking a per-chat field. No chat is touched either
    // way.
    if (result.isEmpty) {
      await widget.contacts.remove(widget.peerAccountId);
      return;
    }
    await widget.contacts.setName(
      widget.peerAccountId,
      name: result,
      server: convo.peerServer,
    );
  }

  @override
  void dispose() {
    widget.session.leaveConversation(widget.peerAccountId);
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _openProfile(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PeerProfileScreen(
          session: widget.session,
          peerAccountId: widget.peerAccountId,
          contacts: widget.contacts,
        ),
      ),
    );
  }

  Widget _buildTitle(BuildContext context, Conversation convo) {
    final colorScheme = Theme.of(context).colorScheme;
    final title = convo.titleFor(widget.session.state.server, widget.contacts);
    final shortAddress = shortFreizoneAddress(
      id: convo.peerAccountId,
      server: convo.peerServer ?? widget.session.state.server,
    );
    return InkWell(
      onTap: () => _openProfile(context),
      child: Row(
        children: [
          PeerAvatar(accountId: convo.peerAccountId, radius: 18),
          const SizedBox(width: 12),
          Expanded(
            child: widget.contacts.nameFor(convo.peerAccountId) != null
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.contacts.nameFor(convo.peerAccountId)!,
                        overflow: TextOverflow.ellipsis,
                      ),
                      // Always shown alongside the alias, smaller and muted,
                      // so which server this peer is actually on is never
                      // hidden behind a name someone else could equally claim.
                      Text(
                        shortAddress,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  )
                : Text(title, overflow: TextOverflow.ellipsis),
          ),
          if (widget.session.federationLocked(convo))
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Icon(Icons.lock, size: 18, color: colorScheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: ListenableBuilder(
          // Both: the session owns the conversation, the contact store owns
          // the name shown here -- and this screen can rename from its own
          // edit icon, so it has to see its own change (APP-19).
          listenable: Listenable.merge([widget.session, widget.contacts]),
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
        listenable: Listenable.merge([widget.session, widget.contacts]),
        builder: (context, _) {
          final convo = widget.session.conversation(widget.peerAccountId)!;
          final items = _buildItems(context, convo);
          _scrollToBottom();
          final unreachable =
              widget.session.reachability == ServerReachability.unreachable;
          // A staged picture is a sendable message on its own, so the send
          // button lights up for it even with an empty text field.
          final canSend =
              _messageController.text.trim().isNotEmpty ||
              _pendingAttachment != null;
          // Whether the composer itself is the last branch rendered below.
          // The reply and staged-picture bars belong to the composer, so they
          // follow this one condition instead of each repeating a subset of
          // it -- which is how the reply bar could previously linger above a
          // blocked or federation-locked chat that has no input at all.
          final federationLocked = widget.session.federationLocked(convo);
          // Off the authoritative block set, not the conversation's mirror
          // (AppSession.isBlocked) -- a stale mirror once showed a normal
          // composer for a peer whose incoming messages were being dropped.
          final peerBlocked = widget.session.isBlocked(convo.peerAccountId);
          final composerAvailable =
              !peerBlocked &&
              !convo.pendingApproval &&
              !unreachable &&
              !federationLocked;
          return Column(
            children: [
              PinnedMessageBar(
                chat: convo,
                onJumpToMessage: _scrollToMessage,
              ),
              Expanded(
                child: PatternBackground(
                  child: ListView(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(8),
                    children: items,
                  ),
                ),
              ),
              if (_replyingTo != null && composerAvailable)
                _buildReplyComposerBar(context, convo, _replyingTo!),
              // Directly above the input, below any reply bar: the reply is
              // context for the message, the picture is part of it.
              if (_pendingAttachment != null && composerAvailable)
                _buildAttachmentComposerBar(context, _pendingAttachment!),
              if (peerBlocked)
                _buildBlockedBar(context, convo)
              else if (convo.pendingApproval)
                _buildPendingRequestBar(context, convo)
              else if (unreachable)
                _buildServerOfflineBar(context)
              else if (federationLocked)
                _buildFederationLockedBar(context)
              else
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
                        // Inside the composer's own branch, so every state
                        // that already hides the input (blocked, pending
                        // approval, unreachable, federation-locked) hides
                        // this too, with no extra condition to keep in sync.
                        // Dropped entirely when the receiving server has told
                        // us it stores no attachments -- offering a button
                        // that can only fail is worse than not having one.
                        //
                        // Greyed out while a picture is already staged: one
                        // attachment per message is all that is rendered
                        // today (no multi-image bubble, no gallery view on the
                        // receiving side), so it goes dead until that picture
                        // is sent or dismissed via the preview bar's X,
                        // rather than silently replacing or dropping it.
                        if (_attachmentsSupported != false)
                          IconButton(
                            icon: const Icon(Icons.image_outlined),
                            tooltip: _pendingAttachment != null
                                ? 'One picture per message'
                                : 'Attach a picture',
                            onPressed:
                                _preparing || _pendingAttachment != null
                                ? null
                                : _pickImage,
                          ),
                        Expanded(
                          child: ListenableBuilder(
                            listenable: widget.settings,
                            builder: (context, _) {
                              final enterSends =
                                  widget.settings.enterSendsMessage;
                              return Focus(
                                onKeyEvent: (node, event) =>
                                    _handleComposerKey(event, enterSends),
                                child: TextField(
                                  controller: _messageController,
                                  decoration: InputDecoration(
                                    hintText: 'Message',
                                    filled: true,
                                    fillColor:
                                        colorScheme.surfaceContainerHighest,
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
                                  keyboardType: TextInputType.multiline,
                                  textInputAction: enterSends
                                      ? TextInputAction.send
                                      : TextInputAction.newline,
                                  textCapitalization:
                                      TextCapitalization.sentences,
                                  onChanged: (_) => setState(() {}),
                                  onSubmitted: (_) => _send(),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        CircleAvatar(
                          radius: 24,
                          backgroundColor: canSend
                              ? colorScheme.primary
                              : colorScheme.surfaceContainerHighest,
                          child: IconButton(
                            icon: Icon(
                              Icons.send,
                              color: canSend
                                  ? colorScheme.onPrimary
                                  : colorScheme.onSurfaceVariant,
                            ),
                            onPressed: _preparing ? null : _send,
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

  /// Replaces the composer while this account's home server is unreachable
  /// (see AppSession.reachability). Sending is disabled; the chat history
  /// above stays fully readable. Unlike the blocked bar this is nothing the
  /// user did wrong, so it uses a neutral tone rather than error red, and
  /// offers no action -- reconnection is automatic (the core's backoff),
  /// and the bar clears itself once the server is reachable again.
  Widget _buildServerOfflineBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        color: colorScheme.tertiaryContainer,
        // Match the height of the blocked/pending bars, whose action buttons
        // give them the standard interactive height -- this bar has no
        // button, so pin the same minimum so the composer-replacement bars
        // stay visually consistent.
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: kMinInteractiveDimension,
          ),
          child: Row(
            children: [
              Icon(
                Icons.cloud_off,
                size: 18,
                color: colorScheme.onTertiaryContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "Server unreachable — can't send messages right now",
                  style: TextStyle(color: colorScheme.onTertiaryContainer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Replaces the message composer while this peer is blocked -- sending
  /// (and, per AppSession._handleIncoming, receiving) is disabled until
  /// unblocked from their profile screen.
  Widget _buildBlockedBar(BuildContext context, Conversation convo) {
    final colorScheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        color: colorScheme.errorContainer,
        child: Row(
          children: [
            Icon(Icons.block, size: 18, color: colorScheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'You have blocked this contact',
                style: TextStyle(color: colorScheme.onErrorContainer),
              ),
            ),
            TextButton(
              onPressed: () =>
                  widget.session.setBlocked(widget.peerAccountId, false),
              child: const Text('Unblock'),
            ),
          ],
        ),
      ),
    );
  }

  /// Replaces the message composer when this is a cross-server conversation
  /// and the user's own home server currently has federation disabled: the
  /// peer could not receive anything sent now, so sending is locked (like the
  /// blocked bar, but the user can't lift it -- only a server admin can, via
  /// the admin screen). Already-received messages above stay readable.
  Widget _buildFederationLockedBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        color: colorScheme.surfaceContainerHighest,
        child: Row(
          children: [
            Icon(Icons.lock, size: 18, color: colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Federation is turned off on your server, so you can\'t message '
                'contacts on other servers.',
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Replaces the message composer for an unactioned "message request" --
  /// a first contact from someone with no prior conversation (see
  /// Conversation.pendingApproval). The message history above (including
  /// whatever greeting they sent) stays fully readable for context;
  /// sending is disabled until Accept.
  Widget _buildPendingRequestBar(BuildContext context, Conversation convo) {
    final colorScheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        color: colorScheme.surfaceContainerHigh,
        child: Row(
          children: [
            Expanded(
              child: Text(
                '${convo.titleFor(widget.session.state.server, widget.contacts)} wants to chat with you',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            TextButton(
              onPressed: () => confirmAndBlock(context, widget.session, widget.contacts, convo),
              style: TextButton.styleFrom(foregroundColor: colorScheme.error),
              child: const Text('Block'),
            ),
            FilledButton(
              onPressed: () =>
                  widget.session.acceptConversation(widget.peerAccountId),
              child: const Text('Accept'),
            ),
          ],
        ),
      ),
    );
  }

  /// The "replying to ..." preview shown above the input while composing
  /// a reply -- the bar itself is shared with the group composer (APP-17);
  /// only the heading is this screen's, since two people always have a name.
  Widget _buildReplyComposerBar(
    BuildContext context,
    Conversation convo,
    StoredMessage replyingTo,
  ) {
    return ReplyComposerBar(
      replyingTo: replyingTo,
      label: replyingTo.mine
          ? 'Replying to yourself'
          : 'Replying to ${convo.titleFor(widget.session.state.server, widget.contacts)}',
      onCancel: () => setState(() => _replyingTo = null),
    );
  }

  /// The picture staged for sending, previewed above the input the same way
  /// a reply is -- so choosing a picture composes it into the message rather
  /// than firing it off, leaving room to type a caption. The X discards it
  /// and re-enables the picker button.
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
          // The full picked JPEG, drawn small (and decoded small, see
          // AttachmentThumbnail) so the composer keeps its height no matter
          // what was picked.
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
                // what will actually be uploaded -- worth showing before the
                // send rather than after.
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

/// A centered, non-bubble transcript line for a local system/info message
/// (see StoredMessageKind.systemInfo) -- e.g. "Secure session was reset".
class _SystemMessage extends StatelessWidget {
  const _SystemMessage({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 24),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lock_reset,
                size: 14,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
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
    required this.session,
    required this.peerAccountId,
    required this.onOpenAddress,
    this.quotedHasImage = false,
    this.deliveryStatus,
    this.onTapQuote,
    this.onRetry,
  });

  final StoredMessage message;
  final String timeLabel;

  /// Needed to fetch and decrypt an attachment on demand -- see
  /// AppSession.ensureAttachmentDownloaded.
  final AppSession session;
  final String peerAccountId;

  /// The peer's display title, used to label a quoted message that was
  /// theirs ("Replying to X" reads the same way the composer bar does).
  final String peerTitle;
  final bool isPinned;
  final VoidCallback onLongPress;

  /// Whether the quoted message was a picture, so the quote can say so with
  /// a small camera icon. An interim stand-in for showing the picture itself:
  /// a real thumbnail would have to travel inside the reply (ReplyPreview
  /// carries text only), so this is derived from local history instead and is
  /// therefore best-effort -- false, and the quote looks exactly as it did
  /// before, whenever the original is no longer stored on this device.
  final bool quotedHasImage;

  /// Null for one of the peer's messages, or one of mine the peer hasn't
  /// confirmed at all yet -- see _ChatScreenState._deliveryStatusFor.
  final ReceiptStatus? deliveryStatus;

  /// Scrolls to the quoted original, if this message is a reply and its
  /// target is still in local history -- null (and the quote becomes
  /// untappable) otherwise.
  final VoidCallback? onTapQuote;

  /// Re-runs a failed send (APP-08). Only wired up for a message that
  /// actually failed.
  final VoidCallback? onRetry;

  /// A Freizone `id*server` address was tapped in this message's text
  /// (APP-14). Handled by the screen, since it needs the conversation list
  /// and the navigator -- and deliberately never resolves on its own.
  final void Function(LinkSpan span) onOpenAddress;

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
                  if (message.isReply)
                    ReplyQuote(
                      previewText: message.replyPreviewText ?? '',
                      // Two people, so this is always answerable -- which is
                      // exactly what stops being true in a group (APP-17).
                      authorLabel: message.replyPreviewMine == true
                          ? 'You'
                          : peerTitle,
                      onBubble: onBubble,
                      quotedHasImage: quotedHasImage,
                      onTap: onTapQuote,
                    ),
                  if (message.hasAttachments) ...[
                    ImageAttachment(
                      session: session,
                      chatId: peerAccountId,
                      message: message,
                    ),
                    if (message.text.isNotEmpty) const SizedBox(height: 6),
                  ],
                  // Doubles as the caption when there's an attachment, so an
                  // image with no text renders nothing extra. MessageText
                  // degrades to a plain Text when there is nothing to link.
                  if (message.text.isNotEmpty)
                    MessageText(
                      text: message.text,
                      style: TextStyle(color: onBubble),
                      onOpenLink: (span) => confirmAndOpenLink(context, span),
                      onOpenAddress: onOpenAddress,
                    ),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        timeLabel,
                        style: TextStyle(
                          fontSize: 11,
                          color: onBubble.withValues(alpha: 0.7),
                        ),
                      ),
                      // One slot, three stages (APP-08): on its way out, out
                      // but unconfirmed, or failed. The receipt checkmarks
                      // only mean anything once it actually left, so a
                      // pending or failed message shows its send state here
                      // instead.
                      if (message.isPending) ...[
                        const SizedBox(width: 4),
                        Icon(
                          Icons.schedule,
                          size: 14,
                          color: onBubble.withValues(alpha: 0.7),
                        ),
                      ] else if (message.hasFailed) ...[
                        const SizedBox(width: 6),
                        // Tappable rather than merely marked: without a
                        // persistent outbox (step 2) this retry is the only
                        // way the message ever gets out, so it has to be
                        // reachable from the bubble itself. Rendered as a
                        // chip carrying its own errorContainer colours,
                        // because bare error red would sit on top of the
                        // bubble's primary fill with no guaranteed contrast.
                        Material(
                          color: colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(10),
                          child: InkWell(
                            onTap: onRetry,
                            borderRadius: BorderRadius.circular(10),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.error_outline,
                                    size: 13,
                                    color: colorScheme.onErrorContainer,
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    'Tap to retry',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: colorScheme.onErrorContainer,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ] else if (deliveryStatus != null) ...[
                        const SizedBox(width: 4),
                        Icon(
                          deliveryStatus == ReceiptStatus.read
                              ? Icons.done_all
                              : Icons.done,
                          size: 14,
                          color: onBubble.withValues(alpha: 0.7),
                        ),
                      ],
                    ],
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
