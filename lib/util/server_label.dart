// Shortens a server address for display in the account switcher's
// per-server group label: shows just the registrable domain, stripped
// of both its TLD and any subdomain (e.g. "chat.behringer24.de" ->
// "behringer24") -- almost always enough to tell servers apart at a
// glance, and semantically simple (subdomain.domain.tld, keep the
// middle part) rather than an arbitrary character count. Two servers
// that only differ by subdomain (or, separately, only by TLD) would
// collide under this alone; the TLD case is detected and disambiguated
// below since two people plausibly registering both "chatcentral.de"
// and "chatcentral.com" isn't far-fetched, but subdomain-only
// collisions are an accepted v1 simplification -- fix if real
// confusion ever surfaces, not something to chase preemptively.
//
// IP-literal and other bare (dot-less) hosts -- local/dev servers --
// are shown as-is, port included: there's no subdomain/TLD structure
// to shorten, and the port is exactly what usually distinguishes two
// such servers running on the same machine (e.g. this project's own
// local-dev docker-compose setup, two servers on the same host on
// different ports).
import 'dart:io';

import 'server_url.dart';

String shortServerLabel(String server, Iterable<String> allServers) {
  final uri = Uri.tryParse(normalizeServerUrl(server));
  final host = uri?.host ?? server;
  if (host.isEmpty) return host;

  if (InternetAddress.tryParse(host) != null || !host.contains('.')) {
    final port = (uri != null && uri.hasPort) ? ':${uri.port}' : '';
    return '$host$port';
  }

  final parts = host.split('.');
  final domainDisplay = parts[parts.length - 2];
  final domainKey = domainDisplay.toLowerCase();
  final domainWithTldDisplay = '$domainDisplay.${parts.last}';

  final collides = allServers.any((other) {
    if (sameServer(other, server)) return false;
    final otherHost = Uri.tryParse(normalizeServerUrl(other))?.host ?? other;
    if (InternetAddress.tryParse(otherHost) != null ||
        !otherHost.contains('.')) {
      return false;
    }
    final otherParts = otherHost.split('.');
    return otherParts[otherParts.length - 2].toLowerCase() == domainKey;
  });

  return collides ? domainWithTldDisplay : domainDisplay;
}
