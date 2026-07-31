import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/util/share_intake.dart';
import 'package:freizone/util/share_shortcuts.dart';

void main() {
  group('shortcut ids', () {
    test('round-trip through the id encoding', () {
      final id = shortcutIdFor(
        accountId: 'q6306ckeh8n27fnw4n0hp',
        peerAccountId: 'qh29f6npum6dl8vu79l9q',
      );
      final target = shortcutTarget(id)!;
      expect(target.accountId, 'q6306ckeh8n27fnw4n0hp');
      expect(target.peerAccountId, 'qh29f6npum6dl8vu79l9q');
    });

    test('a share from the plain share sheet has no target', () {
      // No shortcut id at all -- the picker has to be shown.
      expect(shortcutTarget(null), isNull);
    });

    test('malformed ids are rejected rather than half-parsed', () {
      expect(shortcutTarget(''), isNull);
      expect(shortcutTarget('onlyonepart'), isNull);
      expect(shortcutTarget('|missingaccount'), isNull);
      expect(shortcutTarget('missingpeer|'), isNull);
      expect(shortcutTarget('a|b|c'), isNull);
    });
  });

  group('IncomingShare', () {
    test('text-only and image-only shares are both accepted', () {
      expect(IncomingShare.fromMap({'text': 'hallo'})?.text, 'hallo');
      expect(
        IncomingShare.fromMap({'imagePath': '/cache/shared/ab'})?.imagePath,
        '/cache/shared/ab',
      );
    });

    test('an image with a caption keeps both', () {
      final share = IncomingShare.fromMap({
        'text': 'schau mal',
        'imagePath': '/cache/shared/ab',
      })!;
      expect(share.text, 'schau mal');
      expect(share.imagePath, '/cache/shared/ab');
    });

    test('a share carrying nothing usable is treated as absent', () {
      // The native side can hand over a map whose fields are all null (an
      // ACTION_SEND with neither EXTRA_TEXT nor a readable stream); that must
      // not open an empty picker.
      expect(IncomingShare.fromMap(null), isNull);
      expect(IncomingShare.fromMap({}), isNull);
      expect(IncomingShare.fromMap({'text': null, 'imagePath': null}), isNull);
      expect(IncomingShare.fromMap({'text': ''}), isNull);
    });

    test('a shortcut id is carried through so the picker can be skipped', () {
      final share = IncomingShare.fromMap({
        'text': 'hallo',
        'shortcutId': 'acct|peer',
      })!;
      expect(shortcutTarget(share.shortcutId)?.accountId, 'acct');
    });
  });
}
