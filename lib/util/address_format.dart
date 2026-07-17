// Dart-side mirror of freizone-server's pkg/address.Normalize and
// .FormatForDisplay (address.go) -- purely cosmetic/input-tolerance
// helpers, no crypto. Full checksum validation still only happens
// server-side / via the Go core (FreizoneCore.verifyAddressId) once an
// account's root_pubkey is known; these two just make id entry and
// display forgiving and readable without needing that round trip.

/// Strips cosmetic separators/whitespace and lowercases an account id,
/// so a dash-grouped, spaced, or phone-dictated id ("k5x9 p2qa n7f3...")
/// resolves the same as the canonical 21-character form.
String normalizeAccountId(String input) {
  final buf = StringBuffer();
  for (final ch in input.split('')) {
    switch (ch) {
      case '-':
      case ' ':
      case '\t':
      case '\n':
      case '\r':
        continue;
    }
    buf.write(ch.toLowerCase());
  }
  return buf.toString();
}

/// Inserts a hyphen every 4 characters for readability
/// (`k5x9-p2qa-n7f3-xyzq-eh8m`-style). Purely cosmetic: the canonical
/// form used everywhere else has no separators.
String formatAccountIdForDisplay(String id) {
  final buf = StringBuffer();
  for (var i = 0; i < id.length; i++) {
    if (i > 0 && i % 4 == 0) buf.write('-');
    buf.write(id[i]);
  }
  return buf.toString();
}
