// Wire format for invite QR codes: a custom `freizone://join` URI carrying
// the server address and (when the policy needs one) an invite code. Used
// both when generating a QR (invite_screen.dart) and when the setup
// wizard's scanner (qr_scan_screen.dart) decodes one -- see
// docs/PROTOCOL.md's "Invite QR codes" appendix in freizone-server.
import 'package:flutter/foundation.dart';

@immutable
class InviteUri {
  const InviteUri({required this.server, this.code});

  final String server;
  final String? code;
}

Uri buildInviteUri({required String server, String? code}) {
  return Uri(
    scheme: 'freizone',
    host: 'join',
    queryParameters: {
      'server': server,
      if (code != null && code.isNotEmpty) 'code': code,
    },
  );
}

/// Returns null if raw isn't a recognizable `freizone://join` invite URI.
InviteUri? parseInviteUri(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.scheme != 'freizone' || uri.host != 'join')
    return null;
  final server = uri.queryParameters['server'];
  if (server == null || server.isEmpty) return null;
  final code = uri.queryParameters['code'];
  return InviteUri(
    server: server,
    code: (code == null || code.isEmpty) ? null : code,
  );
}
