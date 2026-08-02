// The client-to-client wire shapes groups add (APP-16 phase 5): `v: 4` group
// chat content and the `v: 5` control envelope. Pure logic, and the contract
// both the send and receive paths are built on -- a second client has to be
// able to reproduce exactly this.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/state/group_control.dart';
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
        replyPreview: const ReplyPreview(text: 'Samstag?', mine: false),
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
      expect(decoded.attachments.single.blobId, 'a' * 64);
      expect(decoded.sentAt, DateTime.utc(2026, 8, 2, 12));
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

  group('GroupControl', () {
    test('round-trips a batch of events', () {
      final encoded = const GroupControl(
        kind: GroupControlKind.events,
        groupId: 'p2xjx0000000000000000',
        stateHash: 'abc123',
        events: [
          {'type': 'member_add', 'subject': 'qben000000000000000b'},
        ],
      ).encode();

      expect(asJson(encoded)['v'], 5);

      final decoded = GroupControl.tryDecode(encoded)!;
      expect(decoded.kind, GroupControlKind.events);
      expect(decoded.groupId, 'p2xjx0000000000000000');
      expect(decoded.stateHash, 'abc123');
      // Carried through untouched -- only the core reads inside an event.
      expect(decoded.events.single['type'], 'member_add');
    });

    test('a sync request carries no events', () {
      final encoded = const GroupControl(
        kind: GroupControlKind.syncRequest,
        groupId: 'p2xjx0000000000000000',
      ).encode();
      expect(asJson(encoded).containsKey('events'), isFalse);
      expect(GroupControl.tryDecode(encoded)!.events, isEmpty);
    });

    test('declines anything that is not a control envelope', () {
      // So the receive path can try each decoder in turn and fall through.
      for (final bytes in [
        const MessageContent(id: 'm1', text: 'hallo').encode(),
        const MessageContent(
          id: 'm1',
          text: 'hallo',
          groupId: 'p2xjx0000000000000000',
        ).encode(),
        asBytes({'v': 5, 'kind': 'nonsense', 'group_id': 'p1'}),
        asBytes({'v': 5, 'kind': 'events'}), // no group to route it to
        asBytes({'v': 5, 'kind': 'events', 'group_id': ''}),
        Uint8List.fromList(utf8.encode('not json at all')),
      ]) {
        expect(GroupControl.tryDecode(bytes), isNull);
      }
    });

    test('a malformed event costs itself, not the envelope', () {
      // Every fact is individually signed, so nothing here is taken on the
      // sender's word -- but the good facts in a snapshot still deserve to
      // arrive.
      final decoded = GroupControl.tryDecode(
        asBytes({
          'v': 5,
          'kind': 'snapshot',
          'group_id': 'p2xjx0000000000000000',
          'events': [
            'not an object',
            {'type': 'genesis'},
            42,
          ],
        }),
      )!;
      expect(decoded.events, hasLength(1));
      expect(decoded.events.single['type'], 'genesis');
    });

    test('an older build renders a control envelope as a placeholder', () {
      // Not silently mishandled: the accepted cost of the versioning scheme,
      // and the reason a group message is v: 4 rather than v: 1 plus a field.
      final decoded = MessageContent.decode(
        const GroupControl(
          kind: GroupControlKind.events,
          groupId: 'p2xjx0000000000000000',
        ).encode(),
        fallbackId: 'fallback',
      );
      expect(decoded.text, contains('newer app feature'));
    });
  });
}
