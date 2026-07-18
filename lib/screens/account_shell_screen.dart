// Wraps ChatListScreen with an account switcher strip -- one avatar per
// connected account (all of which stay live in the background regardless
// of which is shown, see AccountManager), plus "+" to add another.
// ChatListScreen itself is untouched: this just decides which AppSession
// it's handed.
import 'package:flutter/material.dart';

import '../state/account_manager.dart';
import '../state/app_session.dart';
import '../util/address_format.dart';
import 'chat_list_screen.dart';
import 'setup_screen.dart';

class AccountShellScreen extends StatelessWidget {
  const AccountShellScreen({super.key, required this.manager});

  final AccountManager manager;

  Color _avatarColor(String seed) => Colors.primaries[seed.hashCode.abs() % Colors.primaries.length];

  Future<void> _addAccount(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SetupScreen(onRegistered: (state) => manager.addProfile(state)),
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        final active = manager.active;
        return Column(
          children: [
            SafeArea(
              bottom: false,
              child: SizedBox(
                height: 72,
                child: ListView(
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
                              ],
                            ),
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: IconButton.filledTonal(
                        onPressed: () => _addAccount(context),
                        icon: const Icon(Icons.add),
                        tooltip: 'Add account',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: active == null
                  ? const Center(child: Text('No account selected'))
                  : ChatListScreen(session: active),
            ),
          ],
        );
      },
    );
  }
}
