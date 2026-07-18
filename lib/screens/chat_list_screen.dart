// The post-setup home screen: a WhatsApp/Telegram/Signal-style chat
// list. Rebuilds live off AppSession (ListenableBuilder) -- so a
// message arriving for a conversation that isn't open still updates
// its preview/ordering here, since AppSession owns the SSE stream for
// the whole app lifetime, not just while a chat screen happens to be
// open.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_session.dart';
import '../state/conversation.dart';
import '../util/address_format.dart';
import '../util/errors.dart';
import '../util/unread_dot.dart';
import 'admin_screen.dart';
import 'chat_screen.dart';
import 'invite_screen.dart';

class ChatListScreen extends StatelessWidget {
  const ChatListScreen({super.key, required this.session, this.appBarBottom});

  final AppSession session;

  /// Rendered directly below the "Freizone" title bar, as part of the
  /// same AppBar -- e.g. the account switcher strip (AccountShellScreen).
  /// Using AppBar.bottom rather than stacking a separate widget above
  /// this whole screen keeps the status bar icon styling (which Flutter
  /// derives from the topmost AppBar) correct and avoids a seam/gap
  /// between the two.
  final PreferredSizeWidget? appBarBottom;

  Color _avatarColor(String seed) => Colors.primaries[seed.hashCode.abs() % Colors.primaries.length];

  String _initials(Conversation c) {
    final source = c.title;
    return source.isEmpty ? '?' : source.substring(0, source.length >= 2 ? 2 : 1).toUpperCase();
  }

  String _formatTimestamp(DateTime utc) {
    final dt = utc.toLocal();
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');

    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '${two(dt.hour)}:${two(dt.minute)}';
    }
    final yesterday = now.subtract(const Duration(days: 1));
    if (dt.year == yesterday.year && dt.month == yesterday.month && dt.day == yesterday.day) {
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

  Future<void> _openNewChatSheet(BuildContext context) async {
    final peerAccountId = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _NewChatSheet(session: session),
    );
    if (peerAccountId == null || !context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChatScreen(session: session, peerAccountId: peerAccountId)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Freizone'),
        backgroundColor: Colors.grey.shade100,
        bottom: appBarBottom,
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'copy_id') {
                Clipboard.setData(ClipboardData(text: formatAccountIdForDisplay(session.state.accountId)));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Address copied to clipboard')),
                );
              }
              if (value == 'admin') {
                Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => AdminScreen(session: session)))
                    .then((_) => session.refreshRegistrationPolicy());
              }
              if (value == 'invite') {
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => InviteScreen(session: session)));
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'copy_id',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Copy my address'),
                    Text(
                      session.state.server,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (_canInvite(session)) const PopupMenuItem(value: 'invite', child: Text('Invite')),
              if (session.myRole == 'admin' || session.myRole == 'moderator')
                const PopupMenuItem(value: 'admin', child: Text('Server Admin')),
            ],
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          if (session.pushDistributorMissing) {
            session.pushDistributorMissing = false; // one-time hint, consume it
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'No push notification app found -- install one (e.g. ntfy) to get notified while Freizone is closed.',
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
                  Icon(Icons.chat_bubble_outline, size: 64, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: 16),
                  Text('No conversations yet', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  const Text('Tap the button below to start one'),
                ],
              ),
            );
          }
          return ListView.separated(
            itemCount: conversations.length,
            separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
            itemBuilder: (context, i) {
              final convo = conversations[i];
              return ListTile(
                leading: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    CircleAvatar(
                      backgroundColor: _avatarColor(convo.peerAccountId),
                      child: Text(_initials(convo), style: const TextStyle(color: Colors.white)),
                    ),
                    if (convo.hasUnread) const Positioned(top: -2, right: -2, child: UnreadDot()),
                  ],
                ),
                title: Text(convo.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(convo.lastMessagePreview, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: Text(
                  _formatTimestamp(convo.lastActivityAt),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ChatScreen(session: session, peerAccountId: convo.peerAccountId),
                  ),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openNewChatSheet(context),
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
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _idController.dispose();
    _nameController.dispose();
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
      final convo = await widget.session.startConversation(peerAccountId, displayName: _nameController.text);
      if (!mounted) return;
      Navigator.of(context).pop(convo.peerAccountId);
    } catch (e) {
      setState(() {
        _error = describeError(e);
        _loading = false;
      });
    }
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
          Text('Start a new chat', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          TextField(
            controller: _idController,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Peer account id',
              helperText: 'Full id, or just its first 5 characters if you already know them',
            ),
            enabled: !_loading,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(labelText: 'Name (optional)'),
            enabled: !_loading,
            onSubmitted: (_) => _start(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _loading ? null : _start,
            child: _loading
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Start chat'),
          ),
        ],
      ),
    );
  }
}
