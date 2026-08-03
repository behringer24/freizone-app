// Shared "remove this group from this device" confirmation -- used from the
// chat list's long-press options and the group info screen's footer, so the
// wording and the behavior stay in exactly one place.
//
// Purely local removal is only offered where it actually works: for a group
// this account is no longer in, or one that has been dissolved. Forgetting a
// group one is still a member of does not work on its own -- the others keep
// sending, and an arriving message re-creates the transcript for a group whose
// facts are gone: no name, no member list, no info screen, and a composer whose
// send fails with "no group". So while still a member the dialog offers to
// *leave* (or decline) and remove in one step, and for the founder -- who
// cannot leave, since foundership is key possession rather than an assignment --
// it explains that dissolving is the way out.
import 'package:flutter/material.dart';

import '../state/app_session.dart';
import '../state/group_conversation.dart';
import 'errors.dart';

/// Asks, then removes [group] from this device -- leaving or declining first if
/// this account is still in it. Returns true if the group was removed, so a
/// caller sitting on a screen that renders it can leave.
Future<bool> showRemoveGroupDialog(
  BuildContext context,
  AppSession session,
  GroupConversation group,
) async {
  // Taken before the first dialog: after it, this context may be gone.
  final messenger = ScaffoldMessenger.of(context);

  // Read from the fold rather than passed in: the chat list has no resolved
  // state to hand over, and a group whose fact set failed to load has none at
  // all -- which is exactly a case that has to stay removable.
  final resolved = session.groupState(group.groupId)?.resolved;
  final me = resolved?.memberById(session.state.accountId);
  final stillIn = me != null && !(resolved?.dissolved ?? false);

  if (stillIn && me.isFounder) {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Dissolve it first'),
        content: const Text(
          'You founded this group, and a founder cannot leave it -- the group '
          'would be left with an authority outside its own member list. Removing '
          'it here while the others are still in it would only break your own '
          'copy: their messages would keep arriving, with no group left to put '
          'them in.\n\nDissolve the group in its info screen, then remove it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return false;
  }

  // A pending invitation is answered rather than abandoned: declining tells the
  // group, so a moderator can tell a refusal from an unread invitation.
  final pending = stillIn && !me.joined;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        stillIn
            ? (pending ? 'Decline and remove?' : 'Leave and remove?')
            : 'Remove from this device?',
      ),
      content: Text(_bodyFor(stillIn: stillIn, pending: pending)),
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
          child: Text(
            stillIn ? (pending ? 'Decline and remove' : 'Leave and remove') : 'Remove',
          ),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;

  try {
    if (!stillIn) {
      await session.deleteGroup(group.groupId);
    } else if (pending) {
      await session.declineGroupInvite(group.groupId);
    } else {
      await session.leaveAndDeleteGroup(group.groupId);
    }
    return true;
  } catch (e) {
    // Leaving is a signed fact that has to reach the others; if that failed,
    // nothing is removed either -- a half-done removal is the broken state this
    // whole dialog exists to avoid.
    messenger.showSnackBar(SnackBar(content: Text(describeError(e))));
    return false;
  }
}

String _bodyFor({required bool stillIn, required bool pending}) {
  if (!stillIn) {
    return 'This deletes this group, its messages and its pictures from this '
        'device only -- nobody else is affected, and this cannot be undone.';
  }
  if (pending) {
    return 'The group will see that you declined, and you will be removed from '
        'its member list. This group and everything in it then disappears from '
        'this device -- only somebody in the group can invite you again.';
  }
  return 'You will leave the group first -- the others will see that, and you '
      'will stop receiving its messages -- and this group, its messages and its '
      'pictures are then deleted from this device. This cannot be undone, and '
      'rejoining needs a new invitation from a moderator.';
}
