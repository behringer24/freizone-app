// What changed about a group, as the lines its transcript shows (APP-16).
//
// Derived by *diffing the folded view* before and after a batch of facts is
// applied, not by translating the facts one by one. That is the only way that
// tells the truth here: authority is decided by the fold, so a late-arriving
// role grant can retroactively admit an act that was refused when it first
// appeared, and a revocation can undo one that had taken effect -- a removed
// member returns. Reading the events alone would report changes that never
// happened and miss the ones that did.
//
// The batch is still consulted, but only to word a change the diff has already
// established: leaving and being removed both delete the member row, and that
// difference is worth a different sentence.
//
// Pure and dependency-free on purpose: the receive path runs in the background
// push isolate too (see group_receive.dart), so nothing here may touch
// AppSession, storage or the UI.
import '../ffi/models.dart';

/// How a member is named in a line: the same leading characters the transcript
/// labels a bubble's author with, so the two read as the same person.
///
/// The name is frozen into the stored line rather than resolved when the line is
/// rendered. A line is a record of a moment -- re-labelling it later with a name
/// somebody has since changed would quietly rewrite history.
String groupMemberLabel(String accountId) =>
    accountId.length > 5 ? accountId.substring(0, 5) : accountId;

/// The lines to append to a group's transcript for the change from [before] to
/// [after].
///
/// [before] is null when this device had no facts about the group at all -- an
/// invitation arriving, or a group re-appearing after being forgotten locally.
/// Then there is no change to narrate: everything is new, and a transcript that
/// opens with a replay of the whole membership history says nothing about what
/// just happened. Empty list.
///
/// [events] is the batch that was applied, used only to distinguish "left" from
/// "was removed". Safe even when it carries facts that were already known (a
/// re-delivered snapshot): a line is only ever produced for a difference the
/// fold actually made.
List<String> groupStateChangeLines({
  required GroupResolved? before,
  required GroupResolved after,
  required String myAccountId,
  List<Map<String, dynamic>> events = const [],
}) {
  if (before == null || before.groupId.isEmpty) return const [];

  final lines = <String>[];
  final wasThere = {for (final m in before.members) m.accountId: m};
  final nowThere = {for (final m in after.members) m.accountId: m};

  // Second person for this account, third for everyone else -- with the verb
  // forms that follow from it, so a line reads the same way in either case
  // ("You were invited." / "q2xjx was invited.").
  bool me(String accountId) => accountId == myAccountId;
  String who(String accountId) =>
      me(accountId) ? 'You' : groupMemberLabel(accountId);
  String was(String accountId) => me(accountId) ? 'were' : 'was';
  String has(String accountId) => me(accountId) ? 'have' : 'has';
  String isNow(String accountId) => me(accountId) ? 'are' : 'is';

  // Gone. Which way it happened is in the batch, if it says so unambiguously.
  for (final accountId in wasThere.keys) {
    if (nowThere.containsKey(accountId)) continue;
    final left = _batchHas(events, 'leave', accountId);
    final removed = _batchHas(events, 'member_remove', accountId);
    if (left && !removed) {
      lines.add('${who(accountId)} left the group.');
    } else if (removed && !left) {
      lines.add('${who(accountId)} ${was(accountId)} removed from the group.');
    } else {
      // Both, or neither -- say only what is certainly true.
      lines.add('${who(accountId)} ${isNow(accountId)} no longer a member.');
    }
  }

  // Arrived, and accepted. An invitation and its acceptance are two facts and
  // read as two lines, which is what makes an outstanding invitation visible.
  for (final entry in nowThere.entries) {
    final accountId = entry.key;
    final now = entry.value;
    final before = wasThere[accountId];
    if (before == null) {
      lines.add('${who(accountId)} ${was(accountId)} invited.');
      if (now.joined) lines.add('${who(accountId)} joined the group.');
      continue;
    }
    if (!before.joined && now.joined) {
      lines.add('${who(accountId)} joined the group.');
    }
    if (before.role != now.role) {
      lines.add(
        _roleLine(
          who: who(accountId),
          has: has(accountId),
          isNow: isNow(accountId),
          from: before.role,
          to: now.role,
        ),
      );
    }
  }

  if (before.name != after.name) {
    lines.add(
      after.name.isEmpty
          ? 'The group name was removed.'
          : 'The group is now called "${after.name}".',
    );
  }
  if (before.topic != after.topic) {
    lines.add(
      after.topic.isEmpty
          ? 'The topic was removed.'
          : 'The topic is now "${after.topic}".',
    );
  }
  if (!before.dissolved && after.dissolved) {
    lines.add('The group was dissolved.');
  }

  return lines;
}

/// A role change, worded by direction rather than by which event carried it --
/// the fold may have arrived at it through a grant, a revocation, or the
/// re-admission of an earlier one.
String _roleLine({
  required String who,
  required String has,
  required String isNow,
  required String from,
  required String to,
}) {
  const rank = {
    'none': 0,
    'member': 1,
    'moderator': 2,
    'admin': 3,
    'founder': 4,
  };
  if (to == 'member') return '$who $has no special role any more.';
  final up = (rank[to] ?? 0) > (rank[from] ?? 0);
  return up ? '$who $isNow now $to.' : '$who $isNow now $to (was $from).';
}

bool _batchHas(
  List<Map<String, dynamic>> events,
  String type,
  String subject,
) => events.any((e) => e['type'] == type && e['subject'] == subject);
