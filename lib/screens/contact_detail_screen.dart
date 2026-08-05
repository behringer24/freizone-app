// One contact, and the multi-account questions only this screen can answer
// (APP-19).
//
// The contact record is device-wide; every action on it is account-specific.
// That split is the whole reason this screen exists: "which of my accounts
// already talk to this person" is a question no per-account screen can even
// ask, and getting it wrong means writing to somebody from an identity they
// cannot place -- a disclosure that cannot be taken back.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/account_manager.dart';
import '../state/app_session.dart';
import '../state/app_settings.dart';
import '../state/contact_store.dart';
import '../util/address_format.dart';
import '../util/errors.dart';
import '../util/freizone_address.dart';
import '../util/server_url.dart';
import '../widgets/peer_avatar.dart';
import '../widgets/rename_dialog.dart';
import 'chat_screen.dart';

class ContactDetailScreen extends StatelessWidget {
  const ContactDetailScreen({
    super.key,
    required this.manager,
    required this.settings,
    required this.contacts,
    required this.accountId,
  });

  final AccountManager manager;
  final AppSettings settings;
  final ContactStore contacts;

  /// The contact's canonical account id -- the key everywhere, and the reason
  /// a hand-typed address is resolved before a contact is made from it.
  final String accountId;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // The store owns the name, the sessions own the chats and the blocks --
      // and both change what this screen says.
      listenable: Listenable.merge([contacts, ...manager.sessions]),
      builder: (context, _) {
        final contact = contacts.contact(accountId);
        if (contact == null) {
          // Removed, here or from a chat's rename dialog while this was open.
          return Scaffold(
            appBar: AppBar(title: const Text('Contact')),
            body: const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('This contact has been removed.'),
              ),
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(title: Text(contact.name)),
          body: ListView(
            padding: const EdgeInsets.symmetric(vertical: 24),
            children: _body(context, contact),
          ),
        );
      },
    );
  }

  List<Widget> _body(BuildContext context, Contact contact) {
    final theme = Theme.of(context);
    final server = contact.server;
    final shortId = accountId.substring(0, accountIdPrefixLength);
    final fullAddress = server == null
        ? formatAccountIdForDisplay(accountId)
        : buildFreizoneAddress(id: accountId, server: server);
    // Every account of mine that already has a chat with them, and every one
    // that could start one. The two are disjoint by construction, which is what
    // keeps "open the chat" distinct from "start a new one".
    final existing = <AppSession>[];
    final available = <AppSession>[];
    for (final session in manager.sessions) {
      if (session.state.conversations.containsKey(accountId)) {
        existing.add(session);
      } else if (!_unreachableFrom(session, server)) {
        available.add(session);
      }
    }

    return [
      Center(child: PeerAvatar(accountId: accountId, radius: 48)),
      const SizedBox(height: 16),
      Center(
        child: Text(
          contact.name,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      const SizedBox(height: 4),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Text(
          server == null ? shortId : shortFreizoneAddress(id: accountId, server: server),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      const SizedBox(height: 24),
      ListTile(
        title: const Text('Name'),
        subtitle: Text(contact.name),
        trailing: IconButton(
          icon: const Icon(Icons.edit_outlined),
          tooltip: 'Change name',
          onPressed: () => _rename(context, contact),
        ),
      ),
      ListTile(
        title: const Text('Address'),
        subtitle: Text(fullAddress),
        trailing: IconButton(
          icon: const Icon(Icons.copy),
          tooltip: 'Copy address',
          onPressed: () => _copy(context, fullAddress),
        ),
      ),

      const SizedBox(height: 16),
      const Divider(),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Text(
          'Chats',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      if (existing.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'None of your accounts is talking to this contact yet.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      for (final session in existing) _chatRow(context, session),

      if (available.isNotEmpty) ...[
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            existing.isEmpty ? 'Start a chat' : 'Start another chat',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            // Said plainly, because the receiving side sees an address rather
            // than a person: which of my identities I write from is a decision,
            // not a detail.
            'They will see the address of whichever account you write from.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        for (final session in available) _startRow(context, session),
      ],

      // Listed last and separately: an account that cannot reach this contact is
      // worth showing with the reason rather than silently omitting, or the
      // promise "any account that isn't talking to them yet" reads as false in
      // exactly the federated setups that motivate having several accounts.
      if (_lockedOut(server) case final locked when locked.isNotEmpty) ...[
        const SizedBox(height: 8),
        for (final session in locked)
          ListTile(
            enabled: false,
            leading: PeerAvatar(accountId: session.state.accountId, radius: 20),
            title: Text(_accountLabel(session)),
            subtitle: const Text(
              'Federation is off on this account\'s server, so it cannot reach '
              'other servers',
            ),
          ),
      ],

      const SizedBox(height: 24),
      const Divider(),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Text(
          'Remove',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          // The narrowness is the feature. It is what makes this safe to use
          // freely, and it is why deleting a chat is a different action in a
          // different place.
          'Removes the name only. Your chats, their history and your pictures '
          'are untouched -- this contact simply shows as an address again.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      const SizedBox(height: 12),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: OutlinedButton.icon(
          onPressed: () => _remove(context, contact),
          icon: const Icon(Icons.person_remove_alt_1_outlined),
          label: const Text('Remove contact'),
        ),
      ),
    ];
  }

  /// Whether [session]'s account could not reach a contact on [server] at all.
  ///
  /// The same check the chat screen uses to replace its composer with an
  /// explanation -- consulted *before* offering the action rather than after it
  /// has been chosen, which is the mistake this screen exists to prevent.
  bool _unreachableFrom(AppSession session, String? server) {
    if (server == null || sameServer(server, session.state.server)) return false;
    return session.federationLockedFor(server);
  }

  List<AppSession> _lockedOut(String? server) => [
    for (final session in manager.sessions)
      if (!session.state.conversations.containsKey(accountId) &&
          _unreachableFrom(session, server))
        session,
  ];

  Widget _chatRow(BuildContext context, AppSession session) {
    final convo = session.state.conversations[accountId]!;
    // Per account, and this is the only place all of them are visible at once --
    // blocking somebody as a private account says nothing about a work one.
    final blocked = convo.blocked;
    return ListTile(
      leading: PeerAvatar(accountId: session.state.accountId, radius: 20),
      title: Text(_accountLabel(session)),
      subtitle: Text(
        blocked
            ? 'Blocked by this account'
            : '${convo.messages.length} message(s)',
      ),
      trailing: Icon(
        blocked ? Icons.block : Icons.chevron_right,
        color: blocked ? Theme.of(context).colorScheme.error : null,
      ),
      onTap: () => _openChat(context, session),
    );
  }

  Widget _startRow(BuildContext context, AppSession session) => ListTile(
    leading: PeerAvatar(accountId: session.state.accountId, radius: 20),
    title: Text(_accountLabel(session)),
    trailing: const Icon(Icons.chat_bubble_outline),
    onTap: () => _startChat(context, session),
  );

  /// One of my own accounts, named the way the account switcher names it.
  String _accountLabel(AppSession session) => shortFreizoneAddress(
    id: session.state.accountId,
    server: session.state.server,
  );

  void _openChat(BuildContext context, AppSession session) {
    // Switching the active account first: the chat list behind this screen is
    // per account, so leaving the chat would otherwise land on a list that does
    // not contain it.
    manager.setActive(session.state.accountId);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          session: session,
          peerAccountId: accountId,
          settings: settings,
          contacts: contacts,
        ),
      ),
    );
  }

  Future<void> _startChat(BuildContext context, AppSession session) async {
    final server = contacts.contact(accountId)?.server;
    final address = server == null
        ? accountId
        : buildFreizoneAddress(id: accountId, server: server);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await session.startConversation(address);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text("Couldn't start the chat: ${describeError(e)}")),
      );
      return;
    }
    if (!context.mounted) return;
    manager.setActive(session.state.accountId);
    navigator.push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          session: session,
          peerAccountId: accountId,
          settings: settings,
          contacts: contacts,
        ),
      ),
    );
  }

  Future<void> _rename(BuildContext context, Contact contact) async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => RenameDialog(initialName: contact.name),
    );
    if (result == null) return;
    if (result.isEmpty) {
      await contacts.remove(accountId);
      return;
    }
    await contacts.setName(accountId, name: result);
  }

  Future<void> _remove(BuildContext context, Contact contact) async {
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${contact.name}?'),
        content: const Text(
          'Only the name goes. Every chat, its history and its pictures stay '
          'exactly as they are, and this contact shows as an address again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await contacts.remove(accountId);
    navigator.pop();
  }

  Future<void> _copy(BuildContext context, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Address copied to clipboard')));
  }
}
