// The one-time lift of profile aliases into the contact store (APP-19). The
// store's own rules live in contact_store_test.dart; what matters here is that
// nothing assigned in a profile is left behind.
//
// Fixtures are raw profile JSON on purpose, exactly as the import reads it. That
// is not a shortcut around building an AppState -- it is the property being
// tested: phase 2 removes `display_name` from Conversation, so an import that
// went through the parsed model would find nothing to import the moment the two
// halves shipped in the wrong order, or a user skipped a version.
import 'package:flutter_test/flutter_test.dart';
import 'package:freizone/state/contact_import.dart';
import 'package:freizone/state/contact_store.dart';

const clara = 'qclara00000000000000a';
const ben = 'qben000000000000000b0';

void main() {
  Map<String, dynamic> profile(
    String accountId, {
    Map<String, String?> named = const {},
    Map<String, String?> blocked = const {},
    Map<String, String> servers = const {},
  }) => {
    'account_id': accountId,
    'server': 'https://a.example.org',
    'conversations': {
      for (final entry in named.entries)
        entry.key: {
          'peer_account_id': entry.key,
          if (entry.value != null) 'display_name': entry.value,
          if (servers[entry.key] != null) 'peer_server': servers[entry.key],
        },
    },
    'blocked_peers': [
      for (final entry in blocked.entries)
        {
          'peer_account_id': entry.key,
          if (entry.value != null) 'display_name': entry.value,
          if (servers[entry.key] != null) 'peer_server': servers[entry.key],
        },
    ],
  };

  test('takes the aliases out of every profile', () async {
    final store = ContactStore.inMemory();
    await importExistingAliases(store, [
      profile('qaaa0000000000000000a', named: {clara: 'Clara'}),
      profile('qbbb0000000000000000b', named: {ben: 'Ben'}),
    ]);

    expect(store.nameFor(clara), 'Clara');
    expect(store.nameFor(ben), 'Ben');
  });

  test('a name whose conversation is gone still comes across', () async {
    // Why BlockedPeer.displayName existed at all: the blocked list had to show
    // a name with no conversation left. Losing it here would lose the names of
    // exactly the peers a user had most reason to label.
    final store = ContactStore.inMemory();
    await importExistingAliases(store, [
      profile('qaaa0000000000000000a', blocked: {clara: 'Spam Clara'}),
    ]);
    expect(store.nameFor(clara), 'Spam Clara');
  });

  test('a live conversation alias beats the block-time snapshot', () async {
    final store = ContactStore.inMemory();
    await importExistingAliases(store, [
      profile(
        'qaaa0000000000000000a',
        named: {clara: 'Clara (renamed)'},
        blocked: {clara: 'Clara (old)'},
      ),
    ]);
    expect(store.nameFor(clara), 'Clara (renamed)');
  });

  test('carries the peer server across, so nothing has to be re-resolved', () async {
    final store = ContactStore.inMemory();
    await importExistingAliases(store, [
      profile(
        'qaaa0000000000000000a',
        named: {clara: 'Clara'},
        servers: {clara: 'https://b.example.org'},
      ),
    ]);
    expect(store.contact(clara)?.server, 'https://b.example.org');
  });

  test('an unnamed conversation makes no contact', () async {
    // A contact exists only by a deliberate act. Having chatted with somebody
    // is not one -- otherwise the store fills with every account this device
    // has ever exchanged a message with, across every account at once.
    final store = ContactStore.inMemory();
    await importExistingAliases(store, [
      profile('qaaa0000000000000000a', named: {clara: null, ben: '  '}),
    ]);
    expect(store.isEmpty, isTrue);
  });

  test('a disagreement between two profiles is reported, not hidden', () async {
    final store = ContactStore.inMemory();
    final report = await importExistingAliases(store, [
      profile('qbbb0000000000000000b', named: {clara: 'Frau Müller'}),
      profile('qaaa0000000000000000a', named: {clara: 'Clara'}),
    ]);

    expect(store.nameFor(clara), 'Clara', reason: 'lowest profile id wins');
    expect(report.collisions.single.discarded, ['Frau Müller']);
    expect(store.pendingReport, isNotNull);

    await store.dismissReport();
    expect(store.pendingReport, isNull);
  });

  test('no profiles at all is not an error', () async {
    final store = ContactStore.inMemory();
    final report = await importExistingAliases(store, const []);
    expect(report.imported, 0);
    expect(store.isEmpty, isTrue);
  });

  group('profiles it cannot read', () {
    test('a profile with no account id is skipped, not crashed on', () async {
      final store = ContactStore.inMemory();
      await importExistingAliases(store, [
        {'conversations': {clara: {'display_name': 'Clara'}}},
        profile('qaaa0000000000000000a', named: {ben: 'Ben'}),
      ]);
      // Skipped rather than imported under a guessed owner: which profile a
      // name came from is what decides collisions.
      expect(store.nameFor(clara), isNull);
      expect(store.nameFor(ben), 'Ben');
    });

    test('missing, empty or wrongly-typed sections are all just empty', () async {
      // A one-shot migration reading files it did not write this run has to
      // survive anything on disk -- a crash here would be a crash at startup,
      // before any screen exists to report it.
      final store = ContactStore.inMemory();
      final report = await importExistingAliases(store, [
        {'account_id': 'qaaa0000000000000000a'},
        {
          'account_id': 'qbbb0000000000000000b',
          'conversations': 'not a map',
          'blocked_peers': {'not': 'a list'},
        },
        {
          'account_id': 'qccc0000000000000000c',
          'conversations': {clara: 'not a map either'},
          'blocked_peers': ['not a map', {'no_peer_id': true}],
        },
      ]);
      expect(report.imported, 0);
      expect(store.isEmpty, isTrue);
    });
  });
}
