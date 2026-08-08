// End-to-end through the whole bridge: Dart calls the FFI core, the core opens
// a real HTTP connection to a server this test runs, and the events come back
// through the blocking poll into CoreStream's callbacks (SRV-23).
//
// This is the closest thing to "it runs on the device" that a host test can be,
// and it exists because everything it covers used to be unreachable: the core
// only built for Android, so no Dart test could load it at all.
//
// Needs the host core:
//
//     ./native/build_desktop.ps1
//
// Skips rather than fails without it -- the library is gitignored, so a fresh
// checkout has none.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/net/core_stream.dart';
import 'package:freizone/net/dto.dart';
import 'package:freizone/state/local_state.dart';
import 'package:freizone/ffi/freizone_core.dart';

String get _corePath {
  final name = Platform.isWindows
      ? 'freizonecore.dll'
      : Platform.isMacOS
      ? 'libfreizonecore.dylib'
      : 'libfreizonecore.so';
  return File('native/$name').absolute.path;
}

/// A minimal account, enough for the core to sign and stream. The keys are never
/// verified by the test server, only used.
AppState _stateFor(String server) => AppState(
  server: server,
  accountId: 'fz1conformanceaccount',
  rootPub: Uint8List(32),
  rootPriv: Uint8List(64),
  deviceId: 'device-1',
  devicePub: Uint8List(32),
  devicePriv: Uint8List(64),
);

/// Serves the SSE stream, handing each connection to [onConnect] so a test can
/// decide what to write and when to end it.
Future<HttpServer> _serveStream(
  void Function(HttpResponse response) onConnect,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) {
    request.response.headers.set('Content-Type', 'text/event-stream');
    request.response.statusCode = 200;
    // Without this dart:io buffers the whole response and sends nothing until
    // it is closed -- so a test that holds the stream open never gets the core
    // past waiting for headers, and fails as a bare timeout. A real SSE server
    // does not buffer either.
    request.response.bufferOutput = false;
    onConnect(request.response);
  });
  return server;
}

void _writeFrame(HttpResponse response, Map<String, dynamic> message) {
  response.write('event: message\ndata: ${json.encode(message)}\n\n');
}

void main() {
  final coreMissing = !File(_corePath).existsSync()
      ? 'native core not built for this host -- run native/build_desktop.ps1'
      : null;

  group('CoreStream', () {
    late Directory tempDir;
    late Directory previousCwd;

    setUp(() {
      // The core's database path is resolved through path_provider, which has no
      // implementation in a plain test. Running from a temp directory keeps the
      // file it does create out of the repo.
      tempDir = Directory.systemTemp.createTempSync('freizone-core-stream');
      previousCwd = Directory.current;
    });

    tearDown(() {
      Directory.current = previousCwd;
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {
        // The core may still hold the database briefly; a leftover temp
        // directory is not worth failing a test over.
      }
    });

    test('carries a message from the wire to onMessage', () async {
      final received = Completer<MessageResponse>();
      final connected = Completer<void>();

      final server = await _serveStream((response) {
        _writeFrame(response, {
          'message_id': 'm1',
          'sender_account_id': 'fz1sender',
          'sender_device_id': 'device-2',
          'sent_at': '2026-08-07T09:00:00.000Z',
          'payload': {'v': 1, 'id': 'x', 'text': 'hello', 'attachments': []},
        });
        response.flush();
      });
      addTearDown(() => server.close(force: true));

      final stream = CoreStream(
        core: FreizoneCore(libraryPath: _corePath),
        state: _stateFor('http://${server.address.host}:${server.port}'),
        statePath: (id) async =>
            "${tempDir.path}${Platform.pathSeparator}core-$id",
      );
      addTearDown(stream.close);

      unawaited(
        stream.connect(
          onMessage: (m) {
            if (!received.isCompleted) received.complete(m);
          },
          onConnected: () {
            if (!connected.isCompleted) connected.complete();
          },
          // Not decoration: without it a failed attempt is dropped and the test
          // fails as a bare timeout with nothing to go on.
          onError: (e) {
            if (!connected.isCompleted) connected.completeError(e);
            if (!received.isCompleted) received.completeError(e);
          },
        ),
      );

      await connected.future.timeout(const Duration(seconds: 20));
      final message = await received.future.timeout(
        const Duration(seconds: 20),
      );

      expect(message.messageId, 'm1');
      expect(message.senderAccountId, 'fz1sender');
      // The payload stays opaque all the way across: only the crypto layer
      // opens it.
      expect(message.payload['text'], 'hello');
    }, skip: coreMissing);

    test(
      'reports a connect that never came up, and keeps retrying',
      () async {
        final failures = <Object>[];
        final twoFailures = Completer<void>();

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) {
          request.response.statusCode = 503;
          request.response.headers.set('Content-Type', 'application/json');
          request.response.write('{"error":{"code":"unavailable"}}');
          request.response.close();
        });
        addTearDown(() => server.close(force: true));

        final stream = CoreStream(
          core: FreizoneCore(libraryPath: _corePath),
          state: _stateFor('http://${server.address.host}:${server.port}'),
          statePath: (id) async =>
              "${tempDir.path}${Platform.pathSeparator}core-$id",
        );
        addTearDown(stream.close);

        unawaited(
          stream.connect(
            onMessage: (_) {},
            onError: (e) {
              failures.add(e);
              // Two is what shows it is a retry loop rather than one attempt.
              if (failures.length >= 2 && !twoFailures.isCompleted) {
                twoFailures.complete();
              }
            },
          ),
        );

        await twoFailures.future.timeout(const Duration(seconds: 30));
        expect(failures.length, greaterThanOrEqualTo(2));
      },
      skip: coreMissing,
    );

    test('a clean disconnect is not reported as an error', () async {
      final errors = <Object>[];
      var connects = 0;
      final reconnected = Completer<void>();

      final server = await _serveStream((response) {
        // End the response straight away: this is what a resume from background
        // or a brief blip looks like, and the app's rule is that it must not
        // light up the offline badge.
        response.close();
      });
      addTearDown(() => server.close(force: true));

      final stream = CoreStream(
        core: FreizoneCore(libraryPath: _corePath),
        state: _stateFor('http://${server.address.host}:${server.port}'),
        statePath: (id) async =>
            "${tempDir.path}${Platform.pathSeparator}core-$id",
      );
      addTearDown(stream.close);

      unawaited(
        stream.connect(
          onMessage: (_) {},
          onError: errors.add,
          onConnected: () {
            connects++;
            if (connects >= 2 && !reconnected.isCompleted) {
              reconnected.complete();
            }
          },
        ),
      );

      await reconnected.future.timeout(const Duration(seconds: 30));
      expect(
        errors,
        isEmpty,
        reason:
            'a stream that came up and ended is a blip; reporting it would grey '
            'the account out every time the app came back to the foreground',
      );
    }, skip: coreMissing);

    test('close stops the loop without reporting an error', () async {
      final errors = <Object>[];
      final connected = Completer<void>();

      final server = await _serveStream((response) {
        // A heartbeat comment, which is what the real server sends every ~25s
        // to hold an idle stream open. Also the only way the headers reach the
        // client at all: flushing an empty response writes nothing.
        response.write(': heartbeat\n\n');
        response.flush();
      });
      addTearDown(() => server.close(force: true));

      final stream = CoreStream(
        core: FreizoneCore(libraryPath: _corePath),
        state: _stateFor('http://${server.address.host}:${server.port}'),
        statePath: (id) async =>
            "${tempDir.path}${Platform.pathSeparator}core-$id",
      );

      final loop = stream.connect(
        onMessage: (_) {},
        onError: errors.add,
        onConnected: () {
          if (!connected.isCompleted) connected.complete();
        },
      );

      await connected.future.timeout(const Duration(seconds: 20));
      stream.close();

      // And promptly: well inside one poll timeout, because stopping closes the
      // channel the poll is waiting on rather than leaving it to expire. The
      // tight bound is the assertion -- a generous one would pass just as
      // happily if close() had gone back to costing a full 20 seconds.
      await loop.timeout(const Duration(seconds: 5));
      expect(
        errors,
        isEmpty,
        reason: 'a deliberate close is a clean disconnect',
      );
    }, skip: coreMissing);
  });
}
