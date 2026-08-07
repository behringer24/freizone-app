// The trace a blocked member's group message leaves behind (see
// recordBlockedGroupMessage). The property being tested throughout: **the
// hole is visible, but the blocked member gains nothing by writing** -- no
// unread badge, no chat-list bump, and no per-message count that would let
// their output be measured through the very transcript that hides it.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/state/chat_target.dart';
import 'package:freizone/state/group_conversation.dart';
import 'package:freizone/state/group_receive.dart';
import 'package:freizone/state/local_state.dart';

const _groupId = 'p3wrc0000000000000000';
const _blockedPeer = 'qbob000000000000000ab';

AppState _state({bool withGroup = true}) {
  final state = AppState(
    server: 'chat.example.org',
    accountId: 'qme0000000000000000aa',
    rootPub: Uint8List(0),
    rootPriv: Uint8List(0),
    deviceId: 'device1',
    devicePub: Uint8List(0),
    devicePriv: Uint8List(0),
  );
  if (withGroup) {
    state.groups[_groupId] = GroupConversation(groupId: _groupId);
  }
  return state;
}

final _now = DateTime.utc(2026, 8, 7, 12, 0, 0);

void main() {
  group('recordBlockedGroupMessage', () {
    test('leaves one centered system line naming the sender', () {
      final state = _state();
      recordBlockedGroupMessage(state, _groupId, _blockedPeer, _now);

      final line = state.groups[_groupId]!.messages.single;
      expect(line.kind, StoredMessageKind.systemInfo);
      expect(line.text, 'A message from qbob0 was hidden (blocked contact).');
    });

    test('consecutive drops from the same sender collapse into one line', () {
      // How much a blocked member writes stays as unknowable as the content.
      final state = _state();
      recordBlockedGroupMessage(state, _groupId, _blockedPeer, _now);
      recordBlockedGroupMessage(
        state,
        _groupId,
        _blockedPeer,
        _now.add(const Duration(minutes: 1)),
      );

      expect(state.groups[_groupId]!.messages, hasLength(1));
    });

    test('an interleaved real message starts a new run', () {
      // The line marks *where* the hole is; two holes around a real message
      // are two places.
      final state = _state();
      final chat = state.groups[_groupId]!;
      recordBlockedGroupMessage(state, _groupId, _blockedPeer, _now);
      chat.messages.add(
        StoredMessage(
          text: 'hallo',
          mine: false,
          timestamp: _now.add(const Duration(minutes: 1)),
          senderAccountId: 'qclara00000000000000a',
        ),
      );
      recordBlockedGroupMessage(
        state,
        _groupId,
        _blockedPeer,
        _now.add(const Duration(minutes: 2)),
      );

      expect(
        chat.messages.where((m) => m.kind == StoredMessageKind.systemInfo),
        hasLength(2),
      );
    });

    test('gives the blocked member no badge and no chat-list bump', () {
      final state = _state();
      final chat = state.groups[_groupId]!;
      final activityBefore = chat.lastActivityAt;

      recordBlockedGroupMessage(state, _groupId, _blockedPeer, _now);

      expect(chat.hasUnread, isFalse);
      expect(chat.lastActivityAt, activityBefore);
    });

    test('a group this device has no transcript for gets nothing minted', () {
      final state = _state(withGroup: false);
      recordBlockedGroupMessage(state, _groupId, _blockedPeer, _now);
      expect(state.groups, isEmpty);
    });
  });
}
