import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/state/message_content.dart';
import 'package:freizone/state/receipt_signal.dart';

void main() {
  group('ReceiptSignal encode/decode', () {
    test('round-trips a delivered receipt', () {
      final upTo = DateTime.utc(2026, 7, 21, 12, 0, 0);
      final signal = ReceiptSignal(
        status: ReceiptStatus.delivered,
        upToSentAt: upTo,
      );
      final decoded = ReceiptSignal.tryDecode(signal.encode());
      expect(decoded, isNotNull);
      expect(decoded!.status, ReceiptStatus.delivered);
      expect(decoded.upToSentAt, upTo);
    });

    test('round-trips a read receipt', () {
      final upTo = DateTime.utc(2026, 7, 21, 12, 30, 0);
      final signal = ReceiptSignal(status: ReceiptStatus.read, upToSentAt: upTo);
      final decoded = ReceiptSignal.tryDecode(signal.encode());
      expect(decoded!.status, ReceiptStatus.read);
      expect(decoded.upToSentAt, upTo);
    });

    test('tryDecode returns null for an ordinary text message', () {
      final content = MessageContent(id: 'abc', text: 'hello');
      expect(ReceiptSignal.tryDecode(content.encode()), isNull);
    });

    test('tryDecode returns null for garbage bytes', () {
      final garbage = Uint8List.fromList(utf8.encode('not json at all'));
      expect(ReceiptSignal.tryDecode(garbage), isNull);
    });

    test('tryDecode returns null for well-formed JSON missing receipt fields', () {
      final bytes = Uint8List.fromList(
        utf8.encode(jsonEncode({'v': 2, 'kind': 'receipt'})),
      );
      expect(ReceiptSignal.tryDecode(bytes), isNull);
    });
  });
}
