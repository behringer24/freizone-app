import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/util/invite_uri.dart';

void main() {
  group('join invite', () {
    test('strips a default https:// scheme from the encoded server', () {
      final uri = buildInviteUri(server: 'https://chat.example.org', code: 'ABC123');
      final parsed = parseInviteUri(uri.toString());
      expect(parsed?.server, 'chat.example.org');
      expect(parsed?.code, 'ABC123');
    });

    test('keeps a non-default http:// scheme visible (local/dev servers)', () {
      final uri = buildInviteUri(server: 'http://192.168.1.5:18080');
      final parsed = parseInviteUri(uri.toString());
      expect(parsed?.server, 'http://192.168.1.5:18080');
    });

    test('omits code entirely when not given', () {
      final uri = buildInviteUri(server: 'https://chat.example.org');
      final parsed = parseInviteUri(uri.toString());
      expect(parsed?.server, 'chat.example.org');
      expect(parsed?.code, isNull);
    });

    test('rejects a non-join URI', () {
      expect(parseInviteUri('freizone://chat?id=q2xjx&server=chat.example.org'), isNull);
    });

    test('rejects an unrelated string', () {
      expect(parseInviteUri('not a uri at all'), isNull);
    });

    test('rejects a join URI missing server', () {
      expect(parseInviteUri('freizone://join?code=ABC123'), isNull);
    });
  });

  group('chat invite', () {
    test('round-trips id, server, and name', () {
      final uri = buildChatInviteUri(
        id: 'q2xjxe3gtqutyftankjcv',
        server: 'chat.example.org',
        name: 'Anna',
      );
      final parsed = parseChatInviteUri(uri.toString());
      expect(parsed?.id, 'q2xjxe3gtqutyftankjcv');
      expect(parsed?.server, 'chat.example.org');
      expect(parsed?.name, 'Anna');
    });

    test('strips a default https:// scheme from the encoded server', () {
      final uri = buildChatInviteUri(
        id: 'q2xjxe3gtqutyftankjcv',
        server: 'https://chat.example.org',
      );
      final parsed = parseChatInviteUri(uri.toString());
      expect(parsed?.server, 'chat.example.org');
    });

    test('keeps a non-default http:// scheme visible (local/dev servers)', () {
      final uri = buildChatInviteUri(
        id: 'q2xjxe3gtqutyftankjcv',
        server: 'http://192.168.1.5:18080',
      );
      final parsed = parseChatInviteUri(uri.toString());
      expect(parsed?.server, 'http://192.168.1.5:18080');
    });

    test('omits name entirely when not given', () {
      final uri = buildChatInviteUri(
        id: 'q2xjxe3gtqutyftankjcv',
        server: 'chat.example.org',
      );
      final parsed = parseChatInviteUri(uri.toString());
      expect(parsed?.name, isNull);
      expect(uri.toString().contains('name'), isFalse);
    });

    test('omits name when given an empty string', () {
      final uri = buildChatInviteUri(
        id: 'q2xjxe3gtqutyftankjcv',
        server: 'chat.example.org',
        name: '',
      );
      expect(uri.toString().contains('name'), isFalse);
    });

    test('rejects a non-chat URI', () {
      expect(
        parseChatInviteUri('freizone://join?server=chat.example.org'),
        isNull,
      );
    });

    test('rejects a chat URI missing id', () {
      expect(parseChatInviteUri('freizone://chat?server=chat.example.org'), isNull);
    });

    test('rejects a chat URI missing server', () {
      expect(parseChatInviteUri('freizone://chat?id=q2xjx'), isNull);
    });

    test('rejects an unrelated string', () {
      expect(parseChatInviteUri('not a uri at all'), isNull);
    });
  });
}
