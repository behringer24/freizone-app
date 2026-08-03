import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/ffi/models.dart';
import 'package:freizone/state/group_system_lines.dart';

const _me = 'q0me00000000000000000';
const _ben = 'q1ben0000000000000000';
const _clara = 'q2cla0000000000000000';

final _epoch = DateTime.utc(2026, 8, 3);

GroupMember _member(
  String accountId, {
  String role = 'member',
  bool joined = true,
}) => GroupMember(
  accountId: accountId,
  server: 'https://a.example.org',
  role: role,
  joined: joined,
  addedAt: _epoch,
);

GroupResolved _resolved(
  List<GroupMember> members, {
  String name = 'Wandergruppe',
  String topic = '',
  bool dissolved = false,
  String groupId = 'p2xjx0000000000000000',
}) => GroupResolved(
  groupId: groupId,
  founder: _me,
  name: name,
  topic: topic,
  members: members,
  dissolved: dissolved,
);

List<String> _lines({
  GroupResolved? before,
  required GroupResolved after,
  List<Map<String, dynamic>> events = const [],
}) => groupStateChangeLines(
  before: before,
  after: after,
  myAccountId: _me,
  events: events,
);

void main() {
  test('a group we had no facts about at all produces no lines', () {
    // An invitation arriving, or a group re-appearing after being forgotten
    // locally. Everything is new, so a replay of the whole membership history
    // would say nothing about what just happened.
    expect(
      _lines(
        before: null,
        after: _resolved([
          _member(_me, role: 'founder'),
          _member(_ben, joined: false),
        ]),
      ),
      isEmpty,
    );
  });

  test('a re-delivered snapshot changes nothing and says nothing', () {
    // The same snapshot legitimately arrives from several members.
    final state = _resolved([_member(_me, role: 'founder'), _member(_ben)]);
    expect(_lines(before: state, after: state), isEmpty);
  });

  test('an invitation and its acceptance read as two lines, in that order', () {
    final before = _resolved([_member(_me, role: 'founder')]);
    final after = _resolved([
      _member(_me, role: 'founder'),
      _member(_ben, joined: true),
    ]);
    expect(_lines(before: before, after: after), [
      'q1ben was invited.',
      'q1ben joined the group.',
    ]);
  });

  test('accepting an outstanding invitation is its own line', () {
    final before = _resolved([
      _member(_me, role: 'founder'),
      _member(_ben, joined: false),
    ]);
    final after = _resolved([_member(_me, role: 'founder'), _member(_ben)]);
    expect(_lines(before: before, after: after), ['q1ben joined the group.']);
  });

  test('leaving and being removed are told apart by the batch', () {
    final before = _resolved([_member(_me, role: 'founder'), _member(_ben)]);
    final after = _resolved([_member(_me, role: 'founder')]);

    expect(
      _lines(
        before: before,
        after: after,
        events: [
          {'type': 'leave', 'subject': _ben},
        ],
      ),
      ['q1ben left the group.'],
    );
    expect(
      _lines(
        before: before,
        after: after,
        events: [
          {'type': 'member_remove', 'subject': _ben},
        ],
      ),
      ['q1ben was removed from the group.'],
    );
  });

  test('a membership that ends with no event saying how says only that', () {
    // The fold can arrive here on its own: a late revocation can take away the
    // authority an earlier member_add relied on, and the row goes with it.
    final before = _resolved([_member(_me, role: 'founder'), _member(_ben)]);
    final after = _resolved([_member(_me, role: 'founder')]);
    expect(_lines(before: before, after: after), [
      'q1ben is no longer a member.',
    ]);
  });

  test('this account is addressed in the second person', () {
    final before = _resolved([_member(_clara, role: 'founder'), _member(_me)]);
    final after = _resolved([_member(_clara, role: 'founder')]);
    expect(
      _lines(
        before: before,
        after: after,
        events: [
          {'type': 'member_remove', 'subject': _me},
        ],
      ),
      ['You were removed from the group.'],
    );
  });

  test('a role change is worded by direction, not by the event that caused it', () {
    final asMember = _resolved([
      _member(_me, role: 'founder'),
      _member(_ben),
    ]);
    final asModerator = _resolved([
      _member(_me, role: 'founder'),
      _member(_ben, role: 'moderator'),
    ]);
    expect(_lines(before: asMember, after: asModerator), [
      'q1ben is now moderator.',
    ]);
    expect(_lines(before: asModerator, after: asMember), [
      'q1ben has no special role any more.',
    ]);

    final asAdmin = _resolved([
      _member(_me, role: 'founder'),
      _member(_ben, role: 'admin'),
    ]);
    expect(_lines(before: asAdmin, after: asModerator), [
      'q1ben is now moderator (was admin).',
    ]);
  });

  test('name, topic and dissolution each get a line', () {
    final before = _resolved([_member(_me, role: 'founder')]);
    expect(
      _lines(before: before, after: _resolved([_member(_me, role: 'founder')], name: 'Bergtour')),
      ['The group is now called "Bergtour".'],
    );
    expect(
      _lines(before: before, after: _resolved([_member(_me, role: 'founder')], topic: 'Samstag 8:00')),
      ['The topic is now "Samstag 8:00".'],
    );
    expect(
      _lines(
        before: before,
        after: _resolved([_member(_me, role: 'founder')], dissolved: true),
      ),
      ['The group was dissolved.'],
    );
  });

  test('several changes in one batch all get their line', () {
    final before = _resolved([
      _member(_me, role: 'founder'),
      _member(_ben, joined: false),
    ]);
    final after = _resolved([
      _member(_me, role: 'founder'),
      _member(_ben, role: 'moderator'),
      _member(_clara, joined: false),
    ], name: 'Bergtour');

    expect(_lines(before: before, after: after), [
      'q1ben joined the group.',
      'q1ben is now moderator.',
      'q2cla was invited.',
      'The group is now called "Bergtour".',
    ]);
  });
}
