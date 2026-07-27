// One account's profile: avatar (with admin/moderator decoration), its
// short id and server at a glance, both address forms ready to copy,
// and -- as the one destructive action that used to live behind a
// long-press on the account switcher -- permanently deleting it, both
// server-side and on this device.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../net/api_client.dart';
import '../state/account_manager.dart';
import 'backup_screen.dart';
import '../state/app_session.dart';
import '../util/address_format.dart';
import '../util/errors.dart';
import '../util/freizone_address.dart';
import '../util/role_icon.dart';
import '../widgets/peer_avatar.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({
    super.key,
    required this.session,
    required this.manager,
  });

  final AppSession session;
  final AccountManager manager;

  Future<void> _copy(BuildContext context, String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$label copied to clipboard')));
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete account?'),
        content: Text(
          'This permanently deletes ${formatAccountIdForDisplay(session.state.accountId)} -- on the server and on '
          'this device. Anyone who messages you afterward gets an immediate "unknown recipient" error, not '
          'silence. There is no way back to this identity, on this or any other device -- this cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      await manager.deleteAccount(session.state.accountId);
      if (context.mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!context.mounted) return;
      // A 401 here means the server flatly doesn't recognize this
      // device/account -- not a transient error, but a sign the account
      // is already gone or unreachable server-side (its data was reset
      // independently, say). No request this device signs will ever be
      // accepted, so the normal delete can never succeed -- offer the
      // one remaining way to get rid of it: forget it locally only.
      if (e is ApiException && e.statusCode == 401) {
        await _offerOrphanedRemoval(context);
        return;
      }
      // The server was never reached at all (offline, DNS failure,
      // timeout). Unlike the 401 case we learned nothing about the
      // account's real server-side state, so a local-only removal might
      // leave a live remnant behind if the server is only temporarily
      // down. Still offer it -- it's the only way to clear an account
      // whose server is gone for good (a decommissioned test server, say)
      // without first recovering from the seed phrase -- but behind a
      // dialog that spells out that trade-off.
      if (isServerUnreachable(e)) {
        await _offerUnreachableRemoval(context);
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: ${describeError(e)}')),
      );
    }
  }

  Future<void> _offerOrphanedRemoval(BuildContext context) =>
      _confirmLocalRemoval(
        context,
        title: 'Account not recognized by server',
        content:
            'The server rejected this device\'s credentials for ${formatAccountIdForDisplay(session.state.accountId)} -- '
            'this usually means the account no longer exists there. It can never be deleted server-side from here, '
            'since no request this device signs will be accepted. Remove it from this device only?',
      );

  Future<void> _offerUnreachableRemoval(BuildContext context) =>
      _confirmLocalRemoval(
        context,
        title: 'Server not reachable',
        content:
            'Couldn\'t reach ${session.state.server} to delete ${formatAccountIdForDisplay(session.state.accountId)} there. '
            'If the server is only temporarily down, removing the account here now leaves it alive on the server -- '
            'to clear it you would have to recover from your seed phrase and delete again once it is back. If the '
            'server is gone for good, this is the only way to get the account out of your list. Remove from this '
            'device only?',
      );

  /// Confirmation for the local-only escape hatch: on confirmation, forgets
  /// the account on this device (no server delete) and closes the profile
  /// screen. Shared by the two cases where a server-side delete can't be
  /// carried out from here -- [_offerOrphanedRemoval] (a 401) and
  /// [_offerUnreachableRemoval] (an unreachable server) -- which differ only
  /// in their [title] and [content] wording.
  Future<void> _confirmLocalRemoval(
    BuildContext context, {
    required String title,
    required String content,
  }) async {
    final removeLocally = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove from this device'),
          ),
        ],
      ),
    );
    if (removeLocally != true || !context.mounted) return;

    await manager.forgetAccountLocally(session.state.accountId);
    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final accountId = session.state.accountId;
        final shortId = accountId.substring(0, accountIdPrefixLength);
        final server = session.state.server;
        final shortAddress = buildFreizoneAddress(id: shortId, server: server);
        final fullAddress = buildFreizoneAddress(id: accountId, server: server);
        final roleLabel = switch (session.myRole) {
          'admin' => 'Admin',
          'moderator' => 'Moderator',
          _ => null,
        };

        return Scaffold(
          appBar: AppBar(title: const Text('My Profile')),
          body: ListView(
            padding: const EdgeInsets.symmetric(vertical: 24),
            children: [
              Center(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    PeerAvatar(accountId: accountId, radius: 48),
                    if (roleBadgeIcon(session.myRole) case final icon?)
                      Positioned(
                        bottom: -4,
                        right: -4,
                        child: CircleAvatar(
                          radius: 18,
                          backgroundColor: Colors.white,
                          child: Icon(icon, size: 22, color: Colors.black87),
                        ),
                      ),
                  ],
                ),
              ),
              if (roleLabel != null) ...[
                const SizedBox(height: 12),
                Center(
                  child: Chip(
                    label: Text(roleLabel),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Center(
                child: Text(
                  shortId,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  server,
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
              const SizedBox(height: 16),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Security',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.key),
                title: const Text('Recovery phrase'),
                subtitle: const Text(
                  'Back up your account so you can restore it on a new device',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        BackupScreen(rootPriv: session.state.rootPriv),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Danger zone',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                    side: BorderSide(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  onPressed: () => _confirmDelete(context),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete account'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
