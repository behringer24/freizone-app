// Removing an account has to take the core's directory with it.
//
// Worth its own test rather than being assumed, because what is in there is the
// account's identity private keys, both ratchet sessions per peer and every
// transcript -- and because it was missing for five days without anything
// failing: AccountManager cleaned the two pre-cut Dart stores, both of which
// are empty on a current install, and reported success.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/net/core_stream.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('freizone_core_state_test');
    // path_provider has no implementation under `flutter test`; point the
    // documents directory at a scratch one through its platform channel.
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
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  /// The shape the core actually writes: nested directories, not one flat file.
  /// A delete that forgot `recursive` would pass a single-file test.
  Future<Directory> populateCoreState(String accountId) async {
    final root = Directory(await coreStatePath(accountId));
    for (final relative in [
      ['identity.json'],
      ['chats', 'qpeeraccountid000000x', 'log.jsonl'],
      ['peers', 'qpeeraccountid000000x', 'session.json'],
      ['groups', '8groupaccountid00000x', 'facts.json'],
      ['media', 'qpeeraccountid000000x', 'm1'],
    ]) {
      final file = File(
        [root.path, ...relative].join(Platform.pathSeparator),
      );
      await file.parent.create(recursive: true);
      await file.writeAsString('something worth not leaving behind');
    }
    return root;
  }

  test('deleting an account takes the core directory with it', () async {
    final dir = await populateCoreState('acct1');
    expect(dir.existsSync(), isTrue, reason: 'the fixture must exist first');

    await deleteCoreState('acct1');

    expect(dir.existsSync(), isFalse);
    // Nothing at all, not just the top-level files: a non-recursive delete
    // would leave the sessions and the transcripts exactly where they were.
    expect(
      Directory(tempDir.path).listSync(recursive: true),
      isEmpty,
      reason: 'no part of the account may survive its removal',
    );
  });

  test('one account is removed without touching another', () async {
    final mine = await populateCoreState('acct1');
    final other = await populateCoreState('acct2');

    await deleteCoreState('acct1');

    expect(mine.existsSync(), isFalse);
    expect(
      other.listSync(recursive: true).whereType<File>().length,
      5,
      reason: 'a device holds several accounts; only the named one goes',
    );
  });

  test('removing an account that has no core state is not an error', () async {
    // A first run that never got as far as opening the core, or a removal
    // running twice. Both are ordinary, and neither may fail the cleanup this
    // sits in the middle of.
    await deleteCoreState('never-opened');
  });
}
