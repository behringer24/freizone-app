// The group transcript model (APP-16 phase 4). What is tested here is what
// gets persisted and read back -- the membership itself is not part of it, by
// design: that lives in the signed fact set, in its own file, folded by the
// native core.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/state/chat_target.dart';
import 'package:freizone/state/group_conversation.dart';
import 'package:freizone/state/local_state.dart';

void main() {
  StoredMessage line(
    String text, {
    bool mine = false,
    String? author,
    int minute = 0,
  }) => StoredMessage(
    text: text,
    mine: mine,
    timestamp: DateTime.utc(2026, 8, 2, 12, minute),
    senderAccountId: author,
  );

  group('GroupConversation', () {
    test('is a ChatTarget keyed by its group id', () {
      final chat = GroupConversation(groupId: 'p2xjx0000000000000000');
      expect(chat, isA<ChatTarget>());
      expect(chat.id, 'p2xjx0000000000000000');
    });

    test('falls back to a short id until the group has a name', () {
      final chat = GroupConversation(groupId: 'p2xjx0000000000000000');
      // The five leading characters are the version marker plus four of real
      // entropy -- the same grouping an account id is displayed in.
      expect(chat.titleFor('https://a.example.org'), 'Group p2xjx');

      chat.displayName = 'Wandergruppe';
      expect(chat.titleFor('https://a.example.org'), 'Wandergruppe');
    });

    test('the chat-list preview names the author of a message', () {
      // In a one-to-one chat the conversation itself answers "who said this".
      // In a group it does not, so the row has to say.
      final chat = GroupConversation(groupId: 'p2xjx0000000000000000');
      chat.messages.add(line('bis morgen', author: 'qclara00000000000000a'));
      expect(chat.lastMessagePreview, 'qclar: bis morgen');

      chat.messages.add(line('gerne', mine: true, minute: 1));
      expect(chat.lastMessagePreview, 'gerne');
    });

    test('a message from before authors were recorded still reads', () {
      final chat = GroupConversation(groupId: 'p2xjx0000000000000000');
      chat.messages.add(line('older history'));
      expect(chat.lastMessagePreview, 'older history');
    });

    test('round-trips through JSON, receipt watermarks included', () {
      final chat = GroupConversation(
        groupId: 'p2xjx0000000000000000',
        displayName: 'Wandergruppe',
        hasUnread: true,
        pinnedMessageIds: ['m1'],
        invitePending: true,
      );
      chat.messages.add(line('hallo', author: 'qclara00000000000000a'));
      // Per member, not per chat: "read by 12" is a count over members, which
      // the single watermark a one-to-one conversation keeps cannot express.
      chat.memberReadUpTo['qclara00000000000000a'] = DateTime.utc(2026, 8, 2, 11);
      chat.memberDeliveredUpTo['qben000000000000000b'] = DateTime.utc(2026, 8, 2, 10);
      chat.sentReceiptUpTo['qclara00000000000000a'] = DateTime.utc(2026, 8, 2, 9);

      final restored = GroupConversation.fromJson(chat.toJson());
      expect(restored.groupId, chat.groupId);
      expect(restored.displayName, 'Wandergruppe');
      expect(restored.hasUnread, isTrue);
      expect(restored.pinnedMessageIds, ['m1']);
      expect(restored.invitePending, isTrue);
      expect(restored.messages.single.senderAccountId, 'qclara00000000000000a');
      expect(restored.memberReadUpTo['qclara00000000000000a'], DateTime.utc(2026, 8, 2, 11));
      expect(restored.memberDeliveredUpTo['qben000000000000000b'], DateTime.utc(2026, 8, 2, 10));
      expect(restored.sentReceiptUpTo['qclara00000000000000a'], DateTime.utc(2026, 8, 2, 9));
    });

    test('an ordinary group costs no keys it does not need', () {
      final chat = GroupConversation(groupId: 'p2xjx0000000000000000');
      final json = chat.toJson();
      for (final key in [
        'invite_pending',
        'member_delivered_up_to',
        'member_read_up_to',
        'sent_receipt_up_to',
        'pinned_message_ids',
      ]) {
        expect(json.containsKey(key), isFalse, reason: '$key should be omitted');
      }
    });

    test('the fact set is deliberately NOT in the transcript', () {
      // The whole point of the split: a group's facts have the opposite write
      // profile to its transcript, and a second copy of the membership here
      // would be a cache that can disagree with the signed truth.
      final json = GroupConversation(groupId: 'p2xjx0000000000000000').toJson();
      for (final key in ['events', 'state', 'members', 'state_hash']) {
        expect(json.containsKey(key), isFalse, reason: '$key must live in the group file');
      }
    });
  });

  group('AppState.groups', () {
    AppState stateWith(GroupConversation? chat) {
      final state = AppState(
        server: 'chat.example.org',
        accountId: 'qme000000000000000000',
        rootPub: Uint8List(0),
        rootPriv: Uint8List(0),
        deviceId: 'device1',
        devicePub: Uint8List(0),
        devicePriv: Uint8List(0),
      );
      if (chat != null) state.groups[chat.groupId] = chat;
      return state;
    }

    test('omitted from the profile when there are none', () {
      expect(stateWith(null).toJson().containsKey('groups'), isFalse);
    });

    test('group transcripts survive a profile round trip', () {
      final chat = GroupConversation(
        groupId: 'p2xjx0000000000000000',
        displayName: 'Wandergruppe',
      );
      chat.messages.add(line('hallo', author: 'qclara00000000000000a'));

      final restored = AppState.fromJson(stateWith(chat).toJson());
      expect(restored.groups, hasLength(1));
      final group = restored.groups['p2xjx0000000000000000']!;
      expect(group.displayName, 'Wandergruppe');
      expect(group.messages.single.text, 'hallo');
    });
  });
}
