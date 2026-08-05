// The central contact store (APP-19). Two things carry real risk here and both
// are tested: the store is the only place a name lives, so losing one loses it
// everywhere -- and the one-time import moves the source of truth, so getting
// it wrong discards every name the user ever assigned.
import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/state/contact_store.dart';

const clara = 'qclara00000000000000a';
const ben = 'qben000000000000000b0';

void main() {
  group('Contact', () {
    test('round-trips, and omits what it does not have', () {
      const bare = Contact(accountId: clara, name: 'Clara');
      final restored = Contact.fromJson(bare.toJson());
      expect(restored.accountId, clara);
      expect(restored.name, 'Clara');
      expect(restored.server, isNull);
      expect(bare.toJson().containsKey('server'), isFalse);
      expect(bare.toJson().containsKey('created_at'), isFalse);

      final full = Contact(
        accountId: clara,
        name: 'Clara',
        server: 'https://a.example.org',
        createdAt: DateTime.utc(2026, 8, 5, 12),
      );
      final restoredFull = Contact.fromJson(full.toJson());
      expect(restoredFull.server, 'https://a.example.org');
      expect(restoredFull.createdAt, DateTime.utc(2026, 8, 5, 12));
    });

    test('a rename keeps the server and the creation stamp', () {
      // Renaming must not undo a resolution: the server is what makes the
      // contact usable, and it is established once, at creation.
      final original = Contact(
        accountId: clara,
        name: 'Clara',
        server: 'https://a.example.org',
        createdAt: DateTime.utc(2026, 8, 5),
      );
      final renamed = original.copyWith(name: 'Clara privat');
      expect(renamed.name, 'Clara privat');
      expect(renamed.server, 'https://a.example.org');
      expect(renamed.createdAt, DateTime.utc(2026, 8, 5));
    });
  });

  group('ContactStore', () {
    test('names, renames and forgets an address', () async {
      final store = ContactStore.inMemory();
      expect(store.nameFor(clara), isNull);

      await store.setName(clara, name: 'Clara', server: 'https://a.example.org');
      expect(store.nameFor(clara), 'Clara');
      expect(store.contact(clara)?.server, 'https://a.example.org');

      // A rename without a server must not blank the one already there.
      await store.setName(clara, name: 'Clara privat');
      expect(store.nameFor(clara), 'Clara privat');
      expect(store.contact(clara)?.server, 'https://a.example.org');

      await store.remove(clara);
      expect(store.nameFor(clara), isNull);
      expect(store.isEmpty, isTrue);
    });

    test('notifies on every change, since every screen reads through it', () async {
      final store = ContactStore.inMemory();
      var notifications = 0;
      store.addListener(() => notifications++);

      await store.setName(clara, name: 'Clara');
      await store.setName(clara, name: 'Clara privat');
      await store.remove(clara);
      expect(notifications, 3);

      // Removing something that was never there changes nothing, so it must
      // not wake every listener in the app either.
      await store.remove(ben);
      expect(notifications, 3);
    });

    test('sorts by name, case-insensitively, breaking ties by id', () async {
      final store = ContactStore.inMemory();
      await store.setName(ben, name: 'anna');
      await store.setName(clara, name: 'Anna');
      await store.setName('qzoe0000000000000000z', name: 'Zoe');

      final names = store.contacts.map((c) => c.name).toList();
      expect(names, ['anna', 'Anna', 'Zoe']);
      // 'anna' and 'Anna' compare equal, so the id decides -- and keeps
      // deciding the same way on every rebuild.
      expect(store.contacts.first.accountId, ben);
    });
  });

  group('ContactStore.importAliases', () {
    test('lifts every profile alias into the store', () async {
      final store = ContactStore.inMemory();
      final report = await store.importAliases({
        'qme00000000000000000a': {clara: 'Clara', ben: 'Ben'},
      });

      expect(report.imported, 2);
      expect(store.nameFor(clara), 'Clara');
      expect(store.nameFor(ben), 'Ben');
      expect(report.collisions, isEmpty);
      expect(report.worthShowing, isFalse);
    });

    test('carries the server through where a profile recorded one', () async {
      final store = ContactStore.inMemory();
      await store.importAliases(
        {'qme00000000000000000a': {clara: 'Clara'}},
        serversByAccount: {clara: 'https://b.example.org'},
      );
      expect(store.contact(clara)?.server, 'https://b.example.org');
    });

    test('two accounts naming one address the same is not a collision', () async {
      // They simply agree. Reporting it would train the user to dismiss the
      // one notice that is meant to say "you have a decision to make".
      final store = ContactStore.inMemory();
      final report = await store.importAliases({
        'qaaa0000000000000000a': {clara: 'Clara'},
        'qbbb0000000000000000b': {clara: 'Clara'},
      });
      expect(report.collisions, isEmpty);
      expect(report.imported, 1);
      expect(store.nameFor(clara), 'Clara');
    });

    test('a real disagreement keeps the first and reports the rest', () async {
      final store = ContactStore.inMemory();
      final report = await store.importAliases({
        'qbbb0000000000000000b': {clara: 'Frau Müller'},
        'qaaa0000000000000000a': {clara: 'Clara'},
        'qccc0000000000000000c': {clara: 'C.'},
      });

      // "First" is by sorted profile id, NOT by whatever order the map or the
      // directory listing happened to produce -- otherwise which name survives
      // depends on the filesystem.
      expect(store.nameFor(clara), 'Clara');
      expect(report.collisions, hasLength(1));
      expect(report.collisions.single.kept, 'Clara');
      expect(report.collisions.single.discarded, ['Frau Müller', 'C.']);
      expect(report.worthShowing, isTrue);
    });

    test('the winner does not depend on the order the profiles arrive in', () async {
      final orders = [
        {
          'qbbb0000000000000000b': {clara: 'Frau Müller'},
          'qaaa0000000000000000a': {clara: 'Clara'},
        },
        {
          'qaaa0000000000000000a': {clara: 'Clara'},
          'qbbb0000000000000000b': {clara: 'Frau Müller'},
        },
      ];
      for (final aliases in orders) {
        final store = ContactStore.inMemory();
        await store.importAliases(aliases);
        expect(store.nameFor(clara), 'Clara');
      }
    });

    test('runs once, so deleted contacts do not come back', () async {
      // The reason `imported` is recorded rather than inferred from an empty
      // store: a user who removes a contact has made a decision, and the next
      // start must not undo it.
      final store = ContactStore.inMemory();
      await store.importAliases({'qme00000000000000000a': {clara: 'Clara'}});
      await store.remove(clara);

      final second = await store.importAliases({
        'qme00000000000000000a': {clara: 'Clara'},
      });
      expect(store.nameFor(clara), isNull);
      expect(second.imported, 1, reason: 'reports what the first run did');
    });

    test('an empty or blank alias is not a name', () async {
      final store = ContactStore.inMemory();
      final report = await store.importAliases({
        'qme00000000000000000a': {clara: '', ben: '   '},
      });
      expect(report.imported, 0);
      expect(store.isEmpty, isTrue);
    });

    test('a store that already ran the import does nothing', () async {
      final store = ContactStore.inMemory(imported: true);
      final report = await store.importAliases({
        'qme00000000000000000a': {clara: 'Clara'},
      });
      expect(store.isEmpty, isTrue);
      expect(report.imported, 0);
    });
  });

  group('ContactImportReport', () {
    test('round-trips, collisions included', () {
      const report = ContactImportReport(
        imported: 3,
        collisions: [
          ContactNameCollision(
            accountId: clara,
            kept: 'Clara',
            discarded: ['Frau Müller'],
          ),
        ],
      );
      final restored = ContactImportReport.fromJson(report.toJson());
      expect(restored.imported, 3);
      expect(restored.collisions.single.accountId, clara);
      expect(restored.collisions.single.discarded, ['Frau Müller']);
      expect(restored.worthShowing, isTrue);
    });

    test('nothing to show when nothing collided', () {
      const report = ContactImportReport(imported: 5, collisions: []);
      expect(report.worthShowing, isFalse);
    });
  });
}
