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

    test('round-trips sent_at as UTC', () {
      final sentAt = DateTime.utc(2026, 7, 22, 9, 30, 15, 123);
      final content = MessageContent(id: 'ts-id', text: 'hi', sentAt: sentAt);
      final decoded = MessageContent.decode(
        content.encode(),
        fallbackId: 'unused',
      );
      expect(decoded.sentAt, sentAt);
      expect(decoded.sentAt!.isUtc, isTrue);
    });

    test('sent_at is null for a legacy sender that never included it', () {
      final bytes = Uint8List.fromList(
        utf8.encode(jsonEncode({'v': 1, 'id': 'old-id', 'text': 'hi'})),
      );
      final decoded = MessageContent.decode(bytes, fallbackId: 'unused');
      expect(decoded.sentAt, isNull);
    });

    test('omits sent_at entirely when not set', () {
      final content = MessageContent(id: 'no-ts', text: 'hi');
      final raw = jsonDecode(utf8.decode(content.encode())) as Map;
      expect(raw.containsKey('sent_at'), isFalse);
    });

    test('an unparsable sent_at decodes as null, not an error', () {
      final bytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({'v': 1, 'id': 'bad-ts', 'text': 'hi', 'sent_at': 'nope'}),
        ),
      );
      final decoded = MessageContent.decode(bytes, fallbackId: 'unused');
      expect(decoded.sentAt, isNull);
      expect(decoded.text, 'hi');
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

  group('attachments', () {
    MessageAttachment sampleAttachment({Uint8List? thumb}) => MessageAttachment(
      kind: 'image',
      blobId: 'a' * 64,
      key: Uint8List.fromList(List.generate(32, (i) => i)),
      mimeType: 'image/jpeg',
      byteSize: 184320,
      width: 1600,
      height: 1200,
      thumb: thumb,
    );

    test('round-trip through encode/decode', () {
      final content = MessageContent(
        id: 'msg1',
        text: 'look at this',
        attachments: [sampleAttachment()],
      );

      final decoded = MessageContent.decode(content.encode(), fallbackId: 'x');

      expect(decoded.text, 'look at this');
      expect(decoded.attachments, hasLength(1));
      final a = decoded.attachments.first;
      expect(a.kind, 'image');
      expect(a.isImage, isTrue);
      expect(a.blobId, 'a' * 64);
      expect(a.key, sampleAttachment().key);
      expect(a.mimeType, 'image/jpeg');
      expect(a.byteSize, 184320);
      expect(a.width, 1600);
      expect(a.height, 1200);
      expect(a.algorithm, MessageAttachment.defaultAlgorithm);
    });

    test('a thumbnail survives the round-trip', () {
      final thumb = Uint8List.fromList(List.filled(500, 7));
      final content = MessageContent(
        id: 'm',
        text: '',
        attachments: [sampleAttachment(thumb: thumb)],
      );

      final decoded = MessageContent.decode(content.encode(), fallbackId: 'x');
      expect(decoded.attachments.first.thumb, thumb);
    });

    test('an oversized thumbnail is dropped on both encode and decode', () {
      // The cap has to hold on the receiving side too: a peer must not be
      // able to inflate our stored history with a huge inline preview.
      final huge = Uint8List.fromList(
        List.filled(maxAttachmentThumbBytes + 1, 9),
      );
      final content = MessageContent(
        id: 'm',
        text: '',
        attachments: [sampleAttachment(thumb: huge)],
      );

      final encoded = utf8.decode(content.encode());
      expect(encoded.contains('thumb'), isFalse);
      expect(
        MessageContent.decode(content.encode(), fallbackId: 'x').attachments.first.thumb,
        isNull,
      );
    });

    test('stays version 1, so older builds still read the text', () {
      // The whole point of reusing the reserved "attachments" field instead
      // of bumping the version: an older client ignores the unknown entry
      // and still renders the caption, rather than showing the
      // "newer app feature" placeholder for every picture.
      final content = MessageContent(
        id: 'm',
        text: 'caption',
        attachments: [sampleAttachment()],
      );
      final raw = jsonDecode(utf8.decode(content.encode())) as Map<String, dynamic>;
      expect(raw['v'], 1);
      expect(raw['text'], 'caption');
    });

    test('a message with no attachments decodes to an empty list', () {
      final decoded = MessageContent.decode(
        const MessageContent(id: 'm', text: 'plain').encode(),
        fallbackId: 'x',
      );
      expect(decoded.attachments, isEmpty);
    });

    test('a malformed attachment is skipped, keeping the message', () {
      // Missing blob_id/key -- unusable, but the text must still arrive.
      final raw = utf8.encode(jsonEncode({
        'v': 1,
        'id': 'm',
        'text': 'still readable',
        'attachments': [
          {'kind': 'image', 'mime': 'image/jpeg'},
          'not even an object',
        ],
      }));

      final decoded = MessageContent.decode(Uint8List.fromList(raw), fallbackId: 'x');
      expect(decoded.text, 'still readable');
      expect(decoded.attachments, isEmpty);
    });

    test('an unknown kind is preserved rather than dropped', () {
      // Forward compatibility: a future video attachment must reach the UI
      // so it can show "unsupported", not vanish silently.
      final raw = utf8.encode(jsonEncode({
        'v': 1,
        'id': 'm',
        'text': '',
        'attachments': [
          {
            'kind': 'video',
            'blob_id': 'b' * 64,
            'key': base64Encode(List.filled(32, 1)),
            'mime': 'video/mp4',
            'size': 1,
            'w': 1,
            'h': 1,
          },
        ],
      }));

      final decoded = MessageContent.decode(Uint8List.fromList(raw), fallbackId: 'x');
      expect(decoded.attachments, hasLength(1));
      expect(decoded.attachments.first.kind, 'video');
      expect(decoded.attachments.first.isImage, isFalse);
    });
  });
}
