// Finding the tappable parts of a message's text (APP-14).
//
// Deliberately a pure function over a string: no widgets, no context, no
// network. Everything subtle about this feature -- where a URL ends when a
// sentence continues, which of two overlapping matches wins, what is
// *deliberately* not matched -- is decided here and therefore testable
// without pumping a widget.
//
// We linkify PLAIN TEXT, never markup. The consequence is worth stating
// because it is a security property: the visible text always *is* the target,
// so `[your bank](https://evil.example)`-style spoofing has nowhere to live.
import 'freizone_address.dart';

/// What a detected span points at, which decides how a tap is handled.
enum LinkKind {
  /// http(s), or a `www.` prefix that is opened as https.
  url,

  /// A bare email address, opened as `mailto:`.
  email,

  /// A Freizone `id*server` address. Handled entirely in-app -- see
  /// [LinkSpan.target] and APP-14: a tap must not touch the network, because
  /// resolving a peer contacts *that peer's server* directly.
  freizoneAddress,
}

/// One tappable run inside the source text.
class LinkSpan {
  const LinkSpan({
    required this.start,
    required this.end,
    required this.text,
    required this.kind,
    required this.target,
  });

  /// Offsets into the original text, so a renderer can stitch plain gaps and
  /// link runs back together in order.
  final int start;
  final int end;

  /// What to display. Equal to the matched source text except that bidi
  /// control characters have been removed -- U+202E can visually reverse a
  /// URL, which is exactly the trick this must not render faithfully.
  final String text;

  final LinkKind kind;

  /// What to act on: an absolute `https://…`/`http://…` URL, a `mailto:…`
  /// URI, or the raw Freizone address.
  final String target;

  @override
  String toString() => 'LinkSpan($kind, $start-$end, $text -> $target)';
}

/// BIP-350's bech32/bech32m character set, matching freizone-server's
/// `pkg/address`. It excludes `1`, `b`, `i` and `o`, which is what makes an
/// account id resistant to being misread.
const _bech32 = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';

/// The shortest id that may appear in an address. The short form is exactly
/// 5 characters (`shortFreizoneAddress`); this floor is also what stops
/// arithmetic like "2*3.5" from reading as an address.
const _minIdChars = 5;

/// Beyond this, a run is treated as text rather than one enormous link -- a
/// paragraph without spaces is not a URL.
const _maxLinkChars = 2048;

/// Bidi controls: marks, embeddings, overrides and isolates. Stripped from a
/// link's rendered text and never trusted in a target.
final _bidiControls = RegExp('[‎‏‪-‮⁦-⁩]');

// Matched before URLs on purpose: an address may legitimately *contain* a
// scheme ("q2xjx*http://192.168.1.5:18080", see buildFreizoneAddress), so the
// URL pattern would otherwise tear it in half.
final _addressPattern = RegExp(
  '([$_bech32][$_bech32\\-]*)'
  r'\*'
  r'((?:https?://)?[A-Za-z0-9.\-]+(?::\d{1,5})?)',
  caseSensitive: false,
);

final _urlPattern = RegExp(
  r'(?:https?://|www\.)[^\s<>"]+',
  caseSensitive: false,
);

final _emailPattern = RegExp(
  r"[A-Za-z0-9._%+\-!#$&'*/=?^`{|}~]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+",
  caseSensitive: false,
);

/// Finds every tappable run in [text], ordered by position and guaranteed
/// non-overlapping. Returns an empty list for text with nothing in it, which
/// is the common case -- callers can then render a plain [Text] unchanged.
List<LinkSpan> detectLinks(String text) {
  if (text.isEmpty) return const [];

  final spans = <LinkSpan>[];
  // Ranges already claimed, so a later pattern cannot re-match inside an
  // earlier one: an address contains a host, and a URL can contain an "@".
  final taken = <({int start, int end})>[];

  bool overlaps(int start, int end) =>
      taken.any((r) => start < r.end && end > r.start);

  void claim(LinkSpan span) {
    spans.add(span);
    taken.add((start: span.start, end: span.end));
  }

  for (final m in _addressPattern.allMatches(text)) {
    final idPart = m.group(1)!;
    final hostPart = m.group(2)!;
    if (!_plausibleAddress(idPart, hostPart)) continue;
    if (m.end - m.start > _maxLinkChars) continue;
    final raw = m[0]!;
    claim(
      LinkSpan(
        start: m.start,
        end: m.end,
        text: _stripBidi(raw),
        kind: LinkKind.freizoneAddress,
        target: _stripBidi(raw),
      ),
    );
  }

  for (final m in _urlPattern.allMatches(text)) {
    final trimmed = _trimTrailing(m[0]!);
    if (trimmed.isEmpty || trimmed.length > _maxLinkChars) continue;
    final end = m.start + trimmed.length;
    if (overlaps(m.start, end)) continue;
    final clean = _stripBidi(trimmed);
    claim(
      LinkSpan(
        start: m.start,
        end: end,
        text: clean,
        kind: LinkKind.url,
        // A bare "www." host is upgraded to https, never http: guessing the
        // insecure scheme on the user's behalf would be the wrong default.
        target: clean.toLowerCase().startsWith('www.')
            ? 'https://$clean'
            : clean,
      ),
    );
  }

  for (final m in _emailPattern.allMatches(text)) {
    final trimmed = _trimTrailing(m[0]!);
    if (trimmed.isEmpty || trimmed.length > _maxLinkChars) continue;
    final end = m.start + trimmed.length;
    if (overlaps(m.start, end)) continue;
    final clean = _stripBidi(trimmed);
    claim(
      LinkSpan(
        start: m.start,
        end: end,
        text: clean,
        kind: LinkKind.email,
        target: 'mailto:$clean',
      ),
    );
  }

  spans.sort((a, b) => a.start.compareTo(b.start));
  return spans;
}

/// Whether an `id*host` candidate is worth treating as an address at all.
/// Shape only -- Dart cannot verify the bech32m checksum (it lives in the Go
/// core, and its one FFI export checks an id against a *known* root key,
/// which we do not have for an id found in text). The short form carries no
/// checksum in the first place, so this is as strict as it can get.
bool _plausibleAddress(String idPart, String hostPart) {
  final id = idPart.replaceAll('-', '').toLowerCase();
  if (id.length < _minIdChars) return false;
  for (final c in id.split('')) {
    if (!_bech32.contains(c)) return false;
  }

  // A host has to look like one: a dot, an explicit port, or the literal
  // "local" that parseFreizoneAddress already treats as "my own server".
  // The port case matters -- a LAN host like "aff-abe:18080" has no dot.
  final host = hostPart.replaceFirst(RegExp('^https?://', caseSensitive: false), '');
  if (host.toLowerCase() == 'local') return true;
  return host.contains('.') || RegExp(r':\d{1,5}$').hasMatch(host);
}

/// Drops punctuation that belongs to the sentence rather than the link:
/// "(siehe https://x.de)" and "https://x.de." both end one character early.
/// Closing brackets survive while they are balanced, so a URL like
/// `…/wiki/Beispiel_(Begriffsklärung)` stays whole.
String _trimTrailing(String match) {
  var end = match.length;
  while (end > 0) {
    final c = match[end - 1];
    if ('.,;:!?»"\'’'.contains(c)) {
      end--;
      continue;
    }
    if (c == ')' || c == ']' || c == '}') {
      final open = c == ')'
          ? '('
          : c == ']'
          ? '['
          : '{';
      final body = match.substring(0, end);
      final opens = body.split(open).length - 1;
      final closes = body.split(c).length - 1;
      if (closes > opens) {
        end--;
        continue;
      }
    }
    break;
  }
  return match.substring(0, end);
}

String _stripBidi(String s) => s.replaceAll(_bidiControls, '');

/// Whether [span] is an address that resolves to this device's own account,
/// so a tap can say so instead of starting a chat with oneself. Kept here
/// next to detection because it is the same notion of "what is an address".
bool addressIsSelf(LinkSpan span, String ownAccountId) {
  if (span.kind != LinkKind.freizoneAddress) return false;
  final parsed = parseFreizoneAddress(span.target);
  if (parsed == null) return false;
  final id = parsed.idOrPrefix;
  return ownAccountId == id || ownAccountId.startsWith(id);
}
