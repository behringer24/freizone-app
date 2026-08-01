// Formatting for the Server Admin user list's activity signals (SRV-09).
// Separate from the screen because these are the parts with rules worth
// pinning down in tests -- rounding, pluralisation, and the several ways
// "nothing to show" has to read.

/// A byte count as a short human figure: "0 B", "812 B", "2.4 KB", "51 MB".
///
/// Decimal units (1000, not 1024) deliberately: this sits next to a limit the
/// operator sets in bytes via an env var, and 128 MB configured reading back as
/// "122 MB" invites a bug report. One decimal place only below 10 of a unit,
/// where the fraction still carries information -- "3.2 MB" is worth saying,
/// "51.4 MB" is noise in a list meant to be scanned.
String formatByteSize(int bytes) {
  if (bytes < 1000) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1000;
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  final digits = value < 10 ? 1 : 0;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// Storage usage against its quota: "3.2 MB of 256 MB".
///
/// Falls back to the bare usage when [limit] is 0, which the server sends for
/// an account with no devices and an older server sends for everything -- there
/// is no denominator to show, and "3.2 MB of 0 B" would be nonsense. The limit
/// legitimately moves as devices are added or revoked, since it is the
/// per-device quota times the device count (docs/PROTOCOL.md §4).
String formatQuotaUsage(int bytes, int limit) {
  if (limit <= 0) return formatByteSize(bytes);
  return '${formatByteSize(bytes)} of ${formatByteSize(limit)}';
}

/// How long ago something was, coarsely: "just now", "3h", "5d", "2mo".
///
/// Coarse on purpose. This answers "is this account still in use?", where the
/// difference between 40 and 45 days is meaningless and the difference between
/// hours and months is the whole point. Months are approximated at 30 days,
/// which at this resolution is not a lie worth fixing.
String formatAge(DateTime then, {required DateTime now}) {
  final d = now.difference(then);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes}m';
  if (d.inDays < 1) return '${d.inHours}h';
  if (d.inDays < 60) return '${d.inDays}d';
  return '${d.inDays ~/ 30}mo';
}

/// The queue half of a row's subtitle: "3 queued, oldest 5d" — or null when
/// there is nothing queued, so the caller can leave it out entirely rather
/// than print a reassuring "0 queued" on every single row.
String? formatPendingSummary(
  int pendingMessages,
  DateTime? oldestPendingAt, {
  required DateTime now,
}) {
  if (pendingMessages <= 0) return null;
  final queued = '$pendingMessages queued';
  if (oldestPendingAt == null) return queued;
  return '$queued, oldest ${formatAge(oldestPendingAt, now: now)}';
}
