// Hand-rolled Server-Sent Events client for GET /v1/messages/stream
// (docs/PROTOCOL.md in freizone-server), mirroring cmd/devclient's own
// line-based parser -- no external SSE package dependency. The server
// sends one `event: message` / `data: ...` pair per message and a
// `: heartbeat` comment roughly every 25s; only lines starting with
// `data: ` carry anything this client needs.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'dto.dart';

class SseClient {
  SseClient({required this.apiClient, required this.creds});

  final ApiClient apiClient;
  final DeviceCredentials creds;

  bool _closed = false;
  StreamSubscription<String>? _lineSub;
  http.Client? _streamHttp;

  /// Whether the current/last connect attempt actually came up (reached the
  /// stream) before it ended -- lets [connect] tell "connected then dropped"
  /// (reconnect promptly) apart from "never connected" (back off).
  bool _attemptEstablished = false;

  /// Opens the stream and calls [onMessage] for every message received.
  /// Reconnects automatically on any failure or disconnect, calling
  /// [onError] (if given) first, until [close] is called. Runs until
  /// closed -- typically started with an unawaited call from a screen's
  /// initState. [onConnected], if given, fires once per successful
  /// (re)connect -- e.g. AppSession uses it to re-check its one-time-prekey
  /// pool on every reconnect, not just app launch.
  ///
  /// Attempts that never come up retry with exponential backoff between
  /// [initialRetryDelay] and [maxRetryDelay] (±20% jitter), so an offline home
  /// server is probed ever less aggressively (instead of hammered every 3s)
  /// yet still recovers within [maxRetryDelay] once it returns. A connection
  /// that *did* come up and then dropped (a background resume, a brief blip)
  /// instead reconnects after just [quickRetryDelay] with the backoff reset,
  /// so a healthy link recovers in well under a second. [connectTimeout]
  /// bounds a single connect attempt so a dead-but-routed host surfaces as
  /// unreachable in seconds rather than after the OS-level TCP timeout.
  Future<void> connect({
    required void Function(MessageResponse message) onMessage,
    void Function(Object error)? onError,
    void Function()? onConnected,
    Duration initialRetryDelay = const Duration(seconds: 3),
    Duration maxRetryDelay = const Duration(seconds: 30),
    Duration connectTimeout = const Duration(seconds: 10),
    Duration quickRetryDelay = const Duration(milliseconds: 500),
  }) async {
    _closed = false;
    final rand = Random();
    var delay = initialRetryDelay;
    while (!_closed) {
      try {
        await _connectOnce(onMessage, onConnected, connectTimeout);
      } catch (e) {
        if (_closed) return;
        onError?.call(e);
      }
      if (_closed) return;
      if (_attemptEstablished) {
        // Came up and then dropped (resume from background, brief blip):
        // reconnect almost immediately and reset the backoff, so a healthy
        // link recovers in well under a second rather than after the full
        // retry delay.
        delay = initialRetryDelay;
        await Future.delayed(quickRetryDelay);
      } else {
        // Never came up this attempt (server down/unreachable): back off,
        // with ±20% jitter so sessions sharing a server don't reconnect in
        // lockstep.
        final ms = delay.inMilliseconds;
        final jittered = (ms * (0.8 + rand.nextDouble() * 0.4)).round();
        await Future.delayed(Duration(milliseconds: jittered));
        delay = Duration(
          milliseconds: min(ms * 2, maxRetryDelay.inMilliseconds),
        );
      }
    }
  }

  Future<void> _connectOnce(
    void Function(MessageResponse) onMessage,
    void Function()? onConnected,
    Duration connectTimeout,
  ) async {
    _attemptEstablished = false;
    final httpClient = http.Client();
    _streamHttp = httpClient;
    try {
      final streamed = await httpClient
          .send(apiClient.buildStreamRequest(creds))
          .timeout(connectTimeout);
      if (streamed.statusCode != 200) {
        final body = await streamed.stream.bytesToString();
        throw ApiException(streamed.statusCode, null, body);
      }
      onConnected?.call();
      _attemptEstablished = true;

      final lines = streamed.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      final completer = Completer<void>();
      _lineSub = lines.listen(
        (line) {
          if (!line.startsWith('data: ')) return;
          final data = line.substring('data: '.length);
          try {
            onMessage(
              MessageResponse.fromJson(
                json.decode(data) as Map<String, dynamic>,
              ),
            );
          } catch (_) {
            // Malformed line; ignore and keep the connection open.
          }
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
        onError: (Object e) {
          if (!completer.isCompleted) completer.completeError(e);
        },
        cancelOnError: true,
      );
      await completer.future;
    } finally {
      // Close this attempt's client so a timed-out or failed connect
      // doesn't leak its socket: against a dead server every backoff retry
      // would otherwise pile up another lingering SYN-SENT connection that
      // only clears on the OS-level TCP timeout minutes later.
      await _lineSub?.cancel();
      httpClient.close();
    }
  }

  void close() {
    _closed = true;
    _lineSub?.cancel();
    _streamHttp?.close();
  }
}
