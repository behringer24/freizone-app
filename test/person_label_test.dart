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
}
