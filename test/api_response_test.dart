import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/net/api_client.dart';
import 'package:freizone/net/dto.dart';
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

  group('isServerUnreachable', () {
    // Guards profile_screen's delete flow: only a transport-level failure
    // (the server was never reached) may fall back to a local-only removal.
    // A server that answered -- an ApiException, or a non-Freizone reply --
    // must not, since it tells us the account's real server-side state.
    test('is true for transport-level failures', () {
      expect(isServerUnreachable(const SocketException('refused')), isTrue);
      expect(isServerUnreachable(http.ClientException('closed')), isTrue);
      expect(isServerUnreachable(const HandshakeException('tls')), isTrue);
      expect(isServerUnreachable(TimeoutException('timed out')), isTrue);
    });

    test('is false when the server actually answered', () {
      expect(
        isServerUnreachable(ApiException(401, 'unauthorized', 'nope')),
        isFalse,
      );
      expect(
        isServerUnreachable(NotFreizoneServerException(404, 'google.com')),
        isFalse,
      );
    });
  });

  group('batch delivery capability', () {
    test('a server that does not advertise it is treated as not having it', () {
      // Discovered, never assumed: a group spans servers of different vintages,
      // and the fan-out posts individually to one that cannot batch.
      final old = ServerStatus.fromJson({
        'claimed': true,
        'registration_policy': 'open',
      });
      expect(old.batchMessages, isFalse);
      expect(old.maxBatchMessages, 0);

      final current = ServerStatus.fromJson({
        'claimed': true,
        'registration_policy': 'open',
        'batch_messages': true,
        'max_batch_messages': 100,
      });
      expect(current.batchMessages, isTrue);
      expect(current.maxBatchMessages, 100);
    });

    test('a duplicate counts as delivered, an unknown status does not', () {
      // Same reasoning as the 409 on the single-message route: that id is
      // already queued, so a retry has nothing left to do.
      expect(
        BatchSendResult.fromJson({'message_id': 'a', 'status': 'queued'})
            .isDelivered,
        isTrue,
      );
      expect(
        BatchSendResult.fromJson({'message_id': 'a', 'status': 'duplicate'})
            .isDelivered,
        isTrue,
      );
      for (final status in ['queue_full', 'unknown_recipient', 'invalid']) {
        expect(
          BatchSendResult.fromJson({
            'message_id': 'a',
            'status': status,
          }).isDelivered,
          isFalse,
          reason: status,
        );
      }
      // A malformed item is a failure, not a silent success.
      expect(
        BatchSendResult.fromJson(const {}).isDelivered,
        isFalse,
      );
    });
  });

  group('blobRecipientQuery', () {
    test('names one recipient exactly as it always did', () {
      // A one-recipient upload has to stay byte-identical to what pre-SRV-18
      // clients send, since the signature covers the raw query string.
      expect(blobRecipientQuery(['abc123']), 'recipient_device_id=abc123');
    });

    test('repeats the parameter for a group send', () {
      expect(
        blobRecipientQuery(['a', 'b', 'c']),
        'recipient_device_id=a&recipient_device_id=b&recipient_device_id=c',
      );
    });

    test('escapes anything that would break the query string', () {
      expect(
        blobRecipientQuery(['a&b=c']),
        'recipient_device_id=a%26b%3Dc',
      );
    });
  });

  group('blobIdFromUploadResponse', () {
    test('takes the blob id when every recipient was stored', () {
      expect(
        blobIdFromUploadResponse({
          'blob_id': 'deadbeef',
          'size': 12,
          'recipients': [
            {'recipient_device_id': 'a', 'status': 'stored'},
            {'recipient_device_id': 'b', 'status': 'stored'},
          ],
        }, 200),
        'deadbeef',
      );
    });

    test('accepts a pre-SRV-18 response with no recipients list', () {
      // An older server answers 201 with the three original fields and nothing
      // else. Reading that as "nobody was stored" would break every upload to
      // a server that has not been updated.
      expect(
        blobIdFromUploadResponse({'blob_id': 'cafe', 'size': 3}, 201),
        'cafe',
      );
    });

    test('refuses a partial result rather than handing out the id', () {
      // One member at their quota would otherwise be sent a reference to a
      // picture they cannot fetch -- worse than being told it didn't arrive.
      expect(
        () => blobIdFromUploadResponse({
          'blob_id': 'deadbeef',
          'recipients': [
            {'recipient_device_id': 'a', 'status': 'stored'},
            {'recipient_device_id': 'b', 'status': 'quota_exceeded'},
          ],
        }, 200),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            contains('quota_exceeded'),
          ),
        ),
      );
    });

    test('refuses a response that stored nothing at all', () {
      // What the server answers when no recipient could be served: a 200 with
      // outcomes and no blob id.
      expect(
        () => blobIdFromUploadResponse({
          'recipients': [
            {'recipient_device_id': 'a', 'status': 'unknown_recipient'},
          ],
        }, 200),
        throwsA(isA<ApiException>()),
      );
    });

    test('refuses an empty blob id', () {
      expect(
        () => blobIdFromUploadResponse({'blob_id': ''}, 201),
        throwsA(isA<ApiException>()),
      );
    });
  });
}
