// Hand-rolled Server-Sent Events client for GET /v1/messages/stream
// (docs/PROTOCOL.md in freizone-server), mirroring cmd/devclient's own
// line-based parser -- no external SSE package dependency. The server
// sends one `event: message` / `data: ...` pair per message and a
// `: heartbeat` comment roughly every 25s; only lines starting with
// `data: ` carry anything this client needs.
import 'dart:async';
import 'dart:convert';

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

  /// Opens the stream and calls [onMessage] for every message received.
  /// Reconnects automatically after [retryDelay] on any failure or
  /// disconnect, calling [onError] (if given) first, until [close] is
  /// called. Runs until closed -- typically started with an unawaited
  /// call from a screen's initState. [onConnected], if given, fires once
  /// per successful (re)connect -- e.g. AppSession uses it to re-check
  /// its one-time-prekey pool on every reconnect, not just app launch.
  Future<void> connect({
    required void Function(MessageResponse message) onMessage,
    void Function(Object error)? onError,
    void Function()? onConnected,
    Duration retryDelay = const Duration(seconds: 3),
  }) async {
    _closed = false;
    while (!_closed) {
      try {
        await _connectOnce(onMessage, onConnected);
      } catch (e) {
        if (_closed) return;
        onError?.call(e);
      }
      if (_closed) return;
      await Future.delayed(retryDelay);
    }
  }

  Future<void> _connectOnce(
    void Function(MessageResponse) onMessage,
    void Function()? onConnected,
  ) async {
    final httpClient = http.Client();
    _streamHttp = httpClient;

    final streamed = await httpClient.send(apiClient.buildStreamRequest(creds));
    if (streamed.statusCode != 200) {
      final body = await streamed.stream.bytesToString();
      throw ApiException(streamed.statusCode, null, body);
    }
    onConnected?.call();

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
            MessageResponse.fromJson(json.decode(data) as Map<String, dynamic>),
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
  }

  void close() {
    _closed = true;
    _lineSub?.cancel();
    _streamHttp?.close();
  }
}
