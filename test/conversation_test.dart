import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/state/conversation.dart';

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
}
