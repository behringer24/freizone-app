import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/net/api_client.dart';
import 'package:freizone/util/errors.dart';
import 'package:http/http.dart' as http;

void main() {
  group('parseJsonObject', () {
    test('returns the decoded object for a JSON object body', () {
      final resp = http.Response('{"id":"qu0pc","devices":[]}', 200);
      expect(parseJsonObject(resp), {'id': 'qu0pc', 'devices': <dynamic>[]});
    });

    test('throws NotFreizoneServerException for an HTML body', () {
      // A plain web server's 404 page -- the exact symptom of pointing an
      // address at a domain that isn't running Freizone (e.g. *google.com).
      final resp = http.Response(
        '<!DOCTYPE html><html><head><title>404</title></head></html>',
        404,
      );
      expect(
        () => parseJsonObject(resp),
        throwsA(isA<NotFreizoneServerException>()),
      );
    });

    test('throws NotFreizoneServerException for a 200 HTML landing page', () {
      final resp = http.Response('<html><body>Parked</body></html>', 200);
      expect(
        () => parseJsonObject(resp),
        throwsA(isA<NotFreizoneServerException>()),
      );
    });

    test('throws NotFreizoneServerException for a non-object JSON body', () {
      // Valid JSON, but not the object shape a Freizone endpoint returns.
      final resp = http.Response('[1,2,3]', 200);
      expect(
        () => parseJsonObject(resp),
        throwsA(isA<NotFreizoneServerException>()),
      );
    });
  });

  group('describeError', () {
    test('maps NotFreizoneServerException to an actionable hint', () {
      final msg = describeError(NotFreizoneServerException(404, 'google.com'));
      expect(msg.toLowerCase(), contains('freizone server'));
      // Must never leak the raw HTML page (the bug this fixes).
      expect(msg, isNot(contains('<')));
    });

    test('passes an ApiException message straight through', () {
      expect(
        describeError(ApiException(404, 'not_found', 'no such account')),
        'no such account',
      );
    });
  });
}
