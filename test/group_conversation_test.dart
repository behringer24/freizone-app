// The group transcript model (APP-16 phase 4). What is tested here is what
// gets persisted and read back -- the membership itself is not part of it, by
// design: that lives in the signed fact set, in its own file, folded by the
// native core.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/state/chat_target.dart';
import 'package:freizone/state/contact_store.dart';
import 'package:freizone/state/group_conversation.dart';
import 'package:freizone/state/local_state.dart';
import 'package:freizone/state/receipt_signal.dart';

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
      // A group ignores the contact store: it named itself, so its name is not
      // somebody's label for a person (APP-19).
      final contacts = ContactStore.inMemory();
      expect(chat.titleFor('https://a.example.org', contacts), 'Group p2xjx');

      chat.displayName = 'Wandergruppe';
      expect(chat.titleFor('https://a.example.org', contacts), 'Wandergruppe');
    });

    test('the chat-list preview names the author of a message', () {
      // In a one-to-one chat the conversation itself answers "who said this".
      // In a group it does not, so the row has to say.
      final chat = GroupConversation(groupId: 'p2xjx0000000000000000');
      chat.messages.add(line('bis morgen', author: 'qclara00000000000000a'));
      expect(chat.previewFor(ContactStore.inMemory()), 'qclar: bis morgen');

      chat.messages.add(line('gerne', mine: true, minute: 1));
      expect(chat.previewFor(ContactStore.inMemory()), 'gerne');
    });

    test('the preview uses an assigned name, without the id (APP-18)', () {
      // The compact label: this row is one truncated line, and it is the one
      // place the short id is dropped rather than kept in parentheses.
      final chat = GroupConversation(groupId: 'p2xjx0000000000000000');
      chat.messages.add(line('bis morgen', author: 'qclara00000000000000a'));
      final contacts = ContactStore.inMemory(
        contacts: const [
          Contact(accountId: 'qclara00000000000000a', name: 'Clara'),
        ],
      );
      expect(chat.previewFor(contacts), 'Clara: bis morgen');
    });

    test('a message from before authors were recorded still reads', () {
      final chat = GroupConversation(groupId: 'p2xjx0000000000000000');
      chat.messages.add(line('older history'));
      expect(chat.previewFor(ContactStore.inMemory()), 'older history');
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

    test('a reply keeps the quoted author across a restart', () {
      // The fan-out rebuilds each copy's wire quote from the stored fields, so
      // a reply the outbox retries after a restart would otherwise arrive with
      // its quote unattributed -- and a group quote cannot recover the author
      // from `mine`, which is the whole reason the field exists (APP-17).
      final chat = GroupConversation(groupId: 'p2xjx0000000000000000');
      chat.messages.add(
        StoredMessage(
          text: 'passt',
          mine: true,
          timestamp: DateTime.utc(2026, 8, 2, 12),
          sendState: MessageSendState.failed,
          replyToId: 'm1',
          // Empty is a real value -- a reply to a picture with no caption --
          // and must not be confused with absent.
          replyPreviewText: '',
          replyPreviewMine: false,
          replyPreviewAuthorId: 'qclara00000000000000a',
        ),
      );

      final restored = GroupConversation.fromJson(chat.toJson()).messages.single;
      expect(restored.isReply, isTrue);
      expect(restored.replyPreviewText, '');
      expect(restored.replyPreviewMine, isFalse);
      expect(restored.replyPreviewAuthorId, 'qclara00000000000000a');
    });

    test('a one-to-one reply stores no quoted author', () {
      // Two people, so `mine` names the author completely -- and existing
      // history stays byte-identical for having gained nothing.
      final json = StoredMessage(
        text: 'agreed',
        mine: true,
        timestamp: DateTime.utc(2026, 8, 2, 12),
        replyToId: 'm1',
        replyPreviewText: 'Samstag?',
        replyPreviewMine: false,
      ).toJson();
      expect(json.containsKey('reply_preview_author_id'), isFalse);
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

  group('GroupDelivery', () {
    StoredMessage fanOut(List<MessageSendState> states) => StoredMessage(
      text: 'hallo',
      mine: true,
      timestamp: DateTime.utc(2026, 8, 2, 12),
      sendState: MessageSendState.pending,
      deliveries: [
        for (var i = 0; i < states.length; i++)
          GroupDelivery(
            accountId: 'qmember$i',
            wireMessageId: 'wire$i',
            state: states[i],
          ),
      ],
    );

    test('every recipient gets its own wire id', () {
      // The trap: sharing the message id across recipients would make two
      // members on the same server collide -- the second copy answered 409
      // and recorded as delivered to somebody who never received it.
      final message = fanOut([MessageSendState.sent, MessageSendState.pending]);
      final ids = message.deliveries.map((d) => d.wireMessageId).toSet();
      expect(ids, hasLength(2));
      // And none of them is the message's own id, which would let a server
      // recognise the copies as one group message.
      expect(ids.contains(message.id), isFalse);
    });

    test('the aggregate is what the bubble renders', () {
      expect(
        fanOut([
          MessageSendState.sent,
          MessageSendState.pending,
        ]).aggregateSendState,
        MessageSendState.pending,
      );
      expect(
        fanOut([
          MessageSendState.sent,
          MessageSendState.failed,
        ]).aggregateSendState,
        MessageSendState.failed,
      );
      expect(
        fanOut([
          MessageSendState.sent,
          MessageSendState.sent,
        ]).aggregateSendState,
        MessageSendState.sent,
      );
      expect(fanOut([MessageSendState.sent]).deliveredCount, 1);
    });

    test('a group send with no recipients is complete, not stuck', () {
      // A group with nobody else in it yet owes nobody a copy. The empty
      // delivery list makes aggregateSendState fall back to the message's own
      // state, so the fan-out has to resolve it -- otherwise the bubble sits
      // on a clock forever, which is exactly what the first emulator run did.
      final message = fanOut(const []);
      expect(message.aggregateSendState, MessageSendState.pending);

      // What AppSession._fanOut does when there is nothing to send.
      message.sendState = MessageSendState.sent;
      expect(message.aggregateSendState, MessageSendState.sent);
      expect(message.deliveredCount, 0);
    });

    test('a member who got the caption but not the picture is remembered', () {
      // Not a delivery failure -- the message itself arrived -- so it needs its
      // own flag rather than riding on the send state. Persisted, because "they
      // never got the picture" does not become untrue with time and no retry
      // can mend it: that copy already counts as delivered.
      final message = fanOut([MessageSendState.sent, MessageSendState.sent]);
      message.deliveries.first.attachmentSkipped = true;

      final restored = StoredMessage.fromJson(message.toJson());
      expect(restored.deliveries.first.attachmentSkipped, isTrue);
      expect(restored.deliveries.last.attachmentSkipped, isFalse);
      // Still fully delivered: the bubble says the picture missed somebody
      // separately, rather than the k-of-N indicator claiming a failure.
      expect(restored.aggregateSendState, MessageSendState.sent);
    });

    test('nothing is written for the ordinary case', () {
      // The flag costs a key only when it is true, so existing history and
      // every normal send stay byte-identical.
      final message = fanOut([MessageSendState.sent]);
      expect(
        message.deliveries.first.toJson().containsKey('attachment_skipped'),
        isFalse,
      );
    });

    test('a one-to-one message has no deliveries and keeps its own state', () {
      final message = StoredMessage(
        text: 'hallo',
        mine: true,
        timestamp: DateTime.utc(2026, 8, 2, 12),
        sendState: MessageSendState.failed,
      );
      expect(message.isGroupSend, isFalse);
      expect(message.toJson().containsKey('deliveries'), isFalse);
      expect(message.aggregateSendState, MessageSendState.failed);
    });

    test('a partly-delivered fan-out survives a restart, in flight excepted', () {
      final message = fanOut([
        MessageSendState.sent,
        MessageSendState.pending,
        MessageSendState.failed,
      ]);
      final restored = StoredMessage.fromJson(message.toJson());

      expect(restored.deliveries.map((d) => d.state).toList(), [
        MessageSendState.sent,
        // Nothing is in flight in a process that no longer exists, so this
        // copy comes back as one to retry -- and only this copy: the one that
        // arrived is not sent again.
        MessageSendState.failed,
        MessageSendState.failed,
      ]);
      // The wire ids come back too, which is what makes that retry idempotent.
      expect(restored.deliveries.map((d) => d.wireMessageId).toList(), [
        'wire0',
        'wire1',
        'wire2',
      ]);
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

  // Group receipts (APP-16). Two properties matter and neither is obvious from
  // the maps alone: a count is over the copies a message was actually owed, and
  // a watermark only ever moves forward.
  StoredMessage mine(int minute, List<String> recipients) => StoredMessage(
    text: 'x',
    mine: true,
    timestamp: DateTime.utc(2026, 8, 2, 12, minute),
    deliveries: [
      for (final r in recipients)
        GroupDelivery(accountId: r, wireMessageId: 'w-$r-$minute'),
    ],
  );

  group('GroupConversation receipts', () {
    test('counts confirmations over the copies the message was owed', () {
      final chat = GroupConversation(groupId: 'p2xjx0000000000000000');
      final message = mine(0, ['ben', 'clara']);

      expect(chat.deliveredCountFor(message), 0);
      chat.recordMemberReceipt(
        accountId: 'ben',
        status: ReceiptStatus.delivered,
        upTo: message.receiptAnchor,
      );
      expect(chat.deliveredCountFor(message), 1);
      expect(chat.readCountFor(message), 0);

      chat.recordMemberReceipt(
        accountId: 'ben',
        status: ReceiptStatus.read,
        upTo: message.receiptAnchor,
      );
      expect(chat.readCountFor(message), 1);

      // Somebody who was never owed a copy cannot raise the count -- a member
      // who joined after this message was sent, say.
      chat.recordMemberReceipt(
        accountId: 'dora',
        status: ReceiptStatus.read,
        upTo: message.receiptAnchor,
      );
      expect(chat.readCountFor(message), 1);
    });

    test('one marker answers for every message a member has caught up with', () {
      final chat = GroupConversation(groupId: 'p2xjx0000000000000000');
      final first = mine(0, ['ben']);
      final second = mine(5, ['ben']);

      chat.recordMemberReceipt(
        accountId: 'ben',
        status: ReceiptStatus.read,
        upTo: second.receiptAnchor,
      );
      expect(chat.readCountFor(first), 1);
      expect(chat.readCountFor(second), 1);
    });

    test('a watermark never regresses', () {
      final chat = GroupConversation(groupId: 'p2xjx0000000000000000');
      final later = DateTime.utc(2026, 8, 2, 12, 10);
      final earlier = DateTime.utc(2026, 8, 2, 12, 5);

      expect(
        chat.recordMemberReceipt(
          accountId: 'ben',
          status: ReceiptStatus.read,
          upTo: later,
        ),
        isTrue,
      );
      // Delivery is unordered, so an older receipt legitimately arrives second.
      expect(
        chat.recordMemberReceipt(
          accountId: 'ben',
          status: ReceiptStatus.read,
          upTo: earlier,
        ),
        isFalse,
      );
      expect(chat.memberReadUpTo['ben'], later);
    });

    test('the per-member watermarks survive a round trip', () {
      final chat = GroupConversation(groupId: 'p2xjx0000000000000000');
      chat.recordMemberReceipt(
        accountId: 'ben',
        status: ReceiptStatus.delivered,
        upTo: DateTime.utc(2026, 8, 2, 12, 1),
      );
      chat.sentReceiptUpTo['clara'] = DateTime.utc(2026, 8, 2, 12, 2);

      final restored = GroupConversation.fromJson(chat.toJson());
      expect(restored.memberDeliveredUpTo['ben'], DateTime.utc(2026, 8, 2, 12, 1));
      expect(restored.sentReceiptUpTo['clara'], DateTime.utc(2026, 8, 2, 12, 2));
    });
  });

  // What the delivery sheet lists per member (APP-16). The counts above answer
  // "how many"; this is the part that has to combine two independent sources --
  // what a recipient's server did, and what the recipient confirmed.
  //
  // [delivered] is [mine] with every copy accepted by its server, which is
  // where a receipt can start to mean something -- a fresh GroupDelivery is
  // `pending`, and nothing a still-unsent copy hears is a confirmation.
  StoredMessage delivered(int minute, List<String> recipients) {
    final message = mine(minute, recipients);
    for (final delivery in message.deliveries) {
      delivery.state = MessageSendState.sent;
    }
    return message;
  }

  group('GroupConversation.stageFor', () {
    test('the server\'s answer decides before any receipt can', () {
      final chat = GroupConversation(groupId: 'p2xjx0000000000000000');
      final message = mine(0, ['ben', 'clara', 'dora']);
      message.deliveries[0].state = MessageSendState.failed;
      message.deliveries[1].state = MessageSendState.pending;
      message.deliveries[2].state = MessageSendState.sent;

      expect(
        chat.stageFor(message, message.deliveries[0]),
        GroupDeliveryStage.failed,
      );
      expect(
        chat.stageFor(message, message.deliveries[1]),
        GroupDeliveryStage.sending,
      );
      // Accepted by their server and nothing heard from them yet: not the same
      // as received, since the copy sits in their queue until they connect.
      expect(
        chat.stageFor(message, message.deliveries[2]),
        GroupDeliveryStage.sent,
      );
    });

    test('a failed copy stays failed even if a receipt turns up for it', () {
      // Nothing should produce this -- but a stale watermark from an earlier
      // message must not make an undelivered copy look confirmed.
      final chat = GroupConversation(groupId: 'p2xjx0000000000000000');
      final message = mine(0, ['ben']);
      message.deliveries.single.state = MessageSendState.failed;
      chat.recordMemberReceipt(
        accountId: 'ben',
        status: ReceiptStatus.read,
        upTo: message.receiptAnchor,
      );

      expect(
        chat.stageFor(message, message.deliveries.single),
        GroupDeliveryStage.failed,
      );
    });

    test('read wins over received, and outranks a missing delivered receipt', () {
      final chat = GroupConversation(groupId: 'p2xjx0000000000000000');
      final message = delivered(0, ['ben', 'clara']);

      chat.recordMemberReceipt(
        accountId: 'ben',
        status: ReceiptStatus.delivered,
        upTo: message.receiptAnchor,
      );
      // Only the read receipt: the delivered one was lost, which must not
      // leave them looking less far along than they are.
      chat.recordMemberReceipt(
        accountId: 'clara',
        status: ReceiptStatus.read,
        upTo: message.receiptAnchor,
      );

      expect(
        chat.stageFor(message, message.deliveries[0]),
        GroupDeliveryStage.received,
      );
      expect(
        chat.stageFor(message, message.deliveries[1]),
        GroupDeliveryStage.read,
      );
    });

    test('a receipt older than the message confirms nothing', () {
      final chat = GroupConversation(groupId: 'p2xjx0000000000000000');
      final message = delivered(10, ['ben']);
      chat.recordMemberReceipt(
        accountId: 'ben',
        status: ReceiptStatus.read,
        upTo: DateTime.utc(2026, 8, 2, 12, 5),
      );

      expect(
        chat.stageFor(message, message.deliveries.single),
        GroupDeliveryStage.sent,
      );
    });

    test('the stages sort worst first, which is what the sheet relies on', () {
      expect(GroupDeliveryStage.failed.index, lessThan(GroupDeliveryStage.sending.index));
      expect(GroupDeliveryStage.sending.index, lessThan(GroupDeliveryStage.sent.index));
      expect(GroupDeliveryStage.sent.index, lessThan(GroupDeliveryStage.received.index));
      expect(GroupDeliveryStage.received.index, lessThan(GroupDeliveryStage.read.index));
    });
  });
}
