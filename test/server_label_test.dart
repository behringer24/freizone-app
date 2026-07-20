import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/util/server_label.dart';

void main() {
  group('shortServerLabel', () {
    test('strips subdomain and TLD from a normal server', () {
      expect(
        shortServerLabel('chat.behringer24.de', ['chat.behringer24.de']),
        'behringer24',
      );
    });

    test('strips just the TLD when there is no subdomain', () {
      expect(
        shortServerLabel('chatcentral.de', ['chatcentral.de']),
        'chatcentral',
      );
    });

    test('multiple accounts on the same server do not count as a collision', () {
      final servers = ['chat.behringer24.de', 'chat.behringer24.de'];
      expect(shortServerLabel('chat.behringer24.de', servers), 'behringer24');
    });

    test('two domains sharing a name but different TLDs collide, so the TLD is kept', () {
      final servers = ['chatcentral.de', 'chatcentral.com'];
      expect(shortServerLabel('chatcentral.de', servers), 'chatcentral.de');
      expect(shortServerLabel('chatcentral.com', servers), 'chatcentral.com');
    });

    test('collision detection is case-insensitive', () {
      // Uri normalizes host casing to lowercase, so the display value
      // ends up lowercase regardless of how the server was typed --
      // expected and fine, hostnames are conventionally lowercase anyway.
      final servers = ['Chatcentral.de', 'chatcentral.com'];
      expect(shortServerLabel('Chatcentral.de', servers), 'chatcentral.de');
    });

    test('an unrelated third server does not trigger disambiguation', () {
      final servers = ['chat.behringer24.de', 'chatcentral.de'];
      expect(shortServerLabel('chat.behringer24.de', servers), 'behringer24');
      expect(shortServerLabel('chatcentral.de', servers), 'chatcentral');
    });

    test('an IPv4 literal is shown as-is, port included', () {
      final servers = ['http://192.168.1.5:18080'];
      expect(
        shortServerLabel('http://192.168.1.5:18080', servers),
        '192.168.1.5:18080',
      );
    });

    test('two IPs on different ports stay distinct', () {
      final servers = ['http://192.168.1.5:18080', 'http://192.168.1.5:18081'];
      expect(
        shortServerLabel('http://192.168.1.5:18080', servers),
        '192.168.1.5:18080',
      );
      expect(
        shortServerLabel('http://192.168.1.5:18081', servers),
        '192.168.1.5:18081',
      );
    });

    test('a bare dot-less hostname is shown as-is', () {
      expect(
        shortServerLabel('http://localhost:8080', ['http://localhost:8080']),
        'localhost:8080',
      );
    });
  });
}
