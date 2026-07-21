// Shared "block this contact" confirmation -- used from peer_profile_screen
// .dart's Protection section and chat_screen.dart's pending-request bar, so
// the dialog wording and behavior stay in exactly one place. Unblocking
// needs no confirmation and stays a one-line `session.setBlocked(id, false)`
// call at each site.
import 'package:flutter/material.dart';

import '../state/app_session.dart';
import '../state/conversation.dart';

Future<void> confirmAndBlock(
  BuildContext context,
  AppSession session,
  Conversation convo,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Block this contact?'),
      content: Text(
        'You will stop receiving messages from ${convo.titleFor(session.state.server)} on this '
        'device -- they are not notified, and this cannot be undone remotely. You can unblock them here '
        'again at any time.',
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
          child: const Text('Block'),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    await session.setBlocked(convo.peerAccountId, true);
  }
}
