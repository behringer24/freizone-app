// What a stream (re)connect owes the queue, driven through a real AppSession.
//
// core_stream_test.dart already pins the two halves separately: that CoreStream
// calls onConnected, and that CoreAccount.sync drains the queue. What neither
// covers is the wiring between them -- AppSession is what passes one to the
// other, and it is the piece that was missing when a dropped envelope waited
// for an app restart (see CoreAccount.sync). So this drives the whole thing:
// no message is ever streamed here, only queued, and it still has to arrive.
//
// The setup is heavy because AppSession is: init() reaches for prekeys, push
// registration, server status and the media sweep, all of which fail against
// the stub below and are all caught by design. The mocked channels are the
// ones whose absence would otherwise throw *past* those catches --
// path_provider (every path AppSession resolves) and local_notifications (a
// stranger's first message notifies, and _handleIncoming does not await it,
// so a MissingPluginException there surfaces as an unhandled async error and
// fails the test rather than the code under test).
//
// Needs the host core, like core_stream_test.dart:
//
//     ./native/build_desktop.ps1
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/ffi/freizone_core.dart';
import 'package:freizone/ffi/models.dart';
import 'package:freizone/state/app_session.dart';
import 'package:freizone/state/local_state.dart';
import 'package:freizone/state/message_content.dart';

String get _corePath {
  final name = Platform.isWindows
      ? 'freizonecore.dll'
      : Platform.isMacOS
      ? 'libfreizonecore.dylib'
      : 'libfreizonecore.so';
  return File('native/$name').absolute.path;
}

void main() {
  final coreMissing = !File(_corePath).existsSync()
      ? 'native core not built for this host -- run native/build_desktop.ps1'
      : null;

  late Directory tempDir;
  late FreizoneCore core;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = Directory.systemTemp.createTempSync('freizone-session-connect');

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // Every path AppSession resolves -- the core's own directory, the profile,
    // the media store -- comes through here.
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
    // Swallowed rather than asserted on: that a first message notifies is
    // core_stream_test.dart's business, and here it only needs to not throw.
    messenger.setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      (call) async => null,
    );

    core = FreizoneCore(libraryPath: _corePath);
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      null,
    );
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {
      // The core may still hold its files briefly; a leftover temp directory
      // is not worth failing a test over.
    }
  });

  test('a stream connect drains the queue into the session', () async {
    const senderAccountId = 'fz1zzzzsyntheticsenderaccountid00000';
    const receiverAccountId = 'fz1connectdraintestaccount000000';

    // A real X3DH first contact, built with the same stateless crypto calls
    // the send path uses. No one-time prekey: the receiving core was never
    // told one, which is the pool-ran-dry path X3DH already supports.
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
      plaintext: const MessageContent(
        id: 'queued-1',
        text: 'only ever queued',
      ).encode(),
    );
    final payload = core.buildEnvelope(
      initial: initiated.initial,
      header: encrypted.header,
      ciphertext: encrypted.ciphertext,
      rekey: false,
    );

    var queueFetches = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      final path = request.uri.path;

      // The stream: held open, and carrying nothing but the heartbeat comment
      // a real server sends. No message is ever pushed down it, so anything
      // that arrives came from the queue.
      if (path == '/v1/messages/stream') {
        request.response
          ..headers.set('Content-Type', 'text/event-stream')
          ..statusCode = 200
          // Without this dart:io buffers the whole response and the core never
          // gets past waiting for headers, so the connect -- and the drain it
          // triggers -- never happens.
          ..bufferOutput = false
          // And the headers only actually go out once there is something to
          // send with them: flushing an empty response writes nothing, which
          // reads to the core as a stream that never opened. A comment is the
          // right something -- the core ignores it, exactly as it does the
          // real server's heartbeat.
          ..write(': heartbeat\n\n');
        request.response.flush();
        return;
      }

      if (request.method == 'GET' && path == '/v1/messages') {
        queueFetches++;
        // A bare array, which is what the real endpoint answers. Served once:
        // a second fetch finds it drained, exactly as acknowledging it would
        // leave the real queue.
        final body = queueFetches == 1
            ? [
                {
                  'message_id': 'q-m1',
                  'sender_account_id': senderAccountId,
                  'sender_device_id': 'device-2',
                  'sent_at': '2026-08-10T09:00:00.000Z',
                  'payload': payload,
                },
              ]
            : <Map<String, dynamic>>[];
        request.response
          ..headers.set('Content-Type', 'application/json')
          ..write(json.encode(body))
          ..close();
        return;
      }

      if (request.method == 'DELETE' && path.startsWith('/v1/messages/')) {
        request.response
          ..statusCode = 200
          ..close();
        return;
      }

      // Everything else init() and the post-drain housekeeping reach for:
      // prekey status, server status, push target, peer resolution for the
      // receipt. Refused fast on purpose -- all of it is best-effort, and
      // this test is about the drain.
      request.response
        ..statusCode = 404
        ..headers.set('Content-Type', 'application/json')
        ..write('{"error":{"code":"not_found","message":"no"}}')
        ..close();
    });
    addTearDown(() => server.close(force: true));

    // signedPrekey* set, so init() re-asserts rather than minting a first one
    // -- and so the envelope above can actually be opened.
    final state = AppState(
      server: 'http://${server.address.host}:${server.port}',
      accountId: receiverAccountId,
      rootPub: Uint8List(32),
      rootPriv: Uint8List(64),
      // Hex, because the certificates the prekey re-assertion signs decode it
      // -- a readable name there fails before the network even matters.
      deviceId: '12fe666bd3ad7819',
      devicePub: Uint8List(32),
      devicePriv: Uint8List(64),
      dhIdentityPub: receiverDh.pub,
      dhIdentityPriv: receiverDh.priv,
      signedPrekeyId: 1,
      signedPrekeyPub: receiverSpk.pub,
      signedPrekeyPriv: receiverSpk.priv,
    );

    final session = AppSession(state, core: core);
    addTearDown(session.dispose);

    await session.init();

    // The drain is fire-and-forget off the connect, so wait for its effect
    // rather than for the call: the message has to turn up in the session's
    // own view of the conversation, which is what a screen reads.
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      final convo = state.conversations[senderAccountId];
      if (convo != null && convo.messages.any((m) => m.text == 'only ever queued')) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    expect(
      queueFetches,
      greaterThan(0),
      reason: 'a connect has to fetch the queue at all',
    );
    final convo = state.conversations[senderAccountId];
    expect(
      convo,
      isNotNull,
      reason:
          'an envelope that was only ever queued -- never streamed -- still '
          'has to reach the session',
    );
    expect(
      convo!.messages.map((m) => m.text),
      contains('only ever queued'),
    );
  }, skip: coreMissing);
}
