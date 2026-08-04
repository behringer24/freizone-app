// The sticky pinned-message bar (APP-21), which a one-to-one chat and a group
// now share. Worth its own widget test precisely because it is shared: it is
// typed on ChatTarget, so a GroupConversation exercises the same code path
// ChatScreen depends on.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/state/chat_target.dart';
import 'package:freizone/state/group_conversation.dart';
import 'package:freizone/state/message_content.dart';
import 'package:freizone/widgets/pinned_message_bar.dart';

void main() {
  StoredMessage line(String text, {List<MessageAttachment> attachments = const []}) =>
      StoredMessage(
        text: text,
        mine: false,
        timestamp: DateTime.utc(2026, 8, 4, 12),
        attachments: attachments,
      );

  MessageAttachment picture() => MessageAttachment(
    kind: 'image',
    blobId: 'b1',
    key: Uint8List(32),
    mimeType: 'image/jpeg',
    byteSize: 1234,
    width: 800,
    height: 600,
  );

  Future<void> pumpBar(
    WidgetTester tester,
    ChatTarget chat, {
    void Function(String messageId)? onJump,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PinnedMessageBar(
          chat: chat,
          onJumpToMessage: onJump ?? (_) {},
        ),
      ),
    ),
  );

  group('PinnedMessageBar', () {
    testWidgets('renders nothing while no message is pinned', (tester) async {
      final chat = GroupConversation(
        groupId: 'p2xjx0000000000000000',
        messages: [line('hello')],
      );
      await pumpBar(tester, chat);

      expect(find.byIcon(Icons.push_pin), findsNothing);
      expect(find.text('hello'), findsNothing);
    });

    testWidgets('shows the most recently pinned message', (tester) async {
      final first = line('older');
      final second = line('newer');
      final chat = GroupConversation(
        groupId: 'p2xjx0000000000000000',
        messages: [first, second],
        // Appended in pin order, so the last entry is the newest pin -- see
        // AppSession.pinMessage.
        pinnedMessageIds: [first.id, second.id],
      );
      await pumpBar(tester, chat);

      expect(find.text('newer'), findsOneWidget);
      expect(find.text('older'), findsNothing);
      // Browsable, because more than one is pinned.
      expect(find.text('1/2'), findsOneWidget);
    });

    testWidgets('browses to the older pin and back', (tester) async {
      final first = line('older');
      final second = line('newer');
      final chat = GroupConversation(
        groupId: 'p2xjx0000000000000000',
        messages: [first, second],
        pinnedMessageIds: [first.id, second.id],
      );
      await pumpBar(tester, chat);

      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pump();
      expect(find.text('older'), findsOneWidget);
      expect(find.text('2/2'), findsOneWidget);

      // Wraps around rather than stopping at the end.
      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pump();
      expect(find.text('newer'), findsOneWidget);
      expect(find.text('1/2'), findsOneWidget);
    });

    testWidgets('hides the browse controls for a single pin', (tester) async {
      final only = line('just this one');
      final chat = GroupConversation(
        groupId: 'p2xjx0000000000000000',
        messages: [only],
        pinnedMessageIds: [only.id],
      );
      await pumpBar(tester, chat);

      expect(find.byIcon(Icons.chevron_left), findsNothing);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
    });

    testWidgets('labels a caption-less picture instead of a blank line', (
      tester,
    ) async {
      final photo = line('', attachments: [picture()]);
      final chat = GroupConversation(
        groupId: 'p2xjx0000000000000000',
        messages: [photo],
        pinnedMessageIds: [photo.id],
      );
      await pumpBar(tester, chat);

      expect(find.text('Photo'), findsOneWidget);
    });

    testWidgets('says so when the pinned message is gone from history', (
      tester,
    ) async {
      // Defensive: "delete for me" drops the pin along with the message today,
      // so nothing produces this state on purpose -- but the bar resolves an id
      // it does not own and must say so rather than render a blank row.
      final chat = GroupConversation(
        groupId: 'p2xjx0000000000000000',
        messages: [line('still here')],
        pinnedMessageIds: ['gone'],
      );
      await pumpBar(tester, chat);

      expect(find.text('Pinned message no longer available'), findsOneWidget);
    });

    testWidgets('taps through to the pinned message', (tester) async {
      final pinned = line('jump to me');
      final chat = GroupConversation(
        groupId: 'p2xjx0000000000000000',
        messages: [pinned],
        pinnedMessageIds: [pinned.id],
      );
      final jumped = <String>[];
      await pumpBar(tester, chat, onJump: jumped.add);

      await tester.tap(find.text('jump to me'));
      await tester.pump();
      expect(jumped, [pinned.id]);
    });
  });
}
