import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/push/notification_navigation.dart';

void main() {
  group('encodeNotificationPayload', () {
    test('encodes just the account id when no chat is known', () {
      expect(encodeNotificationPayload(accountId: 'acct1'), 'acct1');
    });

    test('encodes account and peer joined by a pipe', () {
      expect(
        encodeNotificationPayload(accountId: 'acct1', peerAccountId: 'peer1'),
        'acct1|peer1',
      );
    });

    test('tags a group id, so a tap opens the group and not a peer chat', () {
      expect(
        encodeNotificationPayload(accountId: 'acct1', groupId: 'grp1'),
        'acct1|grp1|group',
      );
    });
  });

  group('handleNotificationPayload', () {
    test('invokes the registered handler with account and peer', () {
      String? gotAccount;
      String? gotChat;
      bool? gotIsGroup;
      setNotificationTapHandler((accountId, chatId, {isGroup = false}) {
        gotAccount = accountId;
        gotChat = chatId;
        gotIsGroup = isGroup;
      });

      handleNotificationPayload('acct1|peer1');

      expect(gotAccount, 'acct1');
      expect(gotChat, 'peer1');
      expect(gotIsGroup, isFalse);
    });

    test('reports a tagged group id as a group', () {
      String? gotChat;
      bool? gotIsGroup;
      setNotificationTapHandler((accountId, chatId, {isGroup = false}) {
        gotChat = chatId;
        gotIsGroup = isGroup;
      });

      handleNotificationPayload('acct1|grp1|group');

      expect(gotChat, 'grp1');
      expect(gotIsGroup, isTrue);
    });

    test('treats an unknown trailing part as a one-to-one chat', () {
      // Defensive: a payload written by another version of this app, still
      // sitting in the notification tray across an update. The peer chat it
      // used to mean is the safe reading -- never a group that may not exist.
      bool? gotIsGroup;
      setNotificationTapHandler((accountId, chatId, {isGroup = false}) {
        gotIsGroup = isGroup;
      });

      handleNotificationPayload('acct1|peer1|something-else');

      expect(gotIsGroup, isFalse);
    });

    test('invokes the handler with a null chat when only account was encoded', () {
      String? gotAccount;
      String? gotChat = 'not null yet';
      setNotificationTapHandler((accountId, chatId, {isGroup = false}) {
        gotAccount = accountId;
        gotChat = chatId;
      });

      handleNotificationPayload('acct1');

      expect(gotAccount, 'acct1');
      expect(gotChat, isNull);
    });

    test('does nothing for a null payload', () {
      var called = false;
      setNotificationTapHandler((_, _, {isGroup = false}) => called = true);

      handleNotificationPayload(null);

      expect(called, isFalse);
    });

    test('does nothing for an empty payload', () {
      var called = false;
      setNotificationTapHandler((_, _, {isGroup = false}) => called = true);

      handleNotificationPayload('');

      expect(called, isFalse);
    });
  });
}
