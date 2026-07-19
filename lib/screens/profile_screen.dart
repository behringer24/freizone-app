// One account's profile: avatar (with admin/moderator decoration), its
// short id and server at a glance, both address forms ready to copy,
// and -- as the one destructive action that used to live behind a
// long-press on the account switcher -- removing it from this device.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/account_manager.dart';
import '../state/app_session.dart';
import '../util/address_format.dart';
import '../util/avatar_color.dart';
import '../util/freizone_address.dart';
import '../util/role_icon.dart';

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

  Future<void> _confirmRemove(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove account?'),
        content: Text(
          'This removes ${formatAccountIdForDisplay(session.state.accountId)} from this device -- its message '
          'history and keys are deleted locally. The account itself still exists on the server. This cannot be '
          'undone without a recovery seed.',
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
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    await manager.removeProfile(session.state.accountId);
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
          appBar: AppBar(title: const Text('Profile')),
          body: ListView(
            padding: const EdgeInsets.symmetric(vertical: 24),
            children: [
              Center(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    CircleAvatar(
                      radius: 48,
                      backgroundColor: avatarColorFor(accountId),
                      child: Text(
                        accountId.substring(0, 2).toUpperCase(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
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
              const SizedBox(height: 32),
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
                  onPressed: () => _confirmRemove(context),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Remove account from this device'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
