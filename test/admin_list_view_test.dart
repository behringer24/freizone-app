import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/net/dto.dart';
import 'package:freizone/util/admin_list_view.dart';

AdminAccountSummary _account(
  String id, {
  String role = 'user',
  String status = 'active',
  DateTime? createdAt,
  int pendingMessages = 0,
  DateTime? oldestPendingAt,
  int deviceCount = 1,
}) => AdminAccountSummary(
  id: id,
  role: role,
  status: status,
  createdAt: createdAt ?? DateTime.utc(2026, 1, 1),
  pendingMessages: pendingMessages,
  oldestPendingAt: oldestPendingAt,
  deviceCount: deviceCount,
);

List<String> _ids(List<AdminAccountSummary> accounts) =>
    accounts.map((a) => a.id).toList();

void main() {
  group('adminAccountMatches', () {
    final account = _account('qk5x9p2qan7f3xyzqeh8m');

    test('ignores the hyphens the list displays and any case', () {
      expect(adminAccountMatches(account, 'qk5x9-p2qa'), isTrue);
      expect(adminAccountMatches(account, 'QK5X9P2QA'), isTrue);
      expect(adminAccountMatches(account, 'qk5x9 p2qa n7f3'), isTrue);
    });

    test('matches anywhere in the id, not only at the front', () {
      expect(adminAccountMatches(account, 'n7f3'), isTrue);
      expect(adminAccountMatches(account, 'qeh8m'), isTrue);
    });

    test('an empty query matches everything', () {
      expect(adminAccountMatches(account, ''), isTrue);
      expect(adminAccountMatches(account, '  -- '), isTrue);
    });

    test('rejects a non-match', () {
      expect(adminAccountMatches(account, 'zzzz'), isFalse);
    });
  });

  group('adminListView ordering', () {
    test('defaults to oldest account first, as the server already returns', () {
      final accounts = [
        _account('b', createdAt: DateTime.utc(2026, 5, 1)),
        _account('a', createdAt: DateTime.utc(2026, 3, 1)),
        _account('c', createdAt: DateTime.utc(2026, 7, 1)),
      ];
      expect(_ids(adminListView(accounts)), ['a', 'b', 'c']);
    });

    test('role puts the privileged first, unknown roles last', () {
      final accounts = [
        _account('u', role: 'user'),
        _account('a', role: 'admin'),
        _account('x', role: 'archivist'), // a newer server's role
        _account('m', role: 'moderator'),
      ];
      expect(
        _ids(adminListView(accounts, order: AdminSortOrder.role)),
        ['a', 'm', 'u', 'x'],
      );
    });

    test('status surfaces the blocked accounts', () {
      final accounts = [
        _account('a'),
        _account('b', status: 'disabled'),
        _account('c'),
      ];
      expect(
        _ids(adminListView(accounts, order: AdminSortOrder.status)),
        ['b', 'a', 'c'],
      );
    });

    test('pending puts the largest queue first', () {
      final accounts = [
        _account('a', pendingMessages: 2),
        _account('b', pendingMessages: 40),
        _account('c'),
      ];
      expect(
        _ids(adminListView(accounts, order: AdminSortOrder.pending)),
        ['b', 'a', 'c'],
      );
    });

    // An account with nothing queued has no age at all -- sorting it to the
    // front would bury exactly the rows this ordering exists to surface.
    test('oldestPending leads with the longest wait and trails the empty queues', () {
      final accounts = [
        _account('idle'),
        _account('recent', pendingMessages: 1, oldestPendingAt: DateTime.utc(2026, 7, 30)),
        _account('stale', pendingMessages: 1, oldestPendingAt: DateTime.utc(2026, 2, 1)),
      ];
      expect(
        _ids(adminListView(accounts, order: AdminSortOrder.oldestPending)),
        ['stale', 'recent', 'idle'],
      );
    });

    // Without a tiebreak the list visibly reshuffles between rebuilds when
    // several accounts are equal under the chosen ordering.
    test('ties always break by id, so the order is stable', () {
      final sameSecond = DateTime.utc(2026, 4, 1);
      final accounts = [
        _account('c', createdAt: sameSecond),
        _account('a', createdAt: sameSecond),
        _account('b', createdAt: sameSecond),
      ];
      for (final order in AdminSortOrder.values) {
        expect(
          _ids(adminListView(accounts, order: order)),
          ['a', 'b', 'c'],
          reason: 'order $order should be deterministic',
        );
      }
    });

    test('does not mutate the list it was given', () {
      final accounts = [
        _account('b', createdAt: DateTime.utc(2026, 5, 1)),
        _account('a', createdAt: DateTime.utc(2026, 3, 1)),
      ];
      adminListView(accounts, order: AdminSortOrder.id);
      expect(_ids(accounts), ['b', 'a']);
    });
  });

  group('adminListView filtering', () {
    test('search and sort compose', () {
      final accounts = [
        _account('qk5x9aaa', createdAt: DateTime.utc(2026, 5, 1)),
        _account('qk5x9bbb', createdAt: DateTime.utc(2026, 3, 1)),
        _account('zzzzzzzz', createdAt: DateTime.utc(2026, 1, 1)),
      ];
      expect(
        _ids(adminListView(accounts, query: 'QK5X9')),
        ['qk5x9bbb', 'qk5x9aaa'],
      );
    });
  });

  group('adminSortOrderApplies', () {
    test('hides the activity orderings against a server that omits them', () {
      // deviceCount 0 is how an account from a pre-SRV-09 server arrives -- no
      // account can genuinely have zero devices.
      final old = [_account('a', deviceCount: 0)];
      expect(adminSortOrderApplies(AdminSortOrder.pending, old), isFalse);
      expect(adminSortOrderApplies(AdminSortOrder.oldestPending, old), isFalse);
      expect(adminSortOrderApplies(AdminSortOrder.role, old), isTrue);
      expect(adminSortOrderApplies(AdminSortOrder.created, old), isTrue);
    });

    test('offers them as soon as any account reports them', () {
      final mixed = [_account('a', deviceCount: 0), _account('b')];
      expect(adminSortOrderApplies(AdminSortOrder.pending, mixed), isTrue);
    });
  });
}
