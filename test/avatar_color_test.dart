import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/util/avatar_color.dart';

void main() {
  group('accountEntropy', () {
    test('skips the version-marker character at index 0', () {
      // Index 0 is always the version marker (see address_format.dart's
      // accountIdPrefixLength) -- two ids sharing it but differing right
      // after must produce different entropy.
      expect(accountEntropy('qu0pcyuscdc6tshke5aa5'), 'u0pc');
      expect(accountEntropy('qjy2guanukpe2kgjl7qqw'), 'jy2g');
    });

    test(
      'degrades gracefully for an id shorter than accountIdPrefixLength',
      () {
        expect(accountEntropy('qabc'), 'abc');
        expect(accountEntropy('qa'), 'a');
        expect(accountEntropy('q'), 'q');
        expect(accountEntropy(''), '');
      },
    );
  });

  group('avatarColorFor', () {
    test('is stable for the same id', () {
      const id = 'qu0pcyuscdc6tshke5aa5';
      expect(avatarColorFor(id), avatarColorFor(id));
    });

    test('ignores the version-marker character, unlike a raw-id hash', () {
      // Two ids differing only in a part that isn't real entropy must
      // still be allowed to share a color -- the point is that the
      // *real* entropy characters drive the color, not incidental
      // hashCode collisions on the full string.
      expect(
        avatarColorFor('qu0pcyuscdc6tshke5aa5'),
        avatarColorFor('xu0pcyyyyyyyyyyyyyyyy'),
      );
    });
  });
}
