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
  if (e is SocketException ||
      e is http.ClientException ||
      e is HandshakeException ||
      e is TimeoutException) {
    return 'Server not reachable. Check the server address and your connection.';
  }
  return '$e';
}
