// The invisible envelope that carries a group's membership and roles between
// members (APP-16, docs/PROTOCOL.md §12 in freizone-server).
//
// Sent over the exact same encrypted pipeline as a chat message, and like a
// receipt (receipt_signal.dart) or a re-key (rekey_signal.dart) it is never
// shown and never stored as a StoredMessage -- but it is still acknowledged
// and deleted from the queue like any other processed envelope.
//
// Own "v": 5, following the same reasoning as those two: "v": 1 stays chat
// text forever, 2 is receipts, 3 re-keys, 4 group chat content. A build that
// predates groups renders this as MessageContent.decode's "newer app feature"
// placeholder -- unavoidable, since an older build has no rule telling it to
// ignore an envelope it has never heard of, and self-limiting, since it could
// not have been in the group in the first place.
//
// The events themselves are deliberately opaque here. They are signed objects
// produced and verified by the native core, and this layer only carries them.
import 'dart:convert';
import 'dart:typed_data';

/// What a control envelope is for.
enum GroupControlKind {
  /// A few new facts, each carrying the certificate chain that authorizes it.
  /// The ordinary case.
  events('events'),

  /// The sender's whole fact set. What an invitee receives, since they have
  /// nothing to merge into -- and the answer to a state_hash mismatch, since
  /// union of a grow-only set converges without a delta protocol.
  snapshot('snapshot'),

  /// "Send me yours." Rarely needed, because a mismatch is normally answered
  /// unprompted, but it lets a member that knows it is behind ask.
  syncRequest('sync_request');

  const GroupControlKind(this.wireName);

  /// Spelled out rather than derived from [name]: this is a wire value other
  /// clients parse, so it must not follow Dart's camelCase or change if the
  /// enum is ever renamed.
  final String wireName;

  static GroupControlKind? fromWire(Object? value) {
    for (final k in GroupControlKind.values) {
      if (k.wireName == value) return k;
    }
    return null;
  }
}

class GroupControl {
  const GroupControl({
    required this.kind,
    required this.groupId,
    this.stateHash = '',
    this.events = const [],
  });

  final GroupControlKind kind;
  final String groupId;

  /// The sender's own state hash, so a mismatch is visible without a round
  /// trip to discover one.
  final String stateHash;

  /// Signed facts, passed through untouched. Only the native core reads
  /// inside them.
  final List<Map<String, dynamic>> events;

  static const version = 5;

  Uint8List encode() {
    final json = <String, dynamic>{
      'v': version,
      'kind': kind.wireName,
      'group_id': groupId,
      'state_hash': stateHash,
      if (events.isNotEmpty) 'events': events,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  /// Returns null for anything that isn't a well-formed group control
  /// envelope -- a chat message, a receipt, garbage, or a future shape -- so
  /// the caller falls through to its normal handling.
  ///
  /// A `group_id` is required even though the events carry their own: without
  /// one there is nothing to route the envelope to, and trusting the events to
  /// say where they belong would mean parsing them here, which is exactly what
  /// this layer does not do.
  static GroupControl? tryDecode(Uint8List bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['v'] != version) return null;

      final kind = GroupControlKind.fromWire(decoded['kind']);
      final groupId = decoded['group_id'];
      if (kind == null || groupId is! String || groupId.isEmpty) return null;

      return GroupControl(
        kind: kind,
        groupId: groupId,
        stateHash: decoded['state_hash'] as String? ?? '',
        events: _decodeEvents(decoded['events']),
      );
    } catch (_) {
      return null;
    }
  }

  /// A malformed entry is dropped rather than failing the envelope: the other
  /// facts in a snapshot still deserve to arrive, and every one of them is
  /// individually signed, so nothing is taken on the sender's word anyway.
  static List<Map<String, dynamic>> _decodeEvents(dynamic raw) {
    if (raw is! List || raw.isEmpty) return const [];
    final out = <Map<String, dynamic>>[];
    for (final entry in raw) {
      if (entry is Map<String, dynamic>) out.add(entry);
    }
    return out;
  }
}
