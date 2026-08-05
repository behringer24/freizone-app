// The people this device knows, by name (APP-19).
//
// Deliberately **not** per account. Like AppSettings, and unlike AppState, this
// lives in one JSON file for the whole device: one person with one device does
// not have to inherit their accounts' split-brain, which is the decision the
// design document records. Every *action* on a contact stays account-specific
// (blocking, chats) -- that is the complexity accepted in exchange.
//
// It is also the ONLY place a peer's assigned name lives. ChatTarget.displayName
// keeps just its other meaning, a group's own name; a conversation reads the
// name from here. Change it once and it changes everywhere; delete the contact
// and every screen falls back to the short address, with no chat touched.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// One named address.
///
/// A contact **is one account address**, so it is one name. A person holding a
/// work account and a private one is two contacts -- which they would have to be
/// named apart as anyway, or they could not be told apart. Deliberately not a
/// model of a human with several addresses; see the design document for why that
/// is the thing to revisit if it ever bites.
@immutable
class Contact {
  const Contact({
    required this.accountId,
    required this.name,
    this.server,
    this.createdAt,
  });

  factory Contact.fromJson(Map<String, dynamic> j) => Contact(
    accountId: j['account_id'] as String,
    name: j['name'] as String,
    server: j['server'] as String?,
    createdAt: j['created_at'] == null
        ? null
        : DateTime.tryParse(j['created_at'] as String)?.toUtc(),
  );

  /// The canonical, fully resolved account id -- never a prefix. A hand-typed
  /// address is resolved before a contact is made from it, on the phantom-member
  /// precedent from APP-16: a stored prefix is a contact that fails at the
  /// moment somebody finally tries to use it.
  final String accountId;

  final String name;

  /// Where this account lives, when known. Null for a contact imported from a
  /// same-server conversation that never recorded one; callers fall back to
  /// their own account's server, exactly as a conversation does.
  ///
  /// Deliberately **not** the root public key: `account_id == hash(root_pubkey)`,
  /// so the id already commits to the key, and holding a copy here would make a
  /// contact record look authoritative about crypto when it is not.
  final String? server;

  final DateTime? createdAt;

  Map<String, dynamic> toJson() => {
    'account_id': accountId,
    'name': name,
    if (server != null) 'server': server,
    if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
  };

  Contact copyWith({String? name, String? server}) => Contact(
    accountId: accountId,
    name: name ?? this.name,
    server: server ?? this.server,
    createdAt: createdAt,
  );
}

/// One address that two profiles had named differently when the names were
/// lifted into this store.
@immutable
class ContactNameCollision {
  const ContactNameCollision({
    required this.accountId,
    required this.kept,
    required this.discarded,
  });

  factory ContactNameCollision.fromJson(Map<String, dynamic> j) =>
      ContactNameCollision(
        accountId: j['account_id'] as String,
        kept: j['kept'] as String,
        discarded: (j['discarded'] as List<dynamic>).cast<String>().toList(),
      );

  final String accountId;
  final String kept;
  final List<String> discarded;

  Map<String, dynamic> toJson() => {
    'account_id': accountId,
    'kept': kept,
    'discarded': discarded,
  };
}

/// What the one-time import did, kept until the user has been shown it.
///
/// A collision is not silently resolved: two of this device's accounts that
/// called the same address different things is a fact only the user can settle,
/// and picking one without saying so would quietly discard a name they chose.
@immutable
class ContactImportReport {
  const ContactImportReport({
    required this.imported,
    required this.collisions,
  });

  factory ContactImportReport.fromJson(Map<String, dynamic> j) =>
      ContactImportReport(
        imported: j['imported'] as int? ?? 0,
        collisions: ((j['collisions'] as List<dynamic>?) ?? const [])
            .map((c) => ContactNameCollision.fromJson(c as Map<String, dynamic>))
            .toList(),
      );

  final int imported;
  final List<ContactNameCollision> collisions;

  bool get worthShowing => collisions.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'imported': imported,
    'collisions': collisions.map((c) => c.toJson()).toList(),
  };
}

/// The names a single profile had assigned, as the import reads them.
///
/// A plain map rather than an AppState, so the import can be tested without
/// building profiles -- and so the reader stays honest about how little of a
/// profile this actually needs.
typedef ProfileAliases = Map<String, String>;

class ContactStore extends ChangeNotifier {
  // Positional and private, so the fields are assigned directly: a named
  // constructor cannot take `required this._contacts`.
  ContactStore._(this._contacts, this._imported, this._report);

  final Map<String, Contact> _contacts;

  /// Whether the one-time lift of existing aliases has run. Recorded rather
  /// than inferred from an empty store: a user who deletes every contact must
  /// not have their old aliases resurrected on the next start.
  bool _imported;
  ContactImportReport? _report;

  static const _fileName = 'freizone_contacts.json';

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  static Future<ContactStore> load() async {
    final file = await _file();
    if (!file.existsSync()) return ContactStore._({}, false, null);
    final j = json.decode(await file.readAsString()) as Map<String, dynamic>;
    final contacts = <String, Contact>{};
    for (final entry in (j['contacts'] as List<dynamic>?) ?? const []) {
      final contact = Contact.fromJson(entry as Map<String, dynamic>);
      contacts[contact.accountId] = contact;
    }
    return ContactStore._(
      contacts,
      j['imported'] as bool? ?? false,
      j['import_report'] == null
          ? null
          : ContactImportReport.fromJson(
              j['import_report'] as Map<String, dynamic>,
            ),
    );
  }

  Future<void> _save() async {
    final file = await _file();
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'contacts': [for (final c in _contacts.values) c.toJson()],
        'imported': _imported,
        if (_report != null) 'import_report': _report!.toJson(),
      }),
    );
  }

  /// Every contact, by name -- the order the contacts list shows them in.
  /// Case-insensitive, and ties broken by account id so the list cannot
  /// reshuffle between rebuilds (APP-10's rule).
  List<Contact> get contacts {
    final all = _contacts.values.toList();
    all.sort((a, b) {
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return byName != 0 ? byName : a.accountId.compareTo(b.accountId);
    });
    return all;
  }

  bool get isEmpty => _contacts.isEmpty;

  Contact? contact(String accountId) => _contacts[accountId];

  /// The assigned name for an account, or null if this device has not named
  /// them. The single question every screen asks this store.
  String? nameFor(String accountId) => _contacts[accountId]?.name;

  /// The import report, while it still has something to say.
  ContactImportReport? get pendingReport =>
      _report?.worthShowing == true ? _report : null;

  Future<void> dismissReport() async {
    if (_report == null) return;
    _report = null;
    await _save();
    notifyListeners();
  }

  /// Names an address, or renames it. [server] is only written when given, so
  /// renaming a contact never drops the server a resolution established.
  Future<void> setName(
    String accountId, {
    required String name,
    String? server,
  }) async {
    final existing = _contacts[accountId];
    _contacts[accountId] = existing == null
        ? Contact(
            accountId: accountId,
            name: name,
            server: server,
            // Stamped on creation only, so a rename does not reorder anything
            // that ever sorts by this.
            createdAt: DateTime.now().toUtc(),
          )
        : existing.copyWith(name: name, server: server);
    await _save();
    notifyListeners();
  }

  /// Forgets the name and nothing else -- no chat, history, media, session or
  /// block state is touched (the design document's deletion #1). Every screen
  /// that showed the name shows the short address again, exactly as it does for
  /// somebody never named.
  Future<void> remove(String accountId) async {
    if (_contacts.remove(accountId) == null) return;
    await _save();
    notifyListeners();
  }

  /// Lifts the aliases already assigned in each profile into this store, once.
  ///
  /// Without this, moving the source of truth would silently discard every name
  /// the user has ever assigned -- the names live in each account's profile, and
  /// this store is central.
  ///
  /// [aliasesByAccount] is each profile's own aliases, keyed by the profile's
  /// account id. Iterated in **sorted profile order** rather than whatever order
  /// the directory listed, so which name wins a collision is deterministic
  /// instead of depending on the filesystem.
  ///
  /// Servers come from [serversByAccount] where a profile recorded one; a
  /// missing entry leaves the contact's server null, which callers already
  /// handle by falling back to their own.
  Future<ContactImportReport> importAliases(
    Map<String, ProfileAliases> aliasesByAccount, {
    Map<String, String?> serversByAccount = const {},
  }) async {
    if (_imported) {
      return _report ?? const ContactImportReport(imported: 0, collisions: []);
    }

    var imported = 0;
    final collisions = <String, ContactNameCollision>{};
    final profileIds = aliasesByAccount.keys.toList()..sort();

    for (final profileId in profileIds) {
      for (final entry in aliasesByAccount[profileId]!.entries) {
        final peerId = entry.key;
        final name = entry.value.trim();
        if (name.isEmpty) continue;

        final existing = _contacts[peerId];
        if (existing == null) {
          _contacts[peerId] = Contact(
            accountId: peerId,
            name: name,
            server: serversByAccount[peerId],
            createdAt: DateTime.now().toUtc(),
          );
          imported++;
          continue;
        }
        // Already named by an earlier profile. The same name twice is not a
        // conflict -- two accounts simply agreeing -- and is not reported.
        if (existing.name == name) continue;
        final collision = collisions[peerId];
        collisions[peerId] = ContactNameCollision(
          accountId: peerId,
          kept: existing.name,
          discarded: [...?collision?.discarded, name],
        );
      }
    }

    _imported = true;
    _report = ContactImportReport(
      imported: imported,
      collisions: collisions.values.toList()
        ..sort((a, b) => a.accountId.compareTo(b.accountId)),
    );
    await _save();
    notifyListeners();
    return _report!;
  }

  /// Test seam: the same store without touching the filesystem.
  @visibleForTesting
  static ContactStore inMemory({
    List<Contact> contacts = const [],
    bool imported = false,
  }) => _InMemoryContactStore(
    {for (final c in contacts) c.accountId: c},
    imported,
  );
}

/// A [ContactStore] whose save is a no-op -- for tests, and for widget tests
/// that only ever read it.
class _InMemoryContactStore extends ContactStore {
  _InMemoryContactStore(Map<String, Contact> contacts, bool imported)
    : super._(contacts, imported, null);

  @override
  Future<void> _save() async {}
}
