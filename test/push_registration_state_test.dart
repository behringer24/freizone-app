import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/push/push_manager.dart';
import 'package:freizone/state/local_state.dart';

void main() {
  AppState state() => AppState(
    server: 'https://chat.example.org',
    accountId: 'qh29f6npum6dl8vu79l9q',
    rootPub: Uint8List.fromList(List.filled(32, 1)),
    rootPriv: Uint8List.fromList(List.filled(64, 2)),
    deviceId: 'abcdef0123456789',
    devicePub: Uint8List.fromList(List.filled(32, 3)),
    devicePriv: Uint8List.fromList(List.filled(64, 4)),
  );

  group('push registration state persistence', () {
    test('a fresh profile has never registered', () {
      final s = state();
      expect(s.pushRegisteredAt, isNull);
      expect(s.pushMechanism, isNull);
    });

    test('omitted from json when unset, so old profiles stay byte-identical', () {
      final json = state().toJson();
      expect(json.containsKey('push_registered_at'), isFalse);
      expect(json.containsKey('push_mechanism'), isFalse);
    });

    test('round-trips through toJson/fromJson', () {
      final s = state()
        ..pushRegisteredAt = DateTime.utc(2026, 8, 1, 12, 30)
        ..pushMechanism = 'unifiedpush:io.heckel.ntfy';

      final restored = AppState.fromJson(s.toJson());
      expect(restored.pushRegisteredAt, DateTime.utc(2026, 8, 1, 12, 30));
      expect(restored.pushMechanism, 'unifiedpush:io.heckel.ntfy');
    });

    test('a profile written before this field loads as never registered', () {
      // The whole point of persisting it: an install that predates APP-12 has
      // no such key, and must read as "unknown" rather than crashing or
      // claiming a registration that never happened.
      final legacy = state().toJson()..remove('push_registered_at');
      final restored = AppState.fromJson(legacy);
      expect(restored.pushRegisteredAt, isNull);
    });
  });

  group('describeDistributor', () {
    test('names the distributors we know', () {
      expect(describeDistributor('io.heckel.ntfy'), 'ntfy');
      expect(
        describeDistributor('org.unifiedpush.distributor.nextpush'),
        'NextPush',
      );
    });

    test('falls back to the package id for anything else', () {
      // Resolving a real app label would need a PackageManager round trip we
      // deliberately don't take -- showing the id beats showing nothing.
      expect(describeDistributor('com.example.unknown'), 'com.example.unknown');
    });
  });
}
