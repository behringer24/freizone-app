import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/net/dto.dart';

// The admin account entry is a wire contract with freizone-server's
// docs/PROTOCOL.md §4, and most of its fields arrived after the first version
// of the endpoint. What matters here is that an older server -- or a response
// where a field was withheld on purpose -- degrades to something the UI can
// read correctly, rather than to a wrong number stated confidently.

void main() {
  group('AdminAccountSummary.fromJson', () {
    test('reads a full entry', () {
      final account = AdminAccountSummary.fromJson({
        'id': 'qk5x9p2qan7f3xyzqeh8m',
        'role': 'user',
        'status': 'active',
        'created_at': '2026-03-01T10:00:00Z',
        'pending_messages': 3,
        'oldest_pending_at': '2026-07-20T08:30:00Z',
        'blob_count': 2,
        'blob_bytes': 3355443,
        'blob_bytes_limit': 268435456,
        'device_count': 2,
        'invited_by': 'zzzzzp2qan7f3xyzqeh8m',
      });

      expect(account.pendingMessages, 3);
      expect(account.oldestPendingAt, DateTime.utc(2026, 7, 20, 8, 30));
      expect(account.blobBytes, 3355443);
      expect(account.blobBytesLimit, 268435456);
      expect(account.deviceCount, 2);
      expect(account.invitedBy, 'zzzzzp2qan7f3xyzqeh8m');
      expect(account.hasActivitySignals, isTrue);
    });

    // A server predating SRV-09 sends none of the activity fields. Defaulting
    // them to zero is only safe because hasActivitySignals can still tell that
    // case apart from a genuinely idle account -- otherwise the UI would report
    // "no attachments, nothing queued" about a server that never said so.
    test('an older server degrades to no signals rather than false zeroes', () {
      final account = AdminAccountSummary.fromJson({
        'id': 'qk5x9p2qan7f3xyzqeh8m',
        'role': 'user',
        'status': 'active',
        'created_at': '2026-03-01T10:00:00Z',
      });

      expect(account.pendingMessages, 0);
      expect(account.deviceCount, 0);
      expect(account.hasActivitySignals, isFalse);
    });

    test('an idle account on a current server does report signals', () {
      final account = AdminAccountSummary.fromJson({
        'id': 'qk5x9p2qan7f3xyzqeh8m',
        'role': 'user',
        'status': 'active',
        'created_at': '2026-03-01T10:00:00Z',
        'pending_messages': 0,
        'blob_count': 0,
        'blob_bytes': 0,
        'blob_bytes_limit': 134217728,
        'device_count': 1,
      });

      expect(account.hasActivitySignals, isTrue);
      expect(account.pendingMessages, 0);
      expect(account.oldestPendingAt, isNull, reason: 'an empty queue has no oldest message');
    });

    // Withheld from moderators (SRV-14), and equally absent for an account that
    // needed no invite or whose inviter was deleted. All three are "not known
    // here" -- the UI must never render this as "registered openly".
    test('a withheld or absent inviter is simply null', () {
      final account = AdminAccountSummary.fromJson({
        'id': 'qk5x9p2qan7f3xyzqeh8m',
        'role': 'user',
        'status': 'active',
        'created_at': '2026-03-01T10:00:00Z',
        'device_count': 1,
      });
      expect(account.invitedBy, isNull);
    });
  });
}
