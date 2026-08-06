// A chat peer's profile -- the peer-facing counterpart to
// profile_screen.dart (one's own account): avatar, short id and server
// at a glance, both address forms ready to copy, an editable local
// alias, and -- since there's no "remove" for someone else's account --
// a local block/unblock toggle instead of the danger-zone delete button.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ffi/models.dart';
import '../state/app_session.dart';
import '../state/contact_store.dart';
import '../state/conversation.dart';
import '../util/address_format.dart';
import '../util/block_actions.dart';
import '../util/freizone_address.dart';
import '../widgets/peer_avatar.dart';
import '../widgets/rename_dialog.dart';
import '../widgets/verified_badge.dart';

class PeerProfileScreen extends StatelessWidget {
  const PeerProfileScreen({
    super.key,
    required this.session,
    required this.contacts,
    required this.peerAccountId,
  });

  final AppSession session;

  /// The one place a peer's name lives (APP-19).
  final ContactStore contacts;
  final String peerAccountId;

  Future<void> _copy(BuildContext context, String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$label copied to clipboard')));
  }

  /// Same dialog used from the chat screen's own "Edit name" icon -- kept in
  /// sync since both are just alternate entry points to the same name.
  ///
  /// Writes to the contact store, not to this conversation (APP-19): the name is
  /// the person's, so it applies to every account of mine that talks to them,
  /// and clearing it removes the contact rather than blanking a field. Neither
  /// touches the chat.
  Future<void> _showRenameDialog(
    BuildContext context,
    Conversation convo,
  ) async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) =>
          RenameDialog(initialName: contacts.nameFor(peerAccountId) ?? ''),
    );
    if (result == null) return; // cancelled
    if (result.isEmpty) {
      await contacts.remove(peerAccountId);
      return;
    }
    await contacts.setName(
      peerAccountId,
      name: result,
      server: convo.peerServer,
    );
  }

  Future<void> _toggleBlock(BuildContext context, Conversation convo) async {
    if (convo.blocked) {
      await session.setBlocked(peerAccountId, false);
      return;
    }
    await confirmAndBlock(context, session, contacts, convo);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // The session owns the conversation, the store owns the name -- and this
      // screen is where the name is edited, so it has to see its own change.
      listenable: Listenable.merge([session, contacts]),
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

        final shortId = convo.peerAccountId.substring(0, accountIdPrefixLength);
        final peerServer = convo.peerServer ?? session.state.server;
        final shortAddress = shortFreizoneAddress(
          id: convo.peerAccountId,
          server: peerServer,
        );
        final fullAddress = buildFreizoneAddress(
          id: convo.peerAccountId,
          server: peerServer,
        );
        final assignedName = contacts.nameFor(peerAccountId);
        final hasAlias = assignedName != null;
        final primaryText = hasAlias ? assignedName : shortId;

        return Scaffold(
          appBar: AppBar(title: Text('Profile $shortId')),
          body: ListView(
            padding: const EdgeInsets.symmetric(vertical: 24),
            children: [
              Center(
                child: PeerAvatar(accountId: convo.peerAccountId, radius: 48),
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
                  assignedName ?? 'No name set -- shows the address instead',
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
              // On its own line attached to the *server*, never beside the
              // person's name above -- this attestation is about the server,
              // and reads as being about the person if it sits next to a
              // display name (APP-22).
              _ServerListTile(session: session, server: peerServer),
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
                  'Encryption',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'If messages with this contact stop arriving or can no longer be read, the '
                  'secure session may be out of sync. Resetting re-establishes encryption on your '
                  'next message -- history is kept and the other side is not notified.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: OutlinedButton.icon(
                  onPressed: () =>
                      confirmAndResetSession(context, session, contacts, convo),
                  icon: const Icon(Icons.lock_reset),
                  label: const Text('Reset secure session'),
                ),
              ),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
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

/// The peer's server, with its verified badge once (if) it checks out
/// (SRV-19 / APP-22) -- a small self-contained StatefulWidget rather than
/// converting the whole (Stateless) screen above, since fetching an
/// attestation is the one piece of this screen that isn't already
/// available synchronously off [AppSession]/[ContactStore].
class _ServerListTile extends StatefulWidget {
  const _ServerListTile({required this.session, required this.server});

  final AppSession session;
  final String server;

  @override
  State<_ServerListTile> createState() => _ServerListTileState();
}

class _ServerListTileState extends State<_ServerListTile> {
  AttestationInfo? _attestation;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _ServerListTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A federated peer's server can change identity as this profile stays
    // open (e.g. reopened for a different conversation reusing the route) --
    // re-check rather than keep showing the previous server's badge.
    if (oldWidget.server != widget.server) _load();
  }

  Future<void> _load() async {
    final info = await widget.session.attestationFor(widget.server);
    if (!mounted) return;
    setState(() => _attestation = info);
  }

  @override
  Widget build(BuildContext context) {
    final display = withoutDefaultScheme(widget.server);
    return ListTile(
      title: const Text('Server'),
      subtitle: Row(
        children: [
          Flexible(
            child: Text(display, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (_attestation case final info?) ...[
            const SizedBox(width: 6),
            VerifiedBadge(info: info, server: display),
          ],
        ],
      ),
    );
  }
}
