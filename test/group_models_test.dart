// The Dart half of the group FFI boundary (APP-16 phase 3): the shapes the
// native core hands back. The logic they describe is tested in Go
// (native/group_test.go and freizone-server's pkg/group) -- what matters here
// is that this side reads it faithfully and stays tolerant of what an older
// core might omit.
import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/ffi/models.dart';

void main() {
  Map<String, dynamic> resolvedJson() => {
    'group_id': 'p2xjx0000000000000000',
    'founder': 'qfounder000000000000a',
    'name': 'Wandergruppe',
    'topic': 'Samstag 9 Uhr',
    'dissolved': false,
    'state_hash': 'abc123',
    'members': [
      {
        'account_id': 'qfounder000000000000a',
        'server': 'https://a.example.org',
        'role': 'founder',
        'joined': true,
        'added_at': '2026-08-02T12:00:00.000Z',
      },
      {
        'account_id': 'qinvitee000000000000b',
        'server': 'https://b.example.org',
        'role': 'member',
        'joined': false,
        'added_at': '2026-08-02T12:01:00.000Z',
      },
    ],
  };

  group('GroupResolved', () {
    test('reads the folded view the core returns', () {
      final resolved = GroupResolved.fromJson(resolvedJson());
      expect(resolved.groupId, 'p2xjx0000000000000000');
      expect(resolved.name, 'Wandergruppe');
      expect(resolved.topic, 'Samstag 9 Uhr');
      expect(resolved.dissolved, isFalse);
      expect(resolved.members, hasLength(2));
      expect(resolved.roleOf('qfounder000000000000a'), 'founder');
      // Someone who was removed, or never a member, is not an error.
      expect(resolved.roleOf('qstranger00000000000c'), 'none');
    });

    test('an invitee is a member but not joined', () {
      // The distinction the whole invite flow rests on: they are listed, so a
      // moderator sees the invitation is outstanding, but nothing is sent to
      // them until they accept.
      final invitee = GroupResolved.fromJson(
        resolvedJson(),
      ).memberById('qinvitee000000000000b')!;
      expect(invitee.role, 'member');
      expect(invitee.joined, isFalse);
      expect(invitee.server, 'https://b.example.org');
    });

    test('rank helpers follow the precedence the protocol defines', () {
      GroupMember withRole(String role) => GroupMember.fromJson({
        'account_id': 'q1',
        'server': 's',
        'role': role,
        'joined': true,
        'added_at': '2026-08-02T12:00:00.000Z',
      });

      // A founder is also an admin and a moderator, an admin is also a
      // moderator -- the UI gates on "at least this rank", not equality.
      expect(withRole('founder').isFounder, isTrue);
      expect(withRole('founder').isAdmin, isTrue);
      expect(withRole('founder').isModerator, isTrue);
      expect(withRole('admin').isFounder, isFalse);
      expect(withRole('admin').isModerator, isTrue);
      expect(withRole('moderator').isAdmin, isFalse);
      expect(withRole('moderator').isModerator, isTrue);
      expect(withRole('member').isModerator, isFalse);
    });

    test('an empty view is valid -- a group only just heard of', () {
      final empty = GroupResolved.fromJson(const {});
      expect(empty.groupId, isEmpty);
      expect(empty.members, isEmpty);
      expect(empty.roleOf('anyone'), 'none');
    });
  });

  group('GroupStateResult', () {
    test('keeps the state blob opaque and unmodelled', () {
      final result = GroupStateResult.fromJson({
        'group_id': 'p2xjx0000000000000000',
        'state': {
          'events': [
            {'type': 'genesis'},
          ],
        },
        'state_hash': 'abc123',
        'resolved': resolvedJson(),
        'applied': ['e1', 'e2'],
        'known': ['e0'],
      });

      // Persisted and handed back untouched; nothing here reads inside it.
      expect(result.state['events'], isNotNull);
      expect(result.stateHash, 'abc123');
      expect(result.applied, ['e1', 'e2']);
      expect(result.known, ['e0']);
      expect(result.rejected, isEmpty);
      expect(result.resolved.name, 'Wandergruppe');
    });

    test('separates a fact that is merely early from one that is wrong', () {
      final result = GroupStateResult.fromJson({
        'group_id': 'p2xjx0000000000000000',
        'state': <String, dynamic>{},
        'state_hash': '',
        'resolved': <String, dynamic>{},
        'rejected': [
          {'index': 0, 'id': 'e1', 'reason': 'no genesis event yet'},
          {'index': 1, 'id': 'e2', 'reason': 'group: member_add signature verification failed'},
        ],
      });

      // Delivery is unordered, so an event overtaking the snapshot it depends
      // on is routine and worth holding. A bad signature is not: no later
      // fact will change it, and retrying forever is what a hostile peer
      // would want.
      expect(result.rejected.first.isPremature, isTrue);
      expect(result.rejected.last.isPremature, isFalse);
      expect(result.rejected.last.index, 1);
    });
  });
}
