import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/util/admin_format.dart';

void main() {
  group('formatByteSize', () {
    test('shows plain bytes below a kilobyte', () {
      expect(formatByteSize(0), '0 B');
      expect(formatByteSize(812), '812 B');
    });

    // Decimal units, so a limit the operator set as 128 MB reads back as
    // 128 MB rather than 122.
    test('uses decimal units, matching how the limit is configured', () {
      expect(formatByteSize(1000), '1.0 KB');
      expect(formatByteSize(128 * 1000 * 1000), '128 MB');
    });

    test('keeps one decimal only while it still carries information', () {
      expect(formatByteSize(3200000), '3.2 MB');
      expect(formatByteSize(51400000), '51 MB');
    });

    test('climbs no further than terabytes', () {
      expect(formatByteSize(5 * 1000 * 1000 * 1000 * 1000), '5.0 TB');
      expect(formatByteSize(9000 * 1000 * 1000 * 1000 * 1000), '9000 TB');
    });
  });

  group('formatQuotaUsage', () {
    test('shows usage against its limit', () {
      expect(formatQuotaUsage(3200000, 256 * 1000 * 1000), '3.2 MB of 256 MB');
    });

    // 0 is what the server sends for an account with no devices, and what an
    // older server sends for everything -- neither has a denominator.
    test('drops the denominator when there is no meaningful limit', () {
      expect(formatQuotaUsage(3200000, 0), '3.2 MB');
      expect(formatQuotaUsage(0, 0), '0 B');
    });
  });

  group('formatAge', () {
    final now = DateTime.utc(2026, 8, 2, 12, 0, 0);

    test('reads coarsely across the range that matters', () {
      expect(formatAge(now.subtract(const Duration(seconds: 20)), now: now), 'just now');
      expect(formatAge(now.subtract(const Duration(minutes: 42)), now: now), '42m');
      expect(formatAge(now.subtract(const Duration(hours: 3)), now: now), '3h');
      expect(formatAge(now.subtract(const Duration(days: 5)), now: now), '5d');
      expect(formatAge(now.subtract(const Duration(days: 120)), now: now), '4mo');
    });

    test('switches to months only past the point days stop being readable', () {
      expect(formatAge(now.subtract(const Duration(days: 59)), now: now), '59d');
      expect(formatAge(now.subtract(const Duration(days: 60)), now: now), '2mo');
    });
  });

  group('formatPendingSummary', () {
    final now = DateTime.utc(2026, 8, 2, 12, 0, 0);

    // Null, not "0 queued": the healthy case is every row, and saying so on
    // each of them would bury the few rows that mean something.
    test('is absent for an empty queue', () {
      expect(formatPendingSummary(0, null, now: now), isNull);
      expect(formatPendingSummary(0, now, now: now), isNull);
    });

    test('pairs the count with the oldest message age', () {
      expect(
        formatPendingSummary(3, now.subtract(const Duration(days: 5)), now: now),
        '3 queued, oldest 5d',
      );
    });

    test('still reports a count with no timestamp to age', () {
      expect(formatPendingSummary(3, null, now: now), '3 queued');
    });
  });
}
