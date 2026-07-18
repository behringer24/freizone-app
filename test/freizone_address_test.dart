import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/util/freizone_address.dart';

void main() {
  group('parseFreizoneAddress', () {
    test('bare full id has no server part', () {
      final a = parseFreizoneAddress('q2xjx-e3gtq-utyft-ankjc-v');
      expect(a?.idOrPrefix, 'q2xjxe3gtqutyftankjcv');
      expect(a?.server, isNull);
    });

    test('bare 5-char prefix has no server part', () {
      final a = parseFreizoneAddress('q2xjx');
      expect(a?.idOrPrefix, 'q2xjx');
      expect(a?.server, isNull);
    });

    test('*local is equivalent to no server part', () {
      final a = parseFreizoneAddress('q2xjx*local');
      expect(a?.idOrPrefix, 'q2xjx');
      expect(a?.server, isNull);
    });

    test('*local is case-insensitive', () {
      final a = parseFreizoneAddress('q2xjx*LOCAL');
      expect(a?.server, isNull);
    });

    test('domain server part is normalized', () {
      final a = parseFreizoneAddress('q2xjx*chat.example.org');
      expect(a?.idOrPrefix, 'q2xjx');
      expect(a?.server, 'https://chat.example.org');
    });

    test('ip:port server part is normalized, keeping the port', () {
      final a = parseFreizoneAddress('q2xjx*192.168.178.43:18080');
      expect(a?.server, 'https://192.168.178.43:18080');
    });

    test('explicit scheme in the server part is respected', () {
      final a = parseFreizoneAddress('q2xjx*http://192.168.178.43:18080');
      expect(a?.server, 'http://192.168.178.43:18080');
    });

    test('dashes in the id part are stripped, dashes in a hostname are not', () {
      final a = parseFreizoneAddress('q2xjx-e3gtq-utyft-ankjc-v*my-server.example.org');
      expect(a?.idOrPrefix, 'q2xjxe3gtqutyftankjcv');
      expect(a?.server, 'https://my-server.example.org');
    });

    test('empty input is invalid', () {
      expect(parseFreizoneAddress(''), isNull);
      expect(parseFreizoneAddress('   '), isNull);
    });

    test('empty id part is invalid even with a server', () {
      expect(parseFreizoneAddress('*chat.example.org'), isNull);
    });
  });

  group('buildFreizoneAddress', () {
    test('groups the id by 5 and appends the server with a single *', () {
      expect(
        buildFreizoneAddress(id: 'q2xjxe3gtqutyftankjcv', server: 'https://chat.example.org'),
        'q2xjx-e3gtq-utyft-ankjc-v*chat.example.org',
      );
    });

    test('the default https:// scheme is dropped', () {
      expect(
        buildFreizoneAddress(id: 'q2xjxe3gtqutyftankjcv', server: 'https://chat.example.org'),
        isNot(contains('https://')),
      );
    });

    test('a non-default scheme (local/dev servers without TLS) stays visible', () {
      expect(
        buildFreizoneAddress(id: 'q2xjxe3gtqutyftankjcv', server: 'http://192.168.178.43:18080'),
        'q2xjx-e3gtq-utyft-ankjc-v*http://192.168.178.43:18080',
      );
    });

    test('formatAccountIdForDisplay is a no-op on a 5-char prefix, so building from one works unchanged', () {
      expect(
        buildFreizoneAddress(id: 'q2xjx', server: 'https://chat.example.org'),
        'q2xjx*chat.example.org',
      );
    });

    test('round-trips through parseFreizoneAddress back to the original normalized server', () {
      const originalServer = 'https://chat.example.org';
      final built = buildFreizoneAddress(id: 'q2xjxe3gtqutyftankjcv', server: originalServer);
      final parsed = parseFreizoneAddress(built);
      expect(parsed?.server, originalServer);
    });
  });
}
