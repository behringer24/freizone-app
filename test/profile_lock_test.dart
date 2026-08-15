import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/state/local_state.dart';

/// Serialising a load-modify-save sequence is what keeps the background push
/// isolate and the foreground session from reverting each other's Double
/// Ratchet progress -- the cause of conversations that permanently stopped
/// decrypting. These exercise that guarantee directly, with real concurrent
/// futures against real files.
void main() {
  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('freizone_lock_test');
    // path_provider has no implementation under `flutter test`, so point the
    // store at a scratch directory via its platform channel.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => tempDir.path,
        );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await tempDir.delete(recursive: true);
  });

  AppState freshState() => AppState(
    server: 'chat.example.org',
    accountId: 'acct1',
    rootPub: Uint8List(0),
    rootPriv: Uint8List(0),
    deviceId: 'device1',
    devicePub: Uint8List(0),
    devicePriv: Uint8List(0),
  );

  test('concurrent load-modify-save sequences do not lose each other', () async {
    await LocalStateStore.saveProfile(freshState());

    // Two writers, each doing what a real consumer does: load a snapshot, take
    // its time (a network round trip and some decrypts), then save. Without
    // the lock the second load sees the pre-first state and its save reverts
    // the first writer's work entirely.
    Future<void> writer(String id) => LocalStateStore.withProfileLock(
      'acct1',
      () async {
        final state = (await LocalStateStore.loadProfile('acct1'))!;
        await Future<void>.delayed(const Duration(milliseconds: 30));
        state.blockedPeers[id] = BlockedPeer(peerAccountId: id);
        await LocalStateStore.saveProfile(state);
      },
    );

    await Future.wait([writer('msg-a'), writer('msg-b')]);

    final finalState = (await LocalStateStore.loadProfile('acct1'))!;
    expect(finalState.blockedPeers.keys, unorderedEquals(['msg-a', 'msg-b']));
  });

  test('the lock serialises rather than running sequences in parallel', () async {
    await LocalStateStore.saveProfile(freshState());

    var active = 0;
    var maxActive = 0;
    Future<void> section() => LocalStateStore.withProfileLock('acct1', () async {
      active++;
      maxActive = maxActive > active ? maxActive : active;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      active--;
    });

    await Future.wait([section(), section(), section()]);

    expect(maxActive, 1, reason: 'sections must never overlap');
  });

  test('the lock is released even when the action throws', () async {
    await LocalStateStore.saveProfile(freshState());

    await expectLater(
      LocalStateStore.withProfileLock<void>(
        'acct1',
        () async => throw StateError('boom'),
      ),
      throwsStateError,
    );

    // A leaked lock would wedge the account until the stale timeout; this must
    // acquire immediately instead.
    final ran = await LocalStateStore.withProfileLock(
      'acct1',
      () async => true,
    ).timeout(const Duration(seconds: 2));
    expect(ran, isTrue);
  });

  test('an abandoned lock file is taken over rather than wedging forever', () async {
    await LocalStateStore.saveProfile(freshState());

    // Simulate an isolate killed mid-sync: the lock file survives it. Backdate
    // it past the staleness window, which is what Android's process killing
    // would leave behind.
    final lockFile = File(
      '${tempDir.path}${Platform.pathSeparator}freizone_profile_acct1.json.lock',
    );
    await lockFile.create();
    await lockFile.setLastModified(
      DateTime.now().subtract(const Duration(minutes: 5)),
    );

    final ran = await LocalStateStore.withProfileLock(
      'acct1',
      () async => true,
    ).timeout(const Duration(seconds: 5));
    expect(ran, isTrue);
  });
}
