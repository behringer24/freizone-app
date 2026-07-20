import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/push/notification_navigation.dart';

void main() {
  group('encodeNotificationPayload', () {
    test('encodes just the account id when no peer is known', () {
      expect(encodeNotificationPayload(accountId: 'acct1'), 'acct1');
    });

    test('encodes account and peer joined by a pipe', () {
      expect(
        encodeNotificationPayload(accountId: 'acct1', peerAccountId: 'peer1'),
        'acct1|peer1',
      );
    });
  });

  group('handleNotificationPayload', () {
    test('invokes the registered handler with account and peer', () {
      String? gotAccount;
      String? gotPeer;
      setNotificationTapHandler((accountId, peerAccountId) {
        gotAccount = accountId;
        gotPeer = peerAccountId;
      });

      handleNotificationPayload('acct1|peer1');

      expect(gotAccount, 'acct1');
      expect(gotPeer, 'peer1');
    });

    test('invokes the handler with a null peer when only account was encoded', () {
      String? gotAccount;
      String? gotPeer = 'not null yet';
      setNotificationTapHandler((accountId, peerAccountId) {
        gotAccount = accountId;
        gotPeer = peerAccountId;
      });

      handleNotificationPayload('acct1');

      expect(gotAccount, 'acct1');
      expect(gotPeer, isNull);
    });

    test('does nothing for a null payload', () {
      var called = false;
      setNotificationTapHandler((_, _) => called = true);

      handleNotificationPayload(null);

      expect(called, isFalse);
    });

    test('does nothing for an empty payload', () {
      var called = false;
      setNotificationTapHandler((_, _) => called = true);

      handleNotificationPayload('');

      expect(called, isFalse);
    });
  });
}
