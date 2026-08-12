// End-to-end through the whole bridge: Dart calls the FFI core, the core opens
// a real HTTP connection to a server this test runs, and the events come back
// through the blocking poll into CoreStream's callbacks (SRV-23).
//
// This is the closest thing to "it runs on the device" that a host test can be,
// and it exists because everything it covers used to be unreachable: the core
// only built for Android, so no Dart test could load it at all.
//
// [handle] is opened once per test and set to a real identity -- since the cut
// (docs/design/23-shared-client-core.md), the core decrypts every message
// itself, so a handle whose identity cannot open anything is no longer enough
// to prove the crossing works. The one test that needs a message to actually
// decrypt builds a real X3DH handshake with the same stateless FFI crypto
// calls the old send path used (generateX25519KeyPair, initiateSession,
// sessionEncrypt, buildEnvelope) rather than a fixture -- self-contained, and
// it needs no one-time prekey: the responder core was never told one, and a
// bundle without one is exactly the sender-predates-the-field / pool-ran-dry
// path X3DH already has to support.
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
import 'package:freizone/ffi/freizone_core.dart';
import 'package:freizone/ffi/models.dart';
import 'package:freizone/state/core_account.dart';
import 'package:freizone/state/message_content.dart';

String get _corePath {
  final name = Platform.isWindows
      ? 'freizonecore.dll'
      : Platform.isMacOS
      ? 'libfreizonecore.dylib'
      : 'libfreizonecore.so';
  return File('native/$name').absolute.path;
}

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
    late FreizoneCore core;

    setUp(() {
      // The core's database path is resolved through path_provider, which has
      // no implementation in a plain test -- a temp directory stands in.
      tempDir = Directory.systemTemp.createTempSync('freizone-core-stream');
      core = FreizoneCore(libraryPath: _corePath);
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {
        // The core may still hold the database briefly; a leftover temp
        // directory is not worth failing a test over.
      }
    });

    /// Opens a handle against [server] with a minimal identity -- enough to
    /// sign requests and hold a stream. Real decrypt material is opt-in via
    /// [dhIdentityPriv]/[signedPrekeyId]/[signedPrekeyPriv], since most of
    /// these tests are about the connection lifecycle, not about what arrives
    /// on it.
    int openHandle(
      String server, {
      String accountId = 'fz1conformanceaccount',
      Uint8List? dhIdentityPriv,
      int signedPrekeyId = 0,
      Uint8List? signedPrekeyPriv,
    }) {
      final handle = core.coreOpen(
        '${tempDir.path}${Platform.pathSeparator}core-$accountId',
      );
      core.coreSetIdentity(
        handle: handle,
        accountId: accountId,
        server: server,
        rootPub: Uint8List(32),
        rootPriv: Uint8List(64),
        deviceId: 'device-1',
        devicePub: Uint8List(32),
        devicePriv: Uint8List(64),
        dhIdentityPriv: dhIdentityPriv,
        signedPrekeyId: signedPrekeyId,
        signedPrekeyPriv: signedPrekeyPriv,
      );
      return handle;
    }

    /// Starts [stream] and registers the one teardown order that is actually
    /// safe: stop the stream, wait for its `connect()` loop to really finish
    /// (its own `finally` still touches [handle] once), only then close the
    /// handle. `connect()` keeps running in the background after `close()`
    /// returns -- a plain `addTearDown(stream.close)` next to a separate
    /// `addTearDown(() => core.coreClose(handle))` races the two, and the
    /// loop's own cleanup then finds a handle a sibling teardown already
    /// closed.
    Future<void> startAndTeardown(
      CoreStream stream,
      int handle, {
      required void Function(PollOutcome) onMessage,
      void Function(Object)? onError,
      void Function()? onConnected,
    }) {
      final loop = stream.connect(
        onMessage: onMessage,
        onError: onError,
        onConnected: onConnected,
      );
      unawaited(loop);
      addTearDown(() async {
        stream.close();
        await loop.timeout(const Duration(seconds: 5), onTimeout: () {});
        core.coreClose(handle);
      });
      return loop;
    }

    test(
      'a real envelope decrypts and crosses as an outcome, not a payload',
      () async {
        const senderAccountId = 'fz1zzzzsyntheticsenderaccountid00000';

        // A real X3DH first contact, built with the same stateless crypto
        // calls the send path uses -- the "sender" here is nothing but a
        // throwaway keypair, since the protocol's decrypt path never checks
        // the DH identity against senderAccountId (that binding is the
        // account-level signature scheme HTTP requests use, not this one).
        final receiverDh = core.generateX25519KeyPair();
        final receiverSpk = core.generateX25519KeyPair();
        final senderDh = core.generateX25519KeyPair();
        final initiated = core.initiateSession(
          localDhIdentityPriv: senderDh.priv,
          remote: RemoteBundle(
            dhIdentityPub: receiverDh.pub,
            signedPrekeyId: 1,
            signedPrekeyPub: receiverSpk.pub,
          ),
        );
        final content = const MessageContent(id: 'x', text: 'hello').encode();
        final encrypted = core.sessionEncrypt(
          session: initiated.session,
          plaintext: content,
        );
        final payload = core.buildEnvelope(
          initial: initiated.initial,
          header: encrypted.header,
          ciphertext: encrypted.ciphertext,
          rekey: false,
        );

        final outcome = Completer<PollOutcome>();
        final connected = Completer<void>();

        final server = await _serveStream((response) {
          _writeFrame(response, {
            'message_id': 'm1',
            'sender_account_id': senderAccountId,
            'sender_device_id': 'device-2',
            'sent_at': '2026-08-07T09:00:00.000Z',
            'payload': payload,
          });
          response.flush();
        });
        addTearDown(() => server.close(force: true));

        final handle = openHandle(
          'http://${server.address.host}:${server.port}',
          dhIdentityPriv: receiverDh.priv,
          signedPrekeyId: 1,
          signedPrekeyPriv: receiverSpk.priv,
        );
        final stream = CoreStream(core: core, handle: handle);
        startAndTeardown(
          stream,
          handle,
          onMessage: (o) {
            if (!outcome.isCompleted) outcome.complete(o);
          },
          onConnected: () {
            if (!connected.isCompleted) connected.complete();
          },
          // Not decoration: without it a failed attempt is dropped and the
          // test fails as a bare timeout with nothing to go on.
          onError: (e) {
            if (!connected.isCompleted) connected.completeError(e);
            if (!outcome.isCompleted) outcome.completeError(e);
          },
        );

        await connected.future.timeout(const Duration(seconds: 20));
        final got = await outcome.future.timeout(const Duration(seconds: 20));

        // The shell gets an outcome, never the envelope: no payload, no
        // plaintext -- just what changed and whether to say something.
        expect(got.chatId, senderAccountId);
        expect(
          got.notify,
          isTrue,
          reason: 'a first message from a stranger is a new message request',
        );
        expect(got.invitation, isFalse);

        // And the core actually decrypted it: read back through the account
        // API rather than trusting the outcome alone.
        final account = CoreAccount(core: core, handle: handle);
        final messages = account.messages(senderAccountId);
        expect(messages, isNotEmpty);
        expect(messages.last.text, 'hello');
      },
      skip: coreMissing,
    );

    // What a (re)connect owes the queue. The stream drops events rather than
    // let a slow consumer stall the connection (pkg/client's Stream buffers 32
    // and discards past that), nothing re-pushes what it dropped, and the
    // server only wakes a device with no stream open -- so before
    // CoreAccount.sync ran here, an envelope lost that way waited for an app
    // restart. This pins that a drain reaches the same outcome a streamed
    // envelope would, through the same receive path.
    test(
      'a connect drains the queue and reports what was in it',
      () async {
        const senderAccountId = 'fz1zzzzsyntheticsenderaccountid00000';

        final receiverDh = core.generateX25519KeyPair();
        final receiverSpk = core.generateX25519KeyPair();
        final senderDh = core.generateX25519KeyPair();
        final initiated = core.initiateSession(
          localDhIdentityPriv: senderDh.priv,
          remote: RemoteBundle(
            dhIdentityPub: receiverDh.pub,
            signedPrekeyId: 1,
            signedPrekeyPub: receiverSpk.pub,
          ),
        );
        final encrypted = core.sessionEncrypt(
          session: initiated.session,
          plaintext: const MessageContent(id: 'q1', text: 'queued').encode(),
        );
        final payload = core.buildEnvelope(
          initial: initiated.initial,
          header: encrypted.header,
          ciphertext: encrypted.ciphertext,
          rekey: false,
        );

        var acked = false;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) {
          final path = request.uri.path;
          if (request.method == 'GET' && path == '/v1/messages') {
            // A bare array, which is what the real endpoint answers.
            request.response
              ..headers.set('Content-Type', 'application/json')
              ..write(
                json.encode([
                  {
                    'message_id': 'q-m1',
                    'sender_account_id': senderAccountId,
                    'sender_device_id': 'device-2',
                    'sent_at': '2026-08-10T09:00:00.000Z',
                    'payload': payload,
                  },
                ]),
              )
              ..close();
            return;
          }
          if (request.method == 'DELETE' && path == '/v1/messages/q-m1') {
            acked = true;
            request.response
              ..statusCode = 200
              ..close();
            return;
          }
          // Everything the housekeeping after the drain reaches for (prekey
          // status, server status, peer resolution for the receipt). Refused
          // fast on purpose: those are best-effort and belong in
          // SyncReport.problems, and this test is about the drain.
          request.response
            ..statusCode = 404
            ..headers.set('Content-Type', 'application/json')
            ..write('{"error":{"code":"not_found","message":"no"}}')
            ..close();
        });
        addTearDown(() => server.close(force: true));

        final handle = openHandle(
          'http://${server.address.host}:${server.port}',
          dhIdentityPriv: receiverDh.priv,
          signedPrekeyId: 1,
          signedPrekeyPriv: receiverSpk.priv,
        );
        addTearDown(() => core.coreClose(handle));

        final account = CoreAccount(
          core: core,
          handle: handle,
          libraryPath: _corePath,
        );
        final report = await account.sync().timeout(
          const Duration(seconds: 30),
        );

        expect(
          report.outcomes.map((o) => o.chatId),
          contains(senderAccountId),
          reason: 'the queued envelope has to come back as an outcome',
        );
        expect(
          acked,
          isTrue,
          reason: 'a handled envelope must be acknowledged, or it is redelivered forever',
        );
        // Decrypted for real, not merely reported: read it back the way a
        // screen would.
        expect(account.messages(senderAccountId).last.text, 'queued');
      },
      skip: coreMissing,
    );

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

        final handle = openHandle(
          'http://${server.address.host}:${server.port}',
        );
        final stream = CoreStream(core: core, handle: handle);
        startAndTeardown(
          stream,
          handle,
          onMessage: (_) {},
          onError: (e) {
            failures.add(e);
            // Two is what shows it is a retry loop rather than one attempt.
            if (failures.length >= 2 && !twoFailures.isCompleted) {
              twoFailures.complete();
            }
          },
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

      final handle = openHandle(
        'http://${server.address.host}:${server.port}',
      );
      final stream = CoreStream(core: core, handle: handle);
      startAndTeardown(
        stream,
        handle,
        onMessage: (_) {},
        onError: errors.add,
        onConnected: () {
          connects++;
          if (connects >= 2 && !reconnected.isCompleted) {
            reconnected.complete();
          }
        },
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

      final handle = openHandle(
        'http://${server.address.host}:${server.port}',
      );
      final stream = CoreStream(core: core, handle: handle);
      final loop = startAndTeardown(
        stream,
        handle,
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
      // happily if close() had gone back to costing a full 20 seconds. The
      // teardown will call close() and await the loop again -- harmless, both
      // are idempotent -- but the tight bound has to be checked here, inline,
      // to mean anything.
      await loop.timeout(const Duration(seconds: 5));
      expect(
        errors,
        isEmpty,
        reason: 'a deliberate close is a clean disconnect',
      );

      // The handle itself must still be open: closing the stream must not have
      // closed the handle sends and reads still depend on.
      expect(() => core.coreChats(handle), returnsNormally);
    }, skip: coreMissing);
  });
}
