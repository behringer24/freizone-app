// The post-setup home screen: a WhatsApp/Telegram/Signal-style chat
// list. Rebuilds live off AppSession (ListenableBuilder) -- so a
// message arriving for a conversation that isn't open still updates
// its preview/ordering here, since AppSession owns the SSE stream for
// the whole app lifetime, not just while a chat screen happens to be
// open.
import 'package:flutter/material.dart';

import '../state/account_manager.dart';
import '../state/app_session.dart';
import '../state/app_settings.dart';
import '../state/conversation.dart';
import '../util/avatar_color.dart';
import '../util/block_actions.dart';
import '../util/errors.dart';
import '../util/invite_uri.dart';
import '../util/unread_dot.dart';
import '../widgets/qr_scan_button.dart';
import 'admin_screen.dart';
import 'blocked_contacts_screen.dart';
import 'chat_screen.dart';
import 'invite_screen.dart';
import 'my_address_screen.dart';
import 'qr_scan_screen.dart';
import 'settings_screen.dart';

class ChatListScreen extends StatelessWidget {
  const ChatListScreen({
    super.key,
    required this.session,
    required this.settings,
    required this.manager,
    this.appBarBottom,
  });

  final AppSession session;
  final AppSettings settings;

  /// Needed only to forward into SettingsScreen, so changing the push
  /// delivery preference there can re-register push on every live
  /// session immediately (see SettingsScreen._setPushPreference).
  final AccountManager manager;

  /// Rendered directly below the "Freizone" title bar, as part of the
  /// same AppBar -- e.g. the account switcher strip (AccountShellScreen).
  /// Using AppBar.bottom rather than stacking a separate widget above
  /// this whole screen keeps the status bar icon styling (which Flutter
  /// derives from the topmost AppBar) correct and avoids a seam/gap
  /// between the two.
  final PreferredSizeWidget? appBarBottom;

  /// One chat-list row, shared between the "Message requests" section
  /// and the regular list below -- both need the exact same tile, since
  /// the preview text (e.g. a request's greeting, if any) is what
  /// actually answers "who is this."
  Widget _buildConversationTile(BuildContext context, Conversation convo) {
    return ListTile(
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          CircleAvatar(
            backgroundColor: avatarColorFor(convo.peerAccountId),
            child: Text(
              _initials(convo),
              style: const TextStyle(color: Colors.white),
            ),
          ),
          if (convo.hasUnread)
            const Positioned(top: -2, right: -2, child: UnreadDot()),
        ],
      ),
      title: Text(
        convo.titleFor(session.state.server),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        convo.lastMessagePreview,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        _formatTimestamp(convo.lastActivityAt),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              ChatScreen(session: session, peerAccountId: convo.peerAccountId),
        ),
      ),
      onLongPress: () => _showChatOptions(context, convo),
    );
  }

  String _initials(Conversation c) {
    final source = c.titleFor(session.state.server);
    return source.isEmpty
        ? '?'
        : source.substring(0, source.length >= 2 ? 2 : 1).toUpperCase();
  }

  String _formatTimestamp(DateTime utc) {
    final dt = utc.toLocal();
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');

    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '${two(dt.hour)}:${two(dt.minute)}';
    }
    final yesterday = now.subtract(const Duration(days: 1));
    if (dt.year == yesterday.year &&
        dt.month == yesterday.month &&
        dt.day == yesterday.day) {
      return 'Yesterday';
    }
    return '${two(dt.day)}.${two(dt.month)}.${dt.year}';
  }

  /// Whether this device can currently show an "Invite" action: nobody
  /// can on a closed server; on an invite server only admin/moderator
  /// (matches the server-side gate on POST /v1/admin/invites); on an
  /// open server, everyone (no code needed, so there's nothing to gate).
  bool _canInvite(AppSession session) {
    switch (session.registrationPolicy) {
      case 'open':
        return true;
      case 'invite':
        return session.myRole == 'admin' || session.myRole == 'moderator';
      default:
        return false;
    }
  }

  /// Long-press menu for a chat row: clear its history or delete it
  /// entirely, both purely local (the server never stored the history
  /// in the first place). Either action asks for confirmation first,
  /// since there's no undo.
  ///
  /// A still-open, unactioned message request (see [Conversation.
  /// pendingApproval]) gets Accept/Block here instead -- Clear/Delete
  /// don't answer the actual open question ("do I want to talk to this
  /// person"), and deleting would just let them silently ask again the
  /// next time they write (see AppSession.deleteConversation).
  Future<void> _showChatOptions(
    BuildContext context,
    Conversation convo,
  ) async {
    if (convo.pendingApproval) {
      final action = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(convo.titleFor(session.state.server)),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('accept'),
              child: const Text('Accept'),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('block'),
              child: const Text('Block'),
            ),
          ],
        ),
      );
      if (action == null || !context.mounted) return;
      if (action == 'accept') {
        await session.acceptConversation(convo.peerAccountId);
      } else if (action == 'block') {
        await confirmAndBlock(context, session, convo);
      }
      return;
    }

    final action = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(convo.titleFor(session.state.server)),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('clear'),
            child: const Text('Clear chat'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('delete'),
            child: const Text('Delete chat'),
          ),
        ],
      ),
    );
    if (action == null || !context.mounted) return;

    if (action == 'clear') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Clear chat?'),
          content: Text(
            'This permanently deletes the message history with ${convo.titleFor(session.state.server)} on this device. '
            'The conversation itself stays -- this cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Clear'),
            ),
          ],
        ),
      );
      if (confirmed == true)
        await session.clearConversation(convo.peerAccountId);
    } else if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete chat?'),
          content: Text(
            'This permanently removes the conversation with ${convo.titleFor(session.state.server)} and its message history from '
            'this device -- this cannot be undone. ${convo.titleFor(session.state.server)} still exists; you can start a new chat with '
            'them again any time.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (confirmed == true)
        await session.deleteConversation(convo.peerAccountId);
    }
  }

  Future<void> _openNewChatSheet(BuildContext context) async {
    final peerAccountId = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _NewChatSheet(session: session),
    );
    if (peerAccountId == null || !context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            ChatScreen(session: session, peerAccountId: peerAccountId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Freizone',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: isDark ? Colors.white : Theme.of(context).colorScheme.primary,
          ),
        ),
        // A pure-light background (as used in light mode) would glare at
        // night, so dark mode swaps it for a themed dark grey -- the
        // admin/moderator role badges keep their own white circle behind
        // the glyph (see role_icon.dart usage below), so they stay legible
        // either way.
        backgroundColor: isDark
            ? Theme.of(context).colorScheme.surfaceContainerHigh
            : Colors.grey.shade100,
        bottom: appBarBottom,
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'my_address') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => MyAddressScreen(session: session),
                  ),
                );
              }
              if (value == 'admin') {
                Navigator.of(context)
                    .push(
                      MaterialPageRoute(
                        builder: (_) => AdminScreen(session: session),
                      ),
                    )
                    .then((_) => session.refreshRegistrationPolicy());
              }
              if (value == 'invite') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => InviteScreen(session: session),
                  ),
                );
              }
              if (value == 'blocked') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => BlockedContactsScreen(session: session),
                  ),
                );
              }
              if (value == 'settings') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        SettingsScreen(settings: settings, manager: manager),
                  ),
                );
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'my_address',
                child: Text('Invite to chat'),
              ),
              if (_canInvite(session))
                const PopupMenuItem(
                  value: 'invite',
                  child: Text('Invite to server'),
                ),
              if (session.myRole == 'admin' || session.myRole == 'moderator')
                const PopupMenuItem(
                  value: 'admin',
                  child: Text('Server Admin'),
                ),
              const PopupMenuItem(
                value: 'blocked',
                child: Text('Blocked contacts'),
              ),
              const PopupMenuItem(value: 'settings', child: Text('Settings')),
            ],
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          if (session.pushUnavailable) {
            session.pushUnavailable = false; // one-time hint, consume it
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'No push notifications available on this device -- install a UnifiedPush app (e.g. ntfy) or check '
                    'the push delivery setting. Chat still works while Freizone is open.',
                  ),
                  duration: Duration(seconds: 6),
                ),
              );
            });
          }

          final conversations = session.conversations;
          if (conversations.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.chat_bubble_outline,
                    size: 64,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No conversations yet',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text('Tap the button below to start one'),
                ],
              ),
            );
          }

          // Unactioned message requests (first contact from someone with
          // no prior conversation, see Conversation.pendingApproval) are
          // surfaced above everything else, so they're never buried among
          // regular chats -- but rendered with the exact same tile, since
          // the preview text (their greeting, if any) is what actually
          // answers "who is this."
          final pending = conversations.where((c) => c.pendingApproval).toList();
          final regular = conversations
              .where((c) => !c.pendingApproval)
              .toList();

          // A tonal surface a step above the plain background -- Material
          // 3's surfaceContainer* tokens are built exactly for this ("a
          // panel that reads as a distinct area, without a hard border or
          // shadow") and, being derived from the seed color per brightness,
          // land a little darker in light mode and a little lighter in
          // dark mode automatically, rather than needing a manual
          // Brightness check here.
          final requestsSurface = Theme.of(
            context,
          ).colorScheme.surfaceContainerHigh;

          return CustomScrollView(
            slivers: [
              if (pending.isNotEmpty)
                SliverToBoxAdapter(
                  child: Container(
                    color: requestsSurface,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                          child: Text(
                            'Message requests',
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                          ),
                        ),
                        for (final convo in pending) ...[
                          _buildConversationTile(context, convo),
                          if (convo != pending.last)
                            const Divider(height: 1, indent: 72),
                        ],
                        // A visibly heavier rule than the hairline dividers
                        // used between individual rows -- marks this as a
                        // section boundary, not just another list item.
                        Divider(
                          height: 1,
                          thickness: 2,
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              SliverList.separated(
                itemCount: regular.length,
                separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
                itemBuilder: (context, i) =>
                    _buildConversationTile(context, regular[i]),
              ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openNewChatSheet(context),
        // Explicit rather than the Material 3 default (colorScheme.
        // primaryContainer, a much lighter tone) -- matches the darker
        // teal used for the user's own message bubbles in chat_screen.dart.
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        child: const Icon(Icons.chat),
      ),
    );
  }
}

/// Bottom sheet form for starting a new conversation: enter a peer
/// account id, resolve+verify their device (AppSession.startConversation),
/// and pop with the resolved peer id on success.
class _NewChatSheet extends StatefulWidget {
  const _NewChatSheet({required this.session});

  final AppSession session;

  @override
  State<_NewChatSheet> createState() => _NewChatSheetState();
}

class _NewChatSheetState extends State<_NewChatSheet> {
  final _idController = TextEditingController();
  final _nameController = TextEditingController();
  final _greetingController = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _idController.dispose();
    _nameController.dispose();
    _greetingController.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final peerAccountId = _idController.text.trim();
    if (peerAccountId.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final convo = await widget.session.startConversation(
        peerAccountId,
        displayName: _nameController.text,
      );
      final greeting = _greetingController.text.trim();
      if (greeting.isNotEmpty) {
        // Contact is already added either way -- a failed greeting send
        // isn't worth blocking on, since it can just be retried manually
        // from the chat that's about to open.
        try {
          await widget.session.sendMessage(convo.peerAccountId, greeting);
        } catch (_) {
          // ignore
        }
      }
      if (!mounted) return;
      Navigator.of(context).pop(convo.peerAccountId);
    } catch (e) {
      setState(() {
        _error = describeError(e);
        _loading = false;
      });
    }
  }

  /// Pushes the QR scanner and, on a recognizable freizone://chat result
  /// (lib/util/invite_uri.dart), fills the address and name fields --
  /// same pre-fill pattern as the setup wizard's own invite scan.
  Future<void> _scanQr() async {
    final raw = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const QrScanScreen()));
    if (raw == null || !mounted) return;

    final invite = parseChatInviteUri(raw);
    if (invite == null) {
      setState(() => _error = 'That QR code is not a Freizone chat invite');
      return;
    }

    setState(() {
      _idController.text = '${invite.id}*${invite.server}';
      if (invite.name != null) _nameController.text = invite.name!;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Start a new chat',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: TextField(
                  controller: _idController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Peer account id',
                  ),
                  enabled: !_loading,
                ),
              ),
              const SizedBox(width: 12),
              QrScanButton(
                onPressed: _loading ? null : _scanQr,
                tooltip: 'Scan a chat invite QR code',
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Full id, first 5 characters, or a full address like id*server',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(labelText: 'Name (optional)'),
            enabled: !_loading,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _greetingController,
            decoration: const InputDecoration(
              labelText: 'Add a message (optional)',
              helperText:
                  'Sent right away -- helps them recognize who\'s reaching out',
            ),
            enabled: !_loading,
            minLines: 1,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            onSubmitted: (_) => _start(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _loading ? null : _start,
            child: _loading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Start chat'),
          ),
        ],
      ),
    );
  }
}
