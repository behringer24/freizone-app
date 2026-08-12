/// How a transcript writes time, in the one place both of them read it from.
///
/// A one-to-one chat and a group chat are two screens showing the same thing,
/// and a reader moving between them should not have to notice which one they
/// are in. These lived privately in `chat_screen.dart` while the group screen
/// simply had no clock at all -- so this exists as much to keep them from
/// drifting again as to share four lines.
library;

String _two(int n) => n.toString().padLeft(2, '0');

/// The label above a day's first message. [day] is a local-time date.
///
/// Named for the two days a reader has a word for and dated for every other,
/// because "Monday" stops meaning anything about a week back.
String dayLabel(DateTime day) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  if (day == today) return 'Today';
  if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
  return '${_two(day.day)}.${_two(day.month)}.${day.year}';
}

/// The clock on one bubble. Takes UTC -- what a transcript stores -- and shows
/// the reader's own time, since the only question it answers is "when was this,
/// for me".
String timeLabel(DateTime utc) {
  final local = utc.toLocal();
  return '${_two(local.hour)}:${_two(local.minute)}';
}

/// The local calendar day [utc] falls on, which is what a date divider is
/// compared by. Local rather than UTC: a message sent at 00:30 belongs to the
/// day the reader would say it belongs to.
DateTime localDayOf(DateTime utc) {
  final local = utc.toLocal();
  return DateTime(local.year, local.month, local.day);
}
