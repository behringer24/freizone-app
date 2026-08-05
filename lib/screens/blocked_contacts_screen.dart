// Lists every peer blocked on this device for the current account (see
// AppSession.setBlocked/blockedPeers) with an Unblock action -- the one
// place blocking is manageable once a peer's own chat/profile screen no
// longer exists (see AppState.blockedPeers' own doc comment on why a
// block deliberately outlives AppSession.deleteConversation).
import 'package:flutter/material.dart';

import '../state/app_session.dart';
import '../state/contact_store.dart';
import '../util/freizone_address.dart';
import '../widgets/peer_avatar.dart';

class BlockedContactsScreen extends StatelessWidget {
  const BlockedContactsScreen({
    super.key,
    required this.session,
    required this.contacts,
  });

  final AppSession session;

  /// Where a blocked peer's name comes from now (APP-19). `BlockedPeer` used to
  /// snapshot one at block time, purely so this screen could show it with no
  /// conversation left -- which is exactly what the store answers, and without
  /// the staleness a second copy had: renaming a contact now shows here too.
  final ContactStore contacts;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // Both, because either can change what a row says: the session owns who is
      // blocked, the store owns what they are called.
      listenable: Listenable.merge([session, contacts]),
      builder: (context, _) {
        final blocked = session.blockedPeers;
        return Scaffold(
          appBar: AppBar(title: const Text('Blocked contacts')),
          body: blocked.isEmpty
              ? Center(
                  child: Text(
                    'No blocked contacts',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: blocked.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, indent: 72),
                  itemBuilder: (context, i) {
                    final peer = blocked[i];
                    final server = peer.peerServer ?? session.state.server;
                    final name = contacts.nameFor(peer.peerAccountId);
                    final title =
                        name ??
                        shortFreizoneAddress(
                          id: peer.peerAccountId,
                          server: server,
                        );
                    return ListTile(
                      leading: PeerAvatar(
                        accountId: peer.peerAccountId,
                        radius: 20,
                      ),
                      title: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: name != null
                          ? Text(
                              shortFreizoneAddress(
                                id: peer.peerAccountId,
                                server: server,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            )
                          : null,
                      trailing: TextButton(
                        onPressed: () =>
                            session.setBlocked(peer.peerAccountId, false),
                        child: const Text('Unblock'),
                      ),
                    );
                  },
                ),
        );
      },
    );
  }
}
