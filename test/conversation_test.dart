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

  group('StoredMessage.sendState', () {
    StoredMessage outgoing(String text, MessageSendState sendState) =>
        StoredMessage(
          text: text,
          mine: true,
          timestamp: DateTime.utc(2026, 1, 1),
          sendState: sendState,
        );

    test('defaults to sent, so received and legacy history is unaffected', () {
      final m = StoredMessage(
        text: 'hi',
        mine: false,
        timestamp: DateTime.utc(2026, 1, 1),
      );
      expect(m.sendState, MessageSendState.sent);
      expect(m.isPending, isFalse);
      expect(m.hasFailed, isFalse);
    });

    test('a message read back from disk is always sent', () {
      final restored = StoredMessage.fromJson({
        'text': 'from disk',
        'mine': true,
        'timestamp': '2026-01-01T00:00:00.000Z',
      });
      expect(restored.sendState, MessageSendState.sent);
    });

    // The load-bearing invariant of APP-08 step 1: retrying a failed send
    // needs the picture bytes AppSession only holds in memory, so a pending
    // or failed message must never reach disk -- restored, it would be a
    // bubble that can never be sent and never be cleared.
    test('pending and failed messages are left out of toJson', () {
      final convo = Conversation(peerAccountId: 'peer1');
      convo.messages.addAll([
        outgoing('delivered', MessageSendState.sent),
        outgoing('in flight', MessageSendState.pending),
        outgoing('never left', MessageSendState.failed),
      ]);

      final persisted = convo.toJson()['messages'] as List<dynamic>;
      expect(persisted, hasLength(1));
      expect((persisted.single as Map<String, dynamic>)['text'], 'delivered');

      // ...while all three stay visible in the live transcript.
      expect(convo.messages, hasLength(3));
    });

    test('a system info line still persists, since it defaults to sent', () {
      final convo = Conversation(peerAccountId: 'peer1');
      convo.messages.add(
        StoredMessage.system('Secure session was reset', DateTime.utc(2026)),
      );
      expect(convo.toJson()['messages'], hasLength(1));
    });

    test('a resolved send survives the round trip through JSON', () {
      final convo = Conversation(peerAccountId: 'peer1');
      final message = outgoing('pending at first', MessageSendState.pending);
      convo.messages.add(message);
      expect(convo.toJson()['messages'], isEmpty);

      // Exactly what AppSession._deliver does once the POST succeeds.
      message.sendState = MessageSendState.sent;
      final restored = Conversation.fromJson(convo.toJson());
      expect(restored.messages, hasLength(1));
      expect(restored.messages.single.text, 'pending at first');
      expect(restored.messages.single.sendState, MessageSendState.sent);
    });
  });
}
