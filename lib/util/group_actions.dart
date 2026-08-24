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

import '../ffi/models.dart';
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
            stillIn
                ? (pending ? 'Decline and remove' : 'Leave and remove')
                : 'Remove',
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

/// Asks who to invite to [resolved], then invites them.
///
/// Shared for the same reason the removal dialog above is: it is offered from
/// the group's app bar *and* from the member list behind the title, and the
/// flow is more than a button -- it warns when a group is getting large, it
/// accepts every spelling of an address, and it hands the address over whole
/// rather than resolving it first. Two copies would agree today and disagree
/// in a month, and the half that drifts is the half nobody is looking at.
///
/// Callers decide *who* may invite; this only asks the question.
Future<void> showGroupInvite(
  BuildContext context, {
  required AppSession session,
  required String groupId,
  required GroupResolved resolved,
}) async {
  if (resolved.members.length >= _largeGroupThreshold) {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('This group is getting large'),
        content: Text(
          'It already has ${resolved.members.length} members. Every message is '
          'encrypted and sent separately to each of them, so each additional '
          'member makes sending slower and uses more data for everyone. Invite '
          'anyway?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Invite anyway'),
          ),
        ],
      ),
    );
    if (proceed != true || !context.mounted) return;
  }

  final controller = TextEditingController();
  final entered = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Invite someone'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Address',
          hintText: 'id, short id, id*server or id*local',
        ),
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: const Text('Invite'),
        ),
      ],
    ),
  );
  if (entered == null || entered.isEmpty || !context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  try {
    // Handed over whole: parsing the address (an `id*server` names a member on
    // another server, `id*local` or a bare id/prefix one on ours) and resolving
    // it to the canonical full id belongs with the invite itself, since what
    // gets *signed* has to be that canonical id -- see
    // AppSession.inviteToGroup.
    await session.inviteToGroup(groupId, entered);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(describeError(e))));
  }
}

/// Where a group stops being cheap. There is no group key and no server-side
/// fan-out: every message is encrypted and delivered once per member, and every
/// membership change is its own envelope to each of them. So the cost of one
/// more member is linear in a way a group chat's UI does not hint at, and past
/// roughly this many it is worth saying out loud once rather than letting
/// somebody discover it as slowness.
const _largeGroupThreshold = 50;
