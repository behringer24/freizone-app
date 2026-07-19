import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/state/message_content.dart';

void main() {
  group('MessageContent encode/decode', () {
    test('round-trips a plain message', () {
      final content = MessageContent(id: 'abc123', text: 'hello there');
      final decoded = MessageContent.decode(
        content.encode(),
        fallbackId: 'unused',
      );
      expect(decoded.id, 'abc123');
      expect(decoded.text, 'hello there');
      expect(decoded.replyToId, isNull);
      expect(decoded.replyPreview, isNull);
    });

    test('round-trips a reply with its preview', () {
      final content = MessageContent(
        id: 'reply-id',
        text: 'yes exactly',
        replyToId: 'original-id',
        replyPreview: const ReplyPreview(text: 'original text', mine: true),
      );
      final decoded = MessageContent.decode(
        content.encode(),
        fallbackId: 'unused',
      );
      expect(decoded.replyToId, 'original-id');
      expect(decoded.replyPreview?.text, 'original text');
      expect(decoded.replyPreview?.mine, isTrue);
    });

    test('round-trips a federated sender_server', () {
      final content = MessageContent(
        id: 'fed-id',
        text: 'hi from another server',
        senderServer: 'https://chat.example.org',
      );
      final decoded = MessageContent.decode(
        content.encode(),
        fallbackId: 'unused',
      );
      expect(decoded.senderServer, 'https://chat.example.org');
    });

    test('omits sender_server entirely for a same-server message', () {
      final content = MessageContent(id: 'local-id', text: 'hi');
      final raw = jsonDecode(utf8.decode(content.encode())) as Map;
      expect(raw.containsKey('sender_server'), isFalse);
    });

    test('legacy (pre-envelope) bare-text plaintext falls back cleanly', () {
      final bytes = Uint8List.fromList(utf8.encode('just plain old text'));
      final decoded = MessageContent.decode(bytes, fallbackId: 'fallback-1');
      expect(decoded.id, 'fallback-1');
      expect(decoded.text, 'just plain old text');
      expect(decoded.replyToId, isNull);
    });

    test('plaintext that happens to look like JSON but has no "v" also falls back', () {
      final bytes = Uint8List.fromList(utf8.encode('{"foo":"bar"}'));
      final decoded = MessageContent.decode(bytes, fallbackId: 'fallback-2');
      expect(decoded.id, 'fallback-2');
      expect(decoded.text, '{"foo":"bar"}');
    });

    test('a newer, unrecognized envelope version degrades gracefully', () {
      final bytes = Uint8List.fromList(
        utf8.encode(jsonEncode({'v': 99, 'id': 'future-id', 'text': 'x'})),
      );
      final decoded = MessageContent.decode(bytes, fallbackId: 'fallback-3');
      expect(decoded.id, 'future-id');
      expect(decoded.text, isNot('x'));
      expect(decoded.replyToId, isNull);
    });
  });

  group('generateMessageId', () {
    test('produces distinct 32-char hex ids', () {
      final a = generateMessageId();
      final b = generateMessageId();
      expect(a, isNot(b));
      expect(a.length, 32);
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(a), isTrue);
    });
  });
}
