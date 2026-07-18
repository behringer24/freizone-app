// Normalizes a user-typed server address into a full base URL for
// ApiClient. Typing a bare domain ("chat.example.org") should just work
// against a normally-deployed server (TLS via Let's Encrypt on 443, the
// primary supported path per docs/PROTOCOL.md) -- no https:// prefix, no
// port needed. A scheme, if given, is always respected as-is (e.g.
// "http://127.0.0.1:18080" for local/dev servers running without TLS).
String normalizeServerUrl(String input) {
  var s = input.trim();
  if (s.isEmpty) return s;
  if (!s.contains('://')) s = 'https://$s';
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}
