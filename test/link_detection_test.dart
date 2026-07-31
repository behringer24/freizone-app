import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/util/link_detection.dart';

void main() {
  // Convenience: the substrings that got linkified, in order.
  List<String> texts(String input) =>
      detectLinks(input).map((s) => s.text).toList();
  List<String> targets(String input) =>
      detectLinks(input).map((s) => s.target).toList();

  group('nothing to link', () {
    test('empty and plain text produce no spans', () {
      expect(detectLinks(''), isEmpty);
      expect(detectLinks('Hallo, wie geht es dir?'), isEmpty);
    });

    test('a filename is not a link', () {
      // The reason bare domains are not matched at all: this would otherwise
      // become "https://foto.png".
      expect(detectLinks('schau dir foto.png an'), isEmpty);
      expect(detectLinks('das war z.B. gestern'), isEmpty);
      expect(detectLinks('version 1.2.3 ist raus'), isEmpty);
    });

    test('a bare domain without www is not matched', () {
      expect(detectLinks('geh auf example.org'), isEmpty);
    });
  });

  group('urls', () {
    test('https and http are matched as-is', () {
      expect(targets('siehe https://example.org/a'), ['https://example.org/a']);
      expect(targets('siehe http://example.org'), ['http://example.org']);
    });

    test('www is upgraded to https, never http', () {
      expect(targets('siehe www.example.org'), ['https://www.example.org']);
    });

    test('trailing sentence punctuation is not part of the link', () {
      expect(texts('siehe https://example.org.'), ['https://example.org']);
      expect(texts('siehe https://example.org, dann'), ['https://example.org']);
      expect(texts('wirklich https://example.org?'), ['https://example.org']);
      expect(texts('"https://example.org"'), ['https://example.org']);
    });

    test('an unbalanced closing paren is dropped', () {
      expect(texts('(siehe https://example.org)'), ['https://example.org']);
    });

    test('balanced parens inside a url survive', () {
      const url = 'https://de.wikipedia.org/wiki/Beispiel_(Begriffsklärung)';
      expect(texts('siehe $url'), [url]);
    });

    test('several links in one message, in order', () {
      final got = texts('erst https://a.example dann https://b.example');
      expect(got, ['https://a.example', 'https://b.example']);
    });

    test('an absurdly long run is left as text', () {
      final long = 'https://example.org/${'a' * 3000}';
      expect(detectLinks(long), isEmpty);
    });

    test('offsets point back into the source text', () {
      const input = 'ab https://x.example cd';
      final span = detectLinks(input).single;
      expect(input.substring(span.start, span.end), 'https://x.example');
    });
  });

  group('email', () {
    test('a bare address becomes a mailto target', () {
      expect(targets('schreib an foo@example.org'), ['mailto:foo@example.org']);
    });

    test('an address inside a url is not matched separately', () {
      // The url claims the range first, so this stays one span.
      final spans = detectLinks('https://user@example.org/path');
      expect(spans, hasLength(1));
      expect(spans.single.kind, LinkKind.url);
    });
  });

  group('freizone addresses', () {
    test('the short display form is matched', () {
      final span = detectLinks('schreib mal qh29f*chat.example.org').single;
      expect(span.kind, LinkKind.freizoneAddress);
      expect(span.target, 'qh29f*chat.example.org');
    });

    test('a hyphenated full id is matched', () {
      // buildFreizoneAddress emits the grouped form, so this is the shape
      // that actually gets pasted around.
      const addr = 'q6306-ckeh8-n27fn-w4n0h-p*chatcentral.de';
      expect(targets('siehe $addr'), [addr]);
    });

    test('a host with a port and no dot is matched', () {
      // A LAN/dev server: "aff-abe:18080" has no dot at all.
      const addr = 'qh29f*aff-abe:18080';
      expect(targets('siehe $addr'), [addr]);
    });

    test('an embedded scheme is not torn apart by the url pattern', () {
      // withoutDefaultScheme keeps a non-default scheme visible, so an
      // address can legitimately contain "http://".
      const addr = 'q2xjx*http://192.168.1.5:18080';
      final spans = detectLinks('siehe $addr');
      expect(spans, hasLength(1));
      expect(spans.single.kind, LinkKind.freizoneAddress);
      expect(spans.single.target, addr);
    });

    test('"local" is accepted as the host', () {
      expect(targets('qh29f*local'), ['qh29f*local']);
    });

    test('arithmetic is not an address', () {
      // The minimum id length is what rules this out.
      expect(detectLinks('2*3.5 ergibt 7'), isEmpty);
      expect(detectLinks('4*5.0'), isEmpty);
    });

    test('an id using characters bech32 excludes is not an address', () {
      // b, i, o and 1 are not in the charset, so these cannot be ids.
      expect(detectLinks('bibio*example.org'), isEmpty);
      expect(detectLinks('11111*example.org'), isEmpty);
    });

    test('a host that looks like nothing is not an address', () {
      expect(detectLinks('qh29f*nonsense'), isEmpty);
    });
  });

  group('bidi controls', () {
    test('are stripped from the rendered text and the target', () {
      // U+202E (right-to-left override) can visually reverse a URL; the
      // renderer must not reproduce that faithfully.
      const sneaky = 'https://example.org/‮groj.txt';
      final span = detectLinks(sneaky).single;
      expect(span.text.contains('‮'), isFalse);
      expect(span.target.contains('‮'), isFalse);
    });
  });

  group('addressIsSelf', () {
    test('recognises the device\'s own account, short id included', () {
      final span = detectLinks('qh29f*chat.example.org').single;
      expect(addressIsSelf(span, 'qh29f6npum6dl8vu79l9q'), isTrue);
      expect(addressIsSelf(span, 'q6306ckeh8n27fnw4n0hp'), isFalse);
    });

    test('is false for anything that is not an address', () {
      final span = detectLinks('https://example.org').single;
      expect(addressIsSelf(span, 'qh29f6npum6dl8vu79l9q'), isFalse);
    });
  });
}
