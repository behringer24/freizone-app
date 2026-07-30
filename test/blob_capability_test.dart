import 'package:flutter_test/flutter_test.dart';
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
        status({'blobs_enabled': true, 'max_blob_bytes': 4194304}),
      );
      expect(cap.enabled, isTrue);
      expect(cap.maxBytes, 4194304);
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
