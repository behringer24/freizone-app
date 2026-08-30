// The one label rule for a person (APP-18). Short, but it is read by five
// surfaces at once, and the two things that can go wrong there are a name that
// hides the id it stands for and an empty name that renders as punctuation.
import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/state/contact_store.dart';
import 'package:freizone/util/person_label.dart';

const clara = 'qclara00000000000000a';

void main() {
  ContactStore storeWith({String? name}) => ContactStore.inMemory(
    contacts: name == null
        ? const []
        : [Contact(accountId: clara, name: name)],
  );

  group('personLabel', () {
    test('keeps the short id in parentheses behind an assigned name', () {
      // Both halves, always: the name is this device's private note, the id is
      // what the message is actually addressed to.
      expect(personLabel(storeWith(name: 'Clara'), clara), 'Clara (qclar)');
    });

    test('is the bare short id for somebody never named', () {
      expect(personLabel(storeWith(), clara), 'qclar');
    });

    test('treats a blank name as unnamed rather than rendering " (qclar)"', () {
      expect(personLabel(storeWith(name: '   '), clara), 'qclar');
    });

    test('shortens nothing that is already short', () {
      // A prefix should never reach this -- a contact is keyed by a resolved id
      // -- but a label is not the place to throw over it.
      expect(personLabel(ContactStore.inMemory(), 'q1x'), 'q1x');
    });
  });

  group('personLabelCompact', () {
    test('drops the id behind a name, for a one-line row', () {
      expect(personLabelCompact(storeWith(name: 'Clara'), clara), 'Clara');
    });

    test('is the short id when there is no name to shorten to', () {
      // The important half of the exception: dropping the id only makes sense
      // *because* a name replaced it. Unnamed, the row says exactly what the
      // transcript says.
      expect(personLabelCompact(storeWith(), clara), 'qclar');
      expect(personLabelCompact(storeWith(name: '  '), clara), 'qclar');
    });
  });

  _profileNameTests();
}

// The asserted name (APP-27) is the middle link in the label chain: it stands
// in where this device has assigned nothing, and never over an assigned name.
void _profileNameTests() {
  ContactStore storeWith({String? name, String? asserted}) {
    final store = ContactStore.inMemory(
      contacts: name == null ? const [] : [Contact(accountId: clara, name: name)],
    );
    if (asserted != null) store.setSuggestedNames({clara: asserted});
    return store;
  }

  group('an asserted name', () {
    test('labels somebody this device has not named', () {
      expect(
        personLabel(storeWith(asserted: 'Clara S.'), clara),
        'Clara S. (qclar)',
      );
    });

    test('never wins over a name assigned here', () {
      // The whole point of being able to rename somebody: what the user chose
      // has to survive whatever the other side asserts afterwards.
      expect(
        personLabel(storeWith(name: 'Clara', asserted: 'Bank Support'), clara),
        'Clara (qclar)',
      );
    });

    test('is dropped for display when it is withdrawn', () {
      // A withdrawal reaches the store as an absent entry, not an empty one --
      // the core leaves the peer out of the map entirely.
      final store = storeWith(asserted: 'Clara S.');
      store.setSuggestedNames({});
      expect(personLabel(store, clara), 'qclar');
    });

    test('is kept apart from the name a report could forward', () {
      // Two questions, two answers: nameFor is the private note and must never
      // be what suggestedNameFor returns, or a report would carry it.
      final store = storeWith(name: 'Dad', asserted: 'Clara S.');
      expect(store.nameFor(clara), 'Dad');
      expect(store.suggestedNameFor(clara), 'Clara S.');
      expect(store.labelNameFor(clara), 'Dad');
    });

    test('shows in the compact row too, where there is no assigned name', () {
      expect(personLabelCompact(storeWith(asserted: 'Clara S.'), clara), 'Clara S.');
    });
  });
}
