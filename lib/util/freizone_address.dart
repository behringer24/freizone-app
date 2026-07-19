// The full, portable Freizone address format: <id-or-prefix>*<server>,
// e.g. "q2xjx-e3gtq-utyft-ankjc-v*chat.example.org" or, with the short
// id-prefix, "q2xjx*chat.example.org". `*local` (or omitting the `*...`
// part entirely) means "whatever server this is being resolved against
// right now" -- both are exactly equivalent, so a parser can always
// split on the first `*` rather than needing a separate no-separator
// case. The server part, if not `local`, is normalized exactly like the
// setup wizard's own server-address field (normalizeServerUrl) -- a bare
// domain, or an IP[:port] for local/dev servers -- since it's the same
// grammar either way.
//
// A parsed address whose server doesn't match the one being resolved
// against is what AppSession.startConversation uses to route the send
// through a federated (cross-server) path instead of the local one --
// that decision is deliberately left to the caller, not something this
// purely-cosmetic parsing layer makes itself.
import 'address_format.dart';
import 'server_url.dart';

/// A parsed Freizone address. [idOrPrefix] is already normalized
/// (dashes/whitespace stripped, lowercased) -- either the full 21-char
/// id or just its first [accountIdPrefixLength] characters. [server] is
/// null for `*local` or no `*...` part at all (meaning "current
/// server"); otherwise it's already run through [normalizeServerUrl].
class FreizoneAddress {
  const FreizoneAddress({required this.idOrPrefix, this.server});

  final String idOrPrefix;
  final String? server;
}

/// Parses input as a Freizone address (`id*server`, `id*local`, or just
/// `id`/prefix on its own). Returns null if the id part is empty once
/// normalized -- this deliberately doesn't validate charset/length/
/// checksum, since that's what the existing full-id/prefix resolution
/// path already does (server-side, or via the Go core once a
/// root_pubkey is known).
FreizoneAddress? parseFreizoneAddress(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return null;

  final starIndex = trimmed.indexOf('*');
  final idPart = starIndex == -1 ? trimmed : trimmed.substring(0, starIndex);
  final serverPart = starIndex == -1
      ? null
      : trimmed.substring(starIndex + 1).trim();

  final normalizedId = normalizeAccountId(idPart);
  if (normalizedId.isEmpty) return null;

  if (serverPart == null ||
      serverPart.isEmpty ||
      serverPart.toLowerCase() == 'local') {
    return FreizoneAddress(idOrPrefix: normalizedId);
  }
  return FreizoneAddress(
    idOrPrefix: normalizedId,
    server: normalizeServerUrl(serverPart),
  );
}

/// Builds the portable address for id@server, e.g.
/// "q2xjx*chat.example.org" (or "q2xjx*http://192.168.178.43:18080" for
/// a local/dev server without TLS) -- what "copy my address" hands
/// someone else, since (unlike within the app, where "no server part"
/// implicitly means "this session's own server") an address handed to
/// another person needs to be explicit about which server it lives on.
/// [id] may be the full id or just its first [accountIdPrefixLength]
/// characters -- formatAccountIdForDisplay is a no-op on a prefix
/// that short, so either works unchanged. The default "https://" is
/// dropped (parseFreizoneAddress's normalizeServerUrl adds it right
/// back if missing, exactly the same assume-https convention already
/// used everywhere a server address is entered) -- only a non-default
/// scheme like "http://" stays visible, since that's the one case
/// actually worth flagging.
String buildFreizoneAddress({required String id, required String server}) {
  return '${formatAccountIdForDisplay(id)}*${withoutDefaultScheme(server)}';
}

const _defaultScheme = 'https://';

/// Strips a leading "https://" -- the assumed-by-default scheme
/// everywhere a server address is entered or displayed (normalizeServerUrl
/// adds it right back if missing). A non-default scheme like "http://",
/// used by local/dev/test servers, is left visible, since that's the one
/// case actually worth flagging. Shared by [buildFreizoneAddress] and the
/// QR invite URIs (lib/util/invite_uri.dart), so a scanned/typed address
/// never shows a redundant "https://" any more than an email address
/// shows its protocol.
String withoutDefaultScheme(String server) {
  if (server.length > _defaultScheme.length &&
      server.substring(0, _defaultScheme.length).toLowerCase() ==
          _defaultScheme) {
    return server.substring(_defaultScheme.length);
  }
  return server;
}
