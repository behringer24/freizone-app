// The client-to-client wire shapes groups add (APP-16 phase 5): `v: 4` group
// chat content and the `v: 5` control envelope. Pure logic, and the contract
// both the send and receive paths are built on -- a second client has to be
// able to reproduce exactly this.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/state/message_content.dart';

Map<String, dynamic> asJson(Uint8List bytes) =>
    jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

Uint8List asBytes(Map<String, dynamic> json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

void main() {
  group('MessageContent as group chat content', () {
    test('a one-to-one message is still exactly v: 1', () {
      // The freeze that everything else here depends on: adding groups must
      // not change a single byte of what an ordinary chat message looks like.
      final json = asJson(
        const MessageContent(id: 'm1', text: 'hallo').encode(),
      );
      expect(json['v'], 1);
      expect(json.containsKey('group_id'), isFalse);
      expect(json.containsKey('state_hash'), isFalse);
    });

    test('a group message is v: 4 and carries the group and state hash', () {
      final json = asJson(
        const MessageContent(
          id: 'm1',
          text: 'Samstag 9 Uhr',
          groupId: 'p2xjx0000000000000000',
          stateHash: 'abc123',
        ).encode(),
      );
      expect(json['v'], 4);
      expect(json['group_id'], 'p2xjx0000000000000000');
      expect(json['state_hash'], 'abc123');
      // Everything else is v: 1's shape unchanged.
      expect(json['id'], 'm1');
      expect(json['text'], 'Samstag 9 Uhr');
      expect(json['attachments'], isEmpty);
    });

    test('round-trips, replies and attachments included', () {
      final encoded = MessageContent(
        id: 'm2',
        text: 'passt',
        groupId: 'p2xjx0000000000000000',
        stateHash: 'abc123',
        replyToId: 'm1',
        replyPreview: const ReplyPreview(
          text: 'Samstag?',
          mine: false,
          author: 'qk43rj6cphungwkeznxza',
        ),
        sentAt: DateTime.utc(2026, 8, 2, 12),
        attachments: [
          MessageAttachment(
            kind: 'image',
            blobId: 'a' * 64,
            key: Uint8List.fromList(List.filled(32, 3)),
            mimeType: 'image/jpeg',
            byteSize: 1000,
            width: 800,
            height: 600,
          ),
        ],
      ).encode();

      final decoded = MessageContent.decode(encoded, fallbackId: 'fallback');
      expect(decoded.isGroupMessage, isTrue);
      expect(decoded.groupId, 'p2xjx0000000000000000');
      expect(decoded.stateHash, 'abc123');
      expect(decoded.text, 'passt');
      expect(decoded.replyToId, 'm1');
      expect(decoded.replyPreview?.text, 'Samstag?');
      expect(decoded.replyPreview?.author, 'qk43rj6cphungwkeznxza');
      expect(decoded.attachments.single.blobId, 'a' * 64);
      expect(decoded.sentAt, DateTime.utc(2026, 8, 2, 12));
    });

    test('a quote without an author decodes as null, not as an empty id', () {
      // What a reply from a build predating APP-17 looks like. The renderer
      // falls back to local history for it, so "absent" and "somebody whose
      // id is the empty string" must not be the same value.
      final encoded = asBytes({
        'v': 4,
        'group_id': 'p2xjx0000000000000000',
        'id': 'm3',
        'text': 'passt',
        'attachments': <dynamic>[],
        'reply_to': 'm1',
        'reply_preview': {'text': 'Samstag?', 'mine': false},
      });

      final decoded = MessageContent.decode(encoded, fallbackId: 'fallback');
      expect(decoded.replyPreview?.text, 'Samstag?');
      expect(decoded.replyPreview?.author, isNull);
    });

    test('a group quote states its author, a one-to-one quote does not', () {
      // The author id exists because `mine: false` says only "not you" among
      // N members. In a one-to-one chat it identifies the author completely,
      // so the field is left off -- keeping that message byte-identical to
      // what it was before APP-17.
      final group = asJson(
        const MessageContent(
          id: 'm2',
          text: 'passt',
          groupId: 'p2xjx0000000000000000',
          replyToId: 'm1',
          replyPreview: ReplyPreview(
            text: 'Samstag?',
            mine: false,
            author: 'qk43rj6cphungwkeznxza',
          ),
        ).encode(),
      );
      expect(
        (group['reply_preview'] as Map<String, dynamic>)['author'],
        'qk43rj6cphungwkeznxza',
      );

      final oneToOne = asJson(
        const MessageContent(
          id: 'm2',
          text: 'passt',
          replyToId: 'm1',
          replyPreview: ReplyPreview(text: 'Samstag?', mine: false),
        ).encode(),
      );
      expect(
        (oneToOne['reply_preview'] as Map<String, dynamic>).containsKey('author'),
        isFalse,
      );
    });

    test('a v: 1 message decodes as a one-to-one message, not a group one', () {
      final decoded = MessageContent.decode(
        const MessageContent(id: 'm1', text: 'hallo').encode(),
        fallbackId: 'fallback',
      );
      expect(decoded.isGroupMessage, isFalse);
      expect(decoded.groupId, isNull);
    });

    test('a version this build does not know is still a placeholder', () {
      // The rule groups rely on: an older build shows a neutral placeholder
      // rather than misfiling a group message into a one-to-one chat.
      final decoded = MessageContent.decode(
        asBytes({'v': 99, 'id': 'm1', 'text': 'from the future'}),
        fallbackId: 'fallback',
      );
      expect(decoded.text, contains('newer app feature'));
      expect(decoded.id, 'm1');
    });
  });
}
