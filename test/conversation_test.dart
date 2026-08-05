import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/state/contact_store.dart';
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
      // A one-to-one preview names nobody -- the row's title already does -- so
      // the store it now takes (APP-18) changes nothing here.
      final contacts = ContactStore.inMemory();
      expect(convo.previewFor(contacts), '📷 Photo');

      convo.messages.add(StoredMessage(
        text: 'with a caption',
        mine: false,
        timestamp: DateTime.utc(2026, 1, 2),
        attachments: [image()],
      ));
      expect(convo.previewFor(contacts), contains('📷 Photo'));
      expect(convo.previewFor(contacts), contains('with a caption'));
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

    test('history with no send state recorded reads back as sent', () {
      final restored = StoredMessage.fromJson({
        'text': 'from disk',
        'mine': true,
        'timestamp': '2026-01-01T00:00:00.000Z',
      });
      expect(restored.sendState, MessageSendState.sent);
    });

    // APP-08 step 2. Step 1 deliberately dropped unsent messages on close,
    // because a retry needed picture bytes held only in memory. They are
    // durable now -- the sender's own copy is on disk before the bubble
    // paints, so a restored failure can genuinely be resent.
    test('unsent messages are persisted, and a pending one comes back as '
        'failed rather than in flight', () {
      final convo = Conversation(peerAccountId: 'peer1');
      convo.messages.addAll([
        outgoing('delivered', MessageSendState.sent),
        outgoing('in flight', MessageSendState.pending),
        outgoing('never left', MessageSendState.failed),
      ]);

      final persisted = convo.toJson()['messages'] as List<dynamic>;
      expect(persisted, hasLength(3));

      final restored = Conversation.fromJson(convo.toJson());
      expect(restored.messages.map((m) => m.sendState).toList(), [
        MessageSendState.sent,
        // Nothing is in flight in a process that no longer exists, so a
        // pending message restores as a failure to retry. Otherwise it would
        // sit there with a clock icon forever, waiting on a send that no code
        // is running.
        MessageSendState.failed,
        MessageSendState.failed,
      ]);
    });

    test('a sent message costs no extra key, so old history is unchanged', () {
      final sent = outgoing('delivered', MessageSendState.sent);
      expect(sent.toJson().containsKey('send_state'), isFalse);

      final failed = outgoing('never left', MessageSendState.failed);
      expect(failed.toJson()['send_state'], 'failed');
    });

    test('a stale failure reason is not persisted', () {
      // "this server doesn't accept pictures" may simply not be true any
      // more by the next run, and a wrong explanation is worse than none.
      final failed = outgoing('never left', MessageSendState.failed)
        ..sendError = 'blobs are disabled on that server';
      expect(failed.toJson().containsKey('send_error'), isFalse);
      expect(StoredMessage.fromJson(failed.toJson()).sendError, isNull);
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

      // Exactly what AppSession._deliver does once the POST succeeds.
      message.sendState = MessageSendState.sent;
      final restored = Conversation.fromJson(convo.toJson());
      expect(restored.messages, hasLength(1));
      expect(restored.messages.single.text, 'pending at first');
      expect(restored.messages.single.sendState, MessageSendState.sent);
    });
  });

  group('ChatTarget', () {
    test('a conversation is keyed by its peer', () {
      final convo = Conversation(peerAccountId: 'peer1');
      expect(convo, isA<ChatTarget>());
      // Anything keyed by a chat -- the chat map, the media directory --
      // uses this, and for a one-to-one chat it is still the peer's id.
      expect(convo.id, 'peer1');
    });

    test('splitting the base out did not change what gets persisted', () {
      // A fully populated conversation, so a field silently lost or renamed
      // in the ChatTarget extraction shows up here rather than as history
      // that quietly fails to load after an update.
      final convo = Conversation(
        peerAccountId: 'peer1',
        peerServer: 'https://other.example.org',
        peerDeviceId: 'aabbccddeeff0011',
        peerDevicePubKey: Uint8List.fromList(List.filled(32, 7)),
        lastActivityAt: DateTime.utc(2026, 8, 2, 12),
        hasUnread: true,
        pinnedMessageIds: ['m1'],
        blocked: true,
        pendingApproval: true,
        peerDeliveredUpTo: DateTime.utc(2026, 8, 2, 11),
        peerReadUpTo: DateTime.utc(2026, 8, 2, 11, 30),
        sentDeliveredReceiptUpTo: DateTime.utc(2026, 8, 2, 10),
        sentReadReceiptUpTo: DateTime.utc(2026, 8, 2, 10, 30),
      );

      convo.messages.add(
        StoredMessage(
          text: 'hi',
          mine: true,
          timestamp: DateTime.utc(2026, 8, 2, 11, 59),
        ),
      );

      expect(convo.toJson().keys.toSet(), {
        'peer_account_id',
        // 'display_name' is deliberately absent (APP-19) -- see the assertion
        // below on why it must not come back.
        'messages',
        'last_activity_at',
        'has_unread',
        'pinned_message_ids',
        'peer_server',
        'peer_device_id',
        'peer_device_pub_key',
        'blocked',
        'pending_approval',
        'peer_delivered_up_to',
        'peer_read_up_to',
        'sent_delivered_receipt_up_to',
        'sent_read_receipt_up_to',
      });

      final restored = Conversation.fromJson(convo.toJson());
      // No name here any more (APP-19): a peer's name is in the contact store,
      // so a conversation neither carries nor persists one. The key is gone from
      // toJson too, which is what lets the old value disappear from existing
      // profiles on their next save.
      expect(convo.toJson().containsKey('display_name'), isFalse);
      expect(restored.peerServer, 'https://other.example.org');
      expect(restored.peerDeviceId, 'aabbccddeeff0011');
      expect(restored.peerDevicePubKey, convo.peerDevicePubKey);
      expect(restored.lastActivityAt, convo.lastActivityAt);
      expect(restored.hasUnread, isTrue);
      expect(restored.pinnedMessageIds, ['m1']);
      expect(restored.blocked, isTrue);
      expect(restored.pendingApproval, isTrue);
      expect(restored.peerReadUpTo, convo.peerReadUpTo);
      expect(restored.sentReadReceiptUpTo, convo.sentReadReceiptUpTo);
    });

    test('a queued picture survives the round trip, blob id or not', () {
      // What sendMessage puts in the transcript while the upload is still in
      // flight: everything needed to render our own copy, but no blob
      // reference yet -- the server assigns that. Dropping it on load turned
      // a retried photo into a text-only message.
      final convo = Conversation(peerAccountId: 'peer1');
      convo.messages.add(
        StoredMessage(
          text: 'look at this',
          mine: true,
          timestamp: DateTime.utc(2026, 8, 2),
          sendState: MessageSendState.failed,
          attachments: [
            MessageAttachment(
              kind: 'image',
              blobId: '',
              key: Uint8List(0),
              mimeType: 'image/jpeg',
              byteSize: 4242,
              width: 1600,
              height: 1200,
              thumb: Uint8List.fromList([1, 2, 3]),
            ),
          ],
        ),
      );

      final restored = Conversation.fromJson(convo.toJson());
      final attachment = restored.messages.single.attachments.single;
      expect(attachment.blobId, isEmpty);
      // The metadata is what _recoverAttachment rebuilds the upload from, so
      // every field of it has to come back.
      expect(attachment.mimeType, 'image/jpeg');
      expect(attachment.byteSize, 4242);
      expect(attachment.width, 1600);
      expect(attachment.height, 1200);
      expect(attachment.thumb, isNotNull);
    });

    test('a peer may still not send an attachment with no blob to fetch', () {
      // The relaxed rule is for our own history only. Off the wire an entry
      // with no blob id is malformed, and a broken image is worse than none.
      final fromPeer = MessageContent.decode(
        Uint8List.fromList(
          utf8.encode(
            '{"v":1,"id":"m1","text":"hi","attachments":'
            '[{"kind":"image","blob_id":"","key":"","mime":"image/jpeg"}]}',
          ),
        ),
        fallbackId: 'fallback',
      );
      expect(fromPeer.text, 'hi');
      expect(fromPeer.attachments, isEmpty);
    });

    test('a reply keeps its quote across the round trip', () {
      // The other half of what a retried message carries: _deliver rebuilds
      // the wire quote from these three fields, so a restored reply that lost
      // them would arrive as a plain message.
      final convo = Conversation(peerAccountId: 'peer1');
      convo.messages.add(
        StoredMessage(
          text: 'agreed',
          mine: true,
          timestamp: DateTime.utc(2026, 8, 2),
          sendState: MessageSendState.failed,
          replyToId: 'quoted-1',
          // Empty is a real value here -- replying to a photo with no
          // caption -- and must not be confused with absent.
          replyPreviewText: '',
          replyPreviewMine: false,
        ),
      );

      final restored = Conversation.fromJson(convo.toJson()).messages.single;
      expect(restored.isReply, isTrue);
      expect(restored.replyToId, 'quoted-1');
      expect(restored.replyPreviewText, '');
      expect(restored.replyPreviewMine, isFalse);
    });

    test('senderAccountId is absent unless a message actually names one', () {
      // Null for every one-to-one message, where "mine" already answers who
      // wrote it -- so existing history is byte-identical.
      final plain = StoredMessage(
        text: 'hi',
        mine: false,
        timestamp: DateTime.utc(2026),
      );
      expect(plain.toJson().containsKey('sender_account_id'), isFalse);

      final authored = StoredMessage(
        text: 'hi',
        mine: false,
        timestamp: DateTime.utc(2026),
        senderAccountId: 'peer2',
      );
      expect(
        StoredMessage.fromJson(authored.toJson()).senderAccountId,
        'peer2',
      );
    });
  });

  // The point of APP-19 phase 2: a conversation no longer holds a name, it asks
  // for one. These are the properties that make the move safe.
  group('Conversation.titleFor and the contact store', () {
    Conversation peer({String? server}) =>
        Conversation(peerAccountId: 'qclara00000000000000a', peerServer: server);

    test('falls back to the address when this device has not named them', () {
      final convo = peer();
      expect(
        convo.titleFor('https://a.example.org', ContactStore.inMemory()),
        'qclar*a.example.org',
      );
    });

    test('shows the name once there is a contact', () async {
      final convo = peer();
      final contacts = ContactStore.inMemory();
      await contacts.setName('qclara00000000000000a', name: 'Clara');
      expect(convo.titleFor('https://a.example.org', contacts), 'Clara');
    });

    test('removing the contact restores the address and keeps the chat', () async {
      // Deletion #1 from the design document: removing a contact is a labelling
      // decision, not a relationship one. Nothing about the transcript changes.
      final convo = peer();
      convo.messages.add(
        StoredMessage(
          text: 'bis Samstag',
          mine: false,
          timestamp: DateTime.utc(2026, 8, 5),
        ),
      );
      final contacts = ContactStore.inMemory();
      await contacts.setName('qclara00000000000000a', name: 'Clara');
      await contacts.remove('qclara00000000000000a');

      expect(
        convo.titleFor('https://a.example.org', contacts),
        'qclar*a.example.org',
      );
      expect(convo.messages, hasLength(1));
    });

    test('one name serves every account of mine that talks to them', () async {
      // What being central buys: two sessions, two conversations, one name --
      // and no way for them to disagree, since there is only one copy.
      final contacts = ContactStore.inMemory();
      await contacts.setName('qclara00000000000000a', name: 'Clara');
      final fromWork = peer();
      final fromPrivate = peer(server: 'https://b.example.org');
      expect(fromWork.titleFor('https://a.example.org', contacts), 'Clara');
      expect(fromPrivate.titleFor('https://a.example.org', contacts), 'Clara');
    });

    test('the peer server still decides the address it falls back to', () async {
      // Federation: an unnamed peer on another server must not look local.
      final convo = peer(server: 'https://b.example.org');
      expect(
        convo.titleFor('https://a.example.org', ContactStore.inMemory()),
        'qclar*b.example.org',
      );
    });
  });
}
