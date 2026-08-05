// A group's members and moderation (APP-16).
//
// Server administration lives behind the chat list's overflow menu because it
// is server-wide and spans many accounts. Group moderation is the opposite:
// every action is *about one member*, so it belongs where the members are
// listed, in a row's own long-press menu -- the same pattern the chat list
// uses for a conversation.
//
// Nothing here decides what is allowed. The visible actions are gated by this
// account's own rank so the UI does not offer what would be refused, but the
// refusing happens in the fold, independently on every member's device: an
// unauthorized event simply has no effect anywhere.
import 'package:flutter/material.dart';

import '../ffi/models.dart';
import '../state/app_session.dart';
import '../state/contact_store.dart';
import '../util/errors.dart';
import '../util/group_actions.dart';
import '../util/person_label.dart';
import '../util/role_icon.dart';
import '../widgets/peer_avatar.dart';

class GroupInfoScreen extends StatelessWidget {
  const GroupInfoScreen({
    super.key,
    required this.session,
    required this.groupId,
    required this.contacts,
  });

  final AppSession session;
  final String groupId;

  /// Where a member's name comes from (APP-18/APP-19). The member list is the
  /// second place a group has to agree with the transcript about who somebody
  /// is -- the first being the transcript's own author lines.
  final ContactStore contacts;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // Renaming somebody from the transcript behind this screen has to reach
      // this list too.
      listenable: Listenable.merge([session, contacts]),
      builder: (context, _) {
        final resolved = session.groupState(groupId)?.resolved;
        if (resolved == null) {
          // A transcript can exist before this device holds any facts about the
          // group: delivery is unordered, so a message can overtake the snapshot
          // that introduces it. Nothing to show yet -- but the way out of the
          // state has to be reachable, or the chat is a dead end.
          return Scaffold(
            appBar: AppBar(title: const Text('Group info')),
            body: ListView(
              children: [
                const ListTile(
                  leading: Icon(Icons.hourglass_empty),
                  title: Text('This group\'s details are not here yet'),
                  subtitle: Text(
                    'Its member list and name arrive from another member. Until '
                    'they do, there is nothing to show.',
                  ),
                ),
                const Divider(height: 1),
                _removeTile(context),
              ],
            ),
          );
        }
        final me = resolved.memberById(session.state.accountId);

        return Scaffold(
          appBar: AppBar(title: const Text('Group info')),
          body: ListView(
            children: [
              _header(context, resolved, me),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  '${resolved.members.length} member(s)',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
              for (final member in _ordered(resolved))
                _memberTile(context, resolved, me, member),
              const Divider(height: 1),
              _footer(context, resolved, me),
            ],
          ),
        );
      },
    );
  }

  /// Highest rank first, then alphabetical -- so who runs the group is
  /// answered by the top of the list rather than by hunting for badges.
  List<GroupMember> _ordered(GroupResolved resolved) {
    const rank = {'founder': 0, 'admin': 1, 'moderator': 2, 'member': 3};
    final list = [...resolved.members];
    list.sort((a, b) {
      final byRank = (rank[a.role] ?? 9).compareTo(rank[b.role] ?? 9);
      return byRank != 0 ? byRank : a.accountId.compareTo(b.accountId);
    });
    return list;
  }

  Widget _header(
    BuildContext context,
    GroupResolved resolved,
    GroupMember? me,
  ) {
    final canEdit = me?.isModerator ?? false;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          PeerAvatar(accountId: resolved.groupId, radius: 28),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  resolved.name.isEmpty ? '(unnamed group)' : resolved.name,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  resolved.topic.isEmpty ? 'No topic' : resolved.topic,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (canEdit)
            IconButton(
              tooltip: 'Edit name and topic',
              onPressed: () => _editMeta(context, resolved),
              icon: const Icon(Icons.edit_outlined),
            ),
        ],
      ),
    );
  }

  Widget _memberTile(
    BuildContext context,
    GroupResolved resolved,
    GroupMember? me,
    GroupMember member,
  ) {
    final isMe = member.accountId == session.state.accountId;
    final badge = roleBadgeIcon(member.role);
    final actions = _actionsFor(me, member);

    return ListTile(
      leading: PeerAvatar(accountId: member.accountId, radius: 20),
      title: Row(
        children: [
          if (badge != null)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Icon(
                badge,
                size: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          Expanded(
            child: Text(
              // The same label the transcript's author lines carry, so a name
              // here and a bubble there read as one person (APP-18). The full
              // 21-character id it replaces belonged to no question this screen
              // answers -- it is not copyable from here and never was.
              isMe ? 'You' : personLabel(contacts, member.accountId),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      subtitle: Text(
        member.joined
            ? member.role
            : '${member.role} · invited, not accepted yet',
      ),
      trailing: actions.isEmpty
          ? null
          : PopupMenuButton<String>(
              onSelected: (action) => _run(context, action, member),
              itemBuilder: (context) => [
                for (final entry in actions.entries)
                  PopupMenuItem(value: entry.key, child: Text(entry.value)),
              ],
            ),
    );
  }

  /// What this account may do to [member]. The rule the protocol states in one
  /// sentence -- you may only act against strictly lower ranks -- so a
  /// moderator sees nothing for another moderator, and nobody sees anything
  /// for the founder.
  Map<String, String> _actionsFor(GroupMember? me, GroupMember member) {
    if (me == null || member.accountId == session.state.accountId) return {};
    if (member.isFounder) return {};

    final actions = <String, String>{};
    // Only the founder appoints admins: nothing else outranks admin.
    if (me.isFounder && !member.isAdmin) {
      actions['grant_admin'] = 'Make admin';
    }
    if (me.isFounder && member.isAdmin) {
      actions['revoke_admin'] = 'Remove as admin';
    }
    // Moderator is an admin's to give.
    if (me.isAdmin && !member.isAdmin) {
      actions[member.role == 'moderator' ? 'revoke_moderator' : 'grant_moderator'] =
          member.role == 'moderator' ? 'Remove as moderator' : 'Make moderator';
    }
    // Removing needs at least moderator, and a strictly lower target.
    final canRemove = me.isFounder ||
        (me.isAdmin && !member.isAdmin) ||
        (me.isModerator && !member.isModerator);
    if (canRemove) actions['remove'] = 'Remove from group';
    return actions;
  }

  Future<void> _run(
    BuildContext context,
    String action,
    GroupMember member,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      switch (action) {
        case 'grant_admin':
          await session.setGroupRole(groupId, member.accountId, 'admin', grant: true);
        case 'revoke_admin':
          await session.setGroupRole(groupId, member.accountId, 'admin', grant: false);
        case 'grant_moderator':
          await session.setGroupRole(groupId, member.accountId, 'moderator', grant: true);
        case 'revoke_moderator':
          await session.setGroupRole(groupId, member.accountId, 'moderator', grant: false);
        case 'remove':
          if (!context.mounted) return;
          final confirmed = await _confirm(
            context,
            title: 'Remove from group?',
            body: 'They will stop receiving this group\'s messages. Their copy '
                'of the history stays on their device -- end-to-end encryption '
                'leaves no way to take it back.',
            action: 'Remove',
          );
          if (confirmed != true) return;
          await session.removeFromGroup(groupId, member.accountId);
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(e))));
    }
  }

  Widget _footer(
    BuildContext context,
    GroupResolved resolved,
    GroupMember? me,
  ) {
    if (resolved.dissolved) {
      return Column(
        children: [
          const ListTile(title: Text('This group has been dissolved.')),
          // The only thing still worth doing here -- and without it a dissolved
          // group would sit in the chat list for good.
          _removeTile(context),
        ],
      );
    }
    final canInvite = me?.isModerator ?? false;
    return Column(
      children: [
        if (canInvite)
          ListTile(
            leading: const Icon(Icons.person_add_alt),
            title: const Text('Invite someone'),
            onTap: () => _invite(context, resolved),
          ),
        // The founder cannot leave -- "founder" is key possession, not an
        // assignment, so leaving would leave an authority outside the member
        // list. Dissolving is the honest equivalent.
        if (me != null && me.isFounder)
          ListTile(
            leading: Icon(
              Icons.delete_forever,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(
              'Dissolve group',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            onTap: () => _dissolve(context),
          )
        else if (me != null)
          ListTile(
            leading: Icon(
              Icons.logout,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(
              'Leave group',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            onTap: () => _leave(context),
          ),
        // Local only, and offered even while still a member: "I don't want this
        // on this device" is a different question from "am I in this group",
        // and the dialog says plainly that a group one is still in comes back.
        _removeTile(context),
      ],
    );
  }

  Widget _removeTile(BuildContext context) => ListTile(
    leading: const Icon(Icons.delete_outline),
    title: const Text('Remove from this device'),
    onTap: () => _remove(context),
  );

  Future<void> _remove(BuildContext context) async {
    final chat = session.group(groupId);
    if (chat == null) return;
    final navigator = Navigator.of(context);
    if (await showRemoveGroupDialog(context, session, chat)) {
      // Both this screen and the group transcript underneath it render a group
      // that no longer exists, so unwind past both.
      navigator.popUntil((route) => route.isFirst);
    }
  }

  /// Where a group stops being cheap. There is no group key and no server-side
  /// fan-out: every message is encrypted and delivered once per member, and every
  /// membership change is its own envelope to each of them. So the cost of one
  /// more member is linear in a way a group chat's UI does not hint at, and past
  /// roughly this many it is worth saying out loud once rather than letting
  /// somebody discover it as slowness.
  static const _largeGroupThreshold = 50;

  Future<void> _invite(BuildContext context, GroupResolved resolved) async {
    if (resolved.members.length >= _largeGroupThreshold) {
      final proceed = await _confirm(
        context,
        title: 'This group is getting large',
        body:
            'It already has ${resolved.members.length} members. Every message is '
            'encrypted and sent separately to each of them, so each additional '
            'member makes sending slower and uses more data for everyone. Invite '
            'anyway?',
        action: 'Invite anyway',
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
      // Handed over whole: parsing the address (an `id*server` names a member
      // on another server, `id*local` or a bare id/prefix one on ours) and
      // resolving it to the canonical full id belongs with the invite itself,
      // since what gets *signed* has to be that canonical id -- see
      // AppSession.inviteToGroup.
      await session.inviteToGroup(groupId, entered);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(e))));
    }
  }

  Future<void> _editMeta(BuildContext context, GroupResolved resolved) async {
    final nameController = TextEditingController(text: resolved.name);
    final topicController = TextEditingController(text: resolved.topic);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Name and topic'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: topicController,
              decoration: const InputDecoration(labelText: 'Topic'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await session.setGroupMeta(
        groupId,
        name: nameController.text.trim(),
        topic: topicController.text.trim(),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(e))));
    }
  }

  Future<void> _leave(BuildContext context) async {
    final confirmed = await _confirm(
      context,
      title: 'Leave this group?',
      body: 'You will stop receiving its messages. Rejoining needs a new '
          'invitation from a moderator.',
      action: 'Leave',
    );
    if (confirmed != true || !context.mounted) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await session.leaveGroup(groupId);
      navigator.pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(e))));
    }
  }

  Future<void> _dissolve(BuildContext context) async {
    final confirmed = await _confirm(
      context,
      title: 'Dissolve this group?',
      body: 'Nobody will be able to send into it again. Everyone keeps their '
          'copy of the history -- end-to-end encryption leaves no way to take '
          'it back. This cannot be undone.',
      action: 'Dissolve',
    );
    if (confirmed != true || !context.mounted) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await session.dissolveGroup(groupId);
      navigator.pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(e))));
    }
  }

  /// Everything here that cannot be undone asks first, per CLAUDE.md's UX rule.
  Future<bool?> _confirm(
    BuildContext context, {
    required String title,
    required String body,
    required String action,
  }) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(action),
        ),
      ],
    ),
  );
}
