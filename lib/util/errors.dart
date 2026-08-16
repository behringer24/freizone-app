// Turns a caught exception into a message fit for direct display to
// the user. The common case worth collapsing is a transport-level
// failure (server unreachable, connection dropped, DNS failure) --
// left alone, that surfaces as a raw ClientException/SocketException
// message like "Connection closed before full header was received",
// which is meaningless to a non-technical user.
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../ffi/freizone_core_exception.dart';
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
  // A core failure that is not the server being away still reaches somebody
  // eventually, and "FreizoneCoreException: client: POST /v1/..." is not a
  // sentence. The core's own message is written to be read; the wrapper name
  // is what makes it look like a crash report.
  //
  // The `client:` package prefix goes too, and for the same reason: every
  // error pkg/client raises carries it, so it is not a classification the
  // reader can use -- it is the Go package's own name, in front of a sentence
  // written for them. Only the leading one, and only with its space, so a
  // message that happens to contain the word elsewhere is untouched.
  if (e is FreizoneCoreException) {
    const prefix = 'client: ';
    if (!e.message.startsWith(prefix)) return e.message;
    // Capitalised as it is uncovered, because a Go error string starts
    // lower-case by convention -- that reads as deliberate behind `client:`
    // and as a typo at the start of a sentence in a chat window.
    final sentence = e.message.substring(prefix.length);
    if (sentence.isEmpty) return sentence;
    return sentence[0].toUpperCase() + sentence.substring(1);
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
    e is TimeoutException ||
    // The same thing, reported by the core rather than by dart:io. Every
    // request that used to be made here is made there now, so without this the
    // predicate silently stopped matching the failure it was written for --
    // and a stream that could not connect went from a dimmed account to a
    // full-width red banner repeating a socket error every few seconds.
    (e is FreizoneCoreException &&
        e.code == CoreErrorCode.serverUnreachable);
