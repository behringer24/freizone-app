// The "remove permanently" confirmation (APP-19), shared so the one wording
// that has to be exactly right exists once -- following block_actions.dart's
// established shape.
//
// This is the only deletion that drops the ratchet session, and therefore the
// only one that can cost a message. So it asks the public account directory
// first and words itself from the answer: three of the four verdicts mean there
// is no sender left to lose anything from, and the fourth says outright that
// nothing was established.
import 'package:flutter/material.dart';

import '../state/app_session.dart';
import '../state/contact_store.dart';
import '../state/conversation.dart';
import '../state/peer_absence.dart';
import '../util/errors.dart';

Future<void> confirmAndRemovePermanently(
  BuildContext context,
  AppSession session,
  ContactStore contacts,
  Conversation convo,
) async {
  final title = convo.titleFor(session.state.server, contacts);
  final messenger = ScaffoldMessenger.of(context);

  // Checked before the dialog, not after: the answer is what the dialog says.
  // A spinner while it happens, because this is a network round trip to a server
  // that may well be the unreachable one.
  final checking = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const AlertDialog(
      content: Row(
        children: [
          SizedBox(
            height: 20,
            width: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 16),
          Expanded(child: Text('Checking whether they are still reachable...')),
        ],
      ),
    ),
  );

  PeerAbsenceVerdict verdict;
  try {
    verdict = await checkPeerAbsence(
      accountId: convo.peerAccountId,
      server: convo.peerServer ?? session.state.server,
    );
  } catch (e) {
    verdict = PeerAbsenceVerdict(
      PeerAbsence.unknown,
      'The check failed (${describeError(e)}), so whether they are gone is '
          'unknown.',
    );
  }
  if (context.mounted) Navigator.of(context).pop();
  await checking;
  if (!context.mounted) return;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Remove $title permanently?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(verdict.detail),
          const SizedBox(height: 12),
          const Text(
            'This removes the chat, its history, its pictures and the '
            'encryption state -- nothing about them is left on this device.',
          ),
          if (verdict.couldStillLoseMessages) ...[
            const SizedBox(height: 12),
            Text(
              // The honest version of the risk, rather than a generic "cannot
              // be undone": what is actually lost is their first messages if
              // they come back, until a re-key completes.
              'Because that could not be established, there is a risk: if they '
              'do write again, their first messages cannot be read until the '
              'encryption has been rebuilt.',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
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
          child: const Text('Remove permanently'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  await session.removeConversationPermanently(convo.peerAccountId);
  messenger.showSnackBar(
    SnackBar(content: Text('$title was removed from this device')),
  );
}
