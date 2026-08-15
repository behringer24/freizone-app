// The account API as Dart sees it, against the real core.
//
// What this is for is narrow and worth stating, because a broader claim would
// be false. The Go side already tests what each call *decides* (native/
// api_test.go); this tests the two things only a run from Dart can:
//
//   1. every exported symbol resolves. A typo in a lookup name compiles, passes
//      analysis, and fails the first time a screen touches it.
//   2. what Go encodes is what Dart decodes. A field renamed on one side and
//      not the other produces a default, silently -- an empty chat list rather
//      than an error.
//
// Needs `native/build_desktop.ps1` to have run: a `flutter test` process has no
// core linked in, so the library is opened from a path.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/ffi/freizone_core.dart';
import 'package:freizone/state/core_account.dart';

String get _corePath {
  final root = Directory.current.path;
  for (final name in [
    'freizonecore.dll',
    'libfreizonecore.so',
    'libfreizonecore.dylib',
  ]) {
    final candidate = File(
      '$root${Platform.pathSeparator}native${Platform.pathSeparator}$name',
    );
    if (candidate.existsSync()) return candidate.path;
  }
  throw StateError('no host core found -- run native/build_desktop.ps1 first');
}

void main() {
  late Directory dir;
  late FreizoneCore core;
  late CoreAccount account;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('freizone_core_account');
    core = FreizoneCore(libraryPath: _corePath);
    final handle = core.coreOpen('${dir.path}${Platform.pathSeparator}account');
    final identity = core.generateIdentity();
    core.coreSetIdentity(
      handle: handle,
      accountId: identity.accountId,
      server: 'https://home.test',
      rootPub: identity.rootPub,
      rootPriv: identity.rootPriv,
      deviceId: identity.deviceId,
      devicePub: identity.devicePub,
      devicePriv: identity.devicePriv,
    );
    account = CoreAccount(core: core, handle: handle, libraryPath: _corePath);
  });

  tearDown(() {
    core.coreClose(account.handle);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  // A fresh account has nothing, and "nothing" has to come back as an empty
  // list rather than as a failure -- this is also what exercises the array
  // decode, which is a different path from every other call.
  test('a fresh account answers with empty lists, not errors', () {
    expect(account.chats(), isEmpty);
    expect(account.messages('qpeeraccountid000000x'), isEmpty);
  });

  // Every local call, once. The point is not what they do -- Go tests that --
  // but that the symbol behind each one resolves and the round trip works.
  test('every local call resolves and round-trips', () {
    account.setOpenChat('qpeeraccountid000000x');
    account.setOpenChat(null);

    account.blockPeer(
      'qpeeraccountid000000x',
      server: 'https://elsewhere.test',
    );
    account.unblockPeer('qpeeraccountid000000x');
    account.acceptRequest('qpeeraccountid000000x');
    account.clearChat('qpeeraccountid000000x');
    account.deleteChat('qpeeraccountid000000x');

    // Reading a group we hold no facts about is a refusal with a reason, not a
    // crash -- the one local call that legitimately throws.
    expect(
      () => account.groupInfo('8groupaccountid00000x'),
      throwsA(isA<Exception>()),
    );
  });

  // The cut audit's regression (2026-08-15): pin, unpin and per-message
  // deletion must land in the core, because the shell rebuilds its whole view
  // from the core's summaries -- all three used to write only the Dart mirror,
  // so a pin showed until the next rebuild and then silently vanished, and a
  // deleted message came back.
  //
  // The full round trip for pins -- act, then read them back off the chat
  // summary -- is pinned on the Go side (native/api_test.go), because the
  // summary needs a conversation record and those are only ever created by
  // the network half. What only this side can check: the symbols resolve, and
  // the wire field names match -- a misnamed one arrives as an empty id,
  // which the core refuses loudly rather than filing under "".
  test('pin, unpin and delete land in the core, not the mirror', () async {
    const peer = 'qpeeraccountid000000x';
    // A send writes its transcript line before it touches the network
    // (pkg/client.SendText), so failing against a dead server still leaves a
    // real message here to act on.
    await expectLater(
      account.send(peer, 'kept locally'),
      throwsA(isA<Exception>()),
    );
    final messageId = account.messages(peer).single.id;

    account.pinMessage(peer, messageId);
    account.unpinMessage(peer, messageId);

    account.deleteMessage(peer, messageId);
    expect(account.messages(peer), isEmpty);
  });

  // The isolate half. Running one blocking call proves the whole mechanism:
  // the entry point is reachable, the library is found inside the isolate, and
  // a core failure comes back as a Dart exception rather than a dead isolate.
  test(
    'a blocking call runs in an isolate and reports failure as an exception',
    () async {
      // Nothing is listening on home.test, so this fails -- which is exactly what
      // has to arrive back here rather than hanging or crashing the isolate.
      await expectLater(
        account.startConversation('qpeeraccountid000000x'),
        throwsA(isA<Exception>()),
      );
    },
  );

  // Housekeeping is best-effort: it reports what failed rather than throwing,
  // so a caller can log it and carry on.
  test('maintenance reports problems rather than throwing', () async {
    final report = await account.maintain();
    expect(
      report.clean,
      isFalse,
      reason: 'nothing can have worked against a server that is not there',
    );
    expect(report.problems, isNotEmpty);
  });

  // An attachment path answers empty for a message that does not exist, which
  // is the normal state of a picture nobody has looked at.
  test('an attachment nobody has fetched has no path and no error', () async {
    final path = await account.attachmentPath('qpeeraccountid000000x', 'nope');
    expect(path, isEmpty);
  });

  // The same question asked the way the long-press sheet asks it. What this
  // pins is the flag *crossing*: `local_only` reaching Go as false would put a
  // download in front of a menu, and nothing on this side would say so --
  // whether it then declines to download is native/api_test.go's to check,
  // since only Go can build the state where the two answers differ.
  test('a local-only path crosses and answers without an error', () async {
    final path = await account.attachmentPath(
      'qpeeraccountid000000x',
      'nope',
      localOnly: true,
    );
    expect(path, isEmpty);
  });
}
