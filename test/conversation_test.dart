import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/state/conversation.dart';
import 'package:freizone/state/message_content.dart';

void main() {
  group('Conversation.pendingApproval', () {
    test('defaults to false when constructed directly', () {
      final convo = Conversation(peerAccountId: 'abc123');
      expect(convo.pendingApproval, isFalse);
    });

    test('round-trips through toJson/fromJson when true', () {
      final convo = Conversation(
        peerAccountId: 'abc123',
        pendingApproval: true,
      );
      final restored = Conversation.fromJson(convo.toJson());
      expect(restored.pendingApproval, isTrue);
    });

    test('omitted from toJson when false, so it stays compact', () {
      final convo = Conversation(peerAccountId: 'abc123');
      expect(convo.toJson().containsKey('pending_approval'), isFalse);
    });

    test('defaults to false for legacy JSON with no such field', () {
      final restored = Conversation.fromJson({
        'peer_account_id': 'abc123',
        'messages': [],
        'last_activity_at': '2026-01-01T00:00:00.000Z',
        'has_unread': false,
      });
      expect(restored.pendingApproval, isFalse);
    });
  });

  group('StoredMessage attachments', () {
    MessageAttachment image() => MessageAttachment(
      kind: 'image',
      blobId: 'c' * 64,
      key: Uint8List.fromList(List.filled(32, 3)),
      mimeType: 'image/jpeg',
      byteSize: 1234,
      width: 800,
      height: 600,
    );

    test('round-trip through toJson/fromJson', () {
      final msg = StoredMessage(
        id: 'm1',
        text: 'caption',
        mine: true,
        timestamp: DateTime.utc(2026, 1, 2, 3, 4, 5),
        attachments: [image()],
      );

      final restored = StoredMessage.fromJson(msg.toJson());
      expect(restored.hasAttachments, isTrue);
      expect(restored.attachments.first.blobId, 'c' * 64);
      expect(restored.attachments.first.width, 800);
      expect(restored.text, 'caption');
    });

    test('omitted from json when empty, so old history stays byte-identical', () {
      final msg = StoredMessage(
        text: 'plain',
        mine: false,
        timestamp: DateTime.utc(2026, 1, 1),
      );
      expect(msg.toJson().containsKey('attachments'), isFalse);
      expect(msg.hasAttachments, isFalse);
    });

    test('history written before attachments existed still loads', () {
      final legacy = {
        'id': 'old',
        'text': 'from an older build',
        'mine': false,
        'timestamp': DateTime.utc(2026, 1, 1).toIso8601String(),
      };
      final restored = StoredMessage.fromJson(legacy);
      expect(restored.attachments, isEmpty);
      expect(restored.text, 'from an older build');
    });

    test('chat-list preview marks a photo instead of showing a blank row', () {
      final convo = Conversation(peerAccountId: 'peer1');
      convo.messages.add(StoredMessage(
        text: '',
        mine: false,
        timestamp: DateTime.utc(2026, 1, 1),
        attachments: [image()],
      ));
      expect(convo.lastMessagePreview, '📷 Photo');

      convo.messages.add(StoredMessage(
        text: 'with a caption',
        mine: false,
        timestamp: DateTime.utc(2026, 1, 2),
        attachments: [image()],
      ));
      expect(convo.lastMessagePreview, contains('📷 Photo'));
      expect(convo.lastMessagePreview, contains('with a caption'));
    });
  });
}
