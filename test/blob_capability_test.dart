import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/net/api_client.dart';
import 'package:freizone/net/dto.dart';
import 'package:freizone/state/outgoing_attachment.dart';

ServerStatus status(Map<String, dynamic> extra) => ServerStatus.fromJson({
  'claimed': true,
  'registration_policy': 'open',
  ...extra,
});

void main() {
  group('ServerStatus attachment fields', () {
    test('reads blobs_enabled and max_blob_bytes when the server sends them', () {
      final s = status({'blobs_enabled': true, 'max_blob_bytes': 8388608});
      expect(s.blobsEnabled, isTrue);
      expect(s.maxBlobBytes, 8388608);
    });

    test('a server that omits blobs_enabled is treated as not supporting them', () {
      // The opposite default from federation_enabled below, and deliberately
      // so: attachments arrived with SRV-07, so silence means "older server,
      // no blob endpoints", not "on by default".
      final s = status({});
      expect(s.blobsEnabled, isFalse);
      expect(s.maxBlobBytes, 0);
    });

    test('federation still defaults to on when omitted', () {
      expect(status({}).federationEnabled, isTrue);
    });

    test('an explicit blobs_enabled:false is honoured', () {
      expect(status({'blobs_enabled': false}).blobsEnabled, isFalse);
    });

    test('reads max_blob_recipients when the server states it', () {
      expect(status({'max_blob_recipients': 100}).maxBlobRecipients, 100);
    });

    test('a server that omits max_blob_recipients means ONE, not unlimited', () {
      // The whole point of the field (SRV-18): an older server reads only the
      // first recipient, stores the blob for that one device and still answers
      // 201 -- so guessing "unlimited" would silently deliver a group picture
      // to a single member.
      expect(status({'blobs_enabled': true}).maxBlobRecipients, 1);
    });

    test('a nonsensical max_blob_recipients is floored at one', () {
      // A shared upload is never attempted on the strength of a 0 or a
      // negative: one upload per member always works.
      expect(status({'max_blob_recipients': 0}).maxBlobRecipients, 1);
      expect(status({'max_blob_recipients': -5}).maxBlobRecipients, 1);
    });
  });

  group('BlobCapability', () {
    test('accepts anything up to the stated limit', () {
      const cap = BlobCapability(enabled: true, maxBytes: 1000);
      expect(cap.fits(999), isTrue);
      expect(cap.fits(1000), isTrue);
      expect(cap.fits(1001), isFalse);
    });

    test('an unstated limit is not enforced locally', () {
      // Nothing to compare against, so let the upload happen and let the
      // server be the one to refuse it.
      const cap = BlobCapability(enabled: true, maxBytes: 0);
      expect(cap.fits(50 * 1024 * 1024), isTrue);
    });

    test('is built straight from a server status', () {
      final cap = BlobCapability.from(
        status({
          'blobs_enabled': true,
          'max_blob_bytes': 4194304,
          'max_blob_recipients': 50,
        }),
      );
      expect(cap.enabled, isTrue);
      expect(cap.maxBytes, 4194304);
      expect(cap.maxRecipients, 50);
    });

    test('defaults to one recipient per upload', () {
      // What a group send falls back to against a server predating SRV-18:
      // an upload each, which works everywhere.
      const cap = BlobCapability(enabled: true, maxBytes: 0);
      expect(cap.maxRecipients, 1);
      expect(
        BlobCapability.from(status({'blobs_enabled': true})).maxRecipients,
        1,
      );
    });
  });

  group('isPermanentBlobRefusal', () {
    // Why this distinction exists: a group copy that counts as delivered is
    // never revisited, so recording a transient failure as a refusal strands
    // that member's picture permanently. It showed up in testing as "1 member
    // could not receive the picture" that could not be reproduced afterwards.
    test('the server saying no is permanent', () {
      // Blobs switched off, or an unknown/inactive recipient device.
      expect(
        isPermanentBlobRefusal(ApiException(404, 'not_found', 'nope')),
        isTrue,
      );
      // Over that server's per-picture cap.
      expect(
        isPermanentBlobRefusal(
          ApiException(413, 'payload_too_large', 'too big'),
        ),
        isTrue,
      );
    });

    test('anything a retry might get past is not', () {
      for (final error in <Object>[
        TimeoutException('no answer'),
        const SocketException('connection reset'),
        ApiException(500, 'internal', 'server error'),
        ApiException(502, null, 'bad gateway'),
        // A quota frees itself as soon as the recipient empties their
        // downloads, so this must not be treated as a standing refusal.
        ApiException(429, 'blob_quota_exceeded', 'full'),
        // "Stored nothing" from our own partial-result check.
        ApiException(200, 'blob_not_stored', 'refused for a: quota_exceeded'),
        StateError('something else entirely'),
      ]) {
        expect(
          isPermanentBlobRefusal(error),
          isFalse,
          reason: error.toString(),
        );
      }
    });
  });

  group('formatByteSize', () {
    test('renders whole megabytes without a decimal', () {
      expect(formatByteSize(8 * 1024 * 1024), '8 MB');
    });

    test('renders a fractional megabyte with one decimal', () {
      expect(formatByteSize(1536 * 1024), '1.5 MB');
    });

    test('falls back to kilobytes below a megabyte', () {
      expect(formatByteSize(512 * 1024), '512 KB');
    });
  });
}
