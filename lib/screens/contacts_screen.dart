// The people this device knows, by name (APP-19).
//
// Device-wide, not per account: this is the one screen in the app that is not
// about the account currently selected. Every *action* on a contact still is --
// which chat, which block -- and that is what the detail screen is for.
import 'package:flutter/material.dart';

import '../state/account_manager.dart';
import '../state/app_settings.dart';
import '../state/contact_store.dart';
import '../util/address_format.dart';
import '../util/freizone_address.dart';
import '../widgets/add_contact_sheet.dart';
import '../widgets/peer_avatar.dart';
import 'contact_detail_screen.dart';

class ContactsScreen extends StatelessWidget {
  const ContactsScreen({
    super.key,
    required this.manager,
    required this.settings,
    required this.contacts,
  });

  /// Every account on this device, because a contact belongs to none of them:
  /// the detail screen answers "which of my accounts talk to this person".
  final AccountManager manager;
  final AppSettings settings;
  final ContactStore contacts;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: contacts,
      builder: (context, _) {
        final all = contacts.contacts;
        return Scaffold(
          appBar: AppBar(title: const Text('Contacts')),
          floatingActionButton: FloatingActionButton(
            onPressed: () => _add(context),
            tooltip: 'Add a contact',
            child: const Icon(Icons.person_add_alt),
          ),
          body: Column(
            children: [
              if (contacts.pendingReport case final report?)
                _ImportNotice(report: report, onDismiss: contacts.dismissReport),
              Expanded(
                child: all.isEmpty
                    ? _empty(context)
                    : ListView.separated(
                        itemCount: all.length,
                        separatorBuilder: (_, _) =>
                            const Divider(height: 1, indent: 72),
                        itemBuilder: (context, i) => _row(context, all[i]),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _empty(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'No contacts yet',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          // Said rather than left to be inferred: people are surprised that
          // sharing a group with somebody does not list them here. It is
          // deliberate -- otherwise this fills with every account this device
          // has ever been in a room with, for every account at once.
          Text(
            'Naming somebody in a chat or a group adds them here. Being in a '
            'group with somebody does not.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _row(BuildContext context, Contact contact) {
    final server = contact.server;
    return ListTile(
      leading: PeerAvatar(accountId: contact.accountId, radius: 20),
      title: Text(
        contact.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      // The address stays visible under every name. A name is what one person
      // decided to call another; the address is the thing that identifies them,
      // and somebody else could equally claim the name.
      subtitle: Text(
        server == null
            ? formatAccountIdForDisplay(contact.accountId)
            : shortFreizoneAddress(id: contact.accountId, server: server),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ContactDetailScreen(
            manager: manager,
            settings: settings,
            contacts: contacts,
            accountId: contact.accountId,
          ),
        ),
      ),
    );
  }

  Future<void> _add(BuildContext context) async {
    final server = manager.active?.state.server;
    if (server == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AddContactSheet(contacts: contacts, fallbackServer: server),
    );
  }
}

/// What the one-time import did, shown once and dismissed for good.
///
/// Only ever raised for a real disagreement (see ContactStore.importAliases):
/// two of this device's accounts that called one address different things is a
/// decision only the user can settle, and quietly keeping one would discard a
/// name they chose.
class _ImportNotice extends StatelessWidget {
  const _ImportNotice({required this.report, required this.onDismiss});

  final ContactImportReport report;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Names are now shared across your accounts',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  report.collisions.length == 1
                      ? 'One address had two different names. The one below is '
                            'kept -- rename it here if you would rather have '
                            'the other.'
                      : '${report.collisions.length} addresses had more than '
                            'one name. The ones below are kept -- rename them '
                            'here if you would rather have the others.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                for (final collision in report.collisions)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '${collision.kept} — also called '
                      '${collision.discarded.join(', ')}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Dismiss',
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}
