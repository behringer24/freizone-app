// Wraps ChatListScreen with an account switcher strip -- one avatar per
// connected account (all of which stay live in the background regardless
// of which is shown, see AccountManager), plus "+" to add another.
// Rendered via ChatListScreen's appBarBottom slot (AppBar.bottom) rather
// than stacked above the whole screen as a separate widget -- that keeps
// it seamlessly attached to the "Freizone" title bar (no gap) and lets
// Flutter's usual AppBar-driven status bar icon styling keep working,
// since there's still exactly one AppBar at the top of the widget tree.
import 'package:flutter/material.dart';

import '../state/account_manager.dart';
import '../state/app_session.dart';
import '../util/address_format.dart';
import '../util/role_icon.dart';
import '../util/unread_dot.dart';
import 'chat_list_screen.dart';
import 'setup_screen.dart';

class AccountShellScreen extends StatelessWidget {
  const AccountShellScreen({super.key, required this.manager});

  final AccountManager manager;

  Color _avatarColor(String seed) => Colors.primaries[seed.hashCode.abs() % Colors.primaries.length];

  Future<void> _addAccount(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SetupScreen(
          onRegistered: (state) => manager.addProfile(state),
          existingServers: manager.sessions.map((s) => s.state.server).toList(),
          isAddingAccount: true,
        ),
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context, AppSession session) async {
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
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed == true) {
      await manager.removeProfile(session.state.accountId);
    }
  }

  Widget _buildSwitcher(BuildContext context, AppSession? active) {
    return Container(
      color: Colors.white,
      height: 72,
      // Listens to every session directly (not just `manager`) so a
      // badge -- an incoming message, a role change picked up by
      // AccountManager.setActive's refresh -- updates live without
      // needing an account switch to force a rebuild.
      child: ListenableBuilder(
        listenable: Listenable.merge(manager.sessions),
        builder: (context, _) => ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          children: [
            for (final session in manager.sessions)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: GestureDetector(
                  onTap: () => manager.setActive(session.state.accountId),
                  onLongPress: () => _confirmRemove(context, session),
                  child: CircleAvatar(
                    radius: 24,
                    backgroundColor: _avatarColor(session.state.accountId),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Center(
                          child: Text(
                            session.state.accountId.substring(0, 2).toUpperCase(),
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          ),
                        ),
                        if (session == active)
                          Positioned(
                            bottom: -4,
                            left: 16,
                            right: 16,
                            child: Container(height: 3, color: Theme.of(context).colorScheme.primary),
                          ),
                        if (roleBadgeIcon(session.myRole) case final icon?)
                          Positioned(
                            bottom: -3,
                            right: -3,
                            child: CircleAvatar(
                              radius: 12,
                              backgroundColor: Colors.white,
                              child: Icon(icon, size: 16, color: Colors.black87),
                            ),
                          ),
                        if (session.hasAnyUnread) const Positioned(top: -2, right: -2, child: UnreadDot()),
                      ],
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Tooltip(
                message: 'Add account',
                child: InkWell(
                  borderRadius: BorderRadius.circular(24),
                  onTap: () => _addAccount(context),
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Theme.of(context).colorScheme.outline),
                    ),
                    child: Icon(Icons.add, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        final active = manager.active;
        if (active == null) {
          return const Scaffold(body: Center(child: Text('No account selected')));
        }
        return ChatListScreen(
          session: active,
          appBarBottom: PreferredSize(
            preferredSize: const Size.fromHeight(72),
            child: _buildSwitcher(context, active),
          ),
        );
      },
    );
  }
}
