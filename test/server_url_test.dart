import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/util/server_url.dart';

void main() {
  group('normalizeServerUrl', () {
    test('bare domain gets https:// prepended', () {
      expect(normalizeServerUrl('chat.example.org'), 'https://chat.example.org');
    });

    test('explicit scheme is respected as-is', () {
      expect(
        normalizeServerUrl('http://192.168.178.43:18080'),
        'http://192.168.178.43:18080',
      );
    });

    test('trailing slashes are stripped', () {
      expect(normalizeServerUrl('chat.example.org///'), 'https://chat.example.org');
    });
  });

  group('sameServer', () {
    test('bare domain and its explicit https:// form are the same server', () {
      expect(sameServer('chatcentral.de', 'https://chatcentral.de'), isTrue);
    });

    test('bare domain and an explicit http:// form are still the same server', () {
      // Scheme alone shouldn't imply a different server when neither side
      // names an explicit port -- this is the exact bug this function
      // fixes: a device that stored "http://chatcentral.de" (e.g. from a
      // copied link) must still recognize "chatcentral.de" as home.
      expect(sameServer('chatcentral.de', 'http://chatcentral.de'), isTrue);
    });

    test('host comparison is case-insensitive', () {
      expect(sameServer('Chatcentral.de', 'chatcentral.de'), isTrue);
    });

    test('different hosts are different servers', () {
      expect(sameServer('chatcentral.de', 'chat.behringer24.de'), isFalse);
    });

    test('an explicit port on only one side makes them different servers', () {
      expect(sameServer('chatcentral.de', 'chatcentral.de:8443'), isFalse);
    });

    test('matching explicit ports on a local/dev server are the same server', () {
      expect(
        sameServer('http://192.168.178.43:18080', 'https://192.168.178.43:18080'),
        isTrue,
      );
    });

    test('differing explicit ports are different servers', () {
      expect(
        sameServer('192.168.178.43:18080', '192.168.178.43:18081'),
        isFalse,
      );
    });
  });
}
