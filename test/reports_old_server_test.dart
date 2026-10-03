// A new app against a server that predates reports (SRV-33).
//
// Reported from a device on 2026-08-30: opening Server Admin against
// chat.behringer24.de failed with "This address doesn't point to a Freizone
// server." The route is simply absent there, and net/http's mux answers
// `404 page not found` as **plain text** -- which the error path reads as "this
// host does not speak our JSON" rather than as "this route does not exist".
//
// The lesson is not about reports: any optional route added from here on has
// the same shape, and a non-JSON 404 from one of them must never be allowed to
// read as "wrong server".
//
// The exception that reached the screen was NotFreizoneServerException, thrown
// by the body parser -- deliberately **not** an ApiException, which is exactly
// why catching only that one let it through.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/state/app_session.dart';
import 'package:freizone/ffi/freizone_core.dart';
import 'package:freizone/state/local_state.dart';

String get _corePath {
  final name = Platform.isWindows
      ? 'freizonecore.dll'
      : Platform.isMacOS
      ? 'libfreizonecore.dylib'
      : 'libfreizonecore.so';
  return File('native/$name').absolute.path;
}

void main() {
  late HttpServer server;
  late int reportRequests;

  setUp(() async {
    reportRequests = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      if (request.uri.path == '/v1/admin/reports') reportRequests++;
      // Exactly what a server without the route says: Go's mux, plain text.
      request.response
        ..statusCode = 404
        ..headers.set('Content-Type', 'text/plain; charset=utf-8')
        ..write('404 page not found\n')
        ..close();
    });
  });

  tearDown(() => server.close(force: true));

  AppSession sessionFor(HttpServer server) {
    final state = AppState(
      server: 'http://${server.address.host}:${server.port}',
      accountId: 'fz1zzzzsyntheticaccountid0000000000',
      rootPub: Uint8List(32),
      rootPriv: Uint8List(64),
      deviceId: '12fe666bd3ad7819',
      devicePub: Uint8List(32),
      devicePriv: Uint8List(64),
    );
    return AppSession(state, core: FreizoneCore(libraryPath: _corePath));
  }

  test(
    'refreshReports asks nothing of a server that does not offer it',
    () async {
      // No init() here: it opens a core handle and a stream, and this needs
      // neither -- refreshReports is one HTTP call off state.credentials. Which
      // is also why there is nothing to dispose.
      final session = sessionFor(server);
      // reportsEnabled defaults to false and this server never says otherwise.
      await session.refreshReports();

      expect(
        reportRequests,
        0,
        reason:
            'the request must not be made at all -- discovered, not assumed',
      );
      expect(session.openReports, isEmpty);
    },
  );

  test('and it still does not throw if it is asked anyway', () async {
    // No init() here: it opens a core handle and a stream, and this needs
    // neither -- refreshReports is one HTTP call off state.credentials. Which
    // is also why there is nothing to dispose.
    final session = sessionFor(server);
    // The state a restart can produce: the status said yes, the route is gone.
    session.reportsEnabled = true;

    // The whole point. A side note on the admin screen must never be able to
    // take that screen down.
    await expectLater(session.refreshReports(), completes);
    expect(reportRequests, 1, reason: 'it did try');
    expect(session.openReports, isEmpty);
  });
}
