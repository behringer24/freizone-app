// The one-time lift of existing peer aliases into the central contact store
// (APP-19).
//
// Its own file, between ContactStore and the profiles, because the store is
// deliberately decoupled from per-account state: it takes plain maps, knows
// nothing about profiles, and is testable without building one.
//
// Why it has to exist at all: every name assigned so far lives in
// `conversation.display_name` inside each account's own profile. The store is
// central. Moving the source of truth without lifting them would silently
// discard every name the user ever assigned.
//
// It reads **raw profile JSON**, not AppState, and that is the load-bearing
// decision here. Phase 2 of APP-19 takes `display_name` off Conversation
// entirely -- at which point `Conversation.fromJson` stops reading the key, and
// an import that went through the parsed model would find nothing left to
// import. Reading the JSON makes this migration independent of the model it is
// migrating away from, and therefore independent of which release each of the
// two halves lands in.
import 'contact_store.dart';

/// Lifts every alias in [profileJson] into [store], once (the store itself
/// remembers whether it has run).
///
/// Two sources per profile, because a name can outlive its conversation:
///
/// - `conversations[…].display_name` -- the ordinary case;
/// - `blocked_peers[…].display_name` -- a peer whose chat was deleted while they
///   were blocked. That field exists purely so the blocked list could still show
///   a name with no conversation left, which is exactly what the contact store
///   now answers, so it is read here and then goes away.
Future<ContactImportReport> importExistingAliases(
  ContactStore store,
  Iterable<Map<String, dynamic>> profileJson,
) {
  final aliasesByAccount = <String, ProfileAliases>{};
  // Servers are collected across all profiles rather than per profile: the
  // contact is one address wherever it was seen from, and any profile that
  // recorded a server for it recorded the same one.
  final servers = <String, String?>{};

  for (final profile in profileJson) {
    final owner = profile['account_id'];
    if (owner is! String || owner.isEmpty) continue;
    final aliases = <String, String>{};

    // Keyed by peer account id in the profile, so the map key is the id even
    // when the entry itself is malformed.
    final conversations = profile['conversations'];
    if (conversations is Map) {
      conversations.forEach((peerId, entry) {
        if (peerId is! String || entry is! Map) return;
        final name = entry['display_name'];
        if (name is String && name.trim().isNotEmpty) aliases[peerId] = name;
        // Recorded even without a name: a later rename should not have to
        // re-resolve an address this device already knows where to reach.
        servers[peerId] ??= entry['peer_server'] as String?;
      });
    }

    final blocked = profile['blocked_peers'];
    if (blocked is List) {
      for (final entry in blocked) {
        if (entry is! Map) continue;
        final peerId = entry['peer_account_id'];
        if (peerId is! String || peerId.isEmpty) continue;
        final name = entry['display_name'];
        if (name is String && name.trim().isNotEmpty) {
          // A conversation's own alias wins within one profile -- it is the live
          // one, where the blocked entry is a snapshot taken at block time.
          aliases.putIfAbsent(peerId, () => name);
        }
        servers[peerId] ??= entry['peer_server'] as String?;
      }
    }

    if (aliases.isNotEmpty) aliasesByAccount[owner] = aliases;
  }

  return store.importAliases(aliasesByAccount, serversByAccount: servers);
}
