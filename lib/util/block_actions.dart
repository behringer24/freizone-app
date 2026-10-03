// Shared "block this contact" confirmation -- used from peer_profile_screen
// .dart's Protection section and chat_screen.dart's pending-request bar, so
// the dialog wording and behavior stay in exactly one place. Unblocking
// needs no confirmation and stays a one-line `session.setBlocked(id, false)`
// call at each site.
import 'package:flutter/material.dart';

import '../state/app_session.dart';
import '../state/contact_store.dart';
import '../state/conversation.dart';
import 'report_actions.dart';

/// [canReport] adds the "also report" checkbox (APP-28). Reporting lives
/// *inside* blocking rather than beside it: a standalone report button does
/// nothing the user can see, which is how a feature teaches people to distrust
/// it, while blocking is immediately effective and the report rides along.
/// False where this server does not accept reports, so the box is absent
/// rather than present and failing.
Future<void> confirmAndBlock(
  BuildContext context,
  AppSession session,
  ContactStore contacts,
  Conversation convo, {
  bool canReport = false,
  String? assertedName,
}) async {
  var alsoReport = false;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Block this contact?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'You will stop receiving messages from ${convo.titleFor(session.state.server, contacts)} on this '
              'device -- they are not notified, and this cannot be undone remotely. You can unblock them here '
              'again at any time.',
            ),
            if (canReport)
              CheckboxListTile(
                value: alsoReport,
                onChanged: (value) =>
                    setState(() => alsoReport = value ?? false),
                title: const Text('Also report them to the operator'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
          ],
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
    ),
  );
  if (confirmed != true) return;

  // Blocked first, and regardless of what the report does: it is the half the
  // user can see working, and a failed report must not leave them unblocked.
  await session.setBlocked(convo.peerAccountId, true);
  if (!alsoReport || !context.mounted) return;

  await reportContact(
    context,
    session,
    accountId: convo.peerAccountId,
    peerServer: convo.peerServer ?? '',
    assertedName: assertedName,
  );
}

/// Shared "reset secure session" confirmation -- used from
/// peer_profile_screen.dart's Protection section and chat_list_screen.dart's
/// long-press chat options. A recovery action (not destructive), so it uses
/// default button styling rather than the error color.
Future<void> confirmAndResetSession(
  BuildContext context,
  AppSession session,
  ContactStore contacts,
  Conversation convo,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Reset secure session?'),
      content: Text(
        'Use this only if messages with ${convo.titleFor(session.state.server, contacts)} have '
        'stopped arriving or can no longer be read. Your next message re-establishes '
        'encryption. Message history is kept, and the other side is not notified.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Reset'),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    await session.resetSecureSession(convo.peerAccountId);
  }
}
