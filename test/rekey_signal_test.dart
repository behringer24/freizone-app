import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/state/message_content.dart';
import 'package:freizone/state/receipt_signal.dart';
import 'package:freizone/state/rekey_signal.dart';

void main() {
  group('RekeySignal encode/decode', () {
    test('round-trips its reason', () {
      for (final reason in RekeyReason.values) {
        final decoded = RekeySignal.tryDecode(RekeySignal(reason: reason).encode());
        expect(decoded, isNotNull);
        expect(decoded!.reason, reason);
      }
    });

    test('defaults to unspecified', () {
      expect(RekeySignal.tryDecode(const RekeySignal().encode())!.reason,
          RekeyReason.unspecified);
    });

    // Pinned literally: other clients parse these, so they are a contract
    // (docs/PROTOCOL.md §6 in freizone-server), not an implementation detail
    // that may follow a Dart rename.
    test('encodes the wire shape the protocol documents', () {
      final json = jsonDecode(
        utf8.decode(const RekeySignal(reason: RekeyReason.decryptFailures).encode()),
      );
      expect(json, {'v': 3, 'kind': 'rekey', 'reason': 'decrypt_failures'});
      expect(
        jsonDecode(utf8.decode(
          const RekeySignal(reason: RekeyReason.userRequested).encode(),
        ))['reason'],
        'user_requested',
      );
    });

    test('an unknown reason decodes as unspecified rather than failing', () {
      final bytes = Uint8List.fromList(
        utf8.encode(jsonEncode({'v': 3, 'kind': 'rekey', 'reason': 'from_the_future'})),
      );
      final decoded = RekeySignal.tryDecode(bytes);
      expect(decoded, isNotNull);
      expect(decoded!.reason, RekeyReason.unspecified);
    });

    test('tryDecode returns null for an ordinary text message', () {
      expect(RekeySignal.tryDecode(MessageContent(id: 'abc', text: 'hi').encode()),
          isNull);
    });

    test('tryDecode returns null for garbage bytes', () {
      expect(
        RekeySignal.tryDecode(Uint8List.fromList(utf8.encode('not json at all'))),
        isNull,
      );
    });

    // The three control shapes travel the same pipeline and are told apart
    // only by their (v, kind) pair, so each must reject the others outright --
    // a re-key mistaken for a receipt would silently move a peer's checkmarks,
    // and a receipt mistaken for a re-key would add a bogus reset marker.
    test('does not collide with a receipt, in either direction', () {
      final receipt = ReceiptSignal(
        status: ReceiptStatus.read,
        upToSentAt: DateTime.utc(2026, 8, 1),
      ).encode();
      expect(RekeySignal.tryDecode(receipt), isNull);
      expect(ReceiptSignal.tryDecode(const RekeySignal().encode()), isNull);
    });

    // A re-key carries no readable content, but an older build has no way to
    // know that -- worth pinning what it actually does, since this is the one
    // user-visible cost of the format choice (see rekey_signal.dart).
    test('an older build sees the generic newer-feature placeholder', () {
      final content = MessageContent.decode(
        const RekeySignal().encode(),
        fallbackId: 'fallback',
      );
      expect(content.text, contains('newer app feature'));
    });
  });
}
