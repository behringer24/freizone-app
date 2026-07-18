// Dart-side mirror of freizone-server's pkg/address.Normalize and
// .FormatForDisplay (address.go) -- purely cosmetic/input-tolerance
// helpers, no crypto. Full checksum validation still only happens
// server-side / via the Go core (FreizoneCore.verifyAddressId) once an
// account's root_pubkey is known; these two just make id entry and
// display forgiving and readable without needing that round trip.

/// Number of leading characters of an id a server enforces unique among
/// its own accounts (see freizone-server's docs/PROTOCOL.md id-prefix
/// uniqueness note) -- usable as a short, typeable lookup key for the
/// full id. Matches formatAccountIdForDisplay's first group size.
const accountIdPrefixLength = 5;

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

/// Inserts a hyphen every 5 characters for readability
/// (`qk5x9-p2qan-7f3xy-zqeh8-m`-style). Purely cosmetic: the canonical
/// form used everywhere else has no separators. 5 (not 4) is deliberate:
/// the leading char is always the version marker (see freizone-server's
/// pkg/address.CurrentVersion), so a 5-char first group carries 4 real
/// characters of entropy -- and happens to split the 15-char payload into
/// exactly 3 even groups, leaving only the 6-char checksum tail uneven.
String formatAccountIdForDisplay(String id) {
  final buf = StringBuffer();
  for (var i = 0; i < id.length; i++) {
    if (i > 0 && i % 5 == 0) buf.write('-');
    buf.write(id[i]);
  }
  return buf.toString();
}
