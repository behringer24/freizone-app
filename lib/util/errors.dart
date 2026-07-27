// Turns a caught exception into a message fit for direct display to
// the user. The common case worth collapsing is a transport-level
// failure (server unreachable, connection dropped, DNS failure) --
// left alone, that surfaces as a raw ClientException/SocketException
// message like "Connection closed before full header was received",
// which is meaningless to a non-technical user.
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../net/api_client.dart';

String describeError(Object e) {
  if (e is NotFreizoneServerException) {
    return "This address doesn't point to a Freizone server. "
        'Check the server part of the address (after the *).';
  }
  if (e is ApiException) return e.message;
  if (isServerUnreachable(e)) {
    return 'Server not reachable. Check the server address and your connection.';
  }
  // StateError carries an already user-facing message (e.g. the self-chat and
  // federation-disabled guards in AppSession.startConversation) -- show it
  // directly rather than Dart's "Bad state: ..." toString() prefix.
  if (e is StateError) return e.message;
  return '$e';
}

/// Whether [e] means the request never reached a working server at all -- a
/// transport-level failure (unreachable host, dropped connection, TLS
/// handshake failure, DNS failure, or the request timing out) rather than a
/// server that answered. Deliberately does NOT include [ApiException] (the
/// server did reply, so we know its real state) or [NotFreizoneServerException]
/// (something answered, just not a Freizone server): this predicate means "we
/// learned nothing about the account's server-side state." Callers use it to
/// decide whether a local-only fallback is even defensible -- see
/// profile_screen.dart's delete flow.
bool isServerUnreachable(Object e) =>
    e is SocketException ||
    e is http.ClientException ||
    e is HandshakeException ||
    e is TimeoutException;
