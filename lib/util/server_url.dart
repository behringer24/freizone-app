// Normalizes a user-typed server address into a full base URL for
// ApiClient. Typing a bare domain ("chat.example.org") should just work
// against a normally-deployed server (TLS via Let's Encrypt on 443, the
// primary supported path per docs/PROTOCOL.md) -- no https:// prefix, no
// port needed. A scheme, if given, is always respected as-is (e.g.
// "http://127.0.0.1:18080" for local/dev servers running without TLS).
//
// The strictness of that is deliberate and settled: no scheme means https,
// and https that fails is a failure. Do NOT add a fallback that retries over
// http -- that is a silent downgrade of a connection the user believed was
// encrypted -- and do NOT let the address field or its error suggest http as
// a remedy. The people most likely to take that advice are the ones least
// able to judge what it costs, so a helpful hint there is a lesson in
// insecure habits. Plain http exists for test servers, and whoever runs one
// can type the scheme in full; the setup documentation is the right place to
// say so, since the reader has already chosen to run a server without TLS.
String normalizeServerUrl(String input) {
  var s = input.trim();
  if (s.isEmpty) return s;
  if (!s.contains('://')) s = 'https://$s';
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// Whether [a] and [b] identify the same server, once each is run
/// through [normalizeServerUrl]. Scheme is ignored when neither side
/// names an explicit port -- e.g. "chat.example.org" and
/// "http://chat.example.org" are the same server, since the scheme is
/// just how this device happens to be reaching it, not part of the
/// server's identity (see buildFreizoneAddress, which drops the
/// default https:// for exactly this reason). An explicit port on
/// either side is still compared exactly, since that usually does
/// point at a genuinely different endpoint. Host comparison is
/// case-insensitive, since domain names are.
bool sameServer(String a, String b) {
  final ua = Uri.tryParse(normalizeServerUrl(a));
  final ub = Uri.tryParse(normalizeServerUrl(b));
  if (ua == null || ub == null) {
    return normalizeServerUrl(a).toLowerCase() == normalizeServerUrl(b).toLowerCase();
  }
  if (ua.host.toLowerCase() != ub.host.toLowerCase()) return false;
  return (ua.hasPort ? ua.port : null) == (ub.hasPort ? ub.port : null);
}
