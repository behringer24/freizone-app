// The stale-device classification (docs/PROTOCOL.md §4). The property being
// tested throughout: **only an answer that names the device dead may cost the
// cached device id** -- because the reaction to "stale" discards that id and
// (on the delivery path) the ratchet session bound to it. Misclassifying a
// federation switch or a transient failure as "stale" throws away working
// state; misclassifying a dead device as transient is the bug this module
// exists because of -- a group member who re-created their account and then
// never received anything again, every send 404ing against a device id their
// server had long forgotten.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/net/api_client.dart';
import 'package:freizone/state/stale_device.dart';

void main() {
  group('isStaleDeviceError', () {
    test('the claim-path codes are stale', () {
      // `unknown_device`: the id names nothing -- the account was deleted and
      // re-created, so the old device rows cascaded away entirely.
      expect(
        isStaleDeviceError(ApiException(404, 'unknown_device', 'unknown device')),
        isTrue,
      );
      // `no_prekey_bundle`: the row exists but is revoked (or never
      // provisioned) -- equally unusable as a session target.
      expect(
        isStaleDeviceError(
          ApiException(404, 'no_prekey_bundle', 'device has no prekey bundle available'),
        ),
        isTrue,
      );
    });

    test('the delivery-path code is stale', () {
      expect(
        isStaleDeviceError(
          ApiException(404, 'unknown_recipient', 'unknown or inactive recipient'),
        ),
        isTrue,
      );
    });

    test('a server from before the distinct codes still counts', () {
      // Every live server predating the rule answers the same conditions with
      // the catch-all `not_found` -- healing must not wait for a fleet
      // upgrade.
      expect(
        isStaleDeviceError(ApiException(404, 'not_found', 'unknown device')),
        isTrue,
      );
      // Even a codeless 404 body counts: it is still that server's answer to
      // the device id we sent, not a transport failure.
      expect(isStaleDeviceError(ApiException(404, null, '')), isTrue);
    });

    test('federation_disabled is about the server, never the device', () {
      expect(
        isStaleDeviceError(
          ApiException(404, 'federation_disabled', 'federation is disabled on this server'),
        ),
        isFalse,
      );
    });

    test('non-404 answers and non-API failures are not evidence', () {
      // Unreachable is not gone -- the same line peer_absence.dart draws.
      expect(isStaleDeviceError(ApiException(401, 'unauthorized', '')), isFalse);
      expect(isStaleDeviceError(ApiException(500, 'internal', '')), isFalse);
      expect(isStaleDeviceError(ApiException(429, 'recipient_queue_full', '')), isFalse);
      expect(isStaleDeviceError(const SocketException('refused')), isFalse);
      expect(isStaleDeviceError(StateError('invalid dh identity certificate')), isFalse);
    });
  });

  group('isStaleRecipientStatus', () {
    test('only unknown_recipient names a dead device', () {
      expect(isStaleRecipientStatus('unknown_recipient'), isTrue);
    });

    test('statuses a retry can outlive are not stale', () {
      // A full queue empties, an internal error passes; the same device stays
      // the right target for the retry.
      expect(isStaleRecipientStatus('queue_full'), isFalse);
      expect(isStaleRecipientStatus('internal_error'), isFalse);
      expect(isStaleRecipientStatus('invalid'), isFalse);
      expect(isStaleRecipientStatus('queued'), isFalse);
      expect(isStaleRecipientStatus(null), isFalse);
    });
  });
}
