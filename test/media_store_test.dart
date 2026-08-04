import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/state/media_store.dart';

/// The in-flight map only means anything while every consumer is looking at the
/// same store: a picture's download is claimed by whoever gets there first (the
/// prefetch when the message lands), and the bubble that draws it finds out it
/// has landed by listening. A second store makes both halves silently useless
/// -- the paths still agree, so the file is written and found, but nobody hears
/// about it and the picture spins until its bubble is rebuilt from scratch.
///
/// Set up once for the whole file on purpose: the store is a per-isolate
/// singleton, so the first call decides its root for every test here.
void main() {
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('freizone_media_test');
    // path_provider has no implementation under `flutter test`, so point the
    // store at a scratch directory via its platform channel.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => tempDir.path,
        );
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await tempDir.delete(recursive: true);
  });

  test('callers racing for the first store all get the same one', () async {
    // All three before a single await, which is the real sequence when a
    // notification cold-starts the app: the startup sweep, the arriving
    // picture's prefetch and the bubble drawing it, none of them waiting for
    // the others, all while the documents directory is still being resolved.
    final stores = await Future.wait([
      MediaStore.instance(),
      MediaStore.instance(),
      MediaStore.instance(),
    ]);

    expect(stores[1], same(stores[0]));
    expect(stores[2], same(stores[0]));
  });

  test('a fetch state set by one caller reaches another caller\'s listener',
      () async {
    final watcher = await MediaStore.instance();
    final downloader = await MediaStore.instance();

    var notifications = 0;
    void onChanged() => notifications++;
    watcher.addListener(onChanged);
    addTearDown(() => watcher.removeListener(onChanged));

    downloader.markFetching(
      accountId: 'acct1',
      chatId: 'group1',
      messageId: 'msg1',
    );
    expect(notifications, 1);
    expect(
      watcher.stateFor(
        accountId: 'acct1',
        chatId: 'group1',
        messageId: 'msg1',
      ),
      MediaFetchState.downloading,
    );

    // What ImageAttachment waits for: the download settled, so the bubble may
    // stop spinning and read the file off disk.
    downloader.clearFetchState(
      accountId: 'acct1',
      chatId: 'group1',
      messageId: 'msg1',
    );
    expect(notifications, 2);
    expect(
      watcher.stateFor(
        accountId: 'acct1',
        chatId: 'group1',
        messageId: 'msg1',
      ),
      MediaFetchState.idle,
    );
  });

  test('one account downloading a group picture does not claim it for the '
      'other accounts on the device', () async {
    final media = await MediaStore.instance();

    // The same group message, as several accounts on one device see it: one id,
    // one file per account. The first account to start must not make the others
    // look already served -- they would wait for a download that writes into
    // somebody else's directory, and then have nothing to adopt and no second
    // notification coming.
    media.markFetching(
      accountId: 'acctA',
      chatId: 'group1',
      messageId: 'shared',
    );

    expect(
      media.stateFor(accountId: 'acctA', chatId: 'group1', messageId: 'shared'),
      MediaFetchState.downloading,
    );
    for (final other in ['acctB', 'acctC', 'acctD']) {
      expect(
        media.stateFor(
          accountId: other,
          chatId: 'group1',
          messageId: 'shared',
        ),
        MediaFetchState.idle,
        reason: '$other must be free to fetch its own copy',
      );
    }

    // Same account, same message, different chat: also a different file, so
    // also a different claim.
    expect(
      media.stateFor(accountId: 'acctA', chatId: 'group2', messageId: 'shared'),
      MediaFetchState.idle,
    );

    // And a failure belongs to exactly one account, so nobody else gets a retry
    // overlay for a download they never attempted.
    media.markFailed(
      accountId: 'acctA',
      chatId: 'group1',
      messageId: 'shared',
    );
    expect(
      media.stateFor(accountId: 'acctB', chatId: 'group1', messageId: 'shared'),
      MediaFetchState.idle,
    );
    addTearDown(
      () => media.clearFetchState(
        accountId: 'acctA',
        chatId: 'group1',
        messageId: 'shared',
      ),
    );
  });

  test('a group picture and a one-to-one picture never share a path', () async {
    final media = await MediaStore.instance();
    final group = media.fileFor(
      accountId: 'acct1',
      chatId: 'group1',
      messageId: 'msg1',
    );
    final direct = media.fileFor(
      accountId: 'acct1',
      chatId: 'peer1',
      messageId: 'msg1',
    );

    expect(group.path, isNot(direct.path));
    // The thumbnail is a sibling of the full file, so one chat's media is one
    // directory -- what makes deleting a conversation a single recursive
    // removal.
    expect(
      media.thumbFor(accountId: 'acct1', chatId: 'group1', messageId: 'msg1')
          .parent
          .path,
      group.parent.path,
    );
  });
}
