import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/util/chat_time.dart';

// The labels both transcripts read their clock from. Small, but shared by two
// screens now -- which is the whole reason they left chat_screen.dart.

void main() {
  group('chat time labels', () {
    test('names the two days a reader has a word for, dates the rest', () {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      expect(dayLabel(today), 'Today');
      expect(dayLabel(today.subtract(const Duration(days: 1))), 'Yesterday');

      // Anything older is dated: "Monday" stops meaning anything a week back.
      expect(dayLabel(DateTime(2026, 8, 3)), '03.08.2026');
      expect(dayLabel(DateTime(2026, 12, 24)), '24.12.2026');
    });

    test('shows a stored UTC stamp in the reader own time, zero-padded', () {
      final utc = DateTime.utc(2026, 8, 11, 9, 5);
      final local = utc.toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      expect(timeLabel(utc), '${two(local.hour)}:${two(local.minute)}');
    });

    test('a divider groups by the local day, not the UTC one', () {
      // Whatever the reader's zone, the day a message belongs to is the one
      // they would name -- so this is the local calendar date and never the
      // UTC one.
      final utc = DateTime.utc(2026, 8, 11, 23, 30);
      final local = utc.toLocal();
      expect(
        localDayOf(utc),
        DateTime(local.year, local.month, local.day),
      );
    });

    test('two stamps on the same local day share one divider', () {
      final morning = DateTime.utc(2026, 8, 11, 6, 0);
      final evening = morning.add(const Duration(hours: 10));
      // Ten hours apart cannot straddle a local midnight from both ends: if
      // they land on the same local day they must give the same divider.
      if (localDayOf(morning) == localDayOf(evening)) {
        expect(dayLabel(localDayOf(morning)), dayLabel(localDayOf(evening)));
      }
      expect(localDayOf(morning).hour, 0);
    });
  });
}
