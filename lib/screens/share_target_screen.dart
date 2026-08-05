// Where a share from another app lands (APP-15).
//
// A plain ACTION_SEND carries no target, and Freizone is multi-account, so the
// share sheet cannot know who this is for. This screen asks: every account's
// conversations, most recent first, grouped by account when there is more than
// one. Picking one opens that chat with the share staged in the composer --
// nothing is sent until the user presses send.
//
// A share that arrived through one of our own sharing shortcuts never gets
// here: the shortcut already names the target (see share_shortcuts.dart).
import 'package:flutter/material.dart';

import '../state/account_manager.dart';
import '../state/app_session.dart';
import '../state/contact_store.dart';
import '../state/app_settings.dart';
import '../state/conversation.dart';
import '../util/freizone_address.dart';
import '../util/share_intake.dart';
import '../widgets/peer_avatar.dart';
import 'chat_screen.dart';

class ShareTargetScreen extends StatelessWidget {
  const ShareTargetScreen({
    super.key,
    required this.manager,
    required this.settings,
    required this.contacts,
    required this.share,
  });

  final AccountManager manager;
  final AppSettings settings;

  /// The one place a peer's name lives (APP-19).
  final ContactStore contacts;
  final IncomingShare share;

  String get _title {
    if (share.imagePath != null) {
      return share.text == null ? 'Send picture to…' : 'Send picture to…';
    }
    return 'Send to…';
  }

  void _open(BuildContext context, AppSession session, Conversation convo) {
    // Replaces this screen rather than stacking on it: after choosing, going
    // back should leave the chat, not offer the picker again.
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          session: session,
          peerAccountId: convo.peerAccountId,
          contacts: contacts,
          settings: settings,
          sharedText: share.text,
          sharedImagePath: share.imagePath,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sessions = manager.orderedSessions;
    final showAccountHeaders = sessions.length > 1;

    final children = <Widget>[];
    if (share.text != null && share.imagePath == null) {
      children.add(_SharePreview(text: share.text!));
    }

    for (final session in sessions) {
      final convos = session.conversations
          // A pending request is someone we haven't accepted yet; sending them
          // a shared link before answering that question would be odd.
          .where((c) => !c.pendingApproval && !c.blocked)
          .toList();
      if (convos.isEmpty) continue;

      if (showAccountHeaders) {
        // The server alone doesn't say *which* account -- this device can
        // (and the switcher strip's own grouping shows) hold several accounts
        // on the very same server. The full own address (short id*server)
        // is the one label that always disambiguates.
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              shortFreizoneAddress(
                id: session.state.accountId,
                server: session.state.server,
              ),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        );
      }
      for (final convo in convos) {
        children.add(
          ListTile(
            leading: PeerAvatar(accountId: convo.peerAccountId, radius: 20),
            title: Text(
              convo.titleFor(session.state.server, contacts),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _open(context, session, convo),
          ),
        );
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: children.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No chats to share into yet. Start a conversation first, '
                  'then this will list it here.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(children: children),
    );
  }
}

/// A glance at what is about to be sent, so the user can tell they picked the
/// right thing before choosing a recipient. Only for text -- an image is shown
/// in the composer once a chat is open, where it can also be removed again.
class _SharePreview extends StatelessWidget {
  const _SharePreview({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      color: colorScheme.surfaceContainerHigh,
      child: Text(
        text,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}
