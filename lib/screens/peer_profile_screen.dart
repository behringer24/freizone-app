// A chat peer's profile -- the peer-facing counterpart to
// profile_screen.dart (one's own account): avatar, short id and server
// at a glance, both address forms ready to copy, an editable local
// alias, and -- since there's no "remove" for someone else's account --
// a local block/unblock toggle instead of the danger-zone delete button.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_session.dart';
import '../state/conversation.dart';
import '../util/address_format.dart';
import '../util/avatar_color.dart';
import '../util/block_actions.dart';
import '../util/freizone_address.dart';
import '../widgets/rename_dialog.dart';

class PeerProfileScreen extends StatelessWidget {
  const PeerProfileScreen({
    super.key,
    required this.session,
    required this.peerAccountId,
  });

  final AppSession session;
  final String peerAccountId;

  Future<void> _copy(BuildContext context, String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$label copied to clipboard')));
  }

  /// Same dialog used from the chat screen's own "Edit name" icon --
  /// kept in sync since both are just alternate entry points to the
  /// same purely-local alias.
  Future<void> _showRenameDialog(
    BuildContext context,
    Conversation convo,
  ) async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => RenameDialog(initialName: convo.displayName ?? ''),
    );
    if (result == null) return; // cancelled
    await session.setDisplayName(
      peerAccountId,
      result.isEmpty ? null : result,
    );
  }

  Future<void> _toggleBlock(BuildContext context, Conversation convo) async {
    if (convo.blocked) {
      await session.setBlocked(peerAccountId, false);
      return;
    }
    await confirmAndBlock(context, session, convo);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final convo = session.conversation(peerAccountId);
        if (convo == null) {
          // The conversation was deleted (e.g. from the chat list) while
          // this screen was still open -- nothing left to show.
          return Scaffold(
            appBar: AppBar(title: const Text('Profile')),
            body: const Center(
              child: Text('This conversation no longer exists'),
            ),
          );
        }

        final shortId = convo.peerAccountId.substring(
          0,
          accountIdPrefixLength,
        );
        final peerServer = convo.peerServer ?? session.state.server;
        final shortAddress = shortFreizoneAddress(
          id: convo.peerAccountId,
          server: peerServer,
        );
        final fullAddress = buildFreizoneAddress(
          id: convo.peerAccountId,
          server: peerServer,
        );
        final hasAlias = convo.displayName != null;
        final primaryText = hasAlias ? convo.displayName! : shortId;

        return Scaffold(
          appBar: AppBar(title: Text('Profile $shortId')),
          body: ListView(
            padding: const EdgeInsets.symmetric(vertical: 24),
            children: [
              Center(
                child: CircleAvatar(
                  radius: 48,
                  backgroundColor: avatarColorFor(convo.peerAccountId),
                  child: Text(
                    primaryText
                        .substring(0, primaryText.length >= 2 ? 2 : 1)
                        .toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              if (convo.blocked) ...[
                const SizedBox(height: 12),
                Center(
                  child: Chip(
                    label: const Text('Blocked'),
                    backgroundColor: Theme.of(context).colorScheme.error,
                    labelStyle: TextStyle(
                      color: Theme.of(context).colorScheme.onError,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ] else if (convo.pendingApproval) ...[
                const SizedBox(height: 12),
                Center(
                  child: Chip(
                    label: const Text('Pending request'),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Center(
                child: Text(
                  primaryText,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  hasAlias ? shortAddress : peerServer,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              ListTile(
                title: const Text('Peer name'),
                subtitle: Text(
                  convo.displayName ?? 'No name set -- shows the address instead',
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: 'Edit name',
                  onPressed: () => _showRenameDialog(context, convo),
                ),
              ),
              ListTile(
                title: const Text('Short address'),
                subtitle: Text(shortAddress),
                trailing: IconButton(
                  icon: const Icon(Icons.copy),
                  tooltip: 'Copy short address',
                  onPressed: () =>
                      _copy(context, 'Short address', shortAddress),
                ),
              ),
              ListTile(
                title: const Text('Full address'),
                subtitle: Text(fullAddress),
                trailing: IconButton(
                  icon: const Icon(Icons.copy),
                  tooltip: 'Copy full address',
                  onPressed: () => _copy(context, 'Full address', fullAddress),
                ),
              ),
              if (convo.pendingApproval) ...[
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'This is a pending message request -- accept to start chatting, or block below.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: FilledButton.icon(
                    onPressed: () => session.acceptConversation(peerAccountId),
                    icon: const Icon(Icons.check),
                    label: const Text('Accept'),
                  ),
                ),
              ],
              const SizedBox(height: 32),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Protection',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Freizone has open registration, so blocking is currently the only protection against an '
                  'unwanted contact. It only applies on this device -- the other side is never notified.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: convo.blocked
                    ? FilledButton.icon(
                        onPressed: () => _toggleBlock(context, convo),
                        icon: const Icon(Icons.block_flipped),
                        label: const Text('Unblock'),
                      )
                    : OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Theme.of(context).colorScheme.error,
                          side: BorderSide(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                        onPressed: () => _toggleBlock(context, convo),
                        icon: const Icon(Icons.block),
                        label: const Text('Block this contact'),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
